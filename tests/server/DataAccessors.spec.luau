--!nonstrict
-- Typed Data accessors and checks added in 0.4.0: profile:Mutate, the
-- Validate option and the CheckWrites option. Runs against MemoryAdapter
-- with stand-in players, like Data.spec.
return function(t, Constella)
	local Data = Constella.Data
	local Store = Data.Store
	local MemoryAdapter = Data.MemoryAdapter
	local Check = Constella.Network.Check
	local expect = t.expect

	local TEMPLATE = { Coins = 0, Owned = {}, Settings = { Music = true }, Title = "Rookie" }

	local nextUserId = 50000
	local function newPlayer()
		nextUserId += 1
		return t.fakePlayer("Player" .. nextUserId, nextUserId)
	end

	local function newStore(overrides)
		local errors = {}
		local config = {
			Name = "Accessors",
			Template = TEMPLATE,
			Adapter = MemoryAdapter.new(),
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

	local function loaded(overrides)
		local store, adapter, errors = newStore(overrides)
		local player = newPlayer()
		local ok, profile = store:LoadAsync(player):Await()
		assert(ok, tostring(profile))
		local changes = {}
		profile.Changed:Connect(function(key, new, old)
			table.insert(changes, { key, new, old })
		end)
		return profile, changes, store, player, adapter, errors
	end

	-- Changed listeners run on Signal's runner threads; give them a moment.
	local function settle()
		task.wait()
	end

	t.describe("profile:Mutate", function()
		t.it("fires Changed for each key whose value changed", function()
			local profile, changes = loaded()
			profile:Mutate(function(data)
				data.Coins += 5
				data.Title = "Rookie" -- same value: no Changed
			end)
			settle()
			expect(profile.Data.Coins).toBe(5)
			-- Coins changed; Owned and Settings hold tables, so they are reported too.
			local byKey = {}
			for _, change in changes do
				byKey[change[1]] = change
			end
			expect(byKey.Coins[2]).toBe(5)
			expect(byKey.Coins[3]).toBe(0)
			expect(byKey.Title).toBeNil()
			expect(byKey.Owned).toBeTruthy()
			expect(byKey.Owned[2]).toBe(byKey.Owned[3])
			expect(byKey.Settings).toBeTruthy()
		end)

		t.it("never misses an in-place edit of a nested table", function()
			local profile, changes = loaded()
			profile:Mutate(function(data)
				data.Owned.Sword = true
			end)
			settle()
			local reported = false
			for _, change in changes do
				if change[1] == "Owned" then
					reported = change[2].Sword == true
				end
			end
			expect(reported).toBe(true)
		end)

		t.it("reports added and removed keys", function()
			local profile, changes = loaded()
			profile:Mutate(function(data)
				data.Bonus = 3
				data.Title = nil
			end, { Keys = { "Bonus", "Title" } })
			settle()
			expect(changes).toEqual({ { "Bonus", 3, nil }, { "Title", nil, "Rookie" } })
		end)

		-- Regression: changes were queued with table.insert, which skips nil,
		-- so a removed key shifted every later (key, new, old) triple.
		t.it("a removed key doesn't garble the other changes", function()
			local profile, changes = loaded()
			profile:Mutate(function(data)
				data.Title = nil
				data.Coins = 4
			end)
			settle()
			local byKey = {}
			for _, change in changes do
				byKey[change[1]] = change
			end
			expect(byKey.Coins).toEqual({ "Coins", 4, 0 })
			expect(byKey.Title).toEqual({ "Title", nil, "Rookie" })
			for _, change in changes do
				expect(type(change[1])).toBe("string")
			end
		end)

		t.it("with Keys, compares only those keys, in that order", function()
			local profile, changes = loaded()
			profile:Mutate(function(data)
				data.Coins = 9
				data.Title = "Pro"
				data.Owned.Bow = true -- not listed: not reported
			end, { Keys = { "Title", "Coins" } })
			settle()
			expect(changes).toEqual({ { "Title", "Pro", "Rookie" }, { "Coins", 9, 0 } })
		end)

		t.it("fires nothing when nothing changed (Keys of plain values)", function()
			local profile, changes = loaded()
			profile:Mutate(function() end, { Keys = { "Coins", "Title" } })
			settle()
			expect(#changes).toBe(0)
		end)

		t.it("reports what the mutator changed before raising, then re-raises", function()
			local profile, changes = loaded()
			expect(function()
				profile:Mutate(function(data)
					data.Coins = 7
					error("boom")
				end, { Keys = { "Coins" } })
			end).toThrow("boom")
			settle()
			expect(profile.Data.Coins).toBe(7)
			expect(changes).toEqual({ { "Coins", 7, 0 } })
		end)

		t.it("refuses an inactive profile and bad arguments", function()
			local profile, _, store, player = loaded()
			expect(function()
				profile:Mutate("nope" :: any)
			end).toThrow("Mutate expects a function")
			expect(function()
				profile:Mutate(function() end, { Keys = { 1 } :: any })
			end).toThrow("Keys must be an array of strings")
			store:Release(player)
			expect(function()
				profile:Mutate(function(data)
					data.Coins = 1
				end)
			end).toThrow("no longer active")
		end)

		t.it("raises and reports nothing when the session is lost while the mutator yields", function()
			local database = MemoryAdapter.newDatabase()
			local profile, changes = loaded({ Adapter = MemoryAdapter.new({ Database = database }) })
			local other = newStore({ Adapter = MemoryAdapter.new({ Database = database }) })
			local ok, message = pcall(function()
				profile:Mutate(function(data)
					-- Another server takes the session over meanwhile.
					other:LoadAsync(profile.Player):Await()
					data.Coins = 99
				end, { Keys = { "Coins" } })
			end)
			settle()
			expect(ok).toBe(false)
			expect(string.find(tostring(message), "no longer active", 1, true) ~= nil).toBe(true)
			expect(#changes).toBe(0)
		end)

		t.it("a released profile is collectable after many Mutate calls", function()
			local store = newStore()
			local weak = setmetatable({}, { __mode = "k" })
			local done = false
			-- On a thread that finishes, so no stack slot of this one holds them.
			task.spawn(function()
				local player = newPlayer()
				local _, profile = store:LoadAsync(player):Await()
				weak[profile] = true
				weak[player] = true
				profile.Changed:Connect(function() end)
				for index = 1, 500 do
					profile:Mutate(function(data)
						data.Coins = index
					end)
				end
				store:Release(player)
				player:Leave()
				done = true
			end)
			local deadline = os.clock() + 5
			while not done and os.clock() < deadline do
				task.wait()
			end
			-- Promise handlers run on recycled threads; let an idle one run
			-- another job so its stack doesn't still hold the last profile.
			Constella.Promise.resolve(nil):Then(function() end)
			expect(done).toBe(true)
			expect(t.collected(weak)).toBe(true)
			expect(store:GetStats().Loaded).toBe(0)
		end)
	end)

	t.describe("Validate", function()
		t.it("loads data that passes", function()
			local profile = loaded({
				Validate = Check.record({
					Coins = Check.number(0),
					Owned = Check.map(Check.string(), Check.boolean()),
					Settings = Check.record({ Music = Check.boolean() }),
					Title = Check.string(),
				}),
			})
			expect(profile.Data.Coins).toBe(0)
		end)

		t.it("fails as CorruptData, leaves the stored data untouched and kicks", function()
			local adapter = MemoryAdapter.new()
			local stored = { Coins = "lots", Owned = {}, Settings = { Music = true }, Title = "Rookie" }
			stored[Store.VERSION_KEY] = 1
			local store, _, errors = newStore({
				Adapter = adapter,
				Validate = function(data)
					if type(data.Coins) ~= "number" then
						return false, "Coins is not a number"
					end
					return true
				end,
			})
			local player = newPlayer()
			adapter:Write("Accessors", "Player_" .. player.UserId, stored)
			local before = adapter:Peek("Accessors", "Player_" .. player.UserId)
			local ok, err = store:LoadAsync(player):Await()
			expect(ok).toBe(false)
			expect(Store.isError(err, "CorruptData")).toBe(true)
			expect(string.find(err.Message, "Coins is not a number", 1, true) ~= nil).toBe(true)
			expect(adapter:Peek("Accessors", "Player_" .. player.UserId)).toEqual(before)
			expect(adapter:IsLocked("Accessors", "Player_" .. player.UserId)).toBe(false)
			expect(player.Kicked).toBeTruthy()
			expect(#errors).toBe(1)
		end)

		t.it("never shows Constella's version key to Validate, and still saves it", function()
			local adapter = MemoryAdapter.new()
			local sawVersion = false
			local store = newStore({
				Adapter = adapter,
				Validate = function(data)
					sawVersion = data[Store.VERSION_KEY] ~= nil
					return true
				end,
			})
			local player = newPlayer()
			local ok, profile = store:LoadAsync(player):Await()
			expect(ok).toBe(true)
			expect(sawVersion).toBe(false)
			expect(profile.Data[Store.VERSION_KEY]).toBe(1)
			store:Release(player)
			expect(adapter:Peek("Accessors", "Player_" .. player.UserId)[Store.VERSION_KEY]).toBe(1)
		end)

		t.it("a Validate that raises fails the load as LoadFailed", function()
			local store = newStore({
				KickOnFailure = false,
				Validate = function()
					error("validator bug")
				end,
			})
			local ok, err = store:LoadAsync(newPlayer()):Await()
			expect(ok).toBe(false)
			expect(Store.isError(err, "LoadFailed")).toBe(true)
			expect(string.find(err.Message, "validator bug", 1, true) ~= nil).toBe(true)
		end)

		t.it("runs after migrations and reconciliation", function()
			local adapter = MemoryAdapter.new()
			local seen
			local store = newStore({
				Adapter = adapter,
				Version = 2,
				Migrations = {
					[0] = function(data)
						data.Coins = (data.Gold or 0) * 10
						data.Gold = nil
					end,
					[1] = function(data)
						data.Title = "Veteran"
					end,
				},
				Validate = function(data)
					seen = table.clone(data)
					return true
				end,
			})
			local player = newPlayer()
			adapter:Write("Accessors", "Player_" .. player.UserId, { Gold = 4 })
			local ok = store:LoadAsync(player):Await()
			expect(ok).toBe(true)
			expect(seen.Coins).toBe(40)
			expect(seen.Title).toBe("Veteran")
			expect(seen.Owned).toEqual({})
		end)

		t.it("refuses a Validate that isn't a function", function()
			expect(function()
				newStore({ Validate = true })
			end).toThrow("Validate must be a function")
		end)
	end)

	t.describe("CheckWrites", function()
		-- Built at runtime: a mixed table literal is (rightly) a lint warning.
		local mixed: { any } = { 1, 2 };
		(mixed :: any).Name = "x"
		local CASES = {
			{ "an Instance", Instance.new("Folder"), "Instance" },
			{ "a function", function() end, "function" },
			{ "a Vector3", Vector3.one, "Vector3" },
			{ "NaN", 0 / 0, "nan" },
			{ "infinity", math.huge, "inf" },
			{ "invalid UTF-8", "\255", "UTF-8" },
			{ "a metatable", setmetatable({}, {}), "metatable" },
			{ "a mixed table", mixed, "mixes" },
			{ "an array with holes", { [1] = 1, [3] = 3 }, "holes" },
			{ "a fractional key", { [1.5] = true }, "1.5" },
			{ "a table key", { [{}] = true }, "table key" },
		}
		for _, case in CASES do
			t.it(("Set refuses %s"):format(case[1]), function()
				local profile, changes = loaded({ CheckWrites = true })
				expect(function()
					profile:Set("Owned", case[2])
				end).toThrow(case[3])
				settle()
				expect(#changes).toBe(0)
				expect(profile.Data.Owned).toEqual({})
			end)
		end

		t.it("names where in the value the problem is", function()
			local profile = loaded({ CheckWrites = true })
			expect(function()
				profile:Set("Owned", { Swords = { { Damage = 1 }, { Damage = Vector3.one } } })
			end).toThrow("Owned.Swords[2].Damage")
		end)

		t.it("accepts what DataStores can save", function()
			local profile = loaded({ CheckWrites = true })
			profile:Set("Owned", {
				Sword = true,
				List = { 1, 2, 3 },
				Nested = { Deep = { "a", "b" } },
				Empty = {},
				Note = "héllo",
				Data = buffer.create(4),
			})
			profile:Set("Coins", 12.5)
			profile:Update("Coins", function(coins)
				return coins + 1
			end)
			expect(profile.Data.Coins).toBe(13.5)
		end)

		t.it("refuses a table that contains itself", function()
			local profile = loaded({ CheckWrites = true })
			local loop = {}
			loop.Self = loop
			expect(function()
				profile:Set("Owned", loop)
			end).toThrow("deeper than")
		end)

		t.it("Update refuses before writing", function()
			local profile, changes = loaded({ CheckWrites = true })
			expect(function()
				profile:Update("Coins", function()
					return 0 / 0
				end)
			end).toThrow("nan")
			settle()
			expect(profile.Data.Coins).toBe(0)
			expect(#changes).toBe(0)
		end)

		t.it("Mutate reports the edits, then raises", function()
			local profile, changes = loaded({ CheckWrites = true })
			expect(function()
				profile:Mutate(function(data)
					data.Coins = 3
					data.Title = Vector3.one :: any
				end, { Keys = { "Coins", "Title" } })
			end).toThrow("Title is a Vector3")
			settle()
			-- The edits were made in place, so listeners still hear about them.
			expect(#changes).toBe(2)
		end)

		t.it("refuses non-string keys", function()
			local profile = loaded({ CheckWrites = true })
			expect(function()
				profile:Set(5 :: any, true)
			end).toThrow("keys must be strings")
		end)

		t.it("is off by default, as before 0.4.0", function()
			local profile = loaded()
			profile:Set("Owned", Vector3.one)
			expect(profile.Data.Owned).toBe(Vector3.one)
		end)

		t.it("refuses a CheckWrites that isn't a boolean", function()
			expect(function()
				newStore({ CheckWrites = "yes" })
			end).toThrow("CheckWrites must be a boolean")
		end)
	end)
end
