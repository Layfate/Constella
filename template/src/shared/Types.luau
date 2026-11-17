--!strict
-- Every Constella type the game uses, imported in one place.
--
-- Exported types can only be read from a module that is required directly,
-- so this requires Constella's submodules by path. They are the same
-- modules `Constella.X` loads, so nothing is loaded twice.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ConstellaModule = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella")
local Cleanup = require(ConstellaModule:WaitForChild("Cleanup"))
local Core = require(ConstellaModule:WaitForChild("Core"))
local Network = ConstellaModule:WaitForChild("Network")
local NetworkClient = require(Network:WaitForChild("Client"))
local NetworkServer = require(Network:WaitForChild("Server"))
local Replication = require(ConstellaModule:WaitForChild("Replication"))
local State = require(ConstellaModule:WaitForChild("State"))
local Store = require(ConstellaModule:WaitForChild("Data"):WaitForChild("Store"))

export type Context = Core.Context
export type Cleanup = Cleanup.Cleanup

export type Value<T> = State.Value<T>
export type Computed<T> = State.Computed<T>

export type Store<T> = Store.Store<T>
export type Profile<T> = Store.Profile<T>

export type NetworkServer = NetworkServer.Server
export type NetworkClient = NetworkClient.Client
export type ReplicationServer = Replication.ReplicationServer
export type ReplicationClient = Replication.ReplicationClient

return nil
