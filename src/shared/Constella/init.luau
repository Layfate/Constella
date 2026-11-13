--!strict
--[=[
	Constella - a modular Luau toolkit for Roblox.
	Made by Zense. MIT License.

	Every module is loaded lazily on first access, so
	`require(Constella).Signal` loads only Signal. Modules can also be
	required directly: `require(Constella.Signal)`.
]=]

local VERSION = "0.1.0"
local AUTHOR = "Zense"

-- Modules shipped in this version (key -> child ModuleScript name).
local AVAILABLE = {
	Core = "Core",
	Signal = "Signal",
	Cleanup = "Cleanup",
	State = "State",
	Random = "Random",
	Network = "Network",
	Component = "Component",
	Pool = "Pool",
	Zone = "Zone",
	Debug = "Debug",
	Promise = "Promise",
	Data = "Data",
	Replication = "Replication",
}

-- Modules on the roadmap. Accessing them raises a clear error instead of
-- returning a placeholder.
local PLANNED: { [string]: string } = {}

export type Constella = {
	Version: string,
	Author: string,
	Core: typeof(require(script.Core)),
	App: typeof(require(script.Core).App),
	Signal: typeof(require(script.Signal)),
	Cleanup: typeof(require(script.Cleanup)),
	State: typeof(require(script.State)),
	Random: typeof(require(script.Random)),
	Network: typeof(require(script.Network)),
	Component: typeof(require(script.Component)),
	Pool: typeof(require(script.Pool)),
	Zone: typeof(require(script.Zone)),
	Debug: typeof(require(script.Debug)),
	Promise: typeof(require(script.Promise)),
	Data: typeof(require(script.Data)),
	Replication: typeof(require(script.Replication)),
}

-- Loaded modules live here; the public table stays an empty proxy so every
-- write is rejected, even for keys that were already loaded.
local loaded: { [string]: any } = { Version = VERSION, Author = AUTHOR }

local Constella = setmetatable({}, {
	__index = function(_: any, key: any): any
		local cached = loaded[key]
		if cached ~= nil then
			return cached
		end
		if key == "App" then
			local core = loaded.Core or require(script:FindFirstChild("Core") :: any) :: any
			loaded.Core = core
			loaded.App = core.App
			return core.App
		end
		local childName = AVAILABLE[key]
		if childName then
			local module = require(script:FindFirstChild(childName) :: any) :: any
			loaded[key] = module
			return module
		end
		if PLANNED[key] then
			error(
				("[Constella] Constella.%s is not implemented in v%s (planned for %s)"):format(
					key,
					VERSION,
					PLANNED[key]
				),
				2
			)
		end
		error(("[Constella] '%s' is not a Constella module"):format(tostring(key)), 2)
	end,
	__newindex = function()
		error("[Constella] The Constella table is read-only", 2)
	end,
})

return (Constella :: any) :: Constella
