--!nonstrict
return function(t, Constella)
	local Cleanup = Constella.Cleanup
	local Signal = Constella.Signal
	local expect = t.expect

	local function isDestroyedInstance(instance: Instance): boolean
		-- A destroyed instance has its Parent property locked.
		return not pcall(function()
			instance.Parent = workspace
		end)
	end

	t.describe("resource types", function()
		t.it("cleans functions, connections, instances, threads, objects and nested managers", function()
			local cleanup = Cleanup.new()

			local called = false
			cleanup:Add(function()
				called = true
			end)

			local bindable = Instance.new("BindableEvent")
			local connection = cleanup:Add(bindable.Event:Connect(function() end))

			local folder = cleanup:Add(Instance.new("Folder"))

			local threadRan = false
			local thread = cleanup:Add(task.delay(60, function()
				threadRan = true
			end))

			local signal = cleanup:Add(Signal.new())

			local nested = Cleanup.new()
			local nestedCalled = false
			nested:Add(function()
				nestedCalled = true
			end)
			cleanup:Add(nested)

			cleanup:Clean()

			expect(called).toBe(true)
			expect(connection.Connected).toBe(false)
			expect(isDestroyedInstance(folder)).toBe(true)
			expect(coroutine.status(thread)).toBe("dead")
			expect(threadRan).toBe(false)
			expect(signal:IsDestroyed()).toBe(true)
			expect(nestedCalled).toBe(true)
			expect(cleanup:Count()).toBe(0)
			bindable:Destroy()
		end)

		t.it("supports an explicit method name", function()
			local cleanup = Cleanup.new()
			local closed = false
			cleanup:Add({
				Close = function()
					closed = true
				end,
			}, "Close")
			cleanup:Clean()
			expect(closed).toBe(true)
		end)

		t.it("rejects nil, unknown types and missing methods", function()
			local cleanup = Cleanup.new()
			expect(function()
				cleanup:Add(nil)
			end).toThrow("Cannot add nil")
			expect(function()
				cleanup:Add(42)
			end).toThrow("Don't know how to clean")
			expect(function()
				cleanup:Add({}, "Close")
			end).toThrow("has no method 'Close'")
		end)
	end)

	t.describe("ordering and idempotency", function()
		t.it("cleans in reverse order of addition", function()
			local cleanup = Cleanup.new()
			local order = {}
			for index = 1, 3 do
				cleanup:Add(function()
					table.insert(order, index)
				end)
			end
			cleanup:Clean()
			expect(order).toEqual({ 3, 2, 1 })
		end)

		t.it("never disposes a resource twice", function()
			local cleanup = Cleanup.new()
			local count = 0
			cleanup:Add(function()
				count += 1
			end)
			cleanup:Clean()
			cleanup:Clean()
			cleanup:Destroy()
			cleanup:Destroy()
			expect(count).toBe(1)
		end)

		t.it("stays usable after Clean", function()
			local cleanup = Cleanup.new()
			cleanup:Clean()
			local count = 0
			cleanup:Add(function()
				count += 1
			end)
			expect(count).toBe(0)
			cleanup:Clean()
			expect(count).toBe(1)
		end)
	end)

	t.describe("failures", function()
		t.it("cleans every other resource when one disposal fails, then raises", function()
			local cleanup = Cleanup.new()
			local cleaned = {}
			cleanup:Add(function()
				table.insert(cleaned, "a")
			end)
			cleanup:Add(function()
				error("disposal exploded")
			end)
			cleanup:Add(function()
				table.insert(cleaned, "c")
			end)
			expect(function()
				cleanup:Destroy()
			end).toThrow("disposal exploded")
			expect(cleaned).toEqual({ "c", "a" })
			expect(cleanup:Count()).toBe(0)
			expect(cleanup:IsDestroyed()).toBe(true)
		end)
	end)

	t.describe("keys", function()
		t.it("Set replaces and cleans the previous resource under the same key", function()
			local cleanup = Cleanup.new()
			local log = {}
			cleanup:Set("effect", function()
				table.insert(log, "old")
			end)
			cleanup:Set("effect", function()
				table.insert(log, "new")
			end)
			expect(log).toEqual({ "old" })
			expect(cleanup:Count()).toBe(1)
			cleanup:Clean()
			expect(log).toEqual({ "old", "new" })
			expect(cleanup:Get("effect")).toBeNil()
		end)

		t.it("Set(key, nil) cleans and clears the key", function()
			local cleanup = Cleanup.new()
			local cleaned = false
			cleanup:Set("k", function()
				cleaned = true
			end)
			cleanup:Set("k", nil)
			expect(cleaned).toBe(true)
			expect(cleanup:Get("k")).toBeNil()
		end)

		t.it("Remove cleans one resource by key or by value", function()
			local cleanup = Cleanup.new()
			local log = {}
			local byValue = function()
				table.insert(log, "value")
			end
			cleanup:Add(byValue)
			cleanup:Set("key", function()
				table.insert(log, "key")
			end)
			expect(cleanup:Remove("key")).toBe(true)
			expect(cleanup:Remove(byValue)).toBe(true)
			expect(cleanup:Remove("missing")).toBe(false)
			expect(log).toEqual({ "key", "value" })
			expect(cleanup:Count()).toBe(0)
		end)

		t.it("Detach stops tracking without cleaning", function()
			local cleanup = Cleanup.new()
			local cleaned = false
			local fn = cleanup:Set("k", function()
				cleaned = true
			end)
			expect(cleanup:Detach("k")).toBe(fn)
			cleanup:Clean()
			expect(cleaned).toBe(false)
		end)
	end)

	t.describe("after Destroy", function()
		t.it("disposes newly added resources immediately", function()
			local cleanup = Cleanup.new()
			cleanup:Destroy()
			local cleaned = false
			cleanup:Add(function()
				cleaned = true
			end)
			expect(cleaned).toBe(true)
			expect(cleanup:Count()).toBe(0)
		end)
	end)

	t.describe("helpers", function()
		t.it("Connect tracks a Constella signal connection", function()
			local cleanup = Cleanup.new()
			local signal = Signal.new()
			local count = 0
			cleanup:Connect(signal, function()
				count += 1
			end)
			signal:Fire()
			cleanup:Clean()
			signal:Fire()
			expect(count).toBe(1)
		end)

		t.it("Extend creates a child that is cleaned with its parent", function()
			local parent = Cleanup.new()
			local child = parent:Extend()
			local cleaned = false
			child:Add(function()
				cleaned = true
			end)
			parent:Destroy()
			expect(cleaned).toBe(true)
			expect(child:IsDestroyed()).toBe(true)
		end)

		t.it("AttachToInstance destroys the manager with the instance", function()
			local cleanup = Cleanup.new()
			local folder = Instance.new("Folder")
			cleanup:AttachToInstance(folder)
			local cleaned = false
			cleanup:Add(function()
				cleaned = true
			end)
			folder:Destroy()
			task.wait()
			expect(cleaned).toBe(true)
			expect(cleanup:IsDestroyed()).toBe(true)
		end)

		t.it("handles a disposer that adds to the same manager during Clean", function()
			local cleanup = Cleanup.new()
			local lateCleaned = false
			cleanup:Add(function()
				cleanup:Add(function()
					lateCleaned = true
				end)
			end)
			cleanup:Clean()
			expect(lateCleaned).toBe(true)
			expect(cleanup:Count()).toBe(0)
		end)
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
		t.it("frees cleaned resources while the manager stays alive", function()
			local cleanup = Cleanup.new()
			local weak = setmetatable({}, { __mode = "k" })
			do
				for index = 1, 200 do
					local resource = function()
						return index
					end
					weak[resource] = true
					cleanup:Add(resource)
				end
				cleanup:Set("keyed", function() end)
				cleanup:Clean()
			end
			expect(collected(weak)).toBe(true)
			expect(cleanup:Count()).toBe(0)
		end)
	end)
end
