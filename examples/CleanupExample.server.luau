--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cleanup = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"):WaitForChild("Cleanup"))

local cleanup = Cleanup.new()

-- Instances, connections, threads and functions are detected automatically.
local part = cleanup:Add(Instance.new("Part"))
part.Anchored = true
part.Position = Vector3.new(0, 10, 0)
part.Parent = workspace

cleanup:Connect(part.Touched, function(hit: BasePart)
	print("[Cleanup] touched by", hit.Name)
end)

cleanup:Add(task.spawn(function()
	while true do
		part.CFrame *= CFrame.Angles(0, math.rad(5), 0)
		task.wait()
	end
end))

-- Keyed resources replace (and clean) whatever was there before.
cleanup:Set("highlight", Instance.new("Highlight", part))
cleanup:Set("highlight", Instance.new("SelectionBox", part)) -- the Highlight is destroyed

cleanup:Add(function()
	print("[Cleanup] all resources released")
end)

task.wait(3)
cleanup:Destroy() -- stops the loop, disconnects, destroys the part
