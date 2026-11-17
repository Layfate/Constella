--!nonstrict
--!nolint DeprecatedApi
--[=[
	Load and soak test with real Studio clients, server half.

	Launched by .github/scripts/studio_load.ps1 through StudioTestService
	(ExecuteMultiplayerTestAsync), so every player is a real client process
	connected through Roblox's network replicator, and every update crosses
	the real transport. See docs/Benchmarks.md#real-clients.

	Mode "Load" runs fixed phases and measures each one:
	- Idle             nothing sent (baseline traffic)
	- Calibrate1000    a 1,000-byte random string per update, per player
	- Calibrate4000    a 4,000-byte random string per update, per player
	- RawInventory     hand-written baseline: a plain RemoteEvent sends each
	                   player their whole 40-item inventory every update
	- ReplicationFull  the same inventory as a private Replication share
	- ReplicationDelta the same, with Delta = true
	- Requests         every client sends Network requests (some invalid)
	- Game             a whole game tick: requests, private coins, a public
	                   50-entry Delta leaderboard, a zone, a signal, promises

	Mode "Soak" runs the Game tick plus object churn (cleanups, signals,
	promises, a pool, zone items, components, private shares stopped and
	recreated) for Minutes, sampling memory every SampleSeconds.

	Traffic is the engine's own measurement, not an estimate: the server's
	Stats.DataSendKbps for server-to-client traffic and each client's
	Stats.DataSendKbps for client-to-server traffic. (The receive counters
	read 0 in Studio test sessions, so they aren't used.)
]=]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local StudioTestService = game:GetService("StudioTestService")

local args = StudioTestService:GetTestArgs()
if type(args) ~= "table" or args.Suite ~= "ConstellaLoad" then
	return
end

-- Characters add physics traffic that has nothing to do with Constella.
Players.CharacterAutoLoads = false

local Constella = require(ReplicatedStorage.Packages.Constella)
local Network = Constella.Network
local Check = Network.Check
local Replication = Constella.Replication
local State = Constella.State
local Signal = Constella.Signal
local Promise = Constella.Promise
local Cleanup = Constella.Cleanup
local Pool = Constella.Pool
local Zone = Constella.Zone
local Component = Constella.Component

local MODE = args.Mode or "Load"
local CLIENTS = args.Clients
local RATE = args.Rate or 10
local PHASE_SECONDS = args.PhaseSeconds or 20
local WARMUP_SECONDS = args.WarmupSeconds or 6
local REQUESTS_PER_SECOND = args.RequestsPerSecond or 20
local SOAK_MINUTES = args.Minutes or 60
-- false: a control run (clients connected, no Constella work) for the soak.
local WORKLOAD = args.Workload ~= false
local SAMPLE_SECONDS = args.SampleSeconds or 30
local BOARD_SIZE = 50

local function noop() end

local function one()
	return 1
end

local function percentile(values: { number }, p: number): number?
	if #values == 0 then
		return nil
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.clamp(math.ceil(#sorted * p), 1, #sorted)]
end

local function round(value: number?, places: number?): number?
	if value == nil then
		return nil
	end
	local scale = 10 ^ (places or 3)
	return math.round(value * scale) / scale
end

local finished = false
local function finish(passed: boolean, message: string, results: any)
	if finished then
		return
	end
	finished = true
	StudioTestService:EndTest({ Passed = passed, Message = message, Results = results })
end

-- Control channel (plain remotes, so the harness itself never depends on the
-- code under test).
local control = Instance.new("Folder")
control.Name = "ConstellaLoad"
control:SetAttribute("Phase", "Waiting")
control:SetAttribute("WarmupSeconds", WARMUP_SECONDS)
control:SetAttribute("RequestsPerSecond", REQUESTS_PER_SECOND)
control:SetAttribute("SampleSeconds", SAMPLE_SECONDS)
control:SetAttribute("Workload", WORKLOAD)
local function remote(name: string): RemoteEvent
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = control
	return event
end
local calibrate = remote("Calibrate")
local rawInventory = remote("RawInventory")
local expect = remote("Expect")
local report = remote("Report")

-- Incompressible-looking payloads for calibration: printable bytes from a
-- fixed seed, so every run sends the same strings.
local function randomString(length: number, seed: number): string
	local rng = Random.new(seed)
	local bytes = table.create(length)
	for index = 1, length do
		bytes[index] = string.char(rng:NextInteger(33, 126))
	end
	return table.concat(bytes)
end
local CALIBRATION = {
	Calibrate1000 = randomString(1000, 1),
	Calibrate4000 = randomString(4000, 2),
}

-- The 40-item inventory used by the benchmarks (RunBenchmarks.luau).
local function inventory(coins: number)
	local items = table.create(40)
	for index = 1, 40 do
		items[index] = { Id = "Item" .. index, Count = index }
	end
	return { Coins = coins, Items = items }
end

-- One field of one item changes, plus Coins: a new table, as State expects.
local function nextInventory(value, tick: number)
	local nextValue = table.clone(value)
	nextValue.Coins += 1
	local items = table.clone(value.Items)
	local index = tick % #items + 1
	items[index] = { Id = items[index].Id, Count = items[index].Count + 1 }
	nextValue.Items = items
	return nextValue
end

-- Network -----------------------------------------------------------------------
local rejections = 0
local server = Network.Server.new("Load", {
	OnReject = function()
		rejections += 1
	end,
	OnError = function(message)
		warn("[Load] handler error: " .. message)
	end,
})
local buy = server:Event("Buy", {
	Schema = {
		Check.string(20),
		Check.integer(1, 99),
		Check.record({ Note = Check.optional(Check.string(50)) }),
	},
	RateLimit = { Count = REQUESTS_PER_SECOND * 5, Per = 1 },
})
local purchases: { [Player]: number } = {}
buy:Connect(function(player, _item, count)
	purchases[player] = (purchases[player] or 0) + count
end)
local ping = server:Function("Ping", {
	Schema = { Check.integer(0, 2 ^ 31) },
	RateLimit = { Count = 10, Per = 1 },
})
ping:SetHandler(function(_player, value)
	return value + 1
end)

-- Replication -------------------------------------------------------------------
local replicators = {
	ReplicationFull = Replication.Server.new("LoadFull", { Delta = false, MaxValueBytes = 65536 }),
	ReplicationDelta = Replication.Server.new("LoadDelta", { Delta = true, MaxValueBytes = 65536 }),
}
local gameReplicator = Replication.Server.new("LoadGame", { Delta = true })

control.Parent = ReplicatedStorage

-- Wait for every client --------------------------------------------------------
local deadline = os.clock() + 120
while #Players:GetPlayers() < CLIENTS and os.clock() < deadline do
	task.wait(0.1)
end
if #Players:GetPlayers() < CLIENTS then
	finish(false, ("only %d of %d clients joined"):format(#Players:GetPlayers(), CLIENTS))
	return
end
local players = Players:GetPlayers()
table.sort(players, function(a, b)
	return a.UserId < b.UserId
end)
Players.PlayerRemoving:Connect(function(player)
	if not finished then
		finish(false, "client disconnected during the test: " .. player.Name)
	end
end)
-- Give clients time to create their Network and Replication clients.
task.wait(3)

-- Measurement --------------------------------------------------------------------
-- Heartbeat gaps and engine step times, collected for whichever phase runs.
local frameGaps: { number } = {}
local heartbeatMs: { number } = {}
RunService.Heartbeat:Connect(function(deltaTime)
	table.insert(frameGaps, deltaTime * 1000)
	table.insert(heartbeatMs, Stats.HeartbeatTimeMs)
end)

local phaseStarted = os.clock()
local function steady(): boolean
	return os.clock() - phaseStarted >= WARMUP_SECONDS
end

-- Runs `tick` at RATE per second for `seconds`, measuring the time spent in
-- it (with real sends) and the engine's send counter after warm-up.
local function runPhase(name: string, seconds: number, tick: ((number) -> ())?)
	control:SetAttribute("Phase", name)
	phaseStarted = os.clock()
	table.clear(frameGaps)
	table.clear(heartbeatMs)
	local tickMs, sendKbps = {}, {}
	local ticks, steadyTicks, steadyStart = 0, 0, nil
	local nextTick = os.clock()
	local nextSample = os.clock()
	local stopAt = os.clock() + seconds
	while os.clock() < stopAt do
		local now = os.clock()
		if now >= nextTick then
			nextTick += 1 / RATE
			if nextTick < now then
				nextTick = now + 1 / RATE -- fell behind; don't burst
			end
			ticks += 1
			if tick then
				local started = os.clock()
				tick(ticks)
				if steady() then
					table.insert(tickMs, (os.clock() - started) * 1000)
				end
			end
			if steady() then
				steadyStart = steadyStart or now
				steadyTicks += 1
			end
		end
		if now >= nextSample then
			nextSample = now + 0.25
			if steady() then
				table.insert(sendKbps, Stats.DataSendKbps)
			end
		end
		RunService.Heartbeat:Wait()
	end
	local steadySeconds = if steadyStart then os.clock() - steadyStart else 0
	local gaps, steps = table.clone(frameGaps), table.clone(heartbeatMs)
	-- Drop the warm-up part of the frame data too.
	local skip = math.floor(#gaps * WARMUP_SECONDS / seconds)
	for _ = 1, skip do
		table.remove(gaps, 1)
		table.remove(steps, 1)
	end
	return {
		Name = name,
		Ticks = ticks,
		UpdatesPerSecond = round(if steadySeconds > 0 then steadyTicks / steadySeconds else 0, 2),
		TickMsMedian = round(percentile(tickMs, 0.5), 4),
		TickMsP95 = round(percentile(tickMs, 0.95), 4),
		TickMsMax = round(percentile(tickMs, 1), 4),
		ServerSendKbps = round(percentile(sendKbps, 0.5), 3),
		FrameMsMedian = round(percentile(gaps, 0.5), 3),
		FrameMsP99 = round(percentile(gaps, 0.99), 3),
		HeartbeatMsMedian = round(percentile(steps, 0.5), 4),
		HeartbeatMsP99 = round(percentile(steps, 0.99), 4),
		HeapKB = round(collectgarbage("count"), 1),
	}
end

-- Workloads ------------------------------------------------------------------------
local function inventoryPhase(name: string)
	local replicator = replicators[name]
	local states, shares = {}, {}
	for _, player in players do
		states[player] = State.new(inventory(0))
		shares[player] = replicator:ShareWith(player, "Inventory", states[player])
	end
	local result = runPhase(name, PHASE_SECONDS, function(tick)
		for _, player in players do
			local state = states[player]
			state:Set(nextInventory(state:Get(), tick))
		end
	end)
	-- Every client must end up with exactly the server's value.
	for _, player in players do
		expect:FireClient(player, name, states[player]:Get())
	end
	task.wait(3)
	for _, share in shares do
		share:Stop()
	end
	return result
end

local function rawInventoryPhase()
	local values = {}
	for _, player in players do
		values[player] = inventory(0)
	end
	return runPhase("RawInventory", PHASE_SECONDS, function(tick)
		for _, player in players do
			local value = nextInventory(values[player], tick)
			values[player] = value
			rawInventory:FireClient(player, value)
		end
	end)
end

local function calibrationPhase(name: string)
	local payload = CALIBRATION[name]
	return runPhase(name, PHASE_SECONDS, function()
		for _, player in players do
			calibrate:FireClient(player, payload)
		end
	end)
end

-- The game tick: the synthetic benchmark scenario, with real players and
-- real sends.
local coins, coinShares = {}, {}
for _, player in players do
	coins[player] = State.new(0)
	coinShares[player] = gameReplicator:ShareWith(player, "Coins", coins[player])
end
local board = table.create(BOARD_SIZE)
for index = 1, BOARD_SIZE do
	board[index] = { Name = "Player" .. index, Score = 0 }
end
local leaderboard = State.new(board)
gameReplicator:Share("Leaderboard", leaderboard)
local zone = Zone.new({ CFrame = CFrame.new(), Size = Vector3.new(50, 50, 50) }, { AutoUpdate = false })
local entered = 0
zone.Entered:Connect(function()
	entered += 1
end)
for index, player in players do
	zone:Track(player, function()
		-- Players walk in and out of the zone.
		local x = math.sin(os.clock() + index) * 60
		return Vector3.new(x, 0, 0)
	end)
end
local tickSignal = Signal.new()
for _ = 1, #players do
	tickSignal:Connect(noop)
end

local function gameTick(tick: number)
	for _, player in players do
		local state = coins[player]
		state:Set(state:Get() + 1 + (purchases[player] or 0) % 3)
	end
	local nextBoard = table.clone(leaderboard:Get())
	nextBoard[tick % BOARD_SIZE + 1] = { Name = "Player" .. tick % BOARD_SIZE, Score = tick }
	leaderboard:Set(nextBoard)
	zone:Step()
	tickSignal:Fire(tick)
	for index = 1, 10 do
		Promise.resolve(index):Then(one)
	end
end

-- Soak churn: objects created and destroyed all the time, so a leak in any
-- of them shows up as growth.
local churnSignal = Signal.new()
local partTemplate = Instance.new("Part")
partTemplate.Anchored = true
local partFolder = Instance.new("Folder")
partFolder.Name = "LoadParts"
partFolder.Parent = workspace
local partPool = Pool.instances(partTemplate, { MaxIdle = 20 })
local tagged = table.create(20)
for index = 1, 20 do
	local part = Instance.new("Part")
	part.Anchored = true
	part.Name = "Tagged" .. index
	part.Parent = partFolder
	tagged[index] = part
end
local component = nil
local tempShares = {}

local function churn(tick: number)
	local scope = Cleanup.new()
	for _ = 1, 10 do
		scope:Connect(churnSignal, noop)
	end
	scope:Add(Promise.new(function(resolve)
		task.defer(resolve, tick)
	end):Then(one))
	local parts = table.create(5)
	for index = 1, 5 do
		local part = partPool:Acquire()
		part.Parent = partFolder
		parts[index] = part
	end
	for _, part in parts do
		partPool:Release(part)
	end
	local item = {}
	zone:Track(item, function()
		return Vector3.new(tick % 100, 0, 0)
	end)
	churnSignal:Fire(tick)
	zone:Untrack(item)
	scope:Destroy()

	if tick % (RATE * 5) == 0 then
		-- Private shares stopped and recreated.
		for _, player in players do
			if tempShares[player] then
				tempShares[player]:Stop()
			end
			tempShares[player] = gameReplicator:ShareWith(player, "Temp", State.new({ Tick = tick }))
		end
	end
	if tick % (RATE * 10) == 0 then
		-- Components started and stopped, tags added and removed.
		if component then
			component:Destroy()
		end
		for index, part in tagged do
			if (index + tick) % 2 == 0 then
				CollectionService:AddTag(part, "ConstellaLoad")
			else
				CollectionService:RemoveTag(part, "ConstellaLoad")
			end
		end
		component = Component.new({ Tag = "ConstellaLoad", Start = noop, Stop = noop })
		component:Run()
	end
end

-- Collect client reports -----------------------------------------------------------
local function collect(): { [Player]: any }
	local reports = {}
	local connection = report.OnServerEvent:Connect(function(player, payload)
		reports[player] = payload
	end)
	report:FireAllClients("Collect")
	local waitUntil = os.clock() + 20
	while os.clock() < waitUntil do
		local complete = true
		for _, player in players do
			if reports[player] == nil then
				complete = false
			end
		end
		if complete then
			break
		end
		task.wait(0.1)
	end
	connection:Disconnect()
	return reports
end

local function networkTotals()
	local stats = server:GetStats().Buy
	local rejected = 0
	for _, count in stats.Rejected do
		rejected += count
	end
	return stats.Accepted, rejected
end

-- Checks that apply to both modes: the server accepted exactly the valid
-- requests and rejected exactly the invalid ones the clients sent.
local function checkRequests(reports, failures)
	local accepted, rejected = networkTotals()
	local sentValid, sentInvalid = 0, 0
	for _, payload in reports do
		sentValid += payload.SentValid or 0
		sentInvalid += payload.SentInvalid or 0
	end
	if accepted ~= sentValid then
		table.insert(failures, ("server accepted %d requests, clients sent %d valid"):format(accepted, sentValid))
	end
	if rejected ~= sentInvalid then
		table.insert(failures, ("server rejected %d requests, clients sent %d invalid"):format(rejected, sentInvalid))
	end
	return { Accepted = accepted, Rejected = rejected, SentValid = sentValid, SentInvalid = sentInvalid }
end

local function clientList(reports, failures)
	local list = {}
	for index, player in players do
		local payload = reports[player]
		if payload == nil then
			table.insert(failures, player.Name .. " sent no report")
		else
			for _, failure in payload.Failures or {} do
				table.insert(failures, player.Name .. ": " .. failure)
			end
			payload.Failures = nil
			list[index] = payload
		end
	end
	return list
end

local function runLoad()
	local phases = {}
	table.insert(phases, runPhase("Idle", PHASE_SECONDS))
	table.insert(phases, calibrationPhase("Calibrate1000"))
	table.insert(phases, calibrationPhase("Calibrate4000"))
	table.insert(phases, rawInventoryPhase())
	table.insert(phases, inventoryPhase("ReplicationFull"))
	table.insert(phases, inventoryPhase("ReplicationDelta"))
	table.insert(phases, runPhase("Requests", PHASE_SECONDS))
	table.insert(phases, runPhase("Game", PHASE_SECONDS, gameTick))
	control:SetAttribute("Phase", "Done")
	task.wait(1)

	local reports = collect()
	local failures = {}
	local clients = clientList(reports, failures)
	local requests = checkRequests(reports, failures)
	if entered == 0 then
		table.insert(failures, "zone never saw a player enter")
	end
	return failures,
		{
			Mode = "Load",
			Clients = #players,
			Rate = RATE,
			PhaseSeconds = PHASE_SECONDS,
			WarmupSeconds = WARMUP_SECONDS,
			RequestsPerSecond = REQUESTS_PER_SECOND,
			Version = Constella.Version,
			Server = phases,
			ClientReports = clients,
			Requests = requests,
		}
end

-- The heap is a sawtooth (it grows until the incremental collector catches
-- up), so each sample also has the lowest and highest value seen since the
-- previous one, read every frame. The lowest is the floor that a leak raises.
local heapMin, heapMax = math.huge, 0
local function memorySample(started: number, tickMs: { number })
	local sample = {
		Minute = round((os.clock() - started) / 60, 3),
		HeapKB = round(collectgarbage("count"), 1),
		HeapMinKB = round(if heapMin < math.huge then heapMin else collectgarbage("count"), 1),
		HeapMaxKB = round(math.max(heapMax, collectgarbage("count")), 1),
		LuaHeapMB = round(Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.LuaHeap), 3),
		TotalMB = round(Stats:GetTotalMemoryUsageMb(), 1),
		Instances = Stats.InstanceCount,
		TickMsMedian = round(percentile(tickMs, 0.5), 4),
		TickMsP95 = round(percentile(tickMs, 0.95), 4),
		SendKbps = round(Stats.DataSendKbps, 3),
		Accepted = (networkTotals()),
	}
	heapMin, heapMax = math.huge, 0
	return sample
end

local function runSoak()
	control:SetAttribute("Phase", "Soak")
	local started = os.clock()
	local stopAt = started + SOAK_MINUTES * 60
	local samples = {}
	local tickMs = {}
	local ticks = 0
	local nextTick, nextSample = os.clock(), os.clock() + SAMPLE_SECONDS
	table.insert(samples, memorySample(started, tickMs))
	while os.clock() < stopAt do
		local now = os.clock()
		if now >= nextTick then
			nextTick += 1 / RATE
			if nextTick < now then
				nextTick = now + 1 / RATE
			end
			ticks += 1
			local tickStarted = os.clock()
			if WORKLOAD then
				gameTick(ticks)
				churn(ticks)
			end
			table.insert(tickMs, (os.clock() - tickStarted) * 1000)
		end
		local heap = collectgarbage("count")
		heapMin = math.min(heapMin, heap)
		heapMax = math.max(heapMax, heap)
		if now >= nextSample then
			nextSample += SAMPLE_SECONDS
			table.insert(samples, memorySample(started, tickMs))
			table.clear(tickMs)
		end
		RunService.Heartbeat:Wait()
	end
	control:SetAttribute("Phase", "Done")
	task.wait(2)
	local reports = collect()
	local failures = {}
	local clients = clientList(reports, failures)
	local requests = checkRequests(reports, failures)
	local poolStats = partPool:GetStats()
	return failures,
		{
			Mode = "Soak",
			Clients = #players,
			Rate = RATE,
			Minutes = SOAK_MINUTES,
			Workload = WORKLOAD,
			SampleSeconds = SAMPLE_SECONDS,
			RequestsPerSecond = REQUESTS_PER_SECOND,
			Version = Constella.Version,
			Ticks = ticks,
			Server = samples,
			ClientReports = clients,
			Requests = requests,
			Pool = poolStats,
			SignalConnections = churnSignal:GetConnectionCount(),
			ZoneEntered = entered,
		}
end

local ok, failuresOrError, results = pcall(if MODE == "Soak" then runSoak else runLoad)
if not ok then
	finish(false, "load test errored: " .. tostring(failuresOrError), nil)
elseif #failuresOrError > 0 then
	finish(false, table.concat(failuresOrError, "; "), results)
else
	finish(true, ("%s with %d real clients passed"):format(MODE, #players), results)
end
