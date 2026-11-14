--!nonstrict
--[=[
	Data scenarios that need real Roblox servers and live DataStores: a
	player moving to a second server, and many sessions open at once. Not part of RunTests: .github/scripts/roblox_tests.py runs
	each function in its own Open Cloud Luau execution task, so every call
	gets its own server. Each run uses a fresh store name and removes its keys.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Data = Constella.Data
-- Third-party and not committed: CI adds a pinned copy to the test place.
local ProfileStore = require(ServerStorage:WaitForChild("ProfileStore") :: any)

local Live = {}

-- A stand-in player: Data only needs Name, UserId, Parent and Kick.
local function fakePlayer(userId: number)
	local player = { Name = "Player" .. userId, UserId = userId, Parent = true }
	function player:Kick(message)
		self.Kicked = message
		self.Parent = nil
	end
	return player
end

local function newStore(name: string, errors: { string })
	return Data.Store.new({
		Name = name,
		Version = 1,
		Template = { Coins = 0 },
		Adapter = Data.ProfileStoreAdapter.new(ProfileStore),
		OnError = function(message)
			table.insert(errors, message)
		end,
	})
end

local function storedCoins(name: string, key: string): number?
	local view = ProfileStore.New(name):GetAsync(key)
	return view and view.Data and view.Data.Coins
end

--- Server A: loads the player, saves Coins = 111, then waits until another
--- server takes the session over.
function Live.holdSession(name: string, userId: number, waitSeconds: number)
	local errors = {}
	local store = newStore(name, errors)
	local player = fakePlayer(userId)
	local started = os.clock()
	local ok, profile = store:LoadAsync(player):Await()
	if not ok then
		return { error = "load failed: " .. tostring(profile and profile.Message or profile) }
	end
	local loadSeconds = os.clock() - started
	profile:Set("Coins", 111)
	local saved = profile:Save()
	local lost = false
	store.Released:Connect(function(released)
		if released == player then
			lost = true
		end
	end)
	local waitStarted = os.clock()
	while not lost and os.clock() - waitStarted < waitSeconds do
		task.wait(0.25)
	end
	return {
		server = game.JobId,
		loadSeconds = loadSeconds,
		saved = saved,
		lost = lost,
		lostAfterSeconds = os.clock() - waitStarted,
		kicked = player.Kicked,
		stillActive = profile:IsActive(),
		errors = errors,
	}
end

--- Server B: after `delaySeconds`, loads the same player (as if they joined
--- a second server), checks it sees A's data, saves Coins = 222, shuts down
--- and removes the key.
function Live.takeOverSession(name: string, userId: number, delaySeconds: number)
	task.wait(delaySeconds)
	local errors = {}
	local store = newStore(name, errors)
	local player = fakePlayer(userId)
	local started = os.clock()
	local ok, profile = store:LoadAsync(player):Await()
	local loadSeconds = os.clock() - started
	if not ok then
		return { error = "load failed: " .. tostring(profile and profile.Message or profile), loadSeconds = loadSeconds }
	end
	local seen = profile:Get("Coins")
	profile:Set("Coins", 222)
	local shutdown = store:Shutdown(30)
	local key = "Player_" .. userId
	local stored = storedCoins(name, key)
	ProfileStore.New(name):RemoveAsync(key)
	return {
		server = game.JobId,
		loadSeconds = loadSeconds,
		seen = seen,
		shutdown = shutdown,
		stored = stored,
		errors = errors,
	}
end

--- Loads `count` profiles at once. Every profile must load, save the right
--- value on shutdown, and be removed. Keep `count` under about 20: ProfileStore
--- subscribes to one MessagingService topic per active profile, and a server
--- with no players (like this one) allows only about 20 subscriptions.
function Live.manySessions(name: string, count: number, firstUserId: number)
	local errors = {}
	local store = newStore(name, errors)
	local players = {}
	for index = 1, count do
		players[index] = fakePlayer(firstUserId + index)
	end

	local started = os.clock()
	local promises = {}
	for index, player in players do
		promises[index] = store:LoadAsync(player)
	end
	local loaded = 0
	for _, promise in promises do
		if promise:Await() then
			loaded += 1
		end
	end
	local loadSeconds = os.clock() - started

	for index, player in players do
		local profile = store:Get(player)
		if profile then
			profile:Set("Coins", index)
		end
	end
	local shutdownStarted = os.clock()
	local shutdown = store:Shutdown(150)
	local shutdownSeconds = os.clock() - shutdownStarted

	local saved = 0
	local profileStore = ProfileStore.New(name)
	for index, player in players do
		local key = "Player_" .. player.UserId
		if storedCoins(name, key) == index then
			saved += 1
		end
		profileStore:RemoveAsync(key)
	end
	return {
		count = count,
		loaded = loaded,
		loadSeconds = loadSeconds,
		shutdown = shutdown,
		shutdownSeconds = shutdownSeconds,
		saved = saved,
		errors = errors,
	}
end

return Live
