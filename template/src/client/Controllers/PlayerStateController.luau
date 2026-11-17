--!strict
-- Read-only mirrors of the values the server replicates to this player.
-- Other controllers depend on this one instead of opening their own
-- replication client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))

local PlayerStateController = {
	Name = "PlayerStateController",
	Environment = "Client",

	-- nil until the first value arrives from the server. Set in Init.
	Coins = (nil :: any) :: Constella.Computed<number?>,
	Items = (nil :: any) :: Constella.Computed<{ [string]: true }?>,
}

export type PlayerStateController = typeof(PlayerStateController)

function PlayerStateController.Init(self: PlayerStateController, context: Constella.Context)
	local replica = context.Cleanup:Add(Constella.Replication.Client.new(Net.Player.Namespace))
	self.Coins = replica:Get(Net.Player.Coins)
	self.Items = replica:Get(Net.Player.Items)
end

return PlayerStateController
