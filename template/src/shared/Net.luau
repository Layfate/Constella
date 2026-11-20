--!strict
-- Shared by the server and the client, so the two sides can't drift apart.
--
-- Shop is a Network contract: each endpoint's argument Schema (checked by
-- the server before any handler runs) and its types (checked by luau-lsp on
-- both sides). Rate limits and handlers stay on the server. Clients can read
-- this module, so it holds nothing secret: a Schema only checks the shape
-- of a request. Decisions that need server-only knowledge (prices, balances,
-- ownership) are made in the server's handler.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Items = require(script.Parent:WaitForChild("Items"))

local Contract = Constella.Network.Contract
local Check = Constella.Network.Check

return table.freeze({
	Shop = Contract.define({
		Namespace = "Shop",
		-- (itemId) -> (result, balance). Anything that isn't a known item id
		-- is rejected before the handler runs. The balance is nil until the
		-- player's data has loaded.
		Purchase = Contract.fn({ Check.literal(table.unpack(Items.Ids)) }) :: Constella.ContractFunction<(string), (string, number?)>,
	}),

	-- Replication namespace and the values shared through it.
	Player = table.freeze({
		Namespace = "Player",
		Coins = "Coins",
		Items = "Items",
	}),
})
