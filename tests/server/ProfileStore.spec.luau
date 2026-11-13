--!nonstrict
-- Constella.Data against the REAL ProfileStore library (not a stand-in).
--
-- Install ProfileStore (lm-loleris/profilestore, verified with 1.0.3) as a
-- ModuleScript named "ProfileStore" in ServerStorage, ServerScriptService
-- or ReplicatedStorage.Packages. Without it these tests are skipped.
--
-- Every store here uses ProfileStore's mock mode (Adapter option
-- Mock = true), so the suite never reads or writes real player data, even
-- in a place with DataStore access. Mock mode runs ProfileStore's real
-- session, save and end-session code paths against an in-memory store.
return function(t, Constella)
	local HttpService = game:GetService("HttpService")
	local Data = Constella.Data
	local Store = Data.Store
	local expect = t.expect

	local function findProfileStore()
		local candidates = {
			game:GetService("ServerStorage"):FindFirstChild("ProfileStore"),
			game:GetService("ServerScriptService"):FindFirstChild("ProfileStore"),
		}
		local packages = game:GetService("ReplicatedStorage"):FindFirstChild("Packages")
		if packages then
			table.insert(candidates, packages:FindFirstChild("ProfileStore"))
		end
		for _, candidate in candidates do
			if candidate and candidate:IsA("ModuleScript") then
				return candidate
			end
		end
		return nil
	end

	local module = findProfileStore()
	if module == nil then
		t.skip("all ProfileStore tests", "ProfileStore is not installed")
		return
	end
	local ProfileStore = require(module)

	local function uniqueName()
		return "ConstellaTest_" .. string.sub(HttpService:GenerateGUID(false), 1, 8)
	end

	local nextUserId = 50000
	local function fakePlayer(userId)
		if userId == nil then
			nextUserId += 1
			userId = nextUserId
		end
		local player = { Name = "Player" .. userId, UserId = userId, Parent = true }
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
			Name = uniqueName(),
			Template = { Coins = 0, Inventory = {} },
			Adapter = Data.ProfileStoreAdapter.new(ProfileStore, { Mock = true, SaveTimeout = 10 }),
			LoadAttempts = 1,
			RetryDelay = 0,
			OnError = function(message)
				table.insert(errors, message)
			end,
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		return Store.new(config), config.Name, errors
	end

	-- What ProfileStore has actually written for a key (read without a session).
	local function stored(storeName, key)
		local view = ProfileStore.New(storeName).Mock:GetAsync(key)
		return if view then view.Data else nil
	end

	-- Writes raw data with ProfileStore directly, as an older game version would.
	local function seed(storeName, key, data)
		local raw = ProfileStore.New(storeName, {}).Mock:StartSessionAsync(key)
		assert(raw, "could not seed data")
		table.clear(raw.Data)
		for field, value in data do
			raw.Data[field] = value
		end
		local written = false
		raw.OnAfterSave:Connect(function()
			written = true
		end)
		raw:EndSession()
		local deadline = os.clock() + 10
		while not written and os.clock() < deadline do
			task.wait()
		end
		assert(written, "seed save timed out")
	end

	t.describe("sessions", function()
		t.it("loads new profiles from the template at the current version", function()
			local store = newStore()
			local ok, profile = store:LoadAsync(fakePlayer()):Await()
			expect(ok).toBe(true)
			expect(profile.Data.Coins).toBe(0)
			expect(profile.Data.Inventory).toEqual({})
			expect(profile.Data[Store.VERSION_KEY]).toBe(1)
		end)

		t.it("Release returns only after the final save has been written", function()
			local store, name = newStore()
			local player = fakePlayer()
			local _, profile = store:LoadAsync(player):Await()
			profile:Set("Coins", 42)
			store:Release(player)
			local data = stored(name, keyOf(player))
			expect(data.Coins).toBe(42)
			expect(data[Store.VERSION_KEY]).toBe(1)
		end)

		t.it("profile:Save() returns only after the save has been written", function()
			local store, name = newStore()
			local player = fakePlayer()
			local _, profile = store:LoadAsync(player):Await()
			profile:Set("Coins", 7)
			expect(profile:Save()).toBe(true)
			expect(stored(name, keyOf(player)).Coins).toBe(7)
			store:Release(player)
		end)

		t.it("keeps data across sessions", function()
			local store = newStore()
			local player = fakePlayer()
			local _, first = store:LoadAsync(player):Await()
			first:Set("Coins", 99)
			store:Release(player)
			local rejoined = fakePlayer(player.UserId)
			local ok, second = store:LoadAsync(rejoined):Await()
			expect(ok).toBe(true)
			expect(second.Data.Coins).toBe(99)
			store:Release(rejoined)
		end)

		t.it("ends the session when the player leaves during loading", function()
			local store, name = newStore()
			local player = fakePlayer()
			local promise = store:LoadAsync(player)
			player.Parent = nil -- left before ProfileStore finished loading
			local ok, err = promise:Await()
			expect(ok).toBe(false)
			expect(Store.isError(err, "PlayerLeft")).toBe(true)
			-- No session was leaked: ProfileStore refuses a second session for a
			-- key that is still open on this server, so a rejoin proves it closed.
			local rejoined = fakePlayer(player.UserId)
			local rejoinOk = store:LoadAsync(rejoined):Await()
			expect(rejoinOk).toBe(true)
			store:Release(rejoined)
			expect(stored(name, keyOf(player)).Coins).toBe(0)
		end)

		t.it("kicks the player when ProfileStore ends the session", function()
			local store = newStore()
			local player = fakePlayer()
			local _, profile = store:LoadAsync(player):Await()
			profile._session._profile:EndSession() -- as if ended from outside Constella
			local deadline = os.clock() + 5
			while store:Get(player) ~= nil and os.clock() < deadline do
				task.wait()
			end
			expect(store:Get(player)).toBeNil()
			expect(profile:IsActive()).toBe(false)
			expect(player.Kicked ~= nil).toBe(true)
		end)
	end)

	t.describe("migrations", function()
		t.it("migrates data that ProfileStore stored before Constella", function()
			local name = uniqueName()
			local player = fakePlayer()
			seed(name, keyOf(player), { Gold = 10 })
			local store = newStore({
				Name = name,
				Version = 2,
				Migrations = {
					[0] = function(data)
						data.Coins = data.Gold
						data.Gold = nil
					end,
					[1] = function(data)
						data.Coins *= 2
					end,
				},
			})
			local ok, profile = store:LoadAsync(player):Await()
			expect(ok).toBe(true)
			expect(profile.Data.Coins).toBe(20)
			store:Release(player)
			local data = stored(name, keyOf(player))
			expect(data.Coins).toBe(20)
			expect(data.Gold).toBeNil()
			expect(data[Store.VERSION_KEY]).toBe(2)
		end)

		t.it("leaves ProfileStore's stored data untouched when a migration fails", function()
			local name = uniqueName()
			local player = fakePlayer()
			seed(name, keyOf(player), { Gold = 5 })
			local store = newStore({
				Name = name,
				Migrations = {
					[0] = function(data)
						data.Gold = -1
						error("bad migration")
					end,
				},
			})
			local ok, err = store:LoadAsync(player):Await()
			expect(ok).toBe(false)
			expect(Store.isError(err, "MigrationFailed")).toBe(true)
			expect(player.Kicked ~= nil).toBe(true)
			expect(stored(name, keyOf(player))).toEqual({ Gold = 5 })
		end)
	end)

	t.describe("shutdown", function()
		t.it("Shutdown returns once every final save has been written", function()
			local store, name = newStore()
			local players = { fakePlayer(), fakePlayer(), fakePlayer() }
			for index, player in players do
				local _, profile = store:LoadAsync(player):Await()
				profile:Set("Coins", index * 100)
			end
			expect(store:Shutdown(10)).toBe(true)
			for index, player in players do
				expect(stored(name, keyOf(player)).Coins).toBe(index * 100)
			end
		end)
	end)
end
