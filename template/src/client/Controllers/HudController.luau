--!strict
-- A minimal HUD: the coin balance and one buy button per item. The client
-- only displays and asks; the server owns the values and decides.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared:WaitForChild("Items"))
local Net = require(Shared:WaitForChild("Net"))

local State = Constella.State

type PlayerStateController = typeof(require(script.Parent.PlayerStateController))

local HudController = {
	Name = "HudController",
	Environment = "Client",
	Dependencies = { "PlayerStateController" },
}

export type HudController = typeof(HudController)

local function makeLabel(parent: Instance, order: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(200, 36)
	label.BackgroundTransparency = 0.3
	label.TextScaled = true
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

function HudController.Start(_self: HudController, context: Constella.Context)
	local playerState: PlayerStateController = context:Get("PlayerStateController")
	local purchase = context.Cleanup
		:Add(Constella.Network.Client.new(Net.Shop.Namespace))
		:Function(Net.Shop.Purchase, { Timeout = 5 })

	local gui = context.Cleanup:Add(Instance.new("ScreenGui"))
	gui.Name = "Hud"
	gui.ResetOnSpawn = false

	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.Position = UDim2.new(0, 16, 1, -16)
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Parent = frame

	local coinsLabel = makeLabel(frame, 0)
	context.Cleanup:Add(State.bind(coinsLabel, "Text", playerState.Coins, function(coins: number?)
		return if coins then ("Coins: %d"):format(coins) else "Coins: ..."
	end))

	for index, item in Items.List do
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(200, 36)
		button.TextScaled = true
		button.LayoutOrder = index
		button.Parent = frame

		-- Recomputes whenever the balance or the owned items change.
		local text = context.Cleanup:Add(
			State.computed(
				{ playerState.Coins, playerState.Items },
				function(coins: number?, owned: { [string]: true }?): string
					if owned and owned[item.Id] then
						return ("%s (owned)"):format(item.DisplayName)
					end
					local suffix = if coins and coins < item.Price then " - need more coins" else ""
					return ("Buy %s: %d%s"):format(item.DisplayName, item.Price, suffix)
				end
			)
		)
		context.Cleanup:Add(State.bind(button, "Text", text))

		context.Cleanup:Add(button.Activated:Connect(function()
			local ok, result = purchase:Invoke(item.Id)
			if not ok then
				warn(("[Hud] Buying %s failed: %s"):format(item.Id, tostring(result)))
			elseif result ~= "Purchased" then
				print(("[Hud] Couldn't buy %s: %s"):format(item.Id, tostring(result)))
			end
		end))
	end

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

return HudController
