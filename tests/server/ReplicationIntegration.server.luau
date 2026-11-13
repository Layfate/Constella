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

task.spawn(function()
	for value = 1, 3 do
		task.wait(1)
		tick:Set(value)
	end
end)
