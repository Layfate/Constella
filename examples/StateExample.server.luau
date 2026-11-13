--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local State = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"):WaitForChild("State"))

local health = State.new(100)
local maxHealth = State.new(100)

local percent = State.computed({ health, maxHealth }, function(current: number, max: number)
	return math.floor(current / max * 100)
end)
local isLow = State.select(percent, function(value: number)
	return value <= 25
end)

percent:Observe(function(value: number)
	print(("[State] health %d%%"):format(value))
end)
isLow:Subscribe(function(low: boolean)
	print("[State] low health:", low)
end)

health:Set(100) -- equal value: nothing fires
health:Set(20) -- percent 20, low true

-- One notification for both writes.
State.batch(function()
	health:Set(150)
	maxHealth:Set(200)
end)

isLow:Destroy()
percent:Destroy()
