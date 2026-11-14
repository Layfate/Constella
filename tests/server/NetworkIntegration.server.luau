--!nonstrict
-- Play-mode integration test, server half. Studio only.
-- The client half (tests/client/NetworkIntegration.client.luau) sends valid,
-- malformed, forged and excessive requests through real remotes, then calls
-- Verify. The server compares what it actually accepted and rejected for
-- that player with what it expected, prints PASS/FAIL and stores the result
-- as attributes. Counts are kept per player, so the test also works with
-- several clients (Server & Clients mode), where each player has its own
-- rate limit.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Network = Constella.Network
local Check = Network.Check

-- tallies[player][endpoint] = { Accepted = n, Rejected = { [reason] = n } }
local tallies = {}
local function tally(player, endpoint)
	local byEndpoint = tallies[player]
	if byEndpoint == nil then
		byEndpoint = {}
		tallies[player] = byEndpoint
	end
	local entry = byEndpoint[endpoint]
	if entry == nil then
		entry = { Accepted = 0, Rejected = {} }
		byEndpoint[endpoint] = entry
	end
	return entry
end
local function accepted(player, endpoint)
	local entry = tally(player, endpoint)
	entry.Accepted += 1
end

local server = Network.Server.new("ConstellaIntegration", {
	OnError = function() end,
	OnReject = function(player, endpoint, reason)
		local entry = tally(player, endpoint)
		entry.Rejected[reason] = (entry.Rejected[reason] or 0) + 1
	end,
})

local echoReply = server:Event("EchoReply")
local echo = server:Event("Echo", {
	Schema = { Check.string(20), Check.integer(1, 10) },
	RateLimit = { Count = 100, Per = 1 },
})
echo:Connect(function(player, text, times)
	accepted(player, "Echo")
	echoReply:Fire(player, string.rep(text, times))
end)

server:Event("ServerOnly")
server:Event("Limited", { Schema = {}, RateLimit = { Count = 3, Per = 60 } }):Connect(function(player)
	accepted(player, "Limited")
end)

server:Function("Add", { Schema = { Check.number(), Check.number() } }):SetHandler(function(player, a, b)
	accepted(player, "Add")
	return a + b
end)
server:Function("Boom", { Schema = {} }):SetHandler(function(player)
	accepted(player, "Boom")
	error("internal detail that must not reach the client")
end)

local EXPECTED = {
	Echo = { Accepted = 1, Rejected = { InvalidArguments = 4, PayloadTooLarge = 1 } },
	ServerOnly = { Accepted = 0, Rejected = { NotAccepted = 1 } },
	Limited = { Accepted = 3, Rejected = { RateLimited = 7 } },
	Add = { Accepted = 1, Rejected = { InvalidArguments = 1 } },
	Boom = { Accepted = 1, Rejected = { HandlerError = 1 } },
}

local function compare(player): (boolean, string)
	local problems = {}
	for name, expected in EXPECTED do
		local actual = tally(player, name)
		if actual.Accepted ~= expected.Accepted then
			table.insert(problems, ("%s Accepted %d, expected %d"):format(name, actual.Accepted, expected.Accepted))
		end
		local reasons = {}
		for reason in expected.Rejected do
			reasons[reason] = true
		end
		for reason in actual.Rejected do
			reasons[reason] = true
		end
		for reason in reasons do
			local got, want = actual.Rejected[reason] or 0, expected.Rejected[reason] or 0
			if got ~= want then
				table.insert(problems, ("%s %s %d, expected %d"):format(name, reason, got, want))
			end
		end
	end
	table.sort(problems)
	return #problems == 0, table.concat(problems, "; ")
end

local verified, failedPlayers = 0, {}
server:Function("Verify", { Schema = {} }):SetHandler(function(player)
	-- Events and function calls travel separately; give queued events a moment.
	task.wait(0.5)
	local passed, problems = compare(player)
	verified += 1
	if not passed then
		table.insert(failedPlayers, player.Name .. ": " .. problems)
	end
	script:SetAttribute("Verified", verified)
	script:SetAttribute("Passed", #failedPlayers == 0)
	script:SetAttribute("Problems", table.concat(failedPlayers, " | "))
	if passed then
		print(("[Constella integration] Network PASS (%s)"):format(player.Name))
	else
		warn(("[Constella integration] Network FAIL (%s): %s"):format(player.Name, problems))
	end
	return passed, problems
end)
