--!strict
--[=[
	Constella.Data.ProfileStoreAdapter

	Runs Constella.Data on top of ProfileStore (by loleris), which provides
	the DataStore persistence, session locking, autosaving, retries and
	shutdown handling. Constella adds migrations, reconciliation, player
	lifecycle handling and observability on top.

	```lua
	local ProfileStore = require(ServerScriptService.ProfileStore) -- you install it
	local store = Data.Store.new({
		Name = "PlayerData",
		Template = { Coins = 0 },
		Adapter = Data.ProfileStoreAdapter.new(ProfileStore),
	})
	```

	Verified against ProfileStore 1.0.3 (lm-loleris/profilestore) in its
	mock mode; see docs/Data.md for what has and has not been verified.

	Save completion
	ProfileStore's Profile:Save() and Profile:EndSession() return at once
	and write on a separate thread; OnSessionEnd even fires before the final
	write. This adapter therefore waits for ProfileStore's OnAfterSave
	signal (fired after a successful write) so that, in Constella:
	- profile:Save() returns true only once a save has been written;
	- store:Release(player) returns once the final save has been written;
	- store:Shutdown(budget) measures real save completion.
	Both waits are capped by SaveTimeout (default 30 seconds). On timeout
	they return false; ProfileStore keeps retrying the write in the
	background, and its own BindToClose handler keeps the server alive
	until pending saves finish.

	Mock mode
	Pass { Mock = true } to use ProfileStore's in-memory mock store. Use it
	for tests in places with DataStore access, so tests never touch real
	data. ProfileStore's mock StartSessionAsync ignores the Cancel callback.
]=]

export type Options = {
	--- Use ProfileStore's mock store (in memory, never touches real data).
	Mock: boolean?,
	--- Seconds to wait for a save or the final save to be written. Defaults to 30.
	SaveTimeout: number?,
}

local DEFAULT_SAVE_TIMEOUT = 30

-- Resumes the waiting caller unless it was cancelled while it waited.
local function resume(thread: thread)
	if coroutine.status(thread) == "suspended" then
		task.spawn(thread)
	end
end

-- Runs `trigger` (which starts a ProfileStore save) and waits until that
-- save has been written. ProfileStore fires OnSave synchronously when a
-- save starts and OnAfterSave after it is written, so the first
-- OnAfterSave after our OnSave marks completion.
local function saveAndWait(profile: any, trigger: () -> (), timeout: number): (boolean, string?)
	local started = false
	local written = false
	local timedOut = false
	local waiter: thread? = nil

	local onSave = profile.OnSave:Connect(function()
		started = true
	end)
	local onAfterSave = profile.OnAfterSave:Connect(function()
		if started and not written and not timedOut then
			written = true
			if waiter then
				resume(waiter)
			end
		end
	end)
	local function disconnect()
		onSave:Disconnect()
		onAfterSave:Disconnect()
	end

	local ok, err = pcall(trigger :: any)
	if not ok then
		disconnect()
		return false, tostring(err)
	end
	if not started then
		disconnect()
		return false, "SessionEnded"
	end

	if not written then
		waiter = coroutine.running()
		local timer = task.delay(timeout, function()
			if not written then
				timedOut = true
				resume(waiter :: thread)
			end
		end)
		coroutine.yield()
		waiter = nil
		pcall(task.cancel, timer)
	end
	disconnect()

	if timedOut then
		return false, "SaveTimeout"
	end
	return true
end

local SessionClass = {}
SessionClass.__index = SessionClass

function SessionClass.IsActive(self: any): boolean
	return self._profile:IsActive()
end

function SessionClass.OnSessionEnd(self: any, callback: () -> ())
	self._profile.OnSessionEnd:Connect(callback)
end

--- Saves now and yields until the save has been written (or SaveTimeout).
function SessionClass.Save(self: any): (boolean, string?)
	local profile = self._profile
	if not profile:IsActive() then
		return false, "SessionEnded"
	end
	return saveAndWait(profile, function()
		profile:Save()
	end, self._saveTimeout)
end

--- Ends the session and yields until the final save has been written
--- (or SaveTimeout). Returns true at once if the session already ended.
function SessionClass.End(self: any): (boolean, string?)
	local profile = self._profile
	if not profile:IsActive() then
		return true
	end
	return saveAndWait(profile, function()
		profile:EndSession()
	end, self._saveTimeout)
end

local BackendClass = {}
BackendClass.__index = BackendClass

function BackendClass.StartSession(self: any, key: string, options: any): (any, string?)
	local shouldCancel = options and options.ShouldCancel
	local profile = self._store:StartSessionAsync(key, {
		Cancel = shouldCancel,
	})
	if profile == nil then
		if shouldCancel and shouldCancel() then
			return nil, "Cancelled"
		end
		return nil, "SessionUnavailable"
	end
	if options and options.UserId then
		-- Associates the data with the user for GDPR / right-to-erasure requests.
		pcall(profile.AddUserId, profile, options.UserId)
	end
	local session = setmetatable({
		_profile = profile,
		_saveTimeout = self._saveTimeout,
	}, SessionClass) :: any
	-- Constella replaces the contents of this table in place, so ProfileStore
	-- keeps saving the same table it handed out.
	session.Data = profile.Data
	return session
end

local AdapterClass = {}
AdapterClass.__index = AdapterClass

function AdapterClass.Open(self: any, name: string, template: { [any]: any }): any
	local store = self._profileStore.New(name, template)
	if self._mock then
		store = store.Mock
	end
	return setmetatable({ _store = store, _saveTimeout = self._saveTimeout }, BackendClass)
end

local ProfileStoreAdapter = {}

--- `profileStoreModule` is the result of require(ProfileStore).
function ProfileStoreAdapter.new(profileStoreModule: any, options: Options?): any
	if type(profileStoreModule) ~= "table" or type(profileStoreModule.New) ~= "function" then
		error("[Constella.Data] ProfileStoreAdapter.new expects the ProfileStore module (require(ProfileStore))", 2)
	end
	local saveTimeout = if options and options.SaveTimeout ~= nil then options.SaveTimeout else DEFAULT_SAVE_TIMEOUT
	if type(saveTimeout) ~= "number" or not (saveTimeout > 0) or saveTimeout == math.huge then
		error("[Constella.Data] SaveTimeout must be a positive number of seconds", 2)
	end
	return setmetatable({
		_profileStore = profileStoreModule,
		_mock = options ~= nil and options.Mock == true,
		_saveTimeout = saveTimeout,
	}, AdapterClass)
end

return table.freeze(ProfileStoreAdapter)
