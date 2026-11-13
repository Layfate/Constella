--!nonstrict
-- Data failure-simulation tests. Everything runs against MemoryAdapter
-- (in-memory, with session locking and injectable failures) and stand-in
-- players, so load failures, throttling, session takeover, migration
-- failures, newer data, leaving mid-load and shutdown can all be exercised.
return function(t, Constella)
	local Data = Constella.Data
	local Store = Data.Store
	local MemoryAdapter = Data.MemoryAdapter
	local expect = t.expect

	local TEMPLATE = { Coins = 0, Inventory = {}, Settings = { Music = true } }

	local nextUserId = 1000
	local function fakePlayer()
		nextUserId += 1
		local player = { Name = "Player" .. nextUserId, UserId = nextUserId, Parent = true }
		function player:Kick(message)
			self.Kicked = message
			self.Parent = nil
		end
		return player
	end

	local function keyOf(player)
		return "Player_" .. player.UserId
	end

	local function newStore(overrides)
		local errors = {}
		local config = {
			Name = "Test",
			Template = TEMPLATE,
			Adapter = MemoryAdapter.new(),
			LoadAttempts = 3,
			RetryDelay = 0,
			OnError = function(message)
				table.insert(errors, message)
			end,
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		return Store.new(config), config.Adapter, errors
	end

	local function load(store, player)
		return store:LoadAsync(player):Await()
	end

	t.describe("loading", function()
		t.it("creates new profiles from the template and fires Loaded", function()
			local store = newStore()
			local player = fakePlayer()
			local loadedWith
			store.Loaded:Connect(function(p, profile)
				loadedWith = { p, profile }
			end)
			local ok, profile = load(store, player)
			expect(ok).toBe(true)
			expect(profile.Data.Coins).toBe(0)
			expect(profile.Data.Settings.Music).toBe(true)
			expect(profile.Data[Store.VERSION_KEY]).toBe(1)
			expect(store:Get(player)).toBe(profile)
			expect(loadedWith[1]).toBe(player)
			expect(loadedWith[2]).toBe(profile)
		end)

		t.it("returns the same profile instead of opening a second session", function()
			local store, adapter = newStore({ Adapter = MemoryAdapter.new({ Latency = 0.02 }) })
			local player = fakePlayer()
			local first = store:LoadAsync(player)
			local second = store:LoadAsync(player)
			expect(second).toBe(first) -- still loading: the same promise
			local _, a = first:Await()
			local _, b = store:LoadAsync(player):Await() -- loaded: the same profile
			expect(b).toBe(a)
			expect(store:GetStats().LoadsSucceeded).toBe(1)
			expect(adapter:IsLocked("Test", keyOf(player))).toBe(true)
		end)

		t.it("reconciles missing template keys without overwriting existing values", function()
			local store, adapter = newStore()
			local player = fakePlayer()
			adapter:Write("Test", keyOf(player), { [Store.VERSION_KEY] = 1, Coins = 75, Settings = {} })
			local _, profile = load(store, player)
			expect(profile.Data.Coins).toBe(75)
			expect(profile.Data.Inventory).toEqual({})
			expect(profile.Data.Settings.Music).toBe(true)
		end)

		t.it("retries throttled loads with backoff and then succeeds", function()
			local store, adapter = newStore()
			adapter:SimulateFailures({ Loads = 2 })
			local ok = load(store, fakePlayer())
			expect(ok).toBe(true)
		end)

		t.it("kicks the player and writes nothing when every attempt fails", function()
			local store, adapter, errors = newStore()
			adapter:SimulateFailures({ Loads = 10 })
			local player = fakePlayer()
			local ok, err = load(store, player)
			expect(ok).toBe(false)
			expect(Store.isError(err, "LoadFailed")).toBe(true)
			expect(player.Kicked ~= nil).toBe(true)
			expect(store:Get(player)).toBeNil()
			expect(adapter:Peek("Test", keyOf(player))).toBeNil()
			expect(#errors).toBe(1)
			expect(store:GetStats().LoadsFailed).toBe(1)
		end)

		t.it("does not hand out a profile when the player leaves during loading", function()
			local store, adapter = newStore({ Adapter = MemoryAdapter.new({ Latency = 0.05 }) })
			local player = fakePlayer()
			local loaded = false
			store.Loaded:Connect(function()
				loaded = true
			end)
			local promise = store:LoadAsync(player)
			player.Parent = nil
			local ok, err = promise:Await()
			expect(ok).toBe(false)
			expect(Store.isError(err, "PlayerLeft")).toBe(true)
			expect(loaded).toBe(false)
			expect(store:Get(player)).toBeNil()
			expect(adapter:IsLocked("Test", keyOf(player))).toBe(false)
		end)
	end)

	t.describe("migrations", function()
		t.it("runs migrations in order from the stored version", function()
			local order = {}
			local store, adapter = newStore({
				Version = 3,
				Migrations = {
					[0] = function(data)
						table.insert(order, 0)
						data.Coins = data.Gold or 0
						data.Gold = nil
					end,
					[1] = function(data)
						table.insert(order, 1)
						data.Coins *= 2
					end,
					[2] = function(data)
						table.insert(order, 2)
						return { Coins = data.Coins + 1 }
					end,
				},
			})
			local player = fakePlayer()
			adapter:Write("Test", keyOf(player), { Gold = 10 })
			local _, profile = load(store, player)
			expect(order).toEqual({ 0, 1, 2 })
			expect(profile.Data.Coins).toBe(21)
			expect(profile.Data.Gold).toBeNil()
			expect(profile.Data[Store.VERSION_KEY]).toBe(3)
			store:Release(player)
			expect(adapter:Peek("Test", keyOf(player)).Coins).toBe(21)
		end)

		t.it("leaves stored data untouched when a migration fails", function()
			local store, adapter = newStore({
				Version = 2,
				Migrations = {
					[1] = function(data)
						data.Coins = -1 -- partially applied before failing
						error("bad migration")
					end,
				},
			})
			local player = fakePlayer()
			adapter:Write("Test", keyOf(player), { [Store.VERSION_KEY] = 1, Coins = 50 })
			local ok, err = load(store, player)
			expect(ok).toBe(false)
			expect(Store.isError(err, "MigrationFailed")).toBe(true)
			expect(player.Kicked ~= nil).toBe(true)
			expect(adapter:Peek("Test", keyOf(player))).toEqual({ [Store.VERSION_KEY] = 1, Coins = 50 })
			expect(adapter:IsLocked("Test", keyOf(player))).toBe(false)
		end)

		t.it("refuses data saved by a newer game version", function()
			local store, adapter = newStore({ Version = 1 })
			local player = fakePlayer()
			local newer = { [Store.VERSION_KEY] = 2, Coins = 9, NewFeature = true }
			adapter:Write("Test", keyOf(player), newer)
			local ok, err = load(store, player)
			expect(ok).toBe(false)
			expect(Store.isError(err, "NewerVersion")).toBe(true)
			expect(adapter:Peek("Test", keyOf(player))).toEqual(newer)
		end)

		t.it("refuses unversioned data when there is no migration from version 0", function()
			local store, adapter = newStore()
			local player = fakePlayer()
			adapter:Write("Test", keyOf(player), { Legacy = true })
			local ok, err = load(store, player)
			expect(ok).toBe(false)
			expect(Store.isError(err, "MissingMigration")).toBe(true)
			expect(adapter:Peek("Test", keyOf(player))).toEqual({ Legacy = true })
		end)

		t.it("refuses corrupt data", function()
			local store, adapter = newStore()
			local player = fakePlayer()
			adapter:Write("Test", keyOf(player), "not a table")
			local ok, err = load(store, player)
			expect(ok).toBe(false)
			expect(Store.isError(err, "CorruptData")).toBe(true)
			expect(adapter:Peek("Test", keyOf(player))).toBe("not a table")
		end)
	end)

	t.describe("sessions", function()
		t.it("saves on release and makes the profile inactive", function()
			local store, adapter = newStore()
			local player = fakePlayer()
			local _, profile = load(store, player)
			profile:Set("Coins", 42)
			local released = false
			store.Released:Connect(function()
				released = true
			end)
			store:Release(player)
			expect(released).toBe(true)
			expect(profile:IsActive()).toBe(false)
			expect(adapter:Peek("Test", keyOf(player)).Coins).toBe(42)
			expect(adapter:IsLocked("Test", keyOf(player))).toBe(false)
			expect(function()
				profile:Set("Coins", 1)
			end).toThrow("no longer active")
		end)

		t.it("hands the session to another server without losing data", function()
			local database = MemoryAdapter.newDatabase()
			local serverA = newStore({ Adapter = MemoryAdapter.new({ Database = database }) })
			local serverB = newStore({ Adapter = MemoryAdapter.new({ Database = database }) })
			local player = fakePlayer()

			local _, profileA = load(serverA, player)
			profileA:Set("Coins", 50)

			-- The same player joins server B (on B this is a separate Player object).
			local playerOnB = { Name = player.Name, UserId = player.UserId, Parent = true, Kick = player.Kick }
			local _, profileB = load(serverB, playerOnB)
			task.wait()

			expect(profileB.Data.Coins).toBe(50)
			expect(profileA:IsActive()).toBe(false)
			expect(serverA:Get(player)).toBeNil()
			expect(player.Kicked ~= nil).toBe(true)
			expect(serverA:GetStats().SessionsLost).toBe(1)
		end)

		t.it("reports failed saves and keeps the last good data", function()
			local store, adapter, errors = newStore()
			local player = fakePlayer()
			local _, profile = load(store, player)
			profile:Set("Coins", 10)
			expect(profile:Save()).toBe(true)
			profile:Set("Coins", 20)
			adapter:SimulateFailures({ Saves = 10 })
			expect(profile:Save()).toBe(false)
			store:Release(player)
			expect(adapter:Peek("Test", keyOf(player)).Coins).toBe(10)
			expect(#errors).toBe(2)
		end)

		t.it("profile Set/Update fire Changed", function()
			local store = newStore()
			local _, profile = load(store, fakePlayer())
			local changes = {}
			profile.Changed:Connect(function(key, new, old)
				table.insert(changes, { key, new, old })
			end)
			profile:Set("Coins", 5)
			profile:Update("Coins", function(coins)
				return coins + 1
			end)
			profile:Set("Coins", 6)
			expect(changes).toEqual({ { "Coins", 5, 0 }, { "Coins", 6, 5 } })
		end)
	end)

	t.describe("shutdown", function()
		t.it("releases every profile within the budget and refuses new loads", function()
			local store, adapter = newStore({ Adapter = MemoryAdapter.new({ Latency = 0.02 }) })
			local players = { fakePlayer(), fakePlayer(), fakePlayer() }
			for _, player in players do
				local _, profile = load(store, player)
				profile:Set("Coins", player.UserId)
			end
			expect(store:Shutdown(5)).toBe(true)
			for _, player in players do
				expect(adapter:Peek("Test", keyOf(player)).Coins).toBe(player.UserId)
				expect(adapter:IsLocked("Test", keyOf(player))).toBe(false)
			end
			local ok, err = load(store, fakePlayer())
			expect(ok).toBe(false)
			expect(Store.isError(err, "ShuttingDown")).toBe(true)
		end)

		t.it("reports when the budget is exceeded", function()
			local store, _, errors = newStore({ Adapter = MemoryAdapter.new({ Latency = 0.3 }) })
			load(store, fakePlayer())
			expect(store:Shutdown(0.05)).toBe(false)
			expect(#errors).toBe(1)
		end)
	end)

	t.describe("configuration", function()
		t.it("validates the config", function()
			expect(function()
				Store.new({ Name = "X", Template = {}, Adapter = {} })
			end).toThrow("Adapter must be")
			expect(function()
				Store.new({ Name = "X", Template = {}, Adapter = MemoryAdapter.new(), Version = 0 })
			end).toThrow("Version must be")
			expect(function()
				Store.new({
					Name = "X",
					Template = {},
					Adapter = MemoryAdapter.new(),
					Version = 2,
					Migrations = { [2] = function() end },
				})
			end).toThrow("Migration key")
			expect(function()
				Store.new({ Name = "X", Template = { [Store.VERSION_KEY] = 1 }, Adapter = MemoryAdapter.new() })
			end).toThrow("reserved key")
		end)
	end)

	t.describe("ProfileStoreAdapter", function()
		-- A stand-in with ProfileStore's public API. It checks Constella's
		-- wiring only; real ProfileStore must be tested in a live experience.
		local function fakeProfileStore(options)
			local opts = options or {}
			local calls = { Ended = 0, UserIds = {} }
			local ProfileStore = {}
			function ProfileStore.New(name, template)
				calls.Name = name
				calls.Template = template
				local store = {}
				function store:StartSessionAsync(key, params)
					calls.Key = key
					calls.HasCancel = type(params.Cancel) == "function"
					if opts.Fail then
						return nil
					end
					-- Mirrors ProfileStore 1.0.3: Save/EndSession return at once,
					-- OnSave fires when a save starts, OnSessionEnd fires before
					-- the final write, OnAfterSave fires after the write.
					local function newSignal()
						local listeners = {}
						return {
							Connect = function(_, fn)
								table.insert(listeners, fn)
								return {
									Disconnect = function()
										local index = table.find(listeners, fn)
										if index then
											table.remove(listeners, index)
										end
									end,
								}
							end,
							Fire = function(_, ...)
								for _, fn in table.clone(listeners) do
									task.spawn(fn, ...)
								end
							end,
						}
					end
					local profile = { Data = table.clone(template), _active = true }
					profile.OnSessionEnd = newSignal()
					profile.OnSave = newSignal()
					profile.OnAfterSave = newSignal()
					function profile:IsActive()
						return self._active
					end
					local function write(ending)
						task.spawn(function()
							profile.OnSave:Fire()
							if ending then
								profile._active = false
								calls.Ended += 1
								profile.OnSessionEnd:Fire()
							end
							task.wait() -- simulated DataStore call
							calls.Saved = table.clone(profile.Data)
							profile.OnAfterSave:Fire(calls.Saved)
						end)
					end
					function profile:Save()
						if self._active then
							write(false)
						end
					end
					function profile:AddUserId(userId)
						table.insert(calls.UserIds, userId)
					end
					function profile:EndSession()
						if self._active then
							write(true)
						end
					end
					calls.Profile = profile
					return profile
				end
				return store
			end
			return ProfileStore, calls
		end

		t.it("maps sessions onto ProfileStore profiles", function()
			local ProfileStore, calls = fakeProfileStore()
			local store = newStore({ Adapter = Data.ProfileStoreAdapter.new(ProfileStore) })
			local player = fakePlayer()
			local ok, profile = load(store, player)
			expect(ok).toBe(true)
			expect(calls.Name).toBe("Test")
			expect(calls.Key).toBe(keyOf(player))
			expect(calls.HasCancel).toBe(true)
			expect(calls.UserIds).toEqual({ player.UserId })
			expect(calls.Template[Store.VERSION_KEY]).toBe(1)
			-- Constella keeps the profile's own Data table.
			expect(profile.Data).toBe(calls.Profile.Data)
			profile:Set("Coins", 9)
			store:Release(player)
			-- Release returns only after the final write has happened.
			expect(calls.Ended).toBe(1)
			expect(calls.Saved.Coins).toBe(9)
		end)

		t.it("treats a missing profile as a failed load", function()
			local ProfileStore = fakeProfileStore({ Fail = true })
			local store = newStore({ Adapter = Data.ProfileStoreAdapter.new(ProfileStore), LoadAttempts = 1 })
			local player = fakePlayer()
			local ok, err = load(store, player)
			expect(ok).toBe(false)
			expect(Store.isError(err, "LoadFailed")).toBe(true)
			expect(player.Kicked ~= nil).toBe(true)
		end)

		t.it("kicks the player when ProfileStore ends the session elsewhere", function()
			local ProfileStore, calls = fakeProfileStore()
			local store = newStore({ Adapter = Data.ProfileStoreAdapter.new(ProfileStore) })
			local player = fakePlayer()
			load(store, player)
			calls.Profile:EndSession() -- e.g. another server took the session
			task.wait()
			expect(store:Get(player)).toBeNil()
			expect(player.Kicked ~= nil).toBe(true)
		end)

		t.it("rejects something that is not ProfileStore", function()
			expect(function()
				Data.ProfileStoreAdapter.new({})
			end).toThrow("expects the ProfileStore module")
		end)
	end)
end
