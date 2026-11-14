--!nonstrict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local args = StudioTestService:GetTestArgs()
assert(type(args) == "table" and args.Suite == "ConstellaMultiplayer", "launch with the Studio multiplayer runner")

local report = Instance.new("RemoteEvent")
report.Name = "ConstellaIntegrationReport"
local reports, departing, departed = {}, nil, false
local finished = false
local function finish(passed, message)
	if finished then
		return
	end
	finished = true
	StudioTestService:EndTest({ Passed = passed, Message = message })
end

Players.PlayerRemoving:Connect(function(player)
	if player == departing then
		departed = true
		-- Replication and Network PlayerRemoving listeners must finish first.
		task.defer(function()
			local deadline = os.clock() + 5
			while
				script.Parent.ReplicationIntegration:GetAttribute("DisconnectClean") == nil
				and os.clock() < deadline
			do
				task.wait()
			end
			finish(
				script.Parent.ReplicationIntegration:GetAttribute("DisconnectClean") == true,
				"two clients passed; checked private-share cleanup after disconnect"
			)
		end)
	else
		finish(false, "unexpected client disconnect: " .. player.Name)
	end
end)

report.OnServerEvent:Connect(function(player, passed, message)
	if reports[player] ~= nil then
		return
	end
	reports[player] = passed == true
	if passed ~= true then
		finish(false, player.Name .. ": " .. tostring(message))
		return
	end
	local players = Players:GetPlayers()
	if #players ~= args.Clients then
		return
	end
	for _, other in players do
		if reports[other] ~= true then
			return
		end
	end
	local network = script.Parent.NetworkIntegration
	if network:GetAttribute("Passed") ~= true or network:GetAttribute("Verified") ~= args.Clients then
		finish(false, "server Network checks failed")
		return
	end
	departing = players[1]
	report:FireClient(departing, "Leave")
end)
report.Parent = ReplicatedStorage

task.delay(60, function()
	if not departed then
		finish(false, "multiplayer checks or disconnect timed out")
	end
end)
