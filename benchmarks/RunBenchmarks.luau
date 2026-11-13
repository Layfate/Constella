--!nonstrict
--[=[
	Constella benchmarks. Run from the Studio command bar (Edit mode):

	```lua
	print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)())
	```

	Optional comparisons: put these ModuleScripts in ServerStorage.BenchmarkLibs
	- "Signal" - sleitnick/signal (GoodSignal-style)
	- "Trove"  - sleitnick/trove
	Missing libraries are skipped. Returns a Markdown report.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Bench = require(script.Parent.Bench)

local function noop() end

return function(): string
	local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
	local libs = ServerStorage:FindFirstChild("BenchmarkLibs")
	local OtherSignal = libs and libs:FindFirstChild("Signal") and require(libs.Signal)
	local Trove = libs and libs:FindFirstChild("Trove") and require(libs.Trove)

	local rows = {}
	local function record(group, case, library, run, iterations, trials)
		local median, fastest, slowest = Bench.measure(run, iterations, trials)
		table.insert(rows, { group, case, library, median, fastest, slowest })
	end

	-- Signal ----------------------------------------------------------------
	local function signalCases(name, new)
		record("Signal", "Connect + Disconnect", name, function(n)
			local signal = new()
			for _ = 1, n do
				signal:Connect(noop):Disconnect()
			end
		end, 20000)
		record("Signal", "Fire, 1 listener", name, function(n)
			local signal = new()
			signal:Connect(noop)
			for _ = 1, n do
				signal:Fire(1, 2)
			end
		end, 20000)
		record("Signal", "Fire, 10 listeners", name, function(n)
			local signal = new()
			for _ = 1, 10 do
				signal:Connect(noop)
			end
			for _ = 1, n do
				signal:Fire(1, 2)
			end
		end, 5000)
	end
	signalCases("Constella.Signal", Constella.Signal.new)
	if OtherSignal then
		signalCases("sleitnick/signal", OtherSignal.new)
	end

	-- Cleanup ---------------------------------------------------------------
	local bindable = Instance.new("BindableEvent")
	local function cleanupCases(name, new, add, connect, clean)
		record("Cleanup", "Add + Clean 100 functions", name, function(n)
			for _ = 1, n do
				local manager = new()
				for _ = 1, 100 do
					add(manager, noop)
				end
				clean(manager)
			end
		end, 300)
		record("Cleanup", "Connect + Clean 100 RBXScriptConnections", name, function(n)
			for _ = 1, n do
				local manager = new()
				for _ = 1, 100 do
					connect(manager, bindable.Event, noop)
				end
				clean(manager)
			end
		end, 100)
	end
	cleanupCases("Constella.Cleanup", Constella.Cleanup.new, function(m, x)
		m:Add(x)
	end, function(m, s, f)
		m:Connect(s, f)
	end, function(m)
		m:Clean()
	end)
	if Trove then
		cleanupCases("sleitnick/trove", Trove.new, function(m, x)
			m:Add(x)
		end, function(m, s, f)
			m:Connect(s, f)
		end, function(m)
			m:Clean()
		end)
	end

	-- Pool --------------------------------------------------------------------
	local template = Instance.new("Part")
	template.Anchored = true
	local folder = Instance.new("Folder")
	folder.Parent = workspace
	record("Pool", "Spawn + despawn a Part", "Clone + Destroy (no pool)", function(n)
		for _ = 1, n do
			local part = template:Clone()
			part.Parent = folder
			part:Destroy()
		end
	end, 2000)
	record("Pool", "Spawn + despawn a Part", "Constella.Pool", function(n)
		local pool = Constella.Pool.instances(template, { MaxIdle = 16 })
		for _ = 1, n do
			local part = pool:Acquire()
			part.Parent = folder
			pool:Release(part)
		end
		pool:Destroy()
	end, 2000)

	-- Network -------------------------------------------------------------------
	local Check = Constella.Network.Check
	local server = Constella.Network.Server.new("Benchmark", { Parent = Instance.new("Folder"), OnError = noop })
	local buy = server:Event("Buy", {
		Schema = { Check.string(20), Check.integer(1, 99), Check.record({ Note = Check.optional(Check.string(50)) }) },
		RateLimit = { Count = 1e9, Per = 1 },
	})
	buy:Connect(noop)
	local player = { Name = "Bench" }
	record("Network", "Accept a valid request (all checks)", "Constella.Network", function(n)
		for _ = 1, n do
			buy:_receive(player, "Sword", 2, { Note = "gift" })
		end
	end, 20000)
	record("Network", "Reject a forged request", "Constella.Network", function(n)
		for _ = 1, n do
			buy:_receive(player, "Sword", 0 / 0, { Admin = true })
		end
	end, 20000)
	server:Destroy()

	-- Random --------------------------------------------------------------------
	local entries = {}
	for index = 1, 100 do
		entries[index] = { Value = index, Weight = index }
	end
	local loot = Constella.Random.lootTable(entries)
	local rng = Random.new(1)
	record("Random", "Weighted roll, 100 entries", "Random.choose (validates each call)", function(n)
		for _ = 1, n do
			Constella.Random.choose(entries, rng)
		end
	end, 5000)
	record("Random", "Weighted roll, 100 entries", "Random.lootTable:Roll (precomputed)", function(n)
		for _ = 1, n do
			loot:Roll(rng)
		end
	end, 50000)

	-- State -----------------------------------------------------------------------
	record("State", "Set with 1 subscriber", "Constella.State", function(n)
		local value = Constella.State.new(0)
		value:Subscribe(noop)
		for index = 1, n do
			value:Set(index)
		end
	end, 20000)

	-- Memory (approximate) --------------------------------------------------------
	local memory = {}
	local function memoryCase(case, library, build)
		table.insert(memory, { case, library, Bench.memoryKB(build) })
	end
	memoryCase("10,000 connected listeners", "Constella.Signal", function()
		local signal = Constella.Signal.new()
		for _ = 1, 10000 do
			signal:Connect(noop)
		end
		return signal
	end)
	if OtherSignal then
		memoryCase("10,000 connected listeners", "sleitnick/signal", function()
			local signal = OtherSignal.new()
			for _ = 1, 10000 do
				signal:Connect(noop)
			end
			return signal
		end)
	end
	memoryCase("10,000 tracked functions", "Constella.Cleanup", function()
		local manager = Constella.Cleanup.new()
		for _ = 1, 10000 do
			manager:Add(function() end)
		end
		return manager
	end)
	if Trove then
		memoryCase("10,000 tracked functions", "sleitnick/trove", function()
			local manager = Trove.new()
			for _ = 1, 10000 do
				manager:Add(function() end)
			end
			return manager
		end)
	end

	folder:Destroy()
	template:Destroy()
	bindable:Destroy()

	-- Report ------------------------------------------------------------------------
	local lines = {
		"| Group | Case | Implementation | Median µs/op | Fastest | Slowest |",
		"| --- | --- | --- | ---: | ---: | ---: |",
	}
	for _, row in rows do
		table.insert(lines, ("| %s | %s | %s | %.3f | %.3f | %.3f |"):format(table.unpack(row)))
	end
	table.insert(lines, "")
	table.insert(lines, "| Memory case | Implementation | Approx. heap growth (KB) |")
	table.insert(lines, "| --- | --- | ---: |")
	for _, row in memory do
		table.insert(lines, ("| %s | %s | %d |"):format(table.unpack(row)))
	end
	return table.concat(lines, "\n")
end
