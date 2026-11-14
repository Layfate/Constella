--!nonstrict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local report = ReplicatedStorage:WaitForChild("ConstellaIntegrationReport", 20)
assert(report, "integration reporter missing")
report.OnClientEvent:Connect(function(command)
	if command == "Leave" and StudioTestService:CanLeaveTest() then
		StudioTestService:LeaveTest()
	end
end)
local deadline = os.clock() + 40
local names = { "NetworkIntegration", "ReplicationIntegration" }
while os.clock() < deadline do
	local complete = true
	for _, name in names do
		local test = script.Parent:FindFirstChild(name)
		local passed = test and test:GetAttribute("Passed")
		if passed == false then
			report:FireServer(false, name .. " failed")
			return
		end
		if passed ~= true then
			complete = false
		end
	end
	if complete then
		report:FireServer(true, "client checks passed")
		return
	end
	task.wait()
end
report:FireServer(false, "client checks timed out")
