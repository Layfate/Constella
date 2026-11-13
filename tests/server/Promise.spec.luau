--!nonstrict
return function(t, Constella)
	local Promise = Constella.Promise
	local expect = t.expect

	-- Captures unhandled rejections for the duration of `fn`.
	local function withUnhandled(fn)
		local reported = {}
		local previous = Promise.setUnhandledRejectionHandler(function(value)
			table.insert(reported, value)
		end)
		local ok, err = pcall(fn, reported)
		task.wait()
		task.wait()
		Promise.setUnhandledRejectionHandler(previous)
		if not ok then
			error(err, 0)
		end
		return reported
	end

	t.describe("basics", function()
		t.it("resolves asynchronously and chains values", function()
			local result = Promise.new(function(resolve)
				task.wait()
				resolve(2)
			end)
				:Then(function(value)
					return value * 10, "extra"
				end)
				:Expect()
			expect(result).toBe(20)
		end)

		t.it("passes multiple values, including nils", function()
			local ok, a, b, c = Promise.resolve(1, nil, 3):Await()
			expect(ok).toBe(true)
			expect(a).toBe(1)
			expect(b).toBeNil()
			expect(c).toBe(3)
		end)

		t.it("turns thrown errors into ExecutionError rejections", function()
			local ok, err = Promise.new(function()
				error("kaboom")
			end):Await()
			expect(ok).toBe(false)
			expect(Promise.isError(err, "ExecutionError")).toBe(true)
			expect(string.find(err.Message, "kaboom", 1, true) ~= nil).toBe(true)
		end)

		t.it("passes rejections through Then without handlers until Catch", function()
			local value = Promise.reject("bad")
				:Then(function()
					return "skipped"
				end)
				:Catch(function(reason)
					return "recovered from " .. reason
				end)
				:Expect()
			expect(value).toBe("recovered from bad")
		end)

		t.it("adopts a promise returned from a handler", function()
			local value = Promise.resolve(1)
				:Then(function()
					return Promise.delay(0):Then(function()
						return "inner"
					end)
				end)
				:Expect()
			expect(value).toBe("inner")
		end)

		t.it("Expect raises the rejection", function()
			expect(function()
				Promise.reject("nope"):Expect()
			end).toThrow("nope")
		end)

		t.it("Finally runs for every outcome and passes it through", function()
			local seen = {}
			local function track(status)
				table.insert(seen, status)
			end
			local resolved = Promise.resolve("ok"):Finally(track):Expect()
			local ok = Promise.reject("no"):Finally(track):Await()
			local cancelled = Promise.new(function() end)
			local after = cancelled:Finally(track)
			cancelled:Cancel()
			task.wait()
			expect(resolved).toBe("ok")
			expect(ok).toBe(false)
			expect(after:GetStatus()).toBe("Cancelled")
			expect(seen).toEqual({ "Resolved", "Rejected", "Cancelled" })
		end)
	end)

	t.describe("cancellation", function()
		t.it("runs onCancel hooks and cancels the chain downstream", function()
			local cleaned = false
			local root = Promise.new(function(_, _, onCancel)
				onCancel(function()
					cleaned = true
				end)
			end)
			local child = root:Then(function() end)
			root:Cancel()
			expect(cleaned).toBe(true)
			expect(root:GetStatus()).toBe("Cancelled")
			expect(child:GetStatus()).toBe("Cancelled")
			local ok, err = child:Await()
			expect(ok).toBe(false)
			expect(Promise.isError(err, "Cancelled")).toBe(true)
		end)

		t.it("cancels upstream only when it has no other consumers", function()
			local root = Promise.new(function() end)
			local a = root:Then(function() end)
			local b = root:Then(function() end)
			a:Cancel()
			expect(root:GetStatus()).toBe("Pending")
			b:Cancel()
			expect(root:GetStatus()).toBe("Cancelled")
		end)

		t.it("is ignored once settled", function()
			local promise = Promise.resolve(1)
			promise:Cancel()
			expect(promise:GetStatus()).toBe("Resolved")
		end)

		t.it("is cancelled by Cleanup", function()
			local cleanup = Constella.Cleanup.new()
			local promise = cleanup:Add(Promise.new(function() end))
			cleanup:Destroy()
			expect(promise:GetStatus()).toBe("Cancelled")
		end)
	end)

	t.describe("combinators", function()
		t.it("all resolves with values in order", function()
			local values = Promise.all({
				Promise.delay(0.02):Then(function()
					return "slow"
				end),
				Promise.resolve("fast"),
			}):Expect()
			expect(values).toEqual({ "slow", "fast" })
			expect(Promise.all({}):Expect()).toEqual({})
		end)

		t.it("all rejects on the first failure and cancels the rest", function()
			local slow = Promise.delay(5)
			local ok, reason = Promise.all({ slow, Promise.reject("broken") }):Await()
			expect(ok).toBe(false)
			expect(reason).toBe("broken")
			expect(slow:GetStatus()).toBe("Cancelled")
		end)

		t.it("allSettled reports every outcome", function()
			local results = Promise.allSettled({ Promise.resolve(1), Promise.reject("x") }):Expect()
			expect(results).toEqual({ { Status = "Resolved", Value = 1 }, { Status = "Rejected", Value = "x" } })
		end)

		t.it("race settles with the first and cancels the others", function()
			local slow = Promise.delay(5)
			local winner = Promise.race({ slow, Promise.resolve("first") }):Expect()
			expect(winner).toBe("first")
			expect(slow:GetStatus()).toBe("Cancelled")
		end)

		t.it("Timeout rejects with a Timeout error and cancels the slow work", function()
			local stopped = false
			local slow = Promise.new(function(_, _, onCancel)
				onCancel(function()
					stopped = true
				end)
			end)
			local ok, err = slow:Timeout(0.05):Await()
			expect(ok).toBe(false)
			expect(Promise.isError(err, "Timeout")).toBe(true)
			expect(stopped).toBe(true)
		end)

		t.it("Timeout does not fire when the promise wins", function()
			expect(Promise.delay(0):Timeout(1):Await()).toBe(true)
		end)
	end)

	t.describe("helpers", function()
		t.it("retry succeeds after failures", function()
			local attempts = 0
			local value = Promise.retry(function()
				attempts += 1
				if attempts < 3 then
					error("flaky")
				end
				return "done"
			end, { Attempts = 5, Delay = 0 }):Expect()
			expect(value).toBe("done")
			expect(attempts).toBe(3)
		end)

		t.it("retry gives up after the last attempt and honours ShouldRetry", function()
			local attempts = 0
			local ok, reason = Promise.retry(function()
				attempts += 1
				return Promise.reject("still down")
			end, { Attempts = 3, Delay = 0 }):Await()
			expect(ok).toBe(false)
			expect(reason).toBe("still down")
			expect(attempts).toBe(3)

			attempts = 0
			Promise.retry(function()
				attempts += 1
				return Promise.reject("fatal")
			end, {
				Attempts = 5,
				ShouldRetry = function(r)
					return r ~= "fatal"
				end,
			}):Await()
			expect(attempts).toBe(1)
		end)

		t.it("fromEvent resolves with the first matching event", function()
			local signal = Constella.Signal.new()
			local promise = Promise.fromEvent(signal, function(value)
				return value > 5
			end)
			signal:Fire(1)
			signal:Fire(10)
			expect(promise:Expect()).toBe(10)
			expect(signal:GetConnectionCount()).toBe(0)
		end)

		t.it("validates arguments", function()
			expect(function()
				Promise.new(5)
			end).toThrow("expects a function")
			expect(function()
				Promise.resolve(1):Then(5)
			end).toThrow("must be a function")
			expect(function()
				Promise.all({ 1 })
			end).toThrow("is not a promise")
		end)
	end)

	t.describe("unhandled rejections", function()
		t.it("reports rejections nobody handles", function()
			local reported = withUnhandled(function()
				Promise.reject("lost")
				Promise.resolve(1):Then(function()
					error("lost in handler")
				end)
			end)
			expect(#reported).toBe(2)
			expect(reported[1]).toBe("lost")
		end)

		t.it("does not report handled rejections or cancellations", function()
			local reported = withUnhandled(function()
				Promise.reject("handled"):Catch(function() end)
				Promise.reject("awaited"):Await()
				Promise.new(function() end):Cancel()
			end)
			expect(#reported).toBe(0)
		end)
	end)
end
