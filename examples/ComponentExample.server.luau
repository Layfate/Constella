--!strict
-- Every part tagged "ConstellaSpinner" spins. Tag more parts in Studio
-- (Tag Editor / Properties > Tags) while playing and they start spinning too.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Component = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"):WaitForChild("Component"))

local Spinner = {
	Tag = "ConstellaSpinner",
	Filter = function(instance: Instance)
		return instance:IsA("BasePart")
	end,
}

function Spinner:Start()
	local part = self.Instance :: BasePart
	self.Cleanup:Connect(RunService.Heartbeat, function(deltaTime: number)
		part.CFrame *= CFrame.Angles(0, deltaTime * 2, 0)
	end)
end

function Spinner:Stop()
	print("[Component] stopped spinning", self.Instance:GetFullName())
end

local spinners = Component.new(Spinner)
spinners.Added:Connect(function(object)
	print("[Component] spinning", object.Instance:GetFullName())
end)
spinners:Run()

-- Create a demo part, then untag it after 3 seconds.
local part = Instance.new("Part")
part.Name = "SpinnerDemo"
part.Anchored = true
part.Size = Vector3.new(4, 1, 4)
part.Position = Vector3.new(-12, 3, 20)
part.Parent = workspace
CollectionService:AddTag(part, Spinner.Tag)

task.delay(3, function()
	CollectionService:RemoveTag(part, Spinner.Tag) -- Stop runs, Heartbeat connection is cleaned
end)
