--!nonstrict
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

	Method
	- Speed: the whole suite runs `Runs` times (default 5). Within a run,
	  each case is the median of 5 timed trials. The report shows the
	  median across runs, and the best and worst run.
	- Memory: bytes per object, 80th percentile of 21 builds of 5,000
	  objects (see Bench.bytesPerObject for why).
	- Leaks: objects are released while their owner stays alive, then the
	  check waits for the garbage collector to free them (see Bench.luau).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Bench = require(script.Parent.Bench)

local function noop() end

local function traceback(err)
	return debug.traceback(tostring(err), 2)
end

return function(options: { Runs: number? }?): string
	local runs = (options and options.Runs) or 5
	local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
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
	end
	local function plain(fn)
		return fn
	end
	-- Constella always isolates listener errors (xpcall + OnError).
	signalCases("Constella.Signal (errors isolated)", Constella.Signal.new, plain)
	if OtherSignal then
		signalCases("sleitnick/signal (errors not isolated)", OtherSignal.new, plain)
		-- Same guarantee as Constella: each listener wrapped in xpcall.
		signalCases("sleitnick/signal + xpcall per listener (errors isolated)", OtherSignal.new, function(fn)
			return function(...)
				xpcall(fn, traceback, ...)
			end
		end)
	end

	local bindable = Instance.new("BindableEvent")
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
	cleanupCases("Constella.Cleanup", Constella.Cleanup.new)
	if Trove then
		cleanupCases("sleitnick/trove", Trove.new)
	end

	local template = Instance.new("Part")
	template.Anchored = true
	local folder = Instance.new("Folder")
	folder.Parent = workspace
	case("Pool", "Spawn + despawn a Part", "Clone + Destroy (no pool)", 2000, function(n)
		for _ = 1, n do
			local part = template:Clone()
			part.Parent = folder
			part:Destroy()
		end
	end)
	case("Pool", "Spawn + despawn a Part", "Constella.Pool", 2000, function(n)
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
	local buy = server:Event("Buy", {
		Schema = { Check.string(20), Check.integer(1, 99), Check.record({ Note = Check.optional(Check.string(50)) }) },
		RateLimit = { Count = 1e9, Per = 1 },
	})
	buy:Connect(noop)
	local player = { Name = "Bench" }
	case("Network", "Accept a valid request (all checks)", "Constella.Network", 20000, function(n)
		for _ = 1, n do
			buy:_receive(player, "Sword", 2, { Note = "gift" })
		end
	end)
	case("Network", "Reject a forged request", "Constella.Network", 20000, function(n)
		for _ = 1, n do
			buy:_receive(player, "Sword", 0 / 0, { Admin = true })
		end
	end)

	local entries = {}
	for index = 1, 100 do
		entries[index] = { Value = index, Weight = index }
	end
	local loot = Constella.Random.lootTable(entries)
	local rng = Random.new(1)
	case("Random", "Weighted roll, 100 entries", "Random.choose (validates each call)", 5000, function(n)
		for _ = 1, n do
			Constella.Random.choose(entries, rng)
		end
	end)
	case("Random", "Weighted roll, 100 entries", "Random.lootTable:Roll (precomputed)", 50000, function(n)
		for _ = 1, n do
			loot:Roll(rng)
		end
	end)

	case("State", "Set with 1 subscriber", "Constella.State", 20000, function(n)
		local value = Constella.State.new(0)
		value:Subscribe(noop)
		for index = 1, n do
			value:Set(index)
		end
	end)

	for _ = 1, runs do
		for _, entry in cases do
			local median = Bench.measure(entry.run, entry.iterations, 5)
			table.insert(entry.samples, median)
		end
	end
	server:Destroy()
	folder:Destroy()
	template:Destroy()

	-- Memory ----------------------------------------------------------------
	local COUNT = 5000
	local memory = {}
	local function memoryCase(name, implementation, build)
		table.insert(memory, { name, implementation, Bench.bytesPerObject(build, COUNT) })
	end
	memoryCase("Connected listener", "Constella.Signal", function(count)
		local signal = Constella.Signal.new()
		for _ = 1, count do
			signal:Connect(noop)
		end
		return signal
	end)
	if OtherSignal then
		memoryCase("Connected listener", "sleitnick/signal", function(count)
			local signal = OtherSignal.new()
			for _ = 1, count do
				signal:Connect(noop)
			end
			return signal
		end)
	end
	memoryCase("Tracked function", "Constella.Cleanup", function(count)
		local manager = Constella.Cleanup.new()
		for _ = 1, count do
			manager:Add(noop)
		end
		return manager
	end)
	if Trove then
		memoryCase("Tracked function", "sleitnick/trove", function(count)
			local manager = Trove.new()
			for _ = 1, count do
				manager:Add(noop)
			end
			return manager
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
	leakCase("Signal: disconnected listeners (signal kept alive)", function()
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
		return objects, function()
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end)
	leakCase("Cleanup: cleaned resources (manager kept alive)", function()
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
	leakCase("State: unsubscribed callbacks (state kept alive)", function()
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
		return objects, function()
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end)
	leakCase("Pool: objects destroyed past MaxIdle (pool kept alive)", function()
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
	table.clear(owners)
	bindable:Destroy()

	-- Report ------------------------------------------------------------------------
	local lines = {
		("Runs: %d (each the median of 5 trials). Studio %s."):format(
			runs,
			game:GetService("RunService"):GetRobloxVersion()
		),
		"",
		"| Group | Case | Implementation | Median µs/op | Best run | Worst run |",
		"| --- | --- | --- | ---: | ---: | ---: |",
	}
	for _, entry in cases do
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
