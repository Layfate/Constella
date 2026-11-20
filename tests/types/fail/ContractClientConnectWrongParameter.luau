--!strict
-- Type test: luau-lsp must report the error named on the expect line.
-- expect: Expected this to be 'string', but got 'number'
-- Never run: this file isn't part of any place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

-- CoinsChanged carries a number.
client:EventOf(Shop.CoinsChanged):Connect(function(coins: string)
	print(coins)
end)
local _ = server
