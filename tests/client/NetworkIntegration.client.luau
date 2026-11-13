--!nonstrict
-- Play-mode integration test, client half. Acts like an exploiting client:
-- sends wrong types, NaN, extra arguments, forged tables, oversized strings,
-- fires server-only events and floods a rate-limited endpoint.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local client = Constella.Network.Client.new("ConstellaIntegration")

local failures = {}
local function check(condition: boolean, label: string)
	if not condition then
		table.insert(failures, label)
	end
end

-- Server -> client direction.
local echoReply = client:Event("EchoReply")
local reply = nil
echoReply:Connect(function(text)
	reply = text
end)

-- Valid request.
local echo = client:Event("Echo")
echo:Fire("ab", 3)

-- Malformed and forged requests: all must be dropped by the server.
echo:Fire(123, 3) -- wrong type
echo:Fire("ab", 0 / 0) -- NaN
echo:Fire("ab", 3, "extra") -- extra argument
echo:Fire({ Admin = true }, 1) -- forged table
echo:Fire(string.rep("x", 5000), 1) -- oversized payload

-- Firing an event the server never opened to clients.
client:Event("ServerOnly"):Fire("hello")

-- Flooding a rate-limited endpoint (3 per minute).
local limited = client:Event("Limited")
for _ = 1, 10 do
	limited:Fire()
end

-- Functions.
local add = client:Function("Add", { Timeout = 5 })
local ok, sum = add:Invoke(2, 3)
check(ok == true and sum == 5, "Add(2, 3) should return true, 5")
local badOk, badCode = add:Invoke("two", 3)
check(badOk == false and badCode == "Rejected", "Add('two', 3) should return false, 'Rejected'")

local boomOk, boomCode, leaked = client:Function("Boom", { Timeout = 5 }):Invoke()
check(boomOk == false and boomCode == "ServerError", "Boom should return false, 'ServerError'")
check(leaked == nil, "Boom must not leak server error details")

local deadline = os.clock() + 5
while reply == nil and os.clock() < deadline do
	task.wait()
end
check(reply == "ababab", "EchoReply should deliver 'ababab'")

local verifyOk, serverPassed, problems = client:Function("Verify", { Timeout = 10 }):Invoke()
check(verifyOk == true and serverPassed == true, "server stats: " .. tostring(problems))

if #failures == 0 then
	print("[Constella integration] client PASS")
else
	warn("[Constella integration] client FAIL: " .. table.concat(failures, "; "))
end
script:SetAttribute("Passed", #failures == 0)
