--!nonstrict
--[=[
	A tiny, dependency-free test runner used by Constella's own tests.

	Spec modules return `function(t, Constella)` and use:
	  t.describe(name, fn), t.it(name, fn), t.expect(value)
]=]

local TestKit = {}

local function deepEqual(a: any, b: any, seen: { [any]: any }?): boolean
	if a == b then
		return true
	end
	if a ~= a and b ~= b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	local visited = seen or {}
	if visited[a] == b then
		return true
	end
	visited[a] = b
	for key, value in a do
		if not deepEqual(value, b[key], visited) then
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

local function show(value: any): string
	if type(value) == "string" then
		return ("%q"):format(value)
	end
	return tostring(value)
end

local function expect(actual: any)
	local matchers = {}

	function matchers.toBe(expected: any)
		if not (rawequal(actual, expected) or (actual ~= actual and expected ~= expected)) then
			error(("expected %s to be %s"):format(show(actual), show(expected)), 2)
		end
	end

	function matchers.toEqual(expected: any)
		if not deepEqual(actual, expected) then
			error(("expected %s to deeply equal %s"):format(show(actual), show(expected)), 2)
		end
	end

	function matchers.toBeNil()
		if actual ~= nil then
			error(("expected %s to be nil"):format(show(actual)), 2)
		end
	end

	function matchers.toBeTruthy()
		if not actual then
			error(("expected %s to be truthy"):format(show(actual)), 2)
		end
	end

	function matchers.toBeFalsy()
		if actual then
			error(("expected %s to be falsy"):format(show(actual)), 2)
		end
	end

	function matchers.toBeCloseTo(expected: number, tolerance: number?)
		local limit = tolerance or 1e-9
		if type(actual) ~= "number" or math.abs(actual - expected) > limit then
			error(("expected %s to be within %s of %s"):format(show(actual), show(limit), show(expected)), 2)
		end
	end

	function matchers.toBeGreaterThan(expected: number)
		if not (actual > expected) then
			error(("expected %s to be greater than %s"):format(show(actual), show(expected)), 2)
		end
	end

	function matchers.toBeLessThan(expected: number)
		if not (actual < expected) then
			error(("expected %s to be less than %s"):format(show(actual), show(expected)), 2)
		end
	end

	--- `actual` must be a function. Optionally checks that the error message
	--- contains `substring` (plain match).
	function matchers.toThrow(substring: string?)
		local ok, err = pcall(actual)
		if ok then
			error("expected function to throw, but it returned normally", 2)
		end
		if substring and not string.find(tostring(err), substring, 1, true) then
			error(("expected error containing %s, got %s"):format(show(substring), show(tostring(err))), 2)
		end
	end

	function matchers.toNotThrow()
		local ok, err = pcall(actual)
		if not ok then
			error(("expected function not to throw, got %s"):format(show(tostring(err))), 2)
		end
	end

	return matchers
end

export type Spec = {
	name: string,
	run: (t: any, Constella: any) -> (),
}

export type Results = {
	passed: number,
	failed: number,
	skipped: number,
	failures: { { name: string, message: string } },
}

function TestKit.run(specs: { Spec }, Constella: any, options: { Silent: boolean? }?): Results
	local silent = options ~= nil and options.Silent == true
	local results: Results = { passed = 0, failed = 0, skipped = 0, failures = {} }

	local function record(name: string, ok: boolean, message: string?)
		if ok then
			results.passed += 1
		else
			results.failed += 1
			table.insert(results.failures, { name = name, message = message or "?" })
			if not silent then
				warn(("[FAIL] %s\n%s"):format(name, message or ""))
			end
		end
	end

	for _, spec in specs do
		local tests = {}
		local scope = { spec.name }
		local t = {}

		function t.describe(name: string, body: () -> ())
			table.insert(scope, name)
			body()
			table.remove(scope)
		end

		function t.it(name: string, body: () -> ())
			table.insert(tests, { name = table.concat(scope, " > ") .. " > " .. name, body = body })
		end

		t.expect = expect

		--- True once the garbage collector has freed every key of the weak
		--- table `weak`. Roblox cannot force a collection, so this allocates
		--- throwaway tables to keep the incremental collector running, until
		--- `timeout` seconds (default 10) have passed.
		function t.collected(weak: { [any]: any }, timeout: number?): boolean
			local deadline = os.clock() + (timeout or 10)
			while next(weak) ~= nil and os.clock() < deadline do
				for _ = 1, 20000 do
					local _ = { 1, 2, 3 }
				end
				task.wait()
			end
			return next(weak) == nil
		end

		--- Records a test as skipped (for example when an optional
		--- dependency is not installed) instead of running it.
		function t.skip(name: string, reason: string)
			results.skipped += 1
			if not silent then
				print(("[SKIP] %s > %s (%s)"):format(table.concat(scope, " > "), name, reason))
			end
		end

		local collected, collectError = pcall(spec.run, t, Constella)
		if not collected then
			record(spec.name .. " (collecting tests)", false, tostring(collectError))
		end

		for _, test in tests do
			local ok, err = xpcall(test.body, function(message)
				return debug.traceback(tostring(message), 2)
			end)
			record(test.name, ok, err)
		end
	end

	if not silent then
		local summary = ("[Constella tests] %d passed, %d failed"):format(results.passed, results.failed)
		if results.skipped > 0 then
			summary ..= (", %d skipped"):format(results.skipped)
		end
		if results.failed > 0 then
			warn(summary)
		else
			print(summary)
		end
	end
	return results
end

return TestKit
