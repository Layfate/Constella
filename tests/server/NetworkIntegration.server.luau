--!nonstrict
-- Play-mode integration test, server half. Studio only.
-- The client half (tests/client/NetworkIntegration.client.luau) sends valid,
-- malformed, forged and excessive requests through real remotes, then calls
-- Verify. The server compares what it actually accepted and rejected with
-- what it expected, prints PASS/FAIL and stores the result as attributes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Network = Constella.Network
local Check = Network.Check

local server = Network.Server.new("ConstellaIntegration", { OnError = function() end })

local echoReply = server:Event("EchoReply")
local echo = server:Event("Echo", {
	Schema = { Check.string(20), Check.integer(1, 10) },
	RateLimit = { Count = 100, Per = 1 },
})
echo:Connect(function(player, text, times)
	echoReply:Fire(player, string.rep(text, times))
end)

server:Event("ServerOnly")
server:Event("Limited", { Schema = {}, RateLimit = { Count = 3, Per = 60 } })

server:Function("Add", { Schema = { Check.number(), Check.number() } }):SetHandler(function(_, a, b)
	return a + b
end)
server:Function("Boom", { Schema = {} }):SetHandler(function()
	error("internal detail that must not reach the client")
end)

local EXPECTED = {
	Echo = { Accepted = 1, Rejected = { InvalidArguments = 4, PayloadTooLarge = 1 } },
	ServerOnly = { Accepted = 0, Rejected = { NotAccepted = 1 } },
	Limited = { Accepted = 3, Rejected = { RateLimited = 7 } },
	Add = { Accepted = 1, Rejected = { InvalidArguments = 1 } },
	Boom = { Accepted = 1, Rejected = { HandlerError = 1 } },
}

local function compare(): (boolean, string)
	local stats = server:GetStats()
	local problems = {}
	for name, expected in EXPECTED do
		local actual = stats[name]
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

server:Function("Verify", { Schema = {} }):SetHandler(function()
	-- Events and function calls travel separately; give queued events a moment.
	task.wait(0.5)
	local passed, problems = compare()
	script:SetAttribute("Passed", passed)
	script:SetAttribute("Problems", problems)
	if passed then
		print("[Constella integration] Network PASS")
	else
		warn("[Constella integration] Network FAIL: " .. problems)
	end
	return passed, problems
end)
