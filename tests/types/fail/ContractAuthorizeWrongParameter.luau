--!strict
-- Type test: luau-lsp must report the error named on the expect line.
-- expect: Expected this to be exactly 'boolean', but got 'string'
-- Never run: this file isn't part of any place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Constella = require(ReplicatedStorage.Packages.Constella)
local Contract = Constella.Network.Contract
local Check = Constella.Network.Check

local Shop = Contract.define({
	Namespace = "Shop",
	Purchase = Contract.fn({ Check.string(20) }) :: Constella.ContractFunction<(string), (string, number)>,
	CoinsChanged = Contract.event() :: Constella.ContractEvent<(number)>,
})
local server = Constella.Network.Server.new(Shop.Namespace)
local client = Constella.Network.Client.new(Shop.Namespace)
local player = Players:GetPlayers()[1]
local _ = player

-- Authorize receives the contract arguments.
local _ = server:FunctionOf(Shop.Purchase, {
	Authorize = function(_player: Player, itemId: boolean): boolean
		return itemId
	end,
})
local _ = client
