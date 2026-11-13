--!strict
--[=[
	Constella.Data (server only)

	- Data.Store               - player profiles: migrations, reconciliation,
	                             lifecycle, session loss, shutdown budget
	- Data.ProfileStoreAdapter - production backend (you install ProfileStore)
	- Data.MemoryAdapter       - in-memory backend for Studio tests and
	                             failure simulation (not persistent)

	Constella does not implement its own DataStore session locking. Use
	ProfileStore for real player data.
]=]

export type Data = {
	Store: typeof(require(script.Store)),
	ProfileStoreAdapter: typeof(require(script.ProfileStoreAdapter)),
	MemoryAdapter: typeof(require(script.MemoryAdapter)),
}

local PARTS = {
	Store = true,
	ProfileStoreAdapter = true,
	MemoryAdapter = true,
}

local loaded: { [string]: any } = {}

local Data = setmetatable({}, {
	__index = function(_: any, key: any): any
		local cached = loaded[key]
		if cached ~= nil then
			return cached
		end
		if PARTS[key] then
			local module = require(script:FindFirstChild(key) :: any) :: any
			loaded[key] = module
			return module
		end
		error(("[Constella.Data] '%s' is not part of Constella.Data"):format(tostring(key)), 2)
	end,
	__newindex = function()
		error("[Constella.Data] Constella.Data is read-only", 2)
	end,
})

return (Data :: any) :: Data
