--!strict
-- Asks the server to buy items. The server decides; the client only shows
-- the answer.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))

local ShopController = {
	Name = "ShopController",
	Environment = "Client",
}

function ShopController.Start(self: any, _context: any)
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
