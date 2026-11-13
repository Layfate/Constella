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
end
