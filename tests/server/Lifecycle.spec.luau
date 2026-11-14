--!nonstrict
-- Regression tests for cancellation, yielding teardown and owned snapshots.
return function(t, Constella)
	local expect = t.expect
	local Data = Constella.Data
	local Signal = Constella.Signal

	local function waitUntil(predicate)
		local deadline = os.clock() + 3
		while not predicate() and os.clock() < deadline do
			task.wait()
		end
		assert(predicate(), "timed out waiting for test operation")
	end

	local function storeWithMigration()
		local gate = Signal.new()
		local entered = false
		local errors = {}
		local adapter = Data.MemoryAdapter.new()
		local store = Data.Store.new({
			Name = "Lifecycle",
			Template = { Coins = 0 },
			Adapter = adapter,
			Version = 2,
			KickOnFailure = false,
			Migrations = {
				[1] = function(data)
					entered = true
					gate:Wait()
					data.Coins = 999
				end,
			},
			OnError = function(message)
				table.insert(errors, message)
			end,
		})
		local player = { Name = "Lifecycle", UserId = 987, Parent = true }
		adapter:Write("Lifecycle", "Player_987", { Coins = 42, [Data.Store.VERSION_KEY] = 1 })
		local load = store:LoadAsync(player)
		load:Catch(function() end)
		waitUntil(function()
			return entered
		end)
		return store, adapter, player, load, gate, errors
	end

	t.it("cancelled migrations release their sessions and permit a fresh load", function()
		local store, adapter, player, load, gate = storeWithMigration()
		load:Cancel()
		gate:Fire()
		waitUntil(function()
			return store:GetStats().Loading == 0
		end)
		expect(adapter:IsLocked("Lifecycle", "Player_987")).toBe(false)
		expect(adapter:Peek("Lifecycle", "Player_987").Coins).toBe(42)
		expect(store:Get(player)).toBeNil()
		local fresh = store:LoadAsync(player)
		expect(fresh ~= load).toBe(true)
		task.defer(function()
			gate:Fire()
		end)
		local ok = fresh:Await()
		expect(ok).toBe(true)
		expect(store:Shutdown(1)).toBe(true)
		gate:Destroy()
	end)

	t.it("cancellation closes sessions returned by a backend that ignores cancellation", function()
		local backing = Data.MemoryAdapter.new()
		local gate = Signal.new()
		local entered = false
		local adapter = {
			Open = function(_, name, template)
				local backend = backing:Open(name, template)
				return {
					StartSession = function(_, key)
						entered = true
						gate:Wait()
						return backend:StartSession(key, {})
					end,
				}
			end,
		}
		local store = Data.Store.new({ Name = "Late", Template = {}, Adapter = adapter })
		local player = { Name = "Late", UserId = 12, Parent = true }
		local load = store:LoadAsync(player)
		waitUntil(function()
			return entered
		end)
		load:Cancel()
		gate:Fire()
		expect(store:Shutdown(1)).toBe(true)
		expect(store:GetStats().Loading).toBe(0)
		expect(backing:IsLocked("Late", "Player_12")).toBe(false)
		gate:Destroy()
	end)

	t.it("shutdown waits for a yielding migration and never commits its changes", function()
		local store, adapter, player, load, gate = storeWithMigration()
		local finished = false
		task.spawn(function()
			expect(store:Shutdown(1)).toBe(true)
			finished = true
		end)
		expect(finished).toBe(false)
		gate:Fire()
		waitUntil(function()
			return finished
		end)
		local ok, err = load:Await()
		expect(ok).toBe(false)
		expect(Data.Store.isError(err, "ShuttingDown")).toBe(true)
		expect(store:Get(player)).toBeNil()
		expect(adapter:Peek("Lifecycle", "Player_987").Coins).toBe(42)
		expect(adapter:IsLocked("Lifecycle", "Player_987")).toBe(false)
		gate:Destroy()
	end)

	t.it("shutdown times out while a migration is still pending", function()
		local store, adapter, _, _, gate, errors = storeWithMigration()
		expect(store:Shutdown(0)).toBe(false)
		expect(#errors).toBe(1)
		gate:Fire()
		expect(store:Shutdown(1)).toBe(true)
		expect(adapter:IsLocked("Lifecycle", "Player_987")).toBe(false)
		gate:Destroy()
	end)

	for _, action in { "release", "leave", "session loss" } do
		t.it("does not commit after " .. action .. " during migration", function()
			local store, adapter, player, load, gate = storeWithMigration()
			if action == "release" then
				store:Release(player)
			elseif action == "leave" then
				player.Parent = nil
			else
				local other = adapter:Open("Lifecycle", {})
				local session = other:StartSession("Player_987", {})
				session:End()
			end
			gate:Fire()
			local ok = load:Await()
			expect(ok).toBe(false)
			expect(store:Get(player)).toBeNil()
			expect(adapter:Peek("Lifecycle", "Player_987").Coins).toBe(42)
			expect(store:Shutdown(1)).toBe(true)
			gate:Destroy()
		end)
	end

	for _, once in { false, true } do
		t.it("replaces a cancelled Signal runner (Once=" .. tostring(once) .. ")", function()
			local signal = Signal.new()
			local runner
			signal:Once(function()
				runner = coroutine.running()
			end)
			signal:Fire()
			task.cancel(runner)
			local calls = 0
			local connect = if once then signal.Once else signal.Connect
			connect(signal, function()
				calls += 1
			end)
			signal:Fire()
			expect(calls).toBe(1)
			signal:Destroy()
		end)
	end

	t.it("disposes failed prewarm objects and keeps successful idle objects usable", function()
		local created, destroyed = 0, 0
		local pool = Constella.Pool.new({
			Create = function()
				created += 1
				return { Id = created }
			end,
			Reset = function(object)
				if object.Id == 2 then
					error("reset failure")
				end
			end,
			Destroy = function()
				destroyed += 1
			end,
		})
		expect(function()
			pool:Prewarm(3)
		end).toThrow("reset failure")
		expect(pool:GetStats().Idle).toBe(1)
		expect(destroyed).toBe(1)
		expect(pool:Acquire().Id).toBe(1)
		pool:Destroy()
	end)

	t.it("constructor prewarm failure also disposes the earlier idle objects", function()
		local created, destroyed = 0, 0
		expect(function()
			Constella.Pool.new({
				Create = function()
					created += 1
					return {}
				end,
				Reset = function()
					if created == 2 then
						error("reset failure")
					end
				end,
				Destroy = function()
					destroyed += 1
				end,
				Prewarm = 3,
			})
		end).toThrow("reset failure")
		expect(destroyed).toBe(2)
	end)

	for _, delta in { false, true } do
		t.it("owns validated nested snapshots (Delta=" .. tostring(delta) .. ")", function()
			local errors = {}
			local server = Constella.Replication.Server.new("OwnedSnapshot", {
				Parent = Instance.new("Folder"),
				Delta = delta,
				OnError = function(message)
					table.insert(errors, message)
				end,
			})
			local source = { Nested = { Coins = 42 } }
			local state = Constella.State.new(source)
			server:Share("Data", state)
			source.Nested.Coins = function() end
			state:Set({ Nested = source.Nested })
			expect(#errors).toBe(1)
			local snapshot = server:_snapshotFor({})
			expect(snapshot.Data[1].Nested.Coins).toBe(42)
			snapshot.Data[1].Nested.Coins = 99
			expect(server:_snapshotFor({}).Data[1].Nested.Coins).toBe(42)
			state:Set({ Nested = { Coins = 50 } })
			expect(server:_snapshotFor({}).Data[1].Nested.Coins).toBe(50)
			server:Destroy()
		end)
	end
end
