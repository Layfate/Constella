--!strict
-- Loads and saves player data with Constella.Data.
--
-- The demo uses MemoryAdapter, which is NOT persistent (data resets when the
-- server stops). For a real game, install ProfileStore and swap the adapter:
--
--   local ProfileStore = require(ServerScriptService.ProfileStore)
--   Adapter = Constella.Data.ProfileStoreAdapter.new(ProfileStore),

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Constella = require(Packages:WaitForChild("Constella"))
-- Required directly only for their exported types; Constella loads the same modules.
local Core = require(Packages.Constella.Core)
local Store = require(Packages.Constella.Data.Store)

local Data = Constella.Data

export type PlayerData = {
	Coins: number,
	WelcomeClaimed: boolean,
}

local TEMPLATE: PlayerData = {
	Coins = 0,
	WelcomeClaimed = false,
}

local PlayerDataService = {
	Name = "PlayerDataService",
	Environment = "Server",

	-- Created in Init so dependents can connect to Loaded in their own Init.
	Store = (nil :: any) :: Store.Store<PlayerData>,
}

export type PlayerDataService = typeof(PlayerDataService)

function PlayerDataService.Init(self: PlayerDataService, _context: Core.Context)
	self.Store = Data.Store.new({
		Name = "DemoPlayerData",
		Version = 1,
		Template = TEMPLATE,
		Adapter = Data.MemoryAdapter.new(),
		Logger = Constella.Debug.Logger.new("PlayerData"),
	})
end

function PlayerDataService.Start(self: PlayerDataService, _context: Core.Context)
	-- Loads players as they join, releases (and saves) them as they leave.
	self.Store:BindPlayers()
end

function PlayerDataService.Stop(self: PlayerDataService, _context: Core.Context)
	-- Stop also runs after a failed startup, when Init may not have finished.
	if self.Store then
		self.Store:Shutdown(15)
	end
end

return PlayerDataService
