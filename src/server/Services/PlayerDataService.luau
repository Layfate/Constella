--!strict
-- Loads and saves player data with Constella.Data.
--
-- The demo uses MemoryAdapter, which is NOT persistent (data resets when the
-- server stops). For a real game, install ProfileStore and swap the adapter:
--
--   local ProfileStore = require(ServerScriptService.ProfileStore)
--   Adapter = Constella.Data.ProfileStoreAdapter.new(ProfileStore),

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Data = Constella.Data

local PlayerDataService = {
	Name = "PlayerDataService",
	Environment = "Server",

	Store = nil :: any, -- Data.Store, created in Init so dependents can connect to Loaded
}

function PlayerDataService.Init(self: any, _context: any)
	self.Store = Data.Store.new({
		Name = "DemoPlayerData",
		Version = 1,
		Template = {
			Coins = 0,
			WelcomeClaimed = false,
		},
		Adapter = Data.MemoryAdapter.new(),
		Logger = Constella.Debug.Logger.new("PlayerData"),
	})
end

function PlayerDataService.Start(self: any, _context: any)
	-- Loads players as they join, releases (and saves) them as they leave.
	self.Store:BindPlayers()
end

function PlayerDataService.Stop(self: any, _context: any)
	if self.Store then
		self.Store:Shutdown(15)
	end
end

return PlayerDataService
