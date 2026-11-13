--!strict
--[=[
	A small benchmark helper.

	`measure(run, iterations, trials)` calls `run(iterations)` once to warm
	up, then `trials` more times, yielding between trials. It returns the
	median, fastest and slowest time per iteration in microseconds. Using
	the median of several trials keeps one-off hiccups (garbage collection,
	Studio work) from skewing the result.

	`memoryKB(build, trials)` reports the median growth of the Luau heap
	(gcinfo, in KB) while `build()` runs. The heap is shared and garbage
	collection can run at any time, so treat it as approximate.
]=]

local Bench = {}

function Bench.measure(run: (iterations: number) -> (), iterations: number, trials: number?): (number, number, number)
	local count = trials or 7
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

function Bench.memoryKB(build: () -> any, trials: number?): number
	local count = trials or 5
	local samples = table.create(count)
	local keep = {}
	for trial = 1, count do
		task.wait()
		local before = gcinfo()
		keep[trial] = build()
		local after = gcinfo()
		table.insert(samples, math.max(0, after - before))
		keep[trial] = nil
	end
	table.sort(samples)
	return samples[(count + 1) // 2]
end

return Bench
