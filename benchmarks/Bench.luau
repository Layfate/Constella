--!strict
--[=[
	Benchmark helpers.

	measure(run, iterations, trials)
		Calls run(iterations) once to warm up, then `trials` more times,
		yielding between trials. Returns the median, fastest and slowest
		time per iteration in microseconds.

	bytesPerObject(build, count, trials)
		Builds `count` objects (build(count) must return something that
		keeps them alive) many times and reports Luau heap growth in bytes
		per object. Garbage collection running during a build can only make
		a sample SMALLER (it frees unrelated garbage), so the method uses
		many small builds and reports the 80th percentile: the upper
		samples are the uninterrupted ones, and the very top is dropped in
		case something else allocated. Run it in an idle Edit session.
		In testing this gave identical results across repeated rounds,
		whereas the median of large builds did not.

	leakCheck(build, timeoutSeconds)
		Proves that objects become collectable once released. build()
		returns (objects, release): every object is put in a weak-keyed
		table, release() is called, all strong references are dropped, and
		the check waits until the garbage collector has removed them.
		Roblox cannot force a collection, so the check creates throwaway
		garbage to keep the collector running. Returns how many objects are
		still alive when it finishes (0 means no leak) and how long it took.
]=]

local Bench = {}

function Bench.measure(run: (iterations: number) -> (), iterations: number, trials: number?): (number, number, number)
	local count = trials or 5
	run(math.max(1, iterations // 10)) -- warm-up
	task.wait()
	local samples = table.create(count)
	for _ = 1, count do
		local started = os.clock()
		run(iterations)
		local elapsed = os.clock() - started
		table.insert(samples, elapsed / iterations * 1e6)
		task.wait()
	end
	table.sort(samples)
	return samples[(count + 1) // 2], samples[1], samples[count]
end

function Bench.bytesPerObject(build: (count: number) -> any, count: number, trials: number?): number
	local runs = trials or 21
	local samples = table.create(runs)
	for _ = 1, runs do
		task.wait()
		local before = gcinfo()
		local _keep = build(count)
		local after = gcinfo()
		table.insert(samples, (after - before) * 1024 / count)
		_keep = nil
	end
	table.sort(samples)
	return math.max(0, samples[math.ceil(runs * 0.8)])
end

function Bench.leakCheck(build: () -> ({ any }, () -> ()), timeoutSeconds: number?): (number, number)
	local tracked: { [any]: true } = setmetatable({} :: any, { __mode = "k" })
	do
		local objects, release = build()
		for _, object in objects do
			tracked[object] = true
		end
		release()
	end

	local function alive(): number
		local count = 0
		for _ in tracked do
			count += 1
		end
		return count
	end

	local started = os.clock()
	local deadline = started + (timeoutSeconds or 10)
	while alive() > 0 and os.clock() < deadline do
		-- Throwaway allocations keep the incremental collector running.
		for _ = 1, 20000 do
			local _ = { 1, 2, 3 }
		end
		task.wait()
	end
	return alive(), os.clock() - started
end

return Bench
