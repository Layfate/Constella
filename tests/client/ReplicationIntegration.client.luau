--!nonstrict
-- Play-mode integration test, client half (Studio only).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local State = Constella.State
local player = Players.LocalPlayer

local failures = {}
local function check(condition: boolean, label: string)
	if not condition then
		table.insert(failures, label)
	end
end

local replica = Constella.Replication.Client.new("ConstellaReplicationTest")
-- Created now, before the server's changes, so the inventory's updates
-- arrive as Delta patches rather than in the snapshot.
local deltaReplica = Constella.Replication.Client.new("ConstellaReplicationDeltaTest")

check(replica:Get("Secret"):Get() == "for " .. player.Name, "own private value is visible")
check(replica:Get("OtherSecret"):Get() == nil, "another player's private value is not visible")
check(replica:Get("Tick").Set == nil, "replicated states are read-only")

-- UI binding against a real label.
local gui = Instance.new("ScreenGui")
gui.Name = "ConstellaReplicationTest"
local label = Instance.new("TextLabel")
label.Parent = gui
gui.Parent = player:WaitForChild("PlayerGui")
State.bind(label, "Text", replica:Get("Tick"), function(value)
	return "Tick " .. tostring(value)
end)

local deadline = os.clock() + 10
while replica:Get("Tick"):Get() ~= 3 and os.clock() < deadline do
	task.wait()
end
check(replica:Get("Tick"):Get() == 3, "public value reached 3 through updates")
check(label.Text == "Tick 3", "bound label shows the latest value")
gui:Destroy()

-- Delta mode: the inventory arrives as patches and must match exactly.
local inventory = deltaReplica:Get("Inventory")
deadline = os.clock() + 10
while (inventory:Get() == nil or inventory:Get().Coins ~= 3) and os.clock() < deadline do
	task.wait()
end
local value = inventory:Get()
check(value ~= nil and value.Coins == 3, "delta: coins reached 3 through patches")
local itemsIntact = value ~= nil and #value.Items == 40
if itemsIntact then
	for index, item in value.Items do
		if item.Id ~= "Item" .. index or item.Count ~= index then
			itemsIntact = false
		end
	end
end
check(itemsIntact, "delta: the unchanged items arrived intact")
deltaReplica:Destroy()

if #failures == 0 then
	print("[Constella integration] Replication PASS")
else
	warn("[Constella integration] Replication FAIL: " .. table.concat(failures, "; "))
end
script:SetAttribute("Passed", #failures == 0)
