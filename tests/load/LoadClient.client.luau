--!nonstrict
--!nolint DeprecatedApi
--[=[
	Load and soak test with real Studio clients, client half. See
	LoadServer.server.luau.

	Each client samples the engine's own send counter (Stats.DataSendKbps)
	per phase,
	sends Network requests (one in ten deliberately invalid) during the
	Requests, Game and Soak phases, measures Ping round trips, checks that
	Replication delivered exactly the server's final value, and reports
	everything when the server asks.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local control = ReplicatedStorage:WaitForChild("ConstellaLoad", 30)
if not control then
	return
end

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local net = Constella.Network.Client.new("Load")
local buy = net:Event("Buy")
local ping = net:Function("Ping", { Timeout = 10 })
local replicas = {
	ReplicationFull = Constella.Replication.Client.new("LoadFull"),
	ReplicationDelta = Constella.Replication.Client.new("LoadDelta"),
}
local gameReplica = Constella.Replication.Client.new("LoadGame")

local WARMUP_SECONDS = control:GetAttribute("WarmupSeconds")
local REQUESTS_PER_SECOND = control:GetAttribute("RequestsPerSecond")
local SAMPLE_SECONDS = control:GetAttribute("SampleSeconds")

local failures = {}
local received: { [string]: number } = {}
local function count(phase: string)
	received[phase] = (received[phase] or 0) + 1
end

control.Calibrate.OnClientEvent:Connect(function()
	count(control:GetAttribute("Phase"))
end)
control.RawInventory.OnClientEvent:Connect(function()
	count("RawInventory")
end)
for name, replica in replicas do
	replica:Observe("Inventory", function(value)
		if value ~= nil then
			count(name)
		end
	end)
end
local coinUpdates, boardUpdates = 0, 0
gameReplica:Observe("Coins", function()
	coinUpdates += 1
end)
gameReplica:Observe("Leaderboard", function()
	boardUpdates += 1
end)

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- The server sends its final value at the end of each Replication phase;
-- the replica must match it exactly.
local checks = {}
control.Expect.OnClientEvent:Connect(function(phase, expected)
	local replica = replicas[phase]
	local deadline = os.clock() + 3
	local matched = false
	while os.clock() < deadline do
		if deepEqual(replica:Get("Inventory"):Get(), expected) then
			matched = true
			break
		end
		task.wait()
	end
	checks[phase] = matched
	if not matched then
		table.insert(failures, phase .. ": replica differs from the server's value")
	end
end)

-- Send-traffic samples per phase, after the warm-up (the counter is
-- averaged over time, so a phase change takes a few seconds to show).
local phase = control:GetAttribute("Phase")
local phaseStarted = os.clock()
local traffic: { [string]: { number } } = {}
control:GetAttributeChangedSignal("Phase"):Connect(function()
	phase = control:GetAttribute("Phase")
	phaseStarted = os.clock()
end)

local function median(values: { number }): number?
	if #values == 0 then
		return nil
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.ceil(#sorted / 2)]
end

local function round(value: number?, places: number?): number?
	if value == nil then
		return nil
	end
	local scale = 10 ^ (places or 3)
	return math.round(value * scale) / scale
end

task.spawn(function()
	while true do
		if os.clock() - phaseStarted >= WARMUP_SECONDS then
			local entry = traffic[phase]
			if not entry then
				entry = {}
				traffic[phase] = entry
			end
			table.insert(entry, Stats.DataSendKbps)
		end
		task.wait(0.25)
	end
end)

-- Requests: REQUESTS_PER_SECOND each, every tenth one invalid (a wrong
-- type), plus one Ping round trip per second.
-- A soak control run (Workload false) sends nothing.
local SENDING = { Requests = true, Game = true, Soak = control:GetAttribute("Workload") ~= false }
local sentValid, sentInvalid = 0, 0
local sendBudget = 0
local sequence = 0
RunService.Heartbeat:Connect(function(deltaTime)
	if not SENDING[phase] then
		sendBudget = 0
		return
	end
	sendBudget += deltaTime * REQUESTS_PER_SECOND
	while sendBudget >= 1 do
		sendBudget -= 1
		sequence += 1
		if sequence % 10 == 0 then
			buy:Fire(123, 2, {})
			sentInvalid += 1
		else
			buy:Fire("Sword", 2, { Note = "gift" })
			sentValid += 1
		end
	end
end)

local roundTrips: { number } = {}
local pingFailures = 0
task.spawn(function()
	local value = 0
	while true do
		if SENDING[phase] then
			value += 1
			local started = os.clock()
			local ok, result = ping:Invoke(value)
			if ok and result == value + 1 then
				table.insert(roundTrips, (os.clock() - started) * 1000)
			else
				pingFailures += 1
			end
		end
		task.wait(1)
	end
end)

-- Soak: memory and traffic over time.
-- Like the server, each sample has the lowest and highest heap seen since
-- the previous one (read every 0.25 s): the lowest is the floor a leak raises.
-- LuaHeapMB is Studio's per-process tag, which also counts Studio's own Lua.
local soakSamples = {}
local soakStarted = nil
task.spawn(function()
	local heapMin, heapMax = math.huge, 0
	local nextSample = 0
	while true do
		if phase == "Soak" then
			local now = os.clock()
			soakStarted = soakStarted or now
			local heap = collectgarbage("count")
			heapMin = math.min(heapMin, heap)
			heapMax = math.max(heapMax, heap)
			if now >= nextSample then
				nextSample = now + SAMPLE_SECONDS
				table.insert(soakSamples, {
					Minute = round((now - soakStarted) / 60, 3),
					HeapKB = round(heap, 1),
					HeapMinKB = round(heapMin, 1),
					HeapMaxKB = round(heapMax, 1),
					LuaHeapMB = round(Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.LuaHeap), 3),
					SendKbps = round(Stats.DataSendKbps, 3),
				})
				heapMin, heapMax = math.huge, 0
			end
			task.wait(0.25)
		else
			task.wait(0.5)
		end
	end
end)

control.Report.OnClientEvent:Connect(function(command)
	if command ~= "Collect" then
		return
	end
	local phases = {}
	for name, entry in traffic do
		phases[name] = {
			SendKbps = round(median(entry), 3),
			Samples = #entry,
		}
	end
	local sortedTrips = table.clone(roundTrips)
	table.sort(sortedTrips)
	if pingFailures > 0 then
		table.insert(failures, ("%d Ping requests failed"):format(pingFailures))
	end
	control.Report:FireServer({
		Phases = phases,
		Received = received,
		Checks = checks,
		CoinUpdates = coinUpdates,
		LeaderboardUpdates = boardUpdates,
		SentValid = sentValid,
		SentInvalid = sentInvalid,
		PingMsMedian = round(sortedTrips[math.ceil(#sortedTrips / 2)], 3),
		PingMsP95 = round(sortedTrips[math.ceil(#sortedTrips * 0.95)], 3),
		Pings = #sortedTrips,
		Soak = soakSamples,
		Failures = failures,
	})
end)
