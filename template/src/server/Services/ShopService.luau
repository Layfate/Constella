--!strict
-- A server-authoritative shop. The client only says WHICH item it wants;
-- the price, the balance and the decision all live on the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared:WaitForChild("Items"))
local Net = require(Shared:WaitForChild("Net"))

local Check = Constella.Network.Check

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
	local purchase = server:Function(Net.Shop.Purchase, {
		-- Anything that isn't a known item id is rejected before the handler runs.
		Schema = { Check.literal(table.unpack(Items.Ids)) },
		RateLimit = { Count = 2, Per = 1 },
	})

	-- Returns the result ("Purchased", "NotEnoughCoins", "AlreadyOwned" or
	-- "NotLoaded") and the player's new balance.
	purchase:SetHandler(function(player: Player, itemId: string)
		local item = assert(Items.get(itemId), "the schema only lets known items through")
		local result = coins:Buy(player, item.Id, item.Price)
		if result == "Purchased" then
			logger:Info("Purchase", { Player = player.Name, Item = item.Id, Price = item.Price })
		end
		return result, coins:GetCoins(player)
	end)
end

return ShopService
