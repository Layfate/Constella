--!nonstrict
--!nolint DeprecatedApi
--[=[
	Constella benchmarks. Run from the Studio command bar (Edit mode):

	```lua
	print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)())
	print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)({ Runs = 10 }))
	```

	Optional comparisons: put these ModuleScripts in ServerStorage.BenchmarkLibs
	- "Signal" - sleitnick/signal (GoodSignal-style)
	- "Trove"  - sleitnick/trove
	Missing libraries are skipped. Returns a Markdown report.

	A/B comparisons: pass several builds of the package, for example the
	current code and the last release. Every case runs for every build inside
	each run, alternating, so the builds are measured under the same
	conditions. Implementation names then end in "[name]".

	```lua
	RunBenchmarks({
		Runs = 5,
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
	- Memory: bytes per object, 80th percentile of 21 builds of 5,000
	  objects (see Bench.bytesPerObject for why).
	- Leaks: objects are released while their owner stays alive, then the
	  check waits for the garbage collector to free them (see Bench.luau).
]=]

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

return function(options: { Runs: number?, Packages: { Package }? }?): string
	local runs = (options and options.Runs) or 5
	local packages: { Package } = (options and options.Packages)
		or { { Module = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella") } }
	local libs = ServerStorage:FindFirstChild("BenchmarkLibs")
	local OtherSignal = libs and libs:FindFirstChild("Signal") and require(libs.Signal :: any)
	local Trove = libs and libs:FindFirstChild("Trove") and require(libs.Trove :: any)

	-- Speed cases ----------------------------------------------------------
	local cases = {}
	local function case(group, name, implementation, iterations, run)
		table.insert(cases, {
			group = group,
			name = name,
			implementation = implementation,
			iterations = iterations,
			run = run,
			samples = {},
		})
	end

	local bindable = Instance.new("BindableEvent")
	local template = Instance.new("Part")
	template.Anchored = true
	local folder = Instance.new("Folder")
	folder.Parent = workspace
	local servers = {}
	local player = { Name = "Bench" }

	local entries = {}
	for index = 1, 100 do
		entries[index] = { Value = index, Weight = index }
	end
	local rng = Random.new(1)

	local function plain(fn)
		return fn
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

	local function cleanupCases(label, new)
		case("Cleanup", "Add + Clean 100 functions", label, 300, function(n)
			for _ = 1, n do
				local manager = new()
				for _ = 1, 100 do
					manager:Add(noop)
				end
				manager:Clean()
			end
		end)
		case("Cleanup", "Connect + Clean 100 RBXScriptConnections", label, 100, function(n)
			for _ = 1, n do
				local manager = new()
				for _ = 1, 100 do
					manager:Connect(bindable.Event, noop)
				end
				manager:Clean()
			end
		end)
	end

	-- Every case that measures Constella, for one build of the package.
	local function constellaCases(Constella, suffix)
		-- Constella always isolates listener errors (xpcall + OnError).
		signalCases("Constella.Signal" .. suffix, Constella.Signal.new, plain)
		cleanupCases("Constella.Cleanup" .. suffix, Constella.Cleanup.new)

		case("Pool", "Spawn + despawn a Part", "Constella.Pool" .. suffix, 2000, function(n)
			local pool = Constella.Pool.instances(template, { MaxIdle = 16 })
			for _ = 1, n do
				local part = pool:Acquire()
				part.Parent = folder
				pool:Release(part)
			end
			pool:Destroy()
		end)

		local Check = Constella.Network.Check
		local server = Constella.Network.Server.new("Benchmark", { Parent = Instance.new("Folder"), OnError = noop })
		table.insert(servers, server)
		local buy = server:Event("Buy", {
			Schema = {
				Check.string(20),
				Check.integer(1, 99),
				Check.record({ Note = Check.optional(Check.string(50)) }),
			},
			RateLimit = { Count = 1e9, Per = 1 },
		})
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
		case("Promise", "resolve + Then + Await", "Constella.Promise" .. suffix, 5000, function(n)
			for _ = 1, n do
				Promise.resolve(1):Then(one):Await()
			end
		end)
		case("Promise", "Chain 10 Thens, then resolve", "Constella.Promise" .. suffix, 1000, function(n)
			for _ = 1, n do
				local resolve
				local promise = Promise.new(function(done)
					resolve = done
				end)
				for _ = 1, 10 do
					promise = promise:Then(one)
				end
				resolve(1)
			end
		end)
	end

	local multiple = #packages > 1
	local builds = {}
	for _, package in packages do
		local suffix = if multiple then (" [%s]"):format(package.Name or package.Module.Name) else ""
		table.insert(builds, { Constella = require(package.Module), suffix = suffix })
	end
	-- Cases are added build by build per group, so each group's rows sit together.
	for _, build in builds do
		constellaCases(build.Constella, build.suffix)
	end

	if OtherSignal then
		signalCases("sleitnick/signal (errors not isolated)", OtherSignal.new, plain)
		-- Same guarantee as Constella: each listener wrapped in xpcall.
		signalCases("sleitnick/signal + xpcall per listener (errors isolated)", OtherSignal.new, function(fn)
			return function(...)
				xpcall(fn, traceback, ...)
			end
		end)
	end
	if Trove then
		cleanupCases("sleitnick/trove", Trove.new)
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
	-- implementation of a case sits together; within a case, the order the
	-- implementations were added.
	local firstSeen = {}
	for index, entry in cases do
		entry.position = index
		firstSeen[entry.group] = firstSeen[entry.group] or index
		local caseKey = entry.group .. "\0" .. entry.name
		firstSeen[caseKey] = firstSeen[caseKey] or index
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

	for _ = 1, runs do
		for _, entry in cases do
			local median = Bench.measure(entry.run, entry.iterations, 5)
			table.insert(entry.samples, median)
		end
	end
	for _, server in servers do
		server:Destroy()
	end
	folder:Destroy()
	template:Destroy()

	-- Memory ----------------------------------------------------------------
	local COUNT = 5000
	local memory = {}
	local function memoryCase(name, implementation, build)
		table.insert(memory, { name, implementation, Bench.bytesPerObject(build, COUNT) })
	end
	for _, build in builds do
		local Constella, suffix = build.Constella, build.suffix
		memoryCase("Connected listener", "Constella.Signal" .. suffix, function(count)
			local signal = Constella.Signal.new()
			for _ = 1, count do
				signal:Connect(noop)
			end
			return signal
		end)
	end
	if OtherSignal then
		memoryCase("Connected listener", "sleitnick/signal", function(count)
			local signal = OtherSignal.new()
			for _ = 1, count do
				signal:Connect(noop)
			end
			return signal
		end)
	end
	for _, build in builds do
		local Constella, suffix = build.Constella, build.suffix
		memoryCase("Tracked function", "Constella.Cleanup" .. suffix, function(count)
			local manager = Constella.Cleanup.new()
			for _ = 1, count do
				manager:Add(noop)
			end
			return manager
		end)
	end
	if Trove then
		memoryCase("Tracked function", "sleitnick/trove", function(count)
			local manager = Trove.new()
			for _ = 1, count do
				manager:Add(noop)
			end
			return manager
		end)
	end
	for _, build in builds do
		local Promise, suffix = build.Constella.Promise, build.suffix
		memoryCase("Resolved promise", "Constella.Promise" .. suffix, function(count)
			local kept = table.create(count)
			for index = 1, count do
				kept[index] = Promise.resolve(index)
			end
			return kept
		end)
		memoryCase("Settled promise with one Then", "Constella.Promise" .. suffix, function(count)
			local kept = table.create(count)
			for index = 1, count do
				kept[index] = Promise.resolve(index):Then(one)
			end
			return kept
		end)
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
			return objects, function() end
		end)
		table.clear(owners)
	end
	bindable:Destroy()

	-- Report ------------------------------------------------------------------------
	-- version() is deprecated, but its replacement RunService:GetRobloxVersion()
	-- needs RobloxScript capability, which the command bar and plugins lack.
	-- selene: allow(undefined_variable)
	local hasVersion, studioVersion = pcall(version)
	local lines = {
		("Runs: %d (each the median of 5 trials). Roblox %s."):format(
			runs,
			if hasVersion then tostring(studioVersion) else "(version unavailable)"
		),
		"",
		"| Group | Case | Implementation | Median µs/op | Best run | Worst run |",
		"| --- | --- | --- | ---: | ---: | ---: |",
	}
	for _, entry in cases do
		entry.inRunOrder = table.clone(entry.samples)
		table.sort(entry.samples)
		local count = #entry.samples
		table.insert(
			lines,
			("| %s | %s | %s | %.3f | %.3f | %.3f |"):format(
				entry.group,
				entry.name,
				entry.implementation,
				entry.samples[(count + 1) // 2],
				entry.samples[1],
				entry.samples[count]
			)
		)
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
	table.insert(lines, ("| Memory per object (%d objects) | Implementation | Bytes |"):format(COUNT))
	table.insert(lines, "| --- | --- | ---: |")
	for _, row in memory do
		table.insert(lines, ("| %s | %s | %d |"):format(row[1], row[2], math.floor(row[3] + 0.5)))
	end
	table.insert(lines, "")
	table.insert(lines, "| Leak check | Released | Still alive | Seconds |")
	table.insert(lines, "| --- | ---: | ---: | ---: |")
	for _, row in leaks do
		table.insert(lines, ("| %s | %d | %d | %.1f |"):format(row[1], row[2], row[3], row[4]))
	end
	return table.concat(lines, "\n")
end
