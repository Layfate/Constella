--!strict
-- Type test: luau-lsp must report the error named on the expect line.
-- expect: Expected this to be 'number', but got 'string'
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
	-- Coins is a number.
	profile:Mutate(function(data)
		data.Coins = "five"
	end)
end
