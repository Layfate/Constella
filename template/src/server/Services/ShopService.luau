--!strict
-- A server-authoritative shop. The client only says WHICH item it wants;
-- the price, the balance and the decision all live on the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared:WaitForChild("Items"))
local Net = require(Shared:WaitForChild("Net"))

-- A type-only import: the instance comes from context:Get.
type CoinsService = typeof(require(script.Parent.CoinsService))

local ShopService = {
	Name = "ShopService",
	Environment = "Server",
	Dependencies = { "CoinsService" },
}

export type ShopService = typeof(ShopService)

function ShopService.Init(_self: ShopService, context: Constella.Context)
	local coins: CoinsService = context:Get("CoinsService")
	local logger = Constella.Debug.Logger.new("ShopService")

	local server = context.Cleanup:Add(Constella.Network.Server.new(Net.Shop.Namespace, { Logger = logger }))
	-- The Schema comes from the shared contract; the rate limit stays here.
	local purchase = server:FunctionOf(Net.Shop.Purchase, {
		RateLimit = { Count = 2, Per = 1 },
	})

	-- Returns the result ("Purchased", "NotEnoughCoins", "AlreadyOwned" or
	-- "NotLoaded") and the player's new balance.
	-- The contract types the handler: itemId is a string, and it must
	-- return (string, number?).
	purchase:SetHandler(function(player, itemId)
		local item = assert(Items.get(itemId), "the schema only lets known items through")
		local result = coins:Buy(player, item.Id, item.Price)
		if result == "Purchased" then
			logger:Info("Purchase", { Player = player.Name, Item = item.Id, Price = item.Price })
		end
		return result, coins:GetCoins(player)
	end)
end

return ShopService
