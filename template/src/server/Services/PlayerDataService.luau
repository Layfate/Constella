--!strict
-- Loads and saves player data. Other services read profiles from `Store`
-- and listen to `Store.Loaded` / `Store.Released`.
--
-- MemoryAdapter is NOT persistent: data resets when the server stops. Before
-- you publish, install ProfileStore and swap the adapter:
--
--   local ProfileStore = require(ServerScriptService.ProfileStore)
--   Adapter = Data.ProfileStoreAdapter.new(ProfileStore),

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

local Data = Constella.Data

export type PlayerData = {
	Coins: number,
	WelcomeClaimed: boolean,
	--- Owned item ids. Stored as a set so it saves and replicates cleanly.
	Items: { [string]: true },
}

local TEMPLATE: PlayerData = {
	Coins = 0,
	WelcomeClaimed = false,
	Items = {},
}

local PlayerDataService = {
	Name = "PlayerDataService",
	Environment = "Server",

	-- Created in Init so dependents can connect to Loaded in their own Init.
	Store = (nil :: any) :: Types.Store<PlayerData>,
}

export type PlayerDataService = typeof(PlayerDataService)

function PlayerDataService.Init(self: PlayerDataService, _context: Types.Context)
	self.Store = Data.Store.new({
		Name = "PlayerData",
		Version = 1,
		Template = TEMPLATE,
		Adapter = Data.MemoryAdapter.new(),
		Logger = Constella.Debug.Logger.new("PlayerData"),
	})
end

function PlayerDataService.Start(self: PlayerDataService, _context: Types.Context)
	-- Loads players as they join, releases (and saves) them as they leave.
	self.Store:BindPlayers()
end

function PlayerDataService.Stop(self: PlayerDataService, _context: Types.Context)
	-- Stop also runs after a failed startup, when Init may not have finished.
	if self.Store then
		self.Store:Shutdown(15)
	end
end

return PlayerDataService
