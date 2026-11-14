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
local ready = {}
deltaReplicator._net:Function("Ready", { Schema = {} }):SetHandler(function(player)
	ready[player] = true
	return true
end)

-- Return an intentionally stale snapshot after delivering a newer live
-- update. Each player gets a separate value so both clients hit the race.
local raceReplicator = Constella.Replication.Server.new("ConstellaReplicationRaceTest")
raceReplicator._fetch._handler = function(player)
	local state = State.new(1)
	raceReplicator:ShareWith(player, "Race", state)
	local snapshot = raceReplicator:_snapshotFor(player)
	task.delay(0.05, function()
		state:Set(2)
	end)
	task.wait(0.2)
	return snapshot
end

Players.PlayerRemoving:Connect(function(player)
	task.defer(function()
		script:SetAttribute(
			"DisconnectClean",
			replicator._private[player] == nil and raceReplicator._private[player] == nil
		)
	end)
end)
local items = {}
for index = 1, 40 do
	items[index] = { Id = "Item" .. index, Count = index }
end
local inventory = State.new({ Coins = 0, Items = items })
deltaReplicator:Share("Inventory", inventory)

task.spawn(function()
	-- Start changes only after every currently connected client has installed
	-- its mirrors and Delta observer, so snapshots alone cannot pass the test.
	local deadline = os.clock() + 30
	while os.clock() < deadline do
		local players = Players:GetPlayers()
		local allReady = #players > 0
		for _, player in players do
			if not ready[player] then
				allReady = false
			end
		end
		if allReady then
			break
		end
		task.wait()
	end
	for value = 1, 3 do
		task.wait(1)
		tick:Set(value)
		local nextValue = table.clone(inventory:Get())
		nextValue.Coins = value
		inventory:Set(nextValue)
	end
end)
