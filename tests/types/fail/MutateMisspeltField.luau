--!strict
-- Type test: luau-lsp must report the error named on the expect line.
-- expect: Cannot add property 'Coinz' to table 'PlayerData'
-- Never run: this file isn't part of any place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Constella = require(ReplicatedStorage.Packages.Constella)

type PlayerData = { Coins: number }
local store: Constella.Store<PlayerData> = Constella.Data.Store.new({
	Name = "PlayerData",
	Template = { Coins = 0 },
	Adapter = Constella.Data.MemoryAdapter.new(),
})
local profile = store:Get(Players:GetPlayers()[1])
if profile then
	-- Misspelt field.
	profile:Mutate(function(data)
		data.Coinz = 5
	end)
end
