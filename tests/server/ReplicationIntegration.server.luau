--!nonstrict
-- Play-mode integration test, server half (Studio only). Shares a public
-- value that changes over time, a private value for each real player, and
-- a private value for a stand-in "other player" that no real client may see.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local State = Constella.State

local replicator = Constella.Replication.Server.new("ConstellaReplicationTest")

local tick = State.new(0)
replicator:Share("Tick", tick)

-- Private to someone else: must never reach a real client.
replicator:ShareWith({ Name = "SomeoneElse" }, "OtherSecret", State.new("not for you"))

local function onPlayer(player: Player)
	replicator:ShareWith(player, "Secret", State.new("for " .. player.Name))
end
Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do
	onPlayer(player)
end

-- Delta mode: a 40-item inventory whose coins change three times, so the
-- client receives patches rather than whole values.
local deltaReplicator = Constella.Replication.Server.new("ConstellaReplicationDeltaTest", { Delta = true })
local items = {}
for index = 1, 40 do
	items[index] = { Id = "Item" .. index, Count = index }
end
local inventory = State.new({ Coins = 0, Items = items })
deltaReplicator:Share("Inventory", inventory)

task.spawn(function()
	for value = 1, 3 do
		task.wait(1)
		tick:Set(value)
		local nextValue = table.clone(inventory:Get())
		nextValue.Coins = value
		inventory:Set(nextValue)
	end
end)
