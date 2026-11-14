--!nonstrict
-- Server-side authorisation and the client mirror. The Play-mode
-- integration test covers real delivery to a client.
return function(t, Constella)
	local Replication = Constella.Replication
	local State = Constella.State
	local expect = t.expect

	local function newServer()
		local errors = {}
		local server = Replication.Server.new("ReplicationTest", {
			Parent = Instance.new("Folder"),
			OnError = function(message)
				table.insert(errors, message)
			end,
		})
		return server, errors
	end

	local function snapshot(server, player)
		local ok, data = server._fetch:_invoke(player)
		assert(ok, "fetch failed")
		return data
	end

	t.describe("server", function()
		t.it("shares public values with everyone and private values with one player", function()
			local server = newServer()
			local alice, bob = { Name = "Alice" }, { Name = "Bob" }
			server:Share("Round", State.new(3))
			server:ShareWith(alice, "Coins", State.new(100))
			server:ShareWith(bob, "Coins", State.new(5))

			local forAlice = snapshot(server, alice)
			local forBob = snapshot(server, bob)
			expect(forAlice.Round[1]).toBe(3)
			expect(forAlice.Coins[1]).toBe(100)
			expect(forBob.Coins[1]).toBe(5)
			expect(snapshot(server, { Name = "Eve" }).Coins).toBeNil()
			server:Destroy()
		end)

		t.it("bumps the version on every change", function()
			local server = newServer()
			local player = { Name = "P" }
			local value = State.new(1)
			server:ShareWith(player, "Score", value)
			local before = snapshot(server, player).Score[2]
			value:Set(2)
			value:Set(3)
			local after = snapshot(server, player).Score
			expect(after[1]).toBe(3)
			expect(after[2]).toBe(before + 2)
			server:Destroy()
		end)

		t.it("stops sharing on Stop and when the player leaves", function()
			local server = newServer()
			local player = { Name = "P" }
			local share = server:Share("Public", State.new(true))
			server:ShareWith(player, "Private", State.new(1))
			share:Stop()
			expect(snapshot(server, player).Public).toBeNil()
			server:_forgetPlayer(player)
			expect(snapshot(server, player).Private).toBeNil()
			-- The name is free again once every share using it is gone.
			server:Share("Private", State.new(0))
			server:Destroy()
		end)

		t.it("rejects name conflicts and non-replicable values", function()
			local server = newServer()
			local player = { Name = "P" }
			server:Share("Taken", State.new(1))
			expect(function()
				server:Share("Taken", State.new(2))
			end).toThrow("already shared")
			expect(function()
				server:ShareWith(player, "Taken", State.new(2))
			end).toThrow("already shared as public")
			expect(function()
				server:Share("Fn", State.new(function() end))
			end).toThrow("cannot be replicated")
			expect(function()
				server:Share("NotState", 5)
			end).toThrow("must be a Constella state")
			server:Destroy()
		end)

		t.it("reports and skips values that become non-replicable", function()
			local server, errors = newServer()
			local value = State.new({ ok = true })
			server:Share("Thing", value)
			value:Set({ bad = function() end })
			value:Set({ big = string.rep("x", 20000) })
			expect(#errors).toBe(2)
			server:Destroy()
		end)

		t.it("does not accept updates from clients", function()
			local server = newServer()
			local net = server._net
			server._update:_receive({ Name = "Hacker" }, "Coins", 999999, 1000)
			expect(net:GetStats().Update.Rejected.NotAccepted).toBe(1)
			server:Destroy()
		end)
	end)

	t.describe("client mirror", function()
		t.it("applies values and ignores stale versions", function()
			local mirror = Replication._newMirror()
			local coins = mirror:Get("Coins")
			expect(coins:Get()).toBeNil()
			local seen = {}
			coins:Subscribe(function(value)
				table.insert(seen, value)
			end)
			mirror:Apply("Coins", 10, 2)
			mirror:Apply("Coins", 5, 1) -- an older snapshot arriving late
			mirror:Apply("Coins", 12, 3)
			expect(coins:Get()).toBe(12)
			expect(seen).toEqual({ 10, 12 })
			mirror:Destroy()
		end)

		t.it("exposes read-only states and ignores malformed updates", function()
			local mirror = Replication._newMirror()
			local value = mirror:Get("X")
			expect(value.Set).toBeNil()
			mirror:Apply(5, "bad name", 1)
			mirror:Apply("X", "no version", nil)
			expect(value:Get()).toBeNil()
			mirror:Destroy()
		end)
	end)

	t.describe("review fixes", function()
		t.it("keeps versions increasing when a share is stopped and recreated", function()
			local server = newServer()
			local player = { Name = "P" }
			local mirror = Replication._newMirror()

			local first = server:ShareWith(player, "Coins", State.new(5))
			local before = snapshot(server, player).Coins
			mirror:Apply("Coins", before[1], before[2])
			first:Stop()

			-- Recreated under the same name, with a new state starting over.
			server:ShareWith(player, "Coins", State.new(7))
			local after = snapshot(server, player).Coins
			expect(after[2] > before[2]).toBe(true)

			-- A client that remembered the old version still accepts the new share.
			mirror:Apply("Coins", after[1], after[2])
			expect(mirror:Get("Coins"):Get()).toBe(7)
			mirror:Destroy()
			server:Destroy()
		end)

		t.it("serves only validated values in snapshots", function()
			local server, errors = newServer()
			local player = { Name = "P" }
			local value = State.new("ok")
			server:ShareWith(player, "Thing", value)
			local good = snapshot(server, player).Thing
			value:Set(function() end) -- unsupported
			value:Set(string.rep("x", 20000)) -- too large
			local after = snapshot(server, player).Thing
			expect(after[1]).toBe("ok")
			expect(after[2]).toBe(good[2])
			expect(#errors).toBe(2)
			value:Set("fine again")
			expect(snapshot(server, player).Thing[1]).toBe("fine again")
			server:Destroy()
		end)

		t.it("rejects an oversized initial value at Share time", function()
			local server = newServer()
			expect(function()
				server:Share("Huge", State.new(string.rep("x", 20000)))
			end).toThrow("cannot be replicated")
			server:Destroy()
		end)
	end)
	t.describe("delta", function()
		local diff, applyPatch = Replication._diff, Replication._applyPatch
		local deepEqual = function(a, b)
			local ok = pcall(function()
				expect(a).toEqual(b)
			end)
			return ok
		end

		-- Random replicable tables: arrays and string-keyed dictionaries,
		-- nested up to three levels.
		local function randomValue(rng, depth)
			local roll = rng:NextInteger(1, if depth < 3 then 6 else 4)
			if roll == 1 then
				return rng:NextInteger(-5, 5)
			elseif roll == 2 then
				return "s" .. rng:NextInteger(1, 4)
			elseif roll == 3 then
				return rng:NextNumber() < 0.5
			elseif roll == 4 then
				return rng:NextNumber()
			elseif roll == 5 then
				local array = {}
				for index = 1, rng:NextInteger(0, 4) do
					array[index] = randomValue(rng, depth + 1)
				end
				return array
			end
			local map = {}
			for _ = 1, rng:NextInteger(0, 4) do
				map["k" .. rng:NextInteger(1, 6)] = randomValue(rng, depth + 1)
			end
			return map
		end

		-- Changes a copy of `value` a little: sets, removals and nested edits.
		local function mutate(rng, value, depth)
			local copy = table.clone(value)
			for _ = 1, rng:NextInteger(0, 3) do
				local key = "k" .. rng:NextInteger(1, 6)
				local action = rng:NextInteger(1, 3)
				if action == 1 then
					copy[key] = randomValue(rng, depth + 1)
				elseif action == 2 then
					copy[key] = nil
				elseif type(copy[key]) == "table" and depth < 3 then
					copy[key] = mutate(rng, copy[key], depth + 1)
				end
			end
			return copy
		end

		-- True if every table in `patch` is an array or has only string keys.
		local function remoteSafe(value)
			if type(value) ~= "table" then
				return true
			end
			local count = 0
			local stringKeys = true
			for key, item in value do
				count += 1
				if type(key) ~= "string" then
					stringKeys = false
				end
				if not remoteSafe(item) then
					return false
				end
			end
			return stringKeys or count == #value
		end

		t.it("turns any table into any other, using only remote-safe tables", function()
			local rng = Random.new(42)
			for _ = 1, 500 do
				local old = randomValue(rng, 0)
				if type(old) ~= "table" then
					old = { k1 = old }
				end
				local new = mutate(rng, old, 0)
				local patch = diff(old, new, 1) or {}
				expect(remoteSafe(patch)).toBe(true)
				local frozenOld = table.clone(old)
				local result = applyPatch(old, patch, 1)
				expect(deepEqual(result, new)).toBe(true)
				-- The base table is never modified.
				expect(deepEqual(old, frozenOld)).toBe(true)
			end
		end)

		t.it("returns nil for equal tables and rejects malformed patches", function()
			expect(diff({ a = 1, b = { 2 } }, { a = 1, b = { 2 } }, 1)).toBeNil()
			expect(applyPatch({}, "nope", 1)).toBeNil()
			expect(applyPatch({}, { k = "x" }, 1)).toBeNil()
			expect(applyPatch({}, { n = { "a" }, p = { "bad" } }, 1)).toBeNil()
		end)

		local function deltaServer()
			local server = Replication.Server.new("DeltaTest", { Parent = Instance.new("Folder"), Delta = true })
			local sent = {}
			-- Record what would go to clients instead of firing the remote.
			server._update.FireList = function(_, _players, ...)
				table.insert(sent, table.pack(...))
			end
			return server, sent
		end

		local function inventory(coins)
			local items = {}
			for index = 1, 40 do
				items[index] = { Id = "Item" .. index, Count = index }
			end
			return { Coins = coins, Items = items }
		end

		t.it("sends a small change to a large table as a patch clients can apply", function()
			local server, sent = deltaServer()
			local state = State.new(inventory(1))
			server:Share("Inventory", state)
			local initial = sent[1]
			expect(initial[4]).toBe(false) -- removed flag
			expect(initial[5]).toBeNil() -- a full value, not a patch

			local mirror = Replication._newMirror()
			mirror:Apply(initial[1], initial[2], initial[3], initial[4], initial[5])

			local nextValue = table.clone(state:Get())
			nextValue.Coins = 2
			state:Set(nextValue)
			local update = sent[2]
			expect(update[5]).toBe(initial[3]) -- builds on the initial version
			expect(update[2].k).toEqual({ "Coins" })
			expect(update[2].n).toBeNil() -- the item list didn't change
			mirror:Apply(update[1], update[2], update[3], update[4], update[5])
			expect(deepEqual(mirror:Get("Inventory"):Get(), nextValue)).toBe(true)
			mirror:Destroy()
			server:Destroy()
		end)

		t.it("sees changes made in place to the previous table", function()
			local server, sent = deltaServer()
			local state = State.new(inventory(1))
			server:Share("Inventory", state)
			local mirror = Replication._newMirror()
			local first = sent[1]
			mirror:Apply(first[1], first[2], first[3], first[4], first[5])

			-- A common pattern: edit the current table, then set a copy.
			local current = state:Get()
			current.Coins = 7
			current.Items[3].Count = 99
			state:Set(table.clone(current))
			local update = sent[2]
			expect(update[5]).toBe(first[3])
			mirror:Apply(update[1], update[2], update[3], update[4], update[5])
			local seen = mirror:Get("Inventory"):Get()
			expect(seen.Coins).toBe(7)
			expect(seen.Items[3].Count).toBe(99)
			mirror:Destroy()
			server:Destroy()
		end)

		t.it("keeps a client in sync over many random updates, including in-place edits", function()
			local server, sent = deltaServer()
			local rng = Random.new(7)
			local state = State.new({ k1 = 1, k2 = { k3 = { 1, 2, 3 } } })
			server:Share("Random", state)
			local mirror = Replication._newMirror()
			local resyncs = 0
			mirror._onResync = function()
				resyncs += 1
			end
			local delivered = 0
			local function deliver()
				for index = delivered + 1, #sent do
					local message = sent[index]
					mirror:Apply(message[1], message[2], message[3], message[4], message[5])
				end
				delivered = #sent
			end
			deliver()
			for _ = 1, 300 do
				local current = state:Get()
				if rng:NextNumber() < 0.3 then
					-- Edit the current table (and a nested one) in place, then
					-- set a shallow copy.
					current.k1 = rng:NextInteger(1, 100)
					if type(current.k2) == "table" then
						current.k2.k4 = rng:NextInteger(1, 100)
					end
					state:Set(table.clone(current))
				else
					state:Set(mutate(rng, current, 0))
				end
				deliver()
				expect(deepEqual(mirror:Get("Random"):Get(), state:Get())).toBe(true)
			end
			expect(resyncs).toBe(0)
			mirror:Destroy()
			server:Destroy()
		end)

		t.it("sends the whole value when a patch wouldn't be smaller", function()
			local server, sent = deltaServer()
			local state = State.new({ A = 1 })
			server:Share("Small", state)
			state:Set({ B = 2 })
			expect(sent[2][5]).toBeNil()
			expect(sent[2][2]).toEqual({ B = 2 })
			server:Destroy()
		end)

		t.it("is off by default and validates the option", function()
			local server = Replication.Server.new("NoDelta", { Parent = Instance.new("Folder") })
			local sent = {}
			server._update.FireList = function(_, _players, ...)
				table.insert(sent, table.pack(...))
			end
			local state = State.new(inventory(1))
			server:Share("Inventory", state)
			local nextValue = table.clone(state:Get())
			nextValue.Coins = 2
			state:Set(nextValue)
			expect(sent[2][5]).toBeNil()
			server:Destroy()
			expect(function()
				Replication.Server.new("BadDelta", { Parent = Instance.new("Folder"), Delta = "yes" })
			end).toThrow("Delta must be a boolean")
		end)

		t.it("holds patches that arrive before the snapshot and applies them after it", function()
			local mirror = Replication._newMirror()
			local resyncs = 0
			mirror._onResync = function()
				resyncs += 1
			end
			local seen = {}
			mirror:Get("Bag"):Subscribe(function(value)
				table.insert(seen, value.Gold)
			end)
			-- Patches for versions 6 and 7 arrive first, out of order.
			mirror:Apply("Bag", { k = { "Gold" }, v = { 3 } }, 7, false, 6)
			mirror:Apply("Bag", { k = { "Gold" }, v = { 2 } }, 6, false, 5)
			expect(mirror:Get("Bag"):Get()).toBeNil()
			-- Then the snapshot at version 5.
			mirror:Apply("Bag", { Gold = 1, Gems = 4 }, 5)
			expect(mirror:Get("Bag"):Get()).toEqual({ Gold = 3, Gems = 4 })
			expect(seen).toEqual({ 1, 2, 3 })
			expect(resyncs).toBe(0)
			mirror:Destroy()
		end)

		t.it("drops held patches the snapshot already includes", function()
			local mirror = Replication._newMirror()
			mirror:Apply("Bag", { k = { "Gold" }, v = { 2 } }, 6, false, 5)
			mirror:Apply("Bag", { Gold = 2 }, 6) -- the snapshot is already at 6
			mirror:Apply("Bag", { k = { "Gold" }, v = { 3 } }, 7, false, 6)
			expect(mirror:Get("Bag"):Get()).toEqual({ Gold = 3 })
			mirror:Destroy()
		end)

		t.it("asks for a snapshot when a patch can't be applied", function()
			local mirror = Replication._newMirror()
			local resyncs = 0
			mirror._onResync = function()
				resyncs += 1
			end
			mirror:Apply("Bag", { Gold = 1 }, 5)
			-- Malformed patch.
			mirror:Apply("Bag", { k = "Gold" }, 6, false, 5)
			expect(resyncs).toBe(1)
			-- A patch for a value that isn't a table on this client.
			mirror:Apply("Flag", true, 3)
			mirror:Apply("Flag", { k = { "x" }, v = { 1 } }, 4, false, 3)
			expect(resyncs).toBe(2)
			-- Too many patches waiting for a base that never arrives.
			for version = 20, 20 + 64 do
				mirror:Apply("Lost", { k = { "x" }, v = { version } }, version + 1, false, version)
			end
			expect(resyncs).toBe(3)
			expect(mirror:Get("Bag"):Get()).toEqual({ Gold = 1 })
			mirror:Destroy()
		end)
	end)
end
