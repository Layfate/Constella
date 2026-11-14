--!nonstrict
-- Server-side Network tests. Requests are fed through the same internal
-- entry points that OnServerEvent / OnServerInvoke use, with stand-in
-- players, so malformed and forged payloads can be tested without clients.
-- The Play-mode integration test (NetworkIntegration) covers real remotes.
return function(t, Constella)
	local Network = Constella.Network
	local Check = Network.Check
	local expect = t.expect

	local function fakePlayer(name)
		return { Name = name or "Tester" }
	end

	local function newServer(options)
		local opts = options or {}
		opts.Parent = opts.Parent or Instance.new("Folder")
		opts.OnError = opts.OnError or function() end
		return Network.Server.new("Test", opts), opts.Parent
	end

	-- A controllable clock for rate limiting.
	t.describe("server concurrency", function()
		t.it("bounds yielding events across endpoints and players, then returns capacity", function()
			local server = newServer({ MaxInFlightPerPlayer = 1, MaxInFlight = 2 })
			local gate = Constella.Signal.new()
			local a = server:Event("A", { Schema = {}, RateLimit = false })
			local b = server:Event("B", { Schema = {}, RateLimit = false })
			local calls = 0
			a:Connect(function()
				calls += 1
				gate:Wait()
			end)
			b:Connect(function()
				calls += 1
				gate:Wait()
			end)
			local alice, bob, eve = fakePlayer("Alice"), fakePlayer("Bob"), fakePlayer("Eve")
			a:_receive(alice)
			b:_receive(alice)
			b:_receive(bob)
			a:_receive(eve)
			expect(calls).toBe(2)
			expect(server:GetStats().A.InFlight).toBe(1)
			expect(server:GetStats().A.Rejected.Busy).toBe(1)
			expect(server:GetStats().B.Rejected.Busy).toBe(1)
			server:_forgetPlayer(alice) -- disconnect must not reset occupied slots
			a:_receive(alice)
			expect(calls).toBe(2)
			gate:Fire()
			expect(server:GetStats().A.InFlight).toBe(0)
			a:_receive(alice)
			expect(calls).toBe(3)
			gate:Fire()
			server:Destroy()
			gate:Destroy()
		end)

		t.it("holds an event slot until all listeners return", function()
			local server = newServer({ MaxInFlight = 1 })
			local gate = Constella.Signal.new()
			local event = server:Event("Many", { Schema = {}, RateLimit = false })
			event:Connect(function() end)
			event:Connect(function()
				gate:Wait()
			end)
			event:_receive(fakePlayer())
			expect(server:GetStats().Many.InFlight).toBe(1)
			gate:Fire()
			expect(server:GetStats().Many.InFlight).toBe(0)
			server:Destroy()
			gate:Destroy()
		end)

		t.it("bounds yielding authorization and releases function slots on errors", function()
			local server = newServer({ MaxInFlight = 1 })
			local gate = Constella.Signal.new()
			local func = server:Function("Slow", {
				Schema = {},
				RateLimit = false,
				Authorize = function()
					gate:Wait()
					return true
				end,
			})
			func:SetHandler(function()
				error("handler failed")
			end)
			local finished = false
			task.spawn(function()
				local ok, code = func:_invoke(fakePlayer())
				expect(ok).toBe(false)
				expect(code).toBe("ServerError")
				finished = true
			end)
			local ok, code = func:_invoke(fakePlayer())
			expect(ok).toBe(false)
			expect(code).toBe("RateLimited")
			expect(server:GetStats().Slow.InFlight).toBe(1)
			gate:Fire()
			expect(finished).toBe(true)
			expect(server:GetStats().Slow.InFlight).toBe(0)
			server:Destroy()
			gate:Destroy()
		end)

		t.it("aggregates rejection logs while retaining exact counters", function()
			local now, logs = 0, {}
			local server = newServer({
				Clock = function()
					return now
				end,
				RejectLogInterval = 5,
				Logger = {
					Warn = function(_, _, fields)
						table.insert(logs, fields)
					end,
				},
			})
			local event = server:Event("Reject")
			for _ = 1, 100 do
				event:_receive(fakePlayer())
			end
			expect(#logs).toBe(1)
			now = 5
			event:_receive(fakePlayer())
			expect(#logs).toBe(2)
			expect(logs[2].Count).toBe(100)
			expect(server:GetStats().Reject.Rejected.NotAccepted).toBe(101)
			server:Destroy()
		end)
	end)

	local function fakeClock()
		local now = 0
		return function()
			return now
		end, function(seconds)
			now += seconds
		end
	end

	t.describe("Check", function()
		t.it("string enforces type, length and UTF-8", function()
			local v = Check.string(5)
			expect((v("hello"))).toBe(true)
			expect((v("toolong"))).toBe(false)
			expect((v(5))).toBe(false)
			expect((v(nil))).toBe(false)
			expect((v("\255\254"))).toBe(false)
		end)

		t.it("number rejects NaN, infinities and out-of-range values", function()
			local v = Check.number(0, 10)
			expect((v(5.5))).toBe(true)
			expect((v(0 / 0))).toBe(false)
			expect((v(math.huge))).toBe(false)
			expect((v(-1))).toBe(false)
			expect((v("5"))).toBe(false)
		end)

		t.it("integer rejects fractions", function()
			local v = Check.integer(1, 3)
			expect((v(2))).toBe(true)
			expect((v(2.5))).toBe(false)
			expect((v(4))).toBe(false)
		end)

		t.it("array rejects holes, extra keys and oversized arrays", function()
			local v = Check.array(Check.integer(), 3)
			expect((v({ 1, 2, 3 }))).toBe(true)
			expect((v({ 1, 2, 3, 4 }))).toBe(false)
			expect((v({ [1] = 1, [3] = 3 }))).toBe(false)
			-- selene: allow(mixed_table)
			expect((v({ 1, 2, extra = 3 }))).toBe(false)
			expect((v({ 1, "two" }))).toBe(false)
		end)

		t.it("record rejects unknown and invalid fields", function()
			local v = Check.record({ Id = Check.integer(), Note = Check.optional(Check.string(10)) })
			expect((v({ Id = 1 }))).toBe(true)
			expect((v({ Id = 1, Note = "hi" }))).toBe(true)
			expect((v({ Id = 1, Admin = true }))).toBe(false)
			expect((v({ Note = "hi" }))).toBe(false)
		end)

		t.it("literal, union, vector3, instance and enum", function()
			expect((Check.literal("a", "b")("b"))).toBe(true)
			expect((Check.literal("a", "b")("c"))).toBe(false)
			expect((Check.union(Check.boolean(), Check.integer())(3))).toBe(true)
			expect((Check.union(Check.boolean(), Check.integer())("x"))).toBe(false)
			expect((Check.vector3(10)(Vector3.new(1, 2, 3)))).toBe(true)
			expect((Check.vector3()(Vector3.new(0 / 0, 0, 0)))).toBe(false)
			expect((Check.vector3(10)(Vector3.new(100, 0, 0)))).toBe(false)
			local folder = Instance.new("Folder")
			local part = Instance.new("Part")
			part.Parent = folder
			expect((Check.instance("BasePart", folder)(part))).toBe(true)
			expect((Check.instance("BasePart", folder)(Instance.new("Part")))).toBe(false)
			expect((Check.instance("BasePart")(folder))).toBe(false)
			expect((Check.enum(Enum.KeyCode)(Enum.KeyCode.E))).toBe(true)
			expect((Check.enum(Enum.KeyCode)(Enum.Material.Plastic))).toBe(false)
			folder:Destroy()
		end)

		t.it("arguments rejects extra arguments", function()
			local schema = { Check.string(), Check.optional(Check.integer()) }
			expect((Check.arguments(schema, "a"))).toBe(true)
			expect((Check.arguments(schema, "a", 1))).toBe(true)
			expect((Check.arguments(schema, "a", 1, "extra"))).toBe(false)
			expect((Check.arguments(schema))).toBe(false)
		end)
	end)

	t.describe("Payload", function()
		t.it("measures and enforces byte, depth and value limits", function()
			local Payload = Network.Payload
			expect(Payload.measure({ MaxBytes = 100 }, "abc", 1, true)).toBe(7 + 9 + 1)
			expect((Payload.measure({ MaxBytes = 100 }, string.rep("x", 200)))).toBeNil()
			local deep = {}
			local cursor = deep
			for _ = 1, 20 do
				cursor.next = {}
				cursor = cursor.next
			end
			local size, reason = Payload.measure({ MaxBytes = 100000 }, deep)
			expect(size).toBeNil()
			expect(string.find(reason, "nested", 1, true) ~= nil).toBe(true)
			local wide = table.create(1000, 1)
			expect((Payload.measure({ MaxBytes = 1000000 }, wide))).toBeNil()
		end)
	end)

	t.describe("RateLimiter", function()
		t.it("allows bursts up to Count and refills over Per seconds", function()
			local clock, advance = fakeClock()
			local limiter = Network.RateLimiter.new({ Count = 3, Per = 1 }, clock)
			local player = fakePlayer()
			expect(limiter:Consume(player)).toBe(true)
			expect(limiter:Consume(player)).toBe(true)
			expect(limiter:Consume(player)).toBe(true)
			expect(limiter:Consume(player)).toBe(false)
			advance(1 / 3)
			expect(limiter:Consume(player)).toBe(true)
			expect(limiter:Consume(player)).toBe(false)
			advance(10)
			expect(limiter:GetTokens(player)).toBe(3)
		end)

		t.it("keeps players independent and forgets them", function()
			local clock = fakeClock()
			local limiter = Network.RateLimiter.new({ Count = 1, Per = 60 }, clock)
			local a, b = fakePlayer("A"), fakePlayer("B")
			expect(limiter:Consume(a)).toBe(true)
			expect(limiter:Consume(a)).toBe(false)
			expect(limiter:Consume(b)).toBe(true)
			limiter:Forget(a)
			expect(limiter:Consume(a)).toBe(true)
		end)

		t.it("rejects invalid configuration", function()
			expect(function()
				Network.RateLimiter.new({ Count = 0, Per = 1 })
			end).toThrow("RateLimit must be")
			expect(function()
				Network.RateLimiter.new({ Count = 5, Per = 0 / 0 })
			end).toThrow("RateLimit must be")
		end)
	end)

	t.describe("Server events", function()
		t.it("creates remotes inside an owned namespace folder", function()
			local server, parent = newServer()
			server:Event("Ping", { Schema = {} })
			server:Event("Fast", { Schema = {}, Unreliable = true })
			server:Function("Ask", { Schema = {} })
			local folder = parent:FindFirstChild("Test")
			expect(folder ~= nil).toBe(true)
			expect(folder.Ping.ClassName).toBe("RemoteEvent")
			expect(folder.Fast.ClassName).toBe("UnreliableRemoteEvent")
			expect(folder.Ask.ClassName).toBe("RemoteFunction")
			expect(function()
				Network.Server.new("Test", { Parent = parent })
			end).toThrow("already owned")
			server:Destroy()
			expect(parent:FindFirstChild("Test")).toBeNil()
		end)

		t.it("rejects duplicate and invalid endpoint names", function()
			local server = newServer()
			server:Event("Ping", { Schema = {} })
			expect(function()
				server:Event("Ping", { Schema = {} })
			end).toThrow("already exists")
			expect(function()
				server:Event("bad name!", { Schema = {} })
			end).toThrow("letters, digits or underscores")
			expect(function()
				server:Function("NoSchema", {})
			end).toThrow("needs a Schema")
			server:Destroy()
		end)

		t.it("delivers valid requests to handlers with the player first", function()
			local server = newServer()
			local event = server:Event("Buy", { Schema = { Check.string(20), Check.integer(1, 99) } })
			local received
			event:Connect(function(player, item, quantity)
				received = { player.Name, item, quantity }
			end)
			event:_receive(fakePlayer("Alice"), "Sword", 2)
			expect(received).toEqual({ "Alice", "Sword", 2 })
			expect(server:GetStats().Buy.Accepted).toBe(1)
			server:Destroy()
		end)

		t.it("drops malformed and forged payloads before the handler runs", function()
			local rejections = {}
			local server = newServer({
				OnReject = function(_, endpoint, reason)
					table.insert(rejections, endpoint .. ":" .. reason)
				end,
			})
			local event = server:Event("Buy", {
				Schema = { Check.string(20), Check.integer(1, 99) },
				RateLimit = false,
			})
			local calls = 0
			event:Connect(function()
				calls += 1
			end)
			local player = fakePlayer()
			event:_receive(player, 123, 2) -- wrong type
			event:_receive(player, "Sword", 0 / 0) -- NaN
			event:_receive(player, "Sword", 1e9) -- out of range
			event:_receive(player, "Sword", 2, "extra") -- extra argument
			event:_receive(player, { Price = 0 }, 2) -- forged table
			event:_receive(player) -- missing arguments
			event:_receive(player, string.rep("x", 10000), 1) -- oversized
			expect(calls).toBe(0)
			local stats = server:GetStats().Buy
			expect(stats.Accepted).toBe(0)
			expect(stats.Rejected.InvalidArguments).toBe(6)
			expect(stats.Rejected.PayloadTooLarge).toBe(1)
			expect(#rejections).toBe(7)
			server:Destroy()
		end)

		t.it("rejects client fires on events without a Schema", function()
			local server = newServer()
			local event = server:Event("Announce")
			local calls = 0
			event:Connect(function()
				calls += 1
			end)
			event:_receive(fakePlayer(), "anything")
			expect(calls).toBe(0)
			expect(server:GetStats().Announce.Rejected.NotAccepted).toBe(1)
			server:Destroy()
		end)

		t.it("rate limits per player and resets when a player leaves and rejoins", function()
			local clock, advance = fakeClock()
			local server = newServer({ Clock = clock })
			local event = server:Event("Jump", { Schema = {}, RateLimit = { Count = 2, Per = 1 } })
			local player, other = fakePlayer("A"), fakePlayer("B")
			event:_receive(player)
			event:_receive(player)
			event:_receive(player)
			event:_receive(other)
			local stats = server:GetStats().Jump
			expect(stats.Accepted).toBe(3)
			expect(stats.Rejected.RateLimited).toBe(1)

			-- Leaving drops the bucket, so a rejoin starts fresh and nothing leaks.
			server:_forgetPlayer(player)
			event:_receive(player)
			expect(server:GetStats().Jump.Accepted).toBe(4)

			advance(1)
			event:_receive(player)
			expect(server:GetStats().Jump.Accepted).toBe(5)
			server:Destroy()
		end)

		t.it("applies the default rate limit when none is given", function()
			local server = newServer({
				Clock = function()
					return 0
				end,
			})
			local event = server:Event("Spam", { Schema = {} })
			local player = fakePlayer()
			for _ = 1, 50 do
				event:_receive(player)
			end
			local stats = server:GetStats().Spam
			expect(stats.Accepted).toBe(30)
			expect(stats.Rejected.RateLimited).toBe(20)
			server:Destroy()
		end)

		t.it("runs Authorize after validation and treats errors as rejections", function()
			local errors = {}
			local server = newServer({
				OnError = function(message)
					table.insert(errors, message)
				end,
			})
			local event = server:Event("Admin", {
				Schema = { Check.string() },
				Authorize = function(player, command)
					if command == "explode" then
						error("authorize bug")
					end
					return player.Name == "Owner"
				end,
			})
			local calls = 0
			event:Connect(function()
				calls += 1
			end)
			event:_receive(fakePlayer("Owner"), "kick")
			event:_receive(fakePlayer("Guest"), "kick")
			event:_receive(fakePlayer("Owner"), "explode")
			expect(calls).toBe(1)
			expect(server:GetStats().Admin.Rejected.Unauthorized).toBe(2)
			expect(#errors).toBe(1)
			server:Destroy()
		end)

		t.it("isolates handler errors and reports them", function()
			local errors = {}
			local server = newServer({
				OnError = function(message)
					table.insert(errors, message)
				end,
			})
			local event = server:Event("Crash", { Schema = {} })
			local secondRan = false
			event:Connect(function()
				error("handler bug")
			end)
			event:Connect(function()
				secondRan = true
			end)
			event:_receive(fakePlayer())
			expect(secondRan).toBe(true)
			expect(#errors).toBe(1)
			expect(string.find(errors[1], "handler bug", 1, true) ~= nil).toBe(true)
			server:Destroy()
		end)

		t.it("ignores requests after Destroy", function()
			local server = newServer()
			local event = server:Event("Late", { Schema = {} })
			local calls = 0
			event:Connect(function()
				calls += 1
			end)
			server:Destroy()
			event:_receive(fakePlayer())
			expect(calls).toBe(0)
		end)
	end)

	t.describe("Server functions", function()
		t.it("returns true and the handler results for valid calls", function()
			local server = newServer()
			local add = server:Function("Add", { Schema = { Check.number(), Check.number() } })
			add:SetHandler(function(_, a, b)
				return a + b, "ok"
			end)
			local ok, sum, note = add:_invoke(fakePlayer(), 2, 3)
			expect(ok).toBe(true)
			expect(sum).toBe(5)
			expect(note).toBe("ok")
			server:Destroy()
		end)

		t.it("returns generic codes and never leaks server errors", function()
			local server = newServer()
			local fn = server:Function("Risky", { Schema = { Check.integer() }, RateLimit = false })
			local a, b = fn:_invoke(fakePlayer(), 1)
			expect(a).toBe(false)
			expect(b).toBe("Unavailable")
			fn:SetHandler(function(_, value)
				if value == 13 then
					error("secret database path /srv/data")
				end
				return value
			end)
			local ok, code = fn:_invoke(fakePlayer(), "not a number")
			expect(ok).toBe(false)
			expect(code).toBe("Rejected")
			local ok2, code2, extra = fn:_invoke(fakePlayer(), 13)
			expect(ok2).toBe(false)
			expect(code2).toBe("ServerError")
			expect(extra).toBeNil()
			local stats = server:GetStats().Risky
			expect(stats.Rejected.HandlerError).toBe(1)
			expect(stats.Rejected.NoHandler).toBe(1)
			server:Destroy()
		end)

		t.it("reports RateLimited to the caller", function()
			local server = newServer({
				Clock = function()
					return 0
				end,
			})
			local fn = server:Function("Once", { Schema = {}, RateLimit = { Count = 1, Per = 60 } })
			fn:SetHandler(function()
				return true
			end)
			expect((fn:_invoke(fakePlayer()))).toBe(true)
			local ok, code = fn:_invoke(fakePlayer())
			expect(ok).toBe(true) -- a different stand-in player has its own bucket
			local player = fakePlayer()
			fn:_invoke(player)
			ok, code = fn:_invoke(player)
			expect(ok).toBe(false)
			expect(code).toBe("RateLimited")
			server:Destroy()
		end)

		t.it("allows only one handler", function()
			local server = newServer()
			local fn = server:Function("Single", { Schema = {} })
			fn:SetHandler(function() end)
			expect(function()
				fn:SetHandler(function() end)
			end).toThrow("already has a handler")
			server:Destroy()
		end)
	end)

	t.describe("review fixes", function()
		t.it("rejects requests whose validator throws, without throwing", function()
			local errors = {}
			local server = newServer({
				OnError = function(message)
					table.insert(errors, message)
				end,
			})
			local exploding = function()
				error("validator bug")
			end
			local event = server:Event("Fragile", { Schema = { exploding }, RateLimit = false })
			local refined = server:Event("Refined", {
				Schema = {
					Check.refine(Check.integer(), function()
						error("predicate bug")
					end),
				},
				RateLimit = false,
			})
			local fn = server:Function("FragileFn", { Schema = { exploding }, RateLimit = false })
			fn:SetHandler(function()
				return "should not run"
			end)
			local calls = 0
			event:Connect(function()
				calls += 1
			end)

			expect(function()
				event:_receive(fakePlayer(), 1)
				refined:_receive(fakePlayer(), 1)
			end).toNotThrow()
			local ok, code, leaked = fn:_invoke(fakePlayer(), 1)

			expect(calls).toBe(0)
			expect(ok).toBe(false)
			expect(code).toBe("Rejected")
			expect(leaked).toBeNil()
			local stats = server:GetStats()
			expect(stats.Fragile.Rejected.InvalidArguments).toBe(1)
			expect(stats.Refined.Rejected.InvalidArguments).toBe(1)
			expect(stats.FragileFn.Rejected.InvalidArguments).toBe(1)
			expect(#errors).toBe(3)
			server:Destroy()
		end)

		t.it("client Invoke times out and bounds calls that never return", function()
			local neverReturns = {
				InvokeServer = function()
					coroutine.yield() -- like a server that never answers
				end,
			}
			local fn = Network.Client._newFunction("Stuck", neverReturns, { Timeout = 0.05, MaxInFlight = 2 })
			local ok1, code1 = fn:Invoke()
			local ok2, code2 = fn:Invoke()
			expect(ok1).toBe(false)
			expect(code1).toBe("Timeout")
			expect(ok2).toBe(false)
			expect(code2).toBe("Timeout")
			expect(fn:GetInFlight()).toBe(2)
			-- The limit is reached: fail fast instead of piling up more threads.
			local started = os.clock()
			local ok3, code3 = fn:Invoke()
			expect(ok3).toBe(false)
			expect(code3).toBe("TooManyRequests")
			expect(os.clock() - started < 0.04).toBe(true)
		end)

		t.it("client Invoke returns results and releases its slot", function()
			local adds = {
				InvokeServer = function(_, a, b)
					task.wait()
					return true, a + b
				end,
			}
			local fn = Network.Client._newFunction("Add", adds, { Timeout = 2, MaxInFlight = 1 })
			local ok, sum = fn:Invoke(2, 3)
			expect(ok).toBe(true)
			expect(sum).toBe(5)
			expect(fn:GetInFlight()).toBe(0)
			expect((fn:Invoke(1, 1))).toBe(true)
			expect(function()
				Network.Client._newFunction("Bad", adds, { MaxInFlight = 0 })
			end).toThrow("MaxInFlight")
		end)
	end)
end
