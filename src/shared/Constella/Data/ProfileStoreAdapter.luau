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

	Constella does not ship ProfileStore. This adapter uses its public API:
	ProfileStore.New(name, template), store:StartSessionAsync(key, { Cancel }),
	profile.Data, profile:IsActive(), profile:Save(), profile:EndSession(),
	profile.OnSessionEnd:Connect(fn) and profile:AddUserId(userId).
]=]

local SessionClass = {}
SessionClass.__index = SessionClass

function SessionClass.IsActive(self: any): boolean
	return self._profile:IsActive()
end

function SessionClass.OnSessionEnd(self: any, callback: () -> ())
	self._profile.OnSessionEnd:Connect(callback)
end

--- Requests a save. ProfileStore saves asynchronously and retries itself.
function SessionClass.Save(self: any): (boolean, string?)
	if not self._profile:IsActive() then
		return false, "SessionEnded"
	end
	self._profile:Save()
	return true
end

--- Ends the session. ProfileStore performs the final save and releases the lock.
function SessionClass.End(self: any): (boolean, string?)
	if self._profile:IsActive() then
		self._profile:EndSession()
	end
	return true
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
	local session = setmetatable({ _profile = profile }, SessionClass) :: any
	-- Constella replaces the contents of this table in place, so ProfileStore
	-- keeps saving the same table it handed out.
	session.Data = profile.Data
	return session
end

local AdapterClass = {}
AdapterClass.__index = AdapterClass

function AdapterClass.Open(self: any, name: string, template: { [any]: any }): any
	return setmetatable({ _store = self._profileStore.New(name, template) }, BackendClass)
end

local ProfileStoreAdapter = {}

--- `profileStoreModule` is the result of require(ProfileStore).
function ProfileStoreAdapter.new(profileStoreModule: any): any
	if type(profileStoreModule) ~= "table" or type(profileStoreModule.New) ~= "function" then
		error("[Constella.Data] ProfileStoreAdapter.new expects the ProfileStore module (require(ProfileStore))", 2)
	end
	return setmetatable({ _profileStore = profileStoreModule }, AdapterClass)
end

return table.freeze(ProfileStoreAdapter)
