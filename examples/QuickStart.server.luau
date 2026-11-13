--!strict
-- The smallest Constella program: no app, no setup.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))

local cleanup = Constella.Cleanup.new()
local state = Constella.State.new(0)
cleanup:Add(state:Subscribe(function(newValue)
	print("[QuickStart] state is now", newValue)
end))
state:Set(10)

local rarity = Constella.Random.choose({
	{ Value = "Common", Weight = 75 },
	{ Value = "Rare", Weight = 20 },
	{ Value = "Legendary", Weight = 5 },
}, Random.new(1234))
print("[QuickStart] rolled", rarity)

cleanup:Destroy()
