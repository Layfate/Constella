--!strict
--!nolint UnreachableCode
--[=[
	Constella - a modular Luau toolkit for Roblox.
	Made by Zense. MIT License.

	Every module is loaded lazily on first access, so
	`require(Constella).Signal` loads only Signal. Modules can also be
	required directly: `require(Constella.Signal)`.

	Every public type is also exported here (`Constella.Context`,
	`Constella.Store<T>`, ...); see the end of this file.
]=]

local VERSION = "0.3.7"
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

do
	return (Constella :: any) :: Constella
end

-- Public types ---------------------------------------------------------------
--
-- Re-exported so they can be used through the root module alone:
-- `local Constella = require(Packages.Constella)` then `Constella.Context`.
-- With Wally, re-export them into the link file with wally-package-types.
--
-- A module's exported types can only be read through a direct `require`, but
-- requiring every module here would undo lazy loading. These requires come
-- after the module has returned, so the type checker reads them and they
-- never run.

local Core = require(script.Core)
local Signal = require(script.Signal)
local Cleanup = require(script.Cleanup)
local State = require(script.State)
local Promise = require(script.Promise)
local Random = require(script.Random)
local Check = require(script.Network.Check)
local RateLimiter = require(script.Network.RateLimiter)
local NetworkServer = require(script.Network.Server)
local NetworkClient = require(script.Network.Client)
local Replication = require(script.Replication)
local Store = require(script.Data.Store)
local MemoryAdapter = require(script.Data.MemoryAdapter)
local ProfileStoreAdapter = require(script.Data.ProfileStoreAdapter)
local Component = require(script.Component)
local Pool = require(script.Pool)
local Zone = require(script.Zone)
local Debug = require(script.Debug)

-- Core
export type App = Core.App
export type AppOptions = Core.AppOptions
export type AppState = Core.AppState
export type AddModulesOptions = Core.AddModulesOptions
export type Context = Core.Context
export type Definition = Core.Definition
export type Environment = Core.Environment

-- Signal, Cleanup, State
export type Signal<T...> = Signal.Signal<T...>
export type Connection = Signal.Connection
export type SignalOptions = Signal.Options
export type Cleanup = Cleanup.Cleanup
export type Value<T> = State.Value<T>
export type Computed<T> = State.Computed<T>
export type StateOptions<T> = State.Options<T>

-- Promise
export type Promise<T = any> = Promise.Promise<T>
export type AnyPromise = Promise.AnyPromise
export type PromiseStatus = Promise.Status
export type PromiseError = Promise.PromiseError
export type PromiseErrorKind = Promise.ErrorKind
export type RetryOptions = Promise.RetryOptions

-- Random
export type LootEntry<T> = Random.Entry<T>
export type LootTable<T> = Random.LootTable<T>
export type Chance<T> = Random.Chance<T>
export type RollModifiers = Random.Modifiers

-- Network
export type Validator = Check.Validator
export type RateLimitConfig = RateLimiter.Config
export type NetworkServer = NetworkServer.Server
export type NetworkServerOptions = NetworkServer.ServerOptions
export type EndpointConfig = NetworkServer.EndpointConfig
export type EndpointStats = NetworkServer.EndpointStats
export type RejectReason = NetworkServer.RejectReason
export type ServerEvent = NetworkServer.ServerEvent
export type ServerFunction = NetworkServer.ServerFunction
export type NetworkClient = NetworkClient.Client
export type NetworkClientOptions = NetworkClient.ClientOptions
export type ClientEvent = NetworkClient.ClientEvent
export type ClientFunction = NetworkClient.ClientFunction
export type FunctionOptions = NetworkClient.FunctionOptions

-- Replication
export type ReplicationServer = Replication.ReplicationServer
export type ReplicationServerOptions = Replication.ServerOptions
export type ReplicationClient = Replication.ReplicationClient
export type ReplicationClientOptions = Replication.ClientOptions
export type ReplicationShare = Replication.Share

-- Data
export type Store<T = { [string]: any }> = Store.Store<T>
export type StoreConfig<T = { [string]: any }> = Store.Config<T>
export type StoreStats = Store.Stats
export type Profile<T = { [string]: any }> = Store.Profile<T>
export type DataAdapter = Store.Adapter
export type DataError = Store.DataError
export type DataErrorKind = Store.ErrorKind
export type MemoryAdapterOptions = MemoryAdapter.Options
export type ProfileStoreAdapterOptions = ProfileStoreAdapter.Options

-- Component, Pool, Zone
export type Component = Component.Component
export type ComponentDefinition = Component.Definition
export type ComponentObject = Component.Object
export type ComponentOptions = Component.Options
export type Pool<T> = Pool.Pool<T>
export type PoolOptions<T> = Pool.Options<T>
export type PoolStats = Pool.Stats
export type Zone = Zone.Zone
export type ZoneOptions = Zone.Options
export type ZoneShape = Zone.Shape
export type BoxShape = Zone.BoxShape
export type SphereShape = Zone.SphereShape

-- Debug
export type Logger = Debug.Logger
export type LoggerOptions = Debug.LoggerOptions
export type LogLevel = Debug.Level
export type LogRecord = Debug.LogRecord
export type Metrics = Debug.Metrics
export type MetricsSnapshot = Debug.MetricsSnapshot
export type Observation = Debug.Observation
