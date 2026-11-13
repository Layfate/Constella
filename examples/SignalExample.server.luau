--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Require the module directly: only Signal is loaded.
local Signal = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"):WaitForChild("Signal"))

local damaged = Signal.new()

local connection = damaged:Connect(function(target: string, amount: number)
	print(("[Signal] %s took %d damage"):format(target, amount))
end)

damaged:Once(function()
	print("[Signal] first hit!")
end)

damaged:Fire("Dummy", 10) -- prints both
damaged:Fire("Dummy", 5) -- Once listener is gone

task.delay(0.1, damaged.Fire, damaged, "Boss", 99)
local target, amount = damaged:Wait()
print("[Signal] Wait returned", target, amount)

connection:Disconnect()
damaged:Destroy()
