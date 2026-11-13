--!strict
-- Shows the player's coins, replicated from the server, in an on-screen
-- label. The client only reads: the server owns the value.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))

local CoinsController = {
	Name = "CoinsController",
	Environment = "Client",

	Coins = nil :: any, -- read-only State<number?>
}

function CoinsController.Start(self: any, context: any)
	local replica = context.Cleanup:Add(Constella.Replication.Client.new("Player"))
	self.Coins = replica:Get("Coins")

	local gui = context.Cleanup:Add(Instance.new("ScreenGui"))
	gui.Name = "ConstellaCoins"
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(180, 40)
	label.Position = UDim2.new(0, 16, 1, -56)
	label.BackgroundTransparency = 0.3
	label.TextScaled = true
	label.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	context.Cleanup:Add(Constella.State.bind(label, "Text", self.Coins, function(value: number?)
		return if value then ("Coins: %d"):format(value) else "Coins: ..."
	end))
	context.Cleanup:Add(self.Coins:Observe(function(value: number?)
		if value then
			print(("[Demo] Coins: %d"):format(value))
		end
	end))
end

return CoinsController
