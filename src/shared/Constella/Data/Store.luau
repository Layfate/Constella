--!strict
--[=[
	Constella.Data.Store

	Player data on top of an adapter (ProfileStoreAdapter in production,
	MemoryAdapter for testing).

	Load pipeline (LoadAsync)
	1. Start a session through the adapter, retrying with backoff
	   (LoadAttempts, RetryDelay). Cancelled if the player leaves.
	2. Validate and migrate. Data without a version is version 0;
	   Migrations[n] upgrades version n to n+1. Migrations run on a copy.
	3. Reconcile: add template keys that are missing. Existing values are
	   never overwritten.
	4. Commit the migrated copy into the session and fire Loaded.

	Never overwrite on failure
	If any step fails - load, corrupt data, data from a NEWER game version,
	a missing or failing migration - the session is ended WITHOUT changing
	the stored data, the profile is not handed out, and (by default) the
	player is kicked. A player never plays on template data that could
	later be saved over their real data.

	Session loss
	If the backend ends a session (for example the player joined another
	server, which took the session over), the profile becomes inactive,
	writes through it raise, Released fires and the player is kicked if
	still here.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Signal)
local Promise = require(script.Parent.Parent.Promise)
local Util = require(script.Parent.Util)

export type ErrorKind =
	"LoadFailed"
	| "PlayerLeft"
	| "Released"
	| "CorruptData"
	| "NewerVersion"
	| "MissingMigration"
	| "MigrationFailed"
	| "ShuttingDown"

export type DataError = {
	Kind: ErrorKind,
	Message: string,
}

export type Config = {
	--- Store name, passed to the adapter (DataStore name for ProfileStore).
	Name: string,
	--- Default data. New profiles start as a copy; old ones gain missing keys.
	Template: { [string]: any },
	--- Backend: Data.ProfileStoreAdapter.new(ProfileStore) or Data.MemoryAdapter.new().
	Adapter: any,
	--- Current data version (integer >= 1). Defaults to 1.
	Version: number?,
	--- Migrations[n](data) upgrades version n to n+1. May mutate `data`
	--- or return a replacement table.
	Migrations: { [number]: (data: any) -> any }?,
	--- Session start attempts before giving up. Defaults to 3.
	LoadAttempts: number?,
	--- Seconds before the first retry; doubles each time. Defaults to 1.
	RetryDelay: number?,
	--- Kick players whose data cannot be loaded. Defaults to true.
	KickOnFailure: boolean?,
	--- Builds the storage key. Defaults to "Player_<UserId>".
	Key: ((player: Player) -> string)?,
	Logger: any?,
	OnError: ((message: string) -> ())?,
}

export type Profile = {
	Player: Player,
	Key: string,
	Data: { [string]: any },
	Changed: Signal.Signal<string, any, any>,
	Get: (self: any, key: string) -> any,
	Set: (self: any, key: string, value: any) -> (),
	Update: (self: any, key: string, updater: (current: any) -> any) -> (),
	Save: (self: any) -> boolean,
	IsActive: (self: any) -> boolean,
	Release: (self: any) -> (),
}

export type Stats = {
	Loaded: number,
	Loading: number,
	LoadsSucceeded: number,
	LoadsFailed: number,
	SessionsLost: number,
}

export type Store = {
	Name: string,
	Loaded: Signal.Signal<Player, Profile>,
	Released: Signal.Signal<Player>,
	LoadAsync: (self: any, player: Player) -> any,
	Get: (self: any, player: Player) -> Profile?,
	Release: (self: any, player: Player) -> (),
	BindPlayers: (self: any) -> (),
	Shutdown: (self: any, budgetSeconds: number?) -> boolean,
	GetStats: (self: any) -> Stats,
}

local PREFIX = "[Constella.Data] "
local VERSION_KEY = "_ConstellaVersion"
local DEFAULT_KICK_MESSAGE = "Your data could not be loaded. Please rejoin in a moment."
local SESSION_LOST_MESSAGE = "Your data was loaded on another server. Please rejoin."

-- Errors --------------------------------------------------------------------

local ErrorClass = {}
ErrorClass.__index = ErrorClass
ErrorClass.__tostring = function(self: any): string
	return ("%s%s: %s"):format(PREFIX, self.Kind, self.Message)
end

local function dataError(kind: ErrorKind, message: string): DataError
	return (setmetatable({ Kind = kind, Message = message }, ErrorClass) :: any) :: DataError
end

local function isInGame(player: any): boolean
	return player.Parent ~= nil
end

-- Profile -------------------------------------------------------------------

local ProfileClass = {}
ProfileClass.__index = ProfileClass

local function checkActive(self: any, level: number)
	if not self._active then
		error(PREFIX .. ("The profile for %s is no longer active"):format(tostring(self.Key)), level)
	end
end

function ProfileClass.Get(self: any, key: string): any
	return self.Data[key]
end

function ProfileClass.Set(self: any, key: string, value: any)
	checkActive(self, 3)
	local old = self.Data[key]
	if old == value then
		return
	end
	self.Data[key] = value
	self.Changed:Fire(key, value, old)
end

function ProfileClass.Update(self: any, key: string, updater: (any) -> any)
	checkActive(self, 3)
	if type(updater) ~= "function" then
		error(PREFIX .. "Update expects a function", 2)
	end
	ProfileClass.Set(self, key, updater(self.Data[key]))
end

--- Requests a save now. Returns false if the session is gone or the save failed.
function ProfileClass.Save(self: any): boolean
	if not self._active then
		return false
	end
	local ok, saved, reason = pcall(self._session.Save, self._session)
	if not ok or not saved then
		self._store:_report(("Save failed for %s: %s"):format(self.Key, tostring(if ok then reason else saved)))
		return false
	end
	return true
end

function ProfileClass.IsActive(self: any): boolean
	return self._active
end

function ProfileClass.Release(self: any)
	self._store:Release(self.Player)
end

-- Store ---------------------------------------------------------------------

local StoreClass = {}
StoreClass.__index = StoreClass

function StoreClass._report(self: any, message: string)
	if self._logger then
		self._logger:Error(message, { Store = self.Name })
	end
	self._onError(PREFIX .. message)
end

function StoreClass._log(self: any, message: string, fields: { [string]: any }?)
	if self._logger then
		self._logger:Info(message, fields)
	end
end

-- Validates, migrates and reconciles the session data. Returns the
-- prepared copy, or nil and a DataError. Never touches session.Data.
function StoreClass._prepare(self: any, data: any): (any, DataError?)
	if type(data) ~= "table" then
		return nil, dataError("CorruptData", ("stored data is a %s, not a table"):format(typeof(data)))
	end
	local version = data[VERSION_KEY]
	if version == nil then
		version = 0
	end
	if type(version) ~= "number" or version % 1 ~= 0 or version < 0 then
		return nil, dataError("CorruptData", ("invalid stored version %s"):format(tostring(version)))
	end
	local target = self._version
	if version > target then
		return nil,
			dataError(
				"NewerVersion",
				("stored data is version %d but this server only understands up to %d"):format(version, target)
			)
	end

	local working = Util.deepCopy(data)
	while version < target do
		local migrate = self._migrations[version]
		if migrate == nil then
			return nil, dataError("MissingMigration", ("no migration from version %d to %d"):format(version, version + 1))
		end
		local ok, result = xpcall(migrate, function(err)
			return debug.traceback(tostring(err), 2)
		end, working)
		if not ok then
			return nil, dataError("MigrationFailed", ("migration %d -> %d failed: %s"):format(version, version + 1, tostring(result)))
		end
		if result ~= nil then
			if type(result) ~= "table" then
				return nil, dataError("MigrationFailed", ("migration %d -> %d returned a %s"):format(version, version + 1, typeof(result)))
			end
			working = result
		end
		version += 1
	end
	working[VERSION_KEY] = target
	Util.reconcile(working, self._template)
	return working
end

local function endSession(self: any, session: any, key: string)
	local ok, saved, reason = pcall(session.End, session)
	if not ok or saved == false then
		self:_report(("Ending the session for %s failed: %s"):format(key, tostring(if ok then reason else saved)))
	end
end

local function kick(self: any, player: any, message: string)
	if self._kickOnFailure and isInGame(player) then
		pcall(player.Kick, player, message)
	end
end

local function onSessionLost(self: any, player: any, profile: any)
	if not profile._active then
		return
	end
	profile._active = false
	if self._profiles[player] == profile then
		self._profiles[player] = nil
	end
	self._stats.SessionsLost += 1
	self:_log("Session ended by the backend", { Key = profile.Key })
	profile.Changed:Destroy()
	self.Released:Fire(player)
	if isInGame(player) and not profile._releasing then
		kick(self, player, SESSION_LOST_MESSAGE)
	end
end

--- Loads (or returns the already loading/loaded) profile for `player`.
--- Returns a Promise that resolves with the Profile or rejects with a DataError.
function StoreClass.LoadAsync(self: any, player: Player): any
	if self._closing then
		return Promise.reject(dataError("ShuttingDown", "the store is shutting down"))
	end
	local loaded = self._profiles[player]
	if loaded then
		return Promise.resolve(loaded)
	end
	local loading = self._loading[player]
	if loading then
		return loading
	end

	local key = self._keyFor(player)
	self._cancelled[player] = nil

	local function shouldCancel(): boolean
		return self._closing or self._cancelled[player] == true or not isInGame(player)
	end

	local promise = Promise.retry(function()
		return Promise.new(function(resolve, reject)
			local session, reason = self._backend:StartSession(key, {
				UserId = (player :: any).UserId,
				ShouldCancel = shouldCancel,
			})
			if session then
				resolve(session)
			else
				reject(reason or "SessionUnavailable")
			end
		end)
	end, {
		Attempts = self._attempts,
		Delay = self._retryDelay,
		Backoff = 2,
		ShouldRetry = function(reason)
			return reason ~= "Cancelled" and not shouldCancel()
		end,
	})
		:Catch(function(reason)
			if Promise.isError(reason) or getmetatable(reason) == ErrorClass then
				return Promise.reject(reason)
			end
			if reason == "Cancelled" or shouldCancel() then
				return Promise.reject(dataError("PlayerLeft", "loading was cancelled"))
			end
			return Promise.reject(dataError("LoadFailed", ("could not start a session: %s"):format(tostring(reason))))
		end)
		:Then(function(session)
			if shouldCancel() then
				endSession(self, session, key)
				local kind: ErrorKind = if self._closing
					then "ShuttingDown"
					elseif self._cancelled[player] and isInGame(player) then "Released"
					else "PlayerLeft"
				return Promise.reject(dataError(kind, "loading was cancelled"))
			end
			local prepared, problem = self:_prepare(session.Data)
			if prepared == nil then
				-- End WITHOUT applying anything: the stored data is untouched.
				endSession(self, session, key)
				return Promise.reject(problem)
			end
			Util.replaceContents(session.Data, prepared)

			local profile = setmetatable({
				Player = player,
				Key = key,
				Data = session.Data,
				Changed = Signal.new(),
				_session = session,
				_store = self,
				_active = true,
				_releasing = false,
			}, ProfileClass)
			self._profiles[player] = profile
			session:OnSessionEnd(function()
				onSessionLost(self, player, profile)
			end)
			return profile
		end)

	self._loading[player] = promise
	promise:Then(function(profile)
		self._loading[player] = nil
		self._stats.LoadsSucceeded += 1
		self:_log("Profile loaded", { Key = key })
		self.Loaded:Fire(player, profile)
	end, function(problem)
		self._loading[player] = nil
		local kind = if type(problem) == "table" then problem.Kind else nil
		if kind == "PlayerLeft" or kind == "ShuttingDown" or kind == "Released" then
			return
		end
		self._stats.LoadsFailed += 1
		self:_report(("Could not load %s: %s"):format(key, tostring(problem)))
		kick(self, player, self._kickMessage)
	end)
	return promise
end

function StoreClass.Get(self: any, player: Player): any
	return self._profiles[player]
end

--- Ends the player's session (the adapter performs the final save).
--- Cancels a load that is still in progress.
function StoreClass.Release(self: any, player: Player)
	if self._loading[player] then
		self._cancelled[player] = true
	end
	local profile = self._profiles[player]
	if profile == nil then
		return
	end
	self._profiles[player] = nil
	profile._releasing = true
	profile._active = false
	endSession(self, profile._session, profile.Key)
	profile.Changed:Destroy()
	self:_log("Profile released", { Key = profile.Key })
	self.Released:Fire(player)
end

--- Loads players as they join and releases them as they leave.
function StoreClass.BindPlayers(self: any)
	if self._bound then
		return
	end
	self._bound = true
	local function load(player: Player)
		self:LoadAsync(player):Catch(function() end) -- failures are reported and handled by the store
	end
	table.insert(self._connections, Players.PlayerAdded:Connect(load))
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self:Release(player)
	end))
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
end

--- Stops new loads and releases every profile, waiting at most
--- `budgetSeconds` (default 20) for sessions to end. Returns true if all
--- sessions ended within the budget. Call it from game:BindToClose.
function StoreClass.Shutdown(self: any, budgetSeconds: number?): boolean
	self._closing = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	for player in self._loading do
		self._cancelled[player] = true
	end

	local players = {}
	for player in self._profiles do
		table.insert(players, player)
	end
	local pending = #players
	for _, player in players do
		task.spawn(function()
			self:Release(player)
			pending -= 1
		end)
	end
	local deadline = os.clock() + (budgetSeconds or 20)
	while pending > 0 and os.clock() < deadline do
		task.wait()
	end
	if pending > 0 then
		self:_report(("Shutdown budget exceeded with %d session(s) still ending"):format(pending))
		return false
	end
	return true
end

function StoreClass.GetStats(self: any): Stats
	local loading = 0
	for _ in self._loading do
		loading += 1
	end
	local loaded = 0
	for _ in self._profiles do
		loaded += 1
	end
	return {
		Loaded = loaded,
		Loading = loading,
		LoadsSucceeded = self._stats.LoadsSucceeded,
		LoadsFailed = self._stats.LoadsFailed,
		SessionsLost = self._stats.SessionsLost,
	}
end

local Store = {}

function Store.new(config: Config): Store
	if RunService:IsRunning() and not RunService:IsServer() then
		error(PREFIX .. "Data.Store can only be used on the server", 2)
	end
	if type(config) ~= "table" then
		error(PREFIX .. "Store.new expects a config table", 2)
	end
	if type(config.Name) ~= "string" or config.Name == "" then
		error(PREFIX .. "Config.Name must be a non-empty string", 2)
	end
	if type(config.Template) ~= "table" then
		error(PREFIX .. "Config.Template must be a table", 2)
	end
	if config.Template[VERSION_KEY] ~= nil then
		error(PREFIX .. ("Config.Template must not contain the reserved key %s"):format(VERSION_KEY), 2)
	end
	if type(config.Adapter) ~= "table" or type(config.Adapter.Open) ~= "function" then
		error(PREFIX .. "Config.Adapter must be a Data adapter (ProfileStoreAdapter or MemoryAdapter)", 2)
	end
	local version = config.Version or 1
	if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then
		error(PREFIX .. "Config.Version must be an integer >= 1", 2)
	end
	local migrations = config.Migrations or {}
	if type(migrations) ~= "table" then
		error(PREFIX .. "Config.Migrations must be a table", 2)
	end
	for from, migrate in migrations do
		if type(from) ~= "number" or from % 1 ~= 0 or from < 0 or from >= version then
			error(PREFIX .. ("Migration key %s must be an integer from 0 to %d"):format(tostring(from), version - 1), 2)
		end
		if type(migrate) ~= "function" then
			error(PREFIX .. ("Migrations[%d] must be a function"):format(from), 2)
		end
	end
	local attempts = config.LoadAttempts or 3
	if type(attempts) ~= "number" or attempts < 1 or attempts % 1 ~= 0 then
		error(PREFIX .. "Config.LoadAttempts must be a positive integer", 2)
	end
	local retryDelay = config.RetryDelay or 1
	if type(retryDelay) ~= "number" or retryDelay < 0 or retryDelay ~= retryDelay then
		error(PREFIX .. "Config.RetryDelay must be a non-negative number", 2)
	end
	if config.Key ~= nil and type(config.Key) ~= "function" then
		error(PREFIX .. "Config.Key must be a function", 2)
	end

	-- New profiles start at the current version.
	local template = Util.deepCopy(config.Template)
	local adapterTemplate = Util.deepCopy(template)
	adapterTemplate[VERSION_KEY] = version

	local self = setmetatable({
		Name = config.Name,
		Loaded = Signal.new(),
		Released = Signal.new(),
		_backend = config.Adapter:Open(config.Name, adapterTemplate),
		_template = template,
		_version = version,
		_migrations = table.clone(migrations),
		_attempts = attempts,
		_retryDelay = retryDelay,
		_kickOnFailure = config.KickOnFailure ~= false,
		_kickMessage = DEFAULT_KICK_MESSAGE,
		_keyFor = config.Key or function(player: any): string
			return "Player_" .. tostring(player.UserId)
		end,
		_logger = config.Logger,
		_onError = config.OnError or function(message: string)
			task.spawn(error, message, 0)
		end,
		_profiles = {},
		_loading = {},
		_cancelled = {},
		_connections = {},
		_bound = false,
		_closing = false,
		_stats = { LoadsSucceeded = 0, LoadsFailed = 0, SessionsLost = 0 },
	}, StoreClass)
	return (self :: any) :: Store
end

Store.VERSION_KEY = VERSION_KEY

--- True if `value` is a Data error, optionally of the given Kind.
function Store.isError(value: any, kind: ErrorKind?): boolean
	if type(value) ~= "table" or getmetatable(value) ~= ErrorClass then
		return false
	end
	return kind == nil or value.Kind == kind
end

return table.freeze(Store)
