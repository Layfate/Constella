--!nonstrict
return function(t, Constella)
	local Signal = Constella.Signal
	local expect = t.expect

	t.describe("Fire", function()
		t.it("calls listeners in connection order with all arguments", function()
			local signal = Signal.new()
			local calls = {}
			signal:Connect(function(a, b)
				table.insert(calls, { "first", a, b })
			end)
			signal:Connect(function(a, b)
				table.insert(calls, { "second", a, b })
			end)
			signal:Fire(1, "x")
			expect(calls).toEqual({ { "first", 1, "x" }, { "second", 1, "x" } })
		end)

		t.it("passes nil arguments through", function()
			local signal = Signal.new()
			local count
			signal:Connect(function(...)
				count = select("#", ...)
			end)
			signal:Fire(nil, nil, 3)
			expect(count).toBe(3)
		end)

		t.it("does not call a listener disconnected earlier in the same dispatch", function()
			local signal = Signal.new()
			local calls = {}
			local second
			signal:Connect(function()
				table.insert(calls, "first")
				second:Disconnect()
			end)
			second = signal:Connect(function()
				table.insert(calls, "second")
			end)
			signal:Fire()
			expect(calls).toEqual({ "first" })
		end)

		t.it("does not call a listener connected during dispatch until the next Fire", function()
			local signal = Signal.new()
			local calls = {}
			local added = false
			signal:Connect(function()
				table.insert(calls, "existing")
				if not added then
					added = true
					signal:Connect(function()
						table.insert(calls, "late")
					end)
				end
			end)
			signal:Fire()
			expect(calls).toEqual({ "existing" })
			signal:Fire()
			expect(calls).toEqual({ "existing", "existing", "late" })
		end)

		t.it("isolates listener errors and reports them to OnError", function()
			local errors = {}
			local signal = Signal.new({
				OnError = function(message)
					table.insert(errors, message)
				end,
			})
			local reached = false
			signal:Connect(function()
				error("boom")
			end)
			signal:Connect(function()
				reached = true
			end)
			expect(function()
				signal:Fire()
			end).toNotThrow()
			expect(reached).toBe(true)
			expect(#errors).toBe(1)
			expect(string.find(errors[1], "boom", 1, true) ~= nil).toBe(true)
		end)

		t.it("does not let a yielding listener block the others", function()
			local signal = Signal.new()
			local calls = {}
			signal:Connect(function()
				table.insert(calls, "yielder start")
				task.wait()
				table.insert(calls, "yielder end")
			end)
			signal:Connect(function()
				table.insert(calls, "second")
			end)
			signal:Fire()
			expect(calls).toEqual({ "yielder start", "second" })
			task.wait()
			task.wait()
			expect(calls).toEqual({ "yielder start", "second", "yielder end" })
		end)
	end)

	t.describe("Once", function()
		t.it("fires exactly once, even when re-fired from inside the listener", function()
			local signal = Signal.new()
			local count = 0
			signal:Once(function()
				count += 1
				signal:Fire()
			end)
			signal:Fire()
			signal:Fire()
			expect(count).toBe(1)
			expect(signal:GetConnectionCount()).toBe(0)
		end)
	end)

	t.describe("Wait", function()
		t.it("yields until the next Fire and returns its arguments", function()
			local signal = Signal.new()
			task.defer(function()
				signal:Fire("a", 2)
			end)
			local a, b = signal:Wait()
			expect(a).toBe("a")
			expect(b).toBe(2)
			expect(signal:GetConnectionCount()).toBe(0)
		end)
	end)

	t.describe("Disconnect and Destroy", function()
		t.it("Disconnect is idempotent and updates Connected", function()
			local signal = Signal.new()
			local connection = signal:Connect(function() end)
			expect(connection.Connected).toBe(true)
			connection:Disconnect()
			connection:Disconnect()
			expect(connection.Connected).toBe(false)
			expect(signal:GetConnectionCount()).toBe(0)
		end)

		t.it("Destroy disconnects everything and is idempotent", function()
			local signal = Signal.new()
			local called = false
			local connection = signal:Connect(function()
				called = true
			end)
			signal:Destroy()
			signal:Destroy()
			expect(connection.Connected).toBe(false)
			expect(signal:IsDestroyed()).toBe(true)
			signal:Fire()
			expect(called).toBe(false)
		end)

		t.it("rejects Connect after Destroy", function()
			local signal = Signal.new()
			signal:Destroy()
			expect(function()
				signal:Connect(function() end)
			end).toThrow("destroyed")
		end)

		t.it("rejects non-function listeners", function()
			local signal = Signal.new()
			expect(function()
				signal:Connect("nope")
			end).toThrow("expects a function")
		end)
	end)

	t.it("Signal.is recognises signals", function()
		expect(Signal.is(Signal.new())).toBe(true)
		expect(Signal.is({})).toBe(false)
	end)

	-- True once the garbage collector has freed every object in `weak`.
	-- Roblox cannot force a collection, so this allocates throwaway tables
	-- to keep the incremental collector running, with a time limit.
	local function collected(weak, timeout)
		local deadline = os.clock() + (timeout or 10)
		while next(weak) ~= nil and os.clock() < deadline do
			for _ = 1, 20000 do
				local _ = { 1, 2, 3 }
			end
			task.wait()
		end
		return next(weak) == nil
	end

	t.describe("memory", function()
		t.it("frees disconnected listeners while the signal stays alive", function()
			local signal = Signal.new()
			local weak = setmetatable({}, { __mode = "k" })
			do
				local connections = {}
				for index = 1, 200 do
					local listener = function()
						return index
					end
					weak[listener] = true
					table.insert(connections, signal:Connect(listener))
				end
				signal:Fire("payload")
				for _, connection in connections do
					connection:Disconnect()
				end
			end
			expect(collected(weak)).toBe(true)
			expect(signal:GetConnectionCount()).toBe(0)
		end)

		t.it("does not keep fired arguments alive on a new runner thread", function()
			-- Keep the current runner busy so the next Fire has to create a
			-- fresh runner thread; that runner then stays alive as the free
			-- runner. It must not pin the arguments of the call it started with.
			-- Retention like this can be intermittent, so the check repeats.
			local kept = 0
			for _ = 1, 5 do
				local release = Signal.new()
				local blocker = Signal.new()
				blocker:Connect(function()
					release:Wait()
				end)
				blocker:Fire()

				local signal = Signal.new()
				signal:Connect(function() end)
				local weak = setmetatable({}, { __mode = "k" })
				do
					local payload = {}
					weak[payload] = true
					signal:Fire(payload)
				end
				if not collected(weak, 3) then
					kept += 1
				end
				release:Fire()
			end
			expect(kept).toBe(0)
		end)
	end)
end
