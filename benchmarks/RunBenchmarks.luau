--!nonstrict
--!nolint DeprecatedApi
--[=[
	Constella benchmarks. Run from the Studio command bar (Edit mode):

	```lua
	print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)())
	print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)({ Runs = 7 }))
	```

	Optional comparisons: put these ModuleScripts in ServerStorage.BenchmarkLibs
	(CI downloads pinned versions; see ci.yml):
	- "Signal"      - sleitnick/signal (GoodSignal-style)
	- "LemonSignal" - Data-Oriented-House/LemonSignal
	- "Trove"       - sleitnick/trove
	- "Janitor"     - howmanysmall/Janitor
	- "Promise"     - evaera/roblox-lua-promise
	Missing libraries are skipped. Returns a Markdown report.

	A/B comparisons: pass several builds of the package, for example the
	current code and the last release. Every case runs for every build
	back to back inside each run, and every other run reverses their order,
	so the builds are measured under the same conditions. Implementation
	names then end in "[name]", and the first build is compared with the
	second: median ratio, a 95% bootstrap confidence interval, and a
	REGRESSION line for any case that is more than 10% slower with the
	interval's lower end above +5%.

	```lua
	RunBenchmarks({
		Runs = 7,
		Packages = {
			{ Name = "this build", Module = ReplicatedStorage.Packages.Constella },
			{ Name = "baseline", Module = ReplicatedStorage.Packages.ConstellaBaseline },
		},
	})
	```

	Method
	- Speed: the whole suite runs `Runs` times (default 5). Within a run,
	  each case is the median of 5 timed trials. The report shows the
	  median across runs, the best and worst run, and then every run's
	  result in the order the runs happened.
	- Memory: bytes per object, 80th percentile of many builds (see
	  Bench.bytesPerObject for why).
	- Bandwidth: estimated bytes sent per Replication update, measured with
	  Network.Payload (the same estimate Network uses for its limits).
	- Leaks: objects are released while their owner stays alive, then the
	  check waits for the garbage collector to free them (see Bench.luau).
]=]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Bench = require(script.Parent.Bench)

local function noop() end

local function one()
	return 1
end

local function traceback(err)
	return debug.traceback(tostring(err), 2)
end

type Package = { Name: string?, Module: ModuleScript }

-- A 40-item inventory, the shape a Replication share often has.
local function inventory(coins: number)
	local items = table.create(40)
	for index = 1, 40 do
		items[index] = { Id = "Item" .. index, Count = index }
	end
	return { Coins = coins, Items = items }
end

local REGRESSION_RATIO, REGRESSION_LOWER = 1.10, 1.05

return function(options: { Runs: number?, Packages: { Package }? }?): string
	local runs = (options and options.Runs) or 5
	local packages: { Package } = (options and options.Packages)
		or { { Module = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella") } }
	local libs = ServerStorage:FindFirstChild("BenchmarkLibs")
	local function lib(name: string): any
		local module = libs and libs:FindFirstChild(name)
		return if module then require(module :: any) else nil
	end
	local OtherSignal = lib("Signal")
	local LemonSignal = lib("LemonSignal")
	local Trove = lib("Trove")
	local Janitor = lib("Janitor")
	local OtherPromise = lib("Promise")

	-- Speed cases ----------------------------------------------------------
	local cases: { any } = {}
	local currentBuild: number? = nil
	local function case(group, name, implementation, iterations, run)
		table.insert(cases, {
			group = group,
			name = name,
			implementation = implementation,
			iterations = iterations,
			run = run,
			samples = {},
			build = currentBuild,
		})
	end

	-- Everything created for the cases, destroyed after the speed runs.
	local fixtures: { any } = {}
	local function keep(object: any): any
		table.insert(fixtures, object)
		return object
	end

	local bindable = keep(Instance.new("BindableEvent"))
	local template = Instance.new("Part")
	template.Anchored = true
	keep(template)
	local folder = keep(Instance.new("Folder"))
	folder.Parent = workspace
	local player = { Name = "Bench" }

	local entries = {}
	for index = 1, 100 do
		entries[index] = { Value = index, Weight = index }
	end
	local rng = Random.new(1)

	-- Distinct functions to hand to cleanup managers. (Adding the same
	-- function many times isn't a fair test: Janitor keys entries by the
	-- object, so it would keep just one.)
	local distinct = table.create(5000)
	for index = 1, 5000 do
		distinct[index] = function()
			return index
		end
	end

	local function plain(fn)
		return fn
	end
	local function isolated(fn)
		return function(...)
			xpcall(fn, traceback, ...)
		end
	end

	local function signalCases(label, new, wrap)
		case("Signal", "Connect + Disconnect", label, 20000, function(n)
			local signal = new()
			for _ = 1, n do
				signal:Connect(noop):Disconnect()
			end
		end)
		case("Signal", "Fire, 1 listener", label, 20000, function(n)
			local signal = new()
			signal:Connect(wrap(noop))
			for _ = 1, n do
				signal:Fire(1, 2)
			end
		end)
		case("Signal", "Fire, 10 listeners", label, 5000, function(n)
			local signal = new()
			for _ = 1, 10 do
				signal:Connect(wrap(noop))
			end
			for _ = 1, n do
				signal:Fire(1, 2)
			end
		end)
		-- Larger counts show whether the cost per listener stays constant.
		for _, listeners in { 100, 1000 } do
			case("Signal", ("Fire, %d listeners"):format(listeners), label, 50000 // listeners, function(n)
				local signal = new()
				for _ = 1, listeners do
					signal:Connect(wrap(noop))
				end
				for _ = 1, n do
					signal:Fire(1, 2)
				end
			end)
		end
	end

	-- `adapter` hides the API differences: new(), addFunction(manager, fn),
	-- addConnection(manager, event, fn), clean(manager).
	local function cleanupCases(label, adapter)
		case("Cleanup", "Add + Clean 100 functions", label, 300, function(n)
			for _ = 1, n do
				local manager = adapter.new()
				for index = 1, 100 do
					adapter.addFunction(manager, distinct[index])
				end
				adapter.clean(manager)
			end
		end)
		case("Cleanup", "Connect + Clean 100 RBXScriptConnections", label, 100, function(n)
			for _ = 1, n do
				local manager = adapter.new()
				for _ = 1, 100 do
					adapter.addConnection(manager, bindable.Event, noop)
				end
				adapter.clean(manager)
			end
		end)
	end

	-- `adapter`: resolve(value), new(executor), andThen(promise, fn), await(promise)
	local function promiseCases(label, adapter)
		case("Promise", "`resolve` + `Then` + `Await`", label, 5000, function(n)
			for _ = 1, n do
				adapter.await(adapter.andThen(adapter.resolve(1), one))
			end
		end)
		case("Promise", "Chain 10 `Then`s, then resolve", label, 1000, function(n)
			for _ = 1, n do
				local resolve
				local promise = adapter.new(function(done)
					resolve = done
				end)
				for _ = 1, 10 do
					promise = adapter.andThen(promise, one)
				end
				resolve(1)
			end
		end)
	end

	-- Every case that measures Constella, for one build of the package.
	local function constellaCases(Constella, suffix, buildIndex)
		-- Constella always isolates listener errors (xpcall + OnError).
		signalCases("Constella.Signal" .. suffix, Constella.Signal.new, plain)
		cleanupCases("Constella.Cleanup" .. suffix, {
			new = Constella.Cleanup.new,
			addFunction = function(manager, fn)
				manager:Add(fn)
			end,
			addConnection = function(manager, event, fn)
				manager:Connect(event, fn)
			end,
			clean = function(manager)
				manager:Clean()
			end,
		})

		case("Pool", "Spawn + despawn a Part", "Constella.Pool" .. suffix, 2000, function(n)
			local pool = Constella.Pool.instances(template, { MaxIdle = 16 })
			for _ = 1, n do
				local part = pool:Acquire()
				part.Parent = folder
				pool:Release(part)
			end
			pool:Destroy()
		end)

		local Network = Constella.Network
		local Check = Network.Check
		local server = keep(Network.Server.new("Benchmark", { Parent = Instance.new("Folder"), OnError = noop }))
		local schema = {
			Check.string(20),
			Check.integer(1, 99),
			Check.record({ Note = Check.optional(Check.string(50)) }),
		}
		local buy = server:Event("Buy", { Schema = schema, RateLimit = { Count = 1e9, Per = 1 } })
		buy:Connect(noop)
		case("Network", "Accept a valid request (all checks)", "Constella.Network" .. suffix, 20000, function(n)
			for _ = 1, n do
				buy:_receive(player, "Sword", 2, { Note = "gift" })
			end
		end)
		case("Network", "Reject a forged request", "Constella.Network" .. suffix, 20000, function(n)
			for _ = 1, n do
				buy:_receive(player, "Sword", 0 / 0, { Admin = true })
			end
		end)

		local loot = Constella.Random.lootTable(entries)
		case(
			"Random",
			"Weighted roll, 100 entries",
			"`Random.choose` (validates every call)" .. suffix,
			5000,
			function(n)
				for _ = 1, n do
					Constella.Random.choose(entries, rng)
				end
			end
		)
		case("Random", "Weighted roll, 100 entries", "`lootTable:Roll` (precomputed)" .. suffix, 50000, function(n)
			for _ = 1, n do
				loot:Roll(rng)
			end
		end)

		local State = Constella.State
		case("State", "Set with 1 subscriber", "Constella.State" .. suffix, 20000, function(n)
			local value = State.new(0)
			value:Subscribe(noop)
			for index = 1, n do
				value:Set(index)
			end
		end)
		case("State", "Set a source of a computed with 1 subscriber", "Constella.State" .. suffix, 20000, function(n)
			local a, b = State.new(0), State.new(1)
			local sum = State.computed({ a, b }, function(x, y)
				return x + y
			end)
			sum:Subscribe(noop)
			for index = 1, n do
				a:Set(index)
			end
			sum:Destroy()
		end)

		local Promise = Constella.Promise
		promiseCases("Constella.Promise" .. suffix, {
			resolve = Promise.resolve,
			new = Promise.new,
			andThen = function(promise, fn)
				return promise:Then(fn)
			end,
			await = function(promise)
				return promise:Await()
			end,
		})

		-- Zone: steady state (nothing enters or leaves), half the items inside.
		local Zone = Constella.Zone
		local pointZone =
			keep(Zone.new({ CFrame = CFrame.new(), Size = Vector3.new(50, 50, 50) }, { AutoUpdate = false }))
		for index = 1, 100 do
			local item = { Position = Vector3.new(if index % 2 == 0 then 0 else 100, 0, index * 0.1) }
			pointZone:Track(item, function()
				return item.Position
			end)
		end
		case("Zone", "Step, 100 tracked points (custom getters)", "Constella.Zone" .. suffix, 2000, function(n)
			for _ = 1, n do
				pointZone:Step()
			end
		end)
		local partZone =
			keep(Zone.new({ CFrame = CFrame.new(), Size = Vector3.new(50, 50, 50) }, { AutoUpdate = false }))
		for index = 1, 100 do
			local part = keep(Instance.new("Part"))
			part.Position = Vector3.new(if index % 2 == 0 then 0 else 100, 0, index * 0.1)
			partZone:Track(part)
		end
		case("Zone", "Step, 100 tracked Parts (built-in getters)", "Constella.Zone" .. suffix, 2000, function(n)
			for _ = 1, n do
				partZone:Step()
			end
		end)

		-- Replication: the remote itself isn't measured (no players here).
		local Replication = Constella.Replication
		for _, delta in { false, true } do
			local replicator = keep(Replication.Server.new(if delta then "BenchDelta" else "BenchFull", {
				Parent = Instance.new("Folder"),
				Delta = delta,
				OnError = noop,
			}))
			if delta and replicator._delta == nil then
				-- This build has no Delta mode; comparing it would measure
				-- full sends under the Delta label.
				replicator:Destroy()
				continue
			end
			replicator._update.FireList = noop
			local share = State.new(inventory(0))
			replicator:Share("Inventory", share)
			local count = 0
			case(
				"Replication",
				"Publish one change to a 40-item inventory",
				(if delta then "Constella.Replication, `Delta = true`" else "Constella.Replication, full value")
					.. suffix,
				2000,
				function(n)
					for _ = 1, n do
						count += 1
						local value = table.clone(share:Get())
						value.Coins = count
						share:Set(value)
					end
				end
			)
		end

		local Data = Constella.Data
		local store = Data.Store.new({
			Name = "Bench",
			Template = { Coins = 0, Inventory = {}, Settings = { Music = true, Volume = 0.5 } },
			Adapter = Data.MemoryAdapter.new(),
			KickOnFailure = false,
			OnError = noop,
		})
		local nextUserId = 0
		case("Data", "Load + release a profile (MemoryAdapter)", "Constella.Data" .. suffix, 300, function(n)
			for _ = 1, n do
				nextUserId += 1
				local fake = { Name = "Bench", UserId = nextUserId, Parent = true, Kick = noop }
				store:LoadAsync(fake):Await()
				store:Release(fake)
			end
		end)

		local tag = "ConstellaBench" .. buildIndex
		local tagged = keep(Instance.new("Folder"))
		for _ = 1, 200 do
			local part = Instance.new("Part")
			part.Anchored = true
			CollectionService:AddTag(part, tag)
			part.Parent = tagged
		end
		tagged.Parent = workspace
		case("Component", "Run + Destroy with 200 tagged parts", "Constella.Component" .. suffix, 20, function(n)
			for _ = 1, n do
				local component = Constella.Component.new({ Tag = tag, Start = noop, Stop = noop })
				component:Run()
				component:Destroy()
			end
		end)

		-- A server tick with 50 players: coins changing, a request each, a
		-- zone check, a replicated leaderboard update, a broadcast signal
		-- and a few promises.
		local PLAYERS = 50
		local coins, fakes = table.create(PLAYERS), table.create(PLAYERS)
		local tickZone =
			keep(Zone.new({ CFrame = CFrame.new(), Size = Vector3.new(50, 50, 50) }, { AutoUpdate = false }))
		local board = table.create(PLAYERS)
		for index = 1, PLAYERS do
			coins[index] = State.new(0)
			coins[index]:Subscribe(noop)
			fakes[index] = { Name = "Player" .. index }
			local item = { Position = Vector3.new(if index % 2 == 0 then 0 else 100, 0, 0) }
			tickZone:Track(item, function()
				return item.Position
			end)
			board[index] = { Name = "Player" .. index, Score = 0 }
		end
		local tickServer = keep(Network.Server.new("BenchTick", { Parent = Instance.new("Folder"), OnError = noop }))
		local tickBuy = tickServer:Event("Buy", { Schema = schema, RateLimit = { Count = 1e9, Per = 1 } })
		tickBuy:Connect(noop)
		local tickReplicator = keep(Replication.Server.new("BenchTickReplication", {
			Parent = Instance.new("Folder"),
			Delta = true,
			OnError = noop,
		}))
		tickReplicator._update.FireList = noop
		local leaderboard = State.new(board)
		tickReplicator:Share("Leaderboard", leaderboard)
		local tickSignal = Constella.Signal.new()
		for _ = 1, PLAYERS do
			tickSignal:Connect(noop)
		end
		local tick = 0
		case("Scenario", "Server tick, 50 players", "Constella" .. suffix, 200, function(n)
			for _ = 1, n do
				tick += 1
				for index = 1, PLAYERS do
					coins[index]:Set(tick + index)
					tickBuy:_receive(fakes[index], "Sword", 2, { Note = "gift" })
				end
				tickZone:Step()
				local nextBoard = table.clone(leaderboard:Get())
				nextBoard[tick % PLAYERS + 1] = { Name = "Player", Score = tick }
				leaderboard:Set(nextBoard)
				tickSignal:Fire(tick)
				for index = 1, 10 do
					Promise.resolve(index):Then(one)
				end
			end
		end)
	end

	local multiple = #packages > 1
	local builds = {}
	for index, package in packages do
		local suffix = if multiple then (" [%s]"):format(package.Name or package.Module.Name) else ""
		table.insert(builds, { Constella = require(package.Module), suffix = suffix, index = index })
	end
	for _, build in builds do
		currentBuild = build.index
		constellaCases(build.Constella, build.suffix, build.index)
	end
	currentBuild = nil

	if OtherSignal then
		signalCases("sleitnick/signal (errors not isolated)", OtherSignal.new, plain)
		-- Same guarantee as Constella: each listener wrapped in xpcall.
		signalCases("sleitnick/signal + xpcall per listener (errors isolated)", OtherSignal.new, isolated)
	end
	if LemonSignal then
		signalCases("LemonSignal (errors not isolated)", LemonSignal.new, plain)
		signalCases("LemonSignal + xpcall per listener (errors isolated)", LemonSignal.new, isolated)
	end
	if Trove then
		cleanupCases("sleitnick/trove", {
			new = Trove.new,
			addFunction = function(manager, fn)
				manager:Add(fn)
			end,
			addConnection = function(manager, event, fn)
				manager:Connect(event, fn)
			end,
			clean = function(manager)
				manager:Clean()
			end,
		})
	end
	if Janitor then
		cleanupCases("Janitor", {
			new = Janitor.new,
			addFunction = function(manager, fn)
				manager:Add(fn, true)
			end,
			addConnection = function(manager, event, fn)
				manager:Add(event:Connect(fn), "Disconnect")
			end,
			clean = function(manager)
				manager:Cleanup()
			end,
		})
	end
	if OtherPromise then
		promiseCases("evaera/roblox-lua-promise", {
			resolve = OtherPromise.resolve,
			new = OtherPromise.new,
			andThen = function(promise, fn)
				return promise:andThen(fn)
			end,
			await = function(promise)
				return promise:await()
			end,
		})
	end
	case("Pool", "Spawn + despawn a Part", "Clone + Destroy (no pool)", 2000, function(n)
		for _ = 1, n do
			local part = template:Clone()
			part.Parent = folder
			part:Destroy()
		end
	end)
	-- Hand-written baselines without any validation, so the comparison is
	-- about the selection algorithm and not only about validation cost.
	case("Random", "Weighted roll, 100 entries", "Hand-written: sum, then linear scan (each call)", 5000, function(n)
		for _ = 1, n do
			local total = 0
			for _, entry in entries do
				total += entry.Weight
			end
			local roll = rng:NextNumber() * total
			for _, entry in entries do
				roll -= entry.Weight
				if roll < 0 then
					break
				end
			end
		end
	end)
	local cumulative, cumulativeTotal = table.create(#entries), 0
	for index, entry in entries do
		cumulativeTotal += entry.Weight
		cumulative[index] = cumulativeTotal
	end
	case("Random", "Weighted roll, 100 entries", "Hand-written: precomputed totals, linear scan", 50000, function(n)
		for _ = 1, n do
			local roll = rng:NextNumber() * cumulativeTotal
			for index = 1, #cumulative do
				if roll < cumulative[index] then
					break
				end
			end
		end
	end)

	-- Report order: groups and cases in order of first appearance, so every
	-- implementation of a case sits together. Within a case, the builds of
	-- one implementation are next to each other ("X [this build]" then
	-- "X [baseline]"), then the next implementation.
	local firstSeen = {}
	for index, entry in cases do
		firstSeen[entry.group] = firstSeen[entry.group] or index
		local caseKey = entry.group .. "\0" .. entry.name
		firstSeen[caseKey] = firstSeen[caseKey] or index
		local implementationKey = caseKey .. "\0" .. (string.gsub(entry.implementation, " %[[^%]]*%]$", ""))
		firstSeen[implementationKey] = firstSeen[implementationKey] or index
		entry.slot = firstSeen[implementationKey]
		entry.position = entry.slot + index / (#cases + 1)
	end
	table.sort(cases, function(a, b)
		local groupA, groupB = firstSeen[a.group], firstSeen[b.group]
		if groupA ~= groupB then
			return groupA < groupB
		end
		local caseA, caseB = firstSeen[a.group .. "\0" .. a.name], firstSeen[b.group .. "\0" .. b.name]
		if caseA ~= caseB then
			return caseA < caseB
		end
		return a.position < b.position
	end)

	-- The same cases with the builds of each implementation in reverse order.
	-- Every other run uses it, so no build always runs first (straight after
	-- the previous case, whose garbage the collector may still be working on).
	local reversed: { any } = {}
	local first = 1
	while first <= #cases do
		local last = first
		while last < #cases and cases[last + 1].slot == cases[first].slot do
			last += 1
		end
		for index = last, first, -1 do
			table.insert(reversed, cases[index])
		end
		first = last + 1
	end

	for run = 1, runs do
		local order = if run % 2 == 0 then reversed else cases
		for _, entry in order do
			local median = Bench.measure(entry.run, entry.iterations, 5)
			table.insert(entry.samples, median)
		end
	end
	for _, object in fixtures do
		pcall(function()
			object:Destroy()
		end)
	end

	-- Memory ----------------------------------------------------------------
	local COUNT = 5000
	local memory = {}
	local function memoryCase(name, implementation, build, count, trials)
		local objects = count or COUNT
		table.insert(memory, { name, implementation, Bench.bytesPerObject(build, objects, trials), objects })
	end
	-- Promises allocate several times more per object than a connection, so
	-- 5,000 of them usually overlap a garbage collection step, which makes
	-- the sample smaller. Smaller builds, more of them, avoid that.
	local PROMISE_COUNT, PROMISE_TRIALS = 500, 61
	local function listeners(new)
		return function(count)
			local signal = new()
			for _ = 1, count do
				signal:Connect(noop)
			end
			return signal
		end
	end
	for _, build in builds do
		memoryCase("Connected listener", "Constella.Signal" .. build.suffix, listeners(build.Constella.Signal.new))
	end
	if OtherSignal then
		memoryCase("Connected listener", "sleitnick/signal", listeners(OtherSignal.new))
	end
	if LemonSignal then
		memoryCase("Connected listener", "LemonSignal", listeners(LemonSignal.new))
	end
	-- The functions already exist (`distinct`), so only the manager's own
	-- storage is counted.
	for _, build in builds do
		local Cleanup = build.Constella.Cleanup
		memoryCase("Tracked function", "Constella.Cleanup" .. build.suffix, function(count)
			local manager = Cleanup.new()
			for index = 1, count do
				manager:Add(distinct[index])
			end
			return manager
		end)
	end
	if Trove then
		memoryCase("Tracked function", "sleitnick/trove", function(count)
			local manager = Trove.new()
			for index = 1, count do
				manager:Add(distinct[index])
			end
			return manager
		end)
	end
	if Janitor then
		memoryCase("Tracked function", "Janitor", function(count)
			local manager = Janitor.new()
			for index = 1, count do
				manager:Add(distinct[index], true)
			end
			return manager
		end)
	end
	local function resolvedPromises(resolve)
		return function(count)
			local kept = table.create(count)
			for index = 1, count do
				kept[index] = resolve(index)
			end
			return kept
		end
	end
	for _, build in builds do
		local Promise, suffix = build.Constella.Promise, build.suffix
		-- Each includes the 16-byte array slot that keeps the promise.
		memoryCase(
			"Resolved promise",
			"Constella.Promise" .. suffix,
			resolvedPromises(Promise.resolve),
			PROMISE_COUNT,
			PROMISE_TRIALS
		)
		-- A pending child: the promise, its link to the parent and the
		-- parent's queue entry for it. (Promise.new is not measured: its
		-- executor's work is garbage straight away and would count too.)
		memoryCase("Pending promise from Then", "Constella.Promise" .. suffix, function(count)
			local root = Promise.new(noop)
			local kept = table.create(count)
			for index = 1, count do
				kept[index] = root:Then(one)
			end
			return { root, kept }
		end, PROMISE_COUNT, PROMISE_TRIALS)
	end
	if OtherPromise then
		memoryCase(
			"Resolved promise",
			"evaera/roblox-lua-promise",
			resolvedPromises(OtherPromise.resolve),
			PROMISE_COUNT,
			PROMISE_TRIALS
		)
		memoryCase("Pending promise from Then", "evaera/roblox-lua-promise", function(count)
			local root = OtherPromise.new(noop)
			local kept = table.create(count)
			for index = 1, count do
				kept[index] = root:andThen(one)
			end
			return { root, kept }
		end, PROMISE_COUNT, PROMISE_TRIALS)
	end

	-- Bandwidth: what one update of a 40-item inventory sends. ---------------
	local bandwidth = {}
	local measureLimits = { MaxBytes = math.huge, MaxDepth = 64, MaxNodes = math.huge }
	for _, build in builds do
		local Constella, suffix = build.Constella, build.suffix
		for _, delta in { false, true } do
			local replicator = Constella.Replication.Server.new("BenchBandwidth", {
				Parent = Instance.new("Folder"),
				Delta = delta,
				OnError = noop,
			})
			if delta and replicator._delta == nil then
				replicator:Destroy()
				continue
			end
			local sent = {}
			replicator._update.FireList = function(_, _players, ...)
				table.insert(sent, table.pack(...))
			end
			local share = Constella.State.new(inventory(0))
			replicator:Share("Inventory", share)
			local value = table.clone(share:Get())
			value.Coins = 1
			share:Set(value)
			local message = sent[#sent]
			local bytes = Constella.Network.Payload.measure(measureLimits, table.unpack(message, 1, message.n))
			table.insert(bandwidth, {
				(if delta then "Constella.Replication, `Delta = true`" else "Constella.Replication, full value")
					.. suffix,
				bytes,
			})
			replicator:Destroy()
		end
	end

	-- Leak checks: the owner stays alive; released objects must be freed. ------
	local LEAK_COUNT = 2000
	local leaks = {}
	local owners = {}
	local function leakCase(name, build)
		local remaining, seconds = Bench.leakCheck(build, 15)
		table.insert(leaks, { name, LEAK_COUNT, remaining, seconds })
	end
	for _, build in builds do
		local Constella, suffix = build.Constella, build.suffix
		leakCase("Signal: disconnected listeners (signal kept alive)" .. suffix, function()
			local signal = Constella.Signal.new()
			owners.signal = signal
			local objects, connections = {}, {}
			for index = 1, LEAK_COUNT do
				local listener = function()
					return index
				end
				table.insert(objects, listener)
				table.insert(connections, signal:Connect(listener))
			end
			signal:Fire()
			return objects,
				function()
					for _, connection in connections do
						connection:Disconnect()
					end
				end
		end)
		leakCase("Signal: listeners of kept, disconnected connections" .. suffix, function()
			local signal = Constella.Signal.new()
			owners.signal = signal
			local objects, connections = {}, {}
			for index = 1, LEAK_COUNT do
				local listener = function()
					return index
				end
				table.insert(objects, listener)
				table.insert(connections, signal:Connect(listener))
			end
			signal:Fire()
			owners.connections = connections -- the connections themselves stay referenced
			return objects,
				function()
					for _, connection in connections do
						connection:Disconnect()
					end
				end
		end)
		leakCase("Cleanup: cleaned resources (manager kept alive)" .. suffix, function()
			local manager = Constella.Cleanup.new()
			owners.cleanup = manager
			local objects = {}
			for index = 1, LEAK_COUNT do
				local resource = function()
					return index
				end
				table.insert(objects, resource)
				manager:Add(resource)
			end
			return objects, function()
				manager:Clean()
			end
		end)
		leakCase("State: unsubscribed callbacks (state kept alive)" .. suffix, function()
			local value = Constella.State.new(0)
			owners.state = value
			local objects, connections = {}, {}
			for index = 1, LEAK_COUNT do
				local callback = function()
					return index
				end
				table.insert(objects, callback)
				table.insert(connections, value:Subscribe(callback))
			end
			value:Set(1)
			return objects,
				function()
					for _, connection in connections do
						connection:Disconnect()
					end
				end
		end)
		leakCase("Pool: objects destroyed past MaxIdle (pool kept alive)" .. suffix, function()
			local pool = Constella.Pool.new({
				Create = function()
					return {}
				end,
				MaxIdle = 0,
			})
			owners.pool = pool
			local objects = {}
			for _ = 1, LEAK_COUNT do
				table.insert(objects, pool:Acquire())
			end
			return objects, function()
				for _, object in objects do
					pool:Release(object)
				end
			end
		end)
		leakCase("Promise: values of promises a kept chain came from" .. suffix, function()
			local Promise = Constella.Promise
			local objects, chains = {}, {}
			for _ = 1, LEAK_COUNT do
				local payload = {}
				table.insert(objects, payload)
				table.insert(chains, Promise.resolve(payload):Then(one))
			end
			owners.chains = chains -- the end of each chain stays referenced
			-- One more job, so a recycled handler thread doesn't hold the
			-- last payload in an unused stack slot (bounded, not a leak).
			Promise.resolve(nil):Then(one)
			return objects, function() end
		end)
		table.clear(owners)
	end

	-- Report ------------------------------------------------------------------------
	-- version() is deprecated, but its replacement RunService:GetRobloxVersion()
	-- needs RobloxScript capability, which the command bar and plugins lack.
	-- selene: allow(undefined_variable)
	local hasVersion, engineVersion = pcall(version)
	local lines = {
		("Runs: %d (each the median of 5 trials). Roblox %s."):format(
			runs,
			if hasVersion then tostring(engineVersion) else "(version unavailable)"
		),
		"",
	}

	-- A/B: the first build against the second, case by case.
	local comparisons = {}
	local regressions = {}
	if multiple then
		local byKey = {}
		for _, entry in cases do
			if entry.build then
				byKey[entry.slot .. ":" .. entry.build] = entry
			end
		end
		local intervalRng = Random.new(20261114)
		for _, entry in cases do
			local baseline = entry.build == 1 and byKey[entry.slot .. ":2"]
			if baseline then
				local ratio, lower, upper = Bench.ratioInterval(entry.samples, baseline.samples, intervalRng)
				local label = if upper < 0.97 then "faster" elseif lower > 1.03 then "slower" else "same"
				comparisons[entry] = ("%+.0f%% [%+.0f, %+.0f] %s"):format(
					(ratio - 1) * 100,
					(lower - 1) * 100,
					(upper - 1) * 100,
					label
				)
				if ratio > REGRESSION_RATIO and lower > REGRESSION_LOWER then
					table.insert(
						regressions,
						("REGRESSION | %s: %s | %s | %s"):format(
							entry.group,
							entry.name,
							entry.implementation,
							comparisons[entry]
						)
					)
				end
			end
		end
	end

	table.insert(
		lines,
		"| Group | Case | Implementation | Median µs/op | Best run | Worst run | vs baseline (95% CI) |"
	)
	table.insert(lines, "| --- | --- | --- | ---: | ---: | ---: | --- |")
	for _, entry in cases do
		entry.inRunOrder = table.clone(entry.samples)
		table.sort(entry.samples)
		local count = #entry.samples
		table.insert(
			lines,
			("| %s | %s | %s | %.3f | %.3f | %.3f | %s |"):format(
				entry.group,
				entry.name,
				entry.implementation,
				Bench.median(entry.samples),
				entry.samples[1],
				entry.samples[count],
				comparisons[entry] or ""
			)
		)
	end
	table.insert(lines, "")
	if #regressions > 0 then
		table.insert(lines, "Regressions (more than 10% slower, 95% interval above +5%):")
		table.insert(lines, "")
		for _, line in regressions do
			table.insert(lines, line)
		end
	else
		table.insert(lines, "No regressions.")
	end

	-- Every run's result, in the order the runs happened.
	table.insert(lines, "")
	local header, divider = { "| Case | Implementation |" }, { "| --- | --- |" }
	for run = 1, runs do
		table.insert(header, (" Run %d |"):format(run))
		table.insert(divider, " ---: |")
	end
	table.insert(lines, table.concat(header))
	table.insert(lines, table.concat(divider))
	for _, entry in cases do
		local cells = { ("| %s: %s | %s |"):format(entry.group, entry.name, entry.implementation) }
		for _, sample in entry.inRunOrder do
			table.insert(cells, (" %.3f |"):format(sample))
		end
		table.insert(lines, table.concat(cells))
	end

	table.insert(lines, "")
	table.insert(lines, "| Memory per object | Implementation | Bytes | Objects per build |")
	table.insert(lines, "| --- | --- | ---: | ---: |")
	for _, row in memory do
		table.insert(lines, ("| %s | %s | %d | %d |"):format(row[1], row[2], math.floor(row[3] + 0.5), row[4]))
	end
	table.insert(lines, "")
	table.insert(lines, "| Bytes per update (one field of a 40-item inventory changes) | Bytes |")
	table.insert(lines, "| --- | ---: |")
	for _, row in bandwidth do
		table.insert(lines, ("| %s | %d |"):format(row[1], row[2]))
	end
	table.insert(lines, "")
	table.insert(lines, "| Leak check | Released | Still alive | Seconds |")
	table.insert(lines, "| --- | ---: | ---: | ---: |")
	for _, row in leaks do
		table.insert(lines, ("| %s | %d | %d | %.1f |"):format(row[1], row[2], row[3], row[4]))
	end
	return table.concat(lines, "\n")
end
