--!strict
-- Asks the server to buy items. The server decides; the client only shows
-- the answer.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Constella = require(Packages:WaitForChild("Constella"))
-- Required directly only for its exported types; Constella loads the same module.
local Core = require(Packages.Constella.Core)

local ShopController = {
	Name = "ShopController",
	Environment = "Client",
}

function ShopController.Start(_self: typeof(ShopController), _context: Core.Context)
	local shop = Constella.Network.Client.new("Shop")
	local purchase = shop:Function("Purchase", { Timeout = 5 })

	task.wait(1) -- give the welcome reward time to arrive
	for _, item in { "Sword", "Shield" } do
		local ok, result, balance = purchase:Invoke(item)
		if ok then
			print(("[Demo] Buy %s: %s (balance %s)"):format(item, result, tostring(balance)))
		else
			warn(("[Demo] Buy %s failed: %s"):format(item, tostring(result)))
		end
	end
end

return ShopController
