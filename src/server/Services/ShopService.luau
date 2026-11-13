--!strict
-- A server-authoritative shop. The client only says WHAT it wants; prices,
-- balances and the decision all live on the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Network = Constella.Network
local Check = Network.Check

local CATALOG: { [string]: number } = {
	Sword = 10,
	Shield = 100,
}

local ShopService = {
	Name = "ShopService",
	Environment = "Server",
	Dependencies = { "RewardService" },
}

function ShopService.Init(_self: any, context: any)
	local rewards = context:Get("RewardService")
	local logger = Constella.Debug.Logger.new("ShopService")

	local server = context.Cleanup:Add(Network.Server.new("Shop", { Logger = logger }))

	local purchase = server:Function("Purchase", {
		Schema = { Check.literal("Sword", "Shield") },
		RateLimit = { Count = 2, Per = 1 },
	})

	purchase:SetHandler(function(player: Player, item: string)
		local price = CATALOG[item]
		if rewards:SpendCoins(player, price) then
			logger:Info("Purchase", { Player = player.Name, Item = item, Price = price })
			return "Purchased", rewards:GetCoins(player)
		end
		return "NotEnoughCoins", rewards:GetCoins(player)
	end)
end

return ShopService
