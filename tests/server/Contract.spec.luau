--!nonstrict
-- Network contracts (Network.Contract, Server:EventOf/FunctionOf,
-- Client:EventOf/FunctionOf) and the 0.4.0 Network fixes. Requests go
-- through the same internal entry points as Network.spec, with stand-in
-- players; contract endpoints must behave exactly like plain ones.
return function(t, Constella)
	local Network = Constella.Network
	local Contract = Network.Contract
	local Check = Network.Check
	local expect = t.expect

	local function newServer(namespace, options)
		local opts = options or {}
		opts.Parent = opts.Parent or Instance.new("Folder")
		opts.OnError = opts.OnError or function() end
		return Network.Server.new(namespace or "Shop", opts), opts.Parent
	end

	local function shopContract()
		return Contract.define({
			Namespace = "Shop",
			Purchase = Contract.fn({ Check.string(20), Check.integer(1, 99) }),
			Announce = Contract.event(),
			Buy = Contract.event({ Check.string(20) }),
		})
	end

	t.describe("Contract.define", function()
		t.it("names endpoints after their keys and freezes everything", function()
			local shop = shopContract()
			expect(shop.Purchase.Name).toBe("Purchase")
			expect(shop.Purchase.Namespace).toBe("Shop")
			expect(shop.Purchase.Kind).toBe("Function")
			expect(shop.Announce.Kind).toBe("Event")
			expect(shop.Announce.Schema).toBeNil()
			expect(table.isfrozen(shop)).toBe(true)
			expect(table.isfrozen(shop.Purchase)).toBe(true)
			expect(table.isfrozen(shop.Purchase.Schema)).toBe(true)
			expect(Contract.is(shop.Purchase)).toBe(true)
			expect(Contract.is(shop.Purchase, "Function")).toBe(true)
			expect(Contract.is(shop.Purchase, "Event")).toBe(false)
		end)

		t.it("copies the Schema, so changing the caller's array changes nothing", function()
			local schema = { Check.integer(1, 5) }
			local shop = Contract.define({ Namespace = "Shop", Pick = Contract.event(schema) })
			schema[1] = Check.any()
			local server = newServer()
			local event = server:EventOf(shop.Pick)
			local received = 0
			event:Connect(function()
				received += 1
			end)
			event:_receive(t.fakePlayer(), 99)
			expect(received).toBe(0)
			expect(server:GetStats().Pick.Rejected.InvalidArguments).toBe(1)
		end)

		t.it("rejects bad contracts", function()
			expect(function()
				Contract.define({ Purchase = Contract.event() })
			end).toThrow("Namespace")
			expect(function()
				Contract.define({ Namespace = "bad name", Purchase = Contract.event() })
			end).toThrow("Namespace")
			expect(function()
				Contract.define({ Namespace = "Shop", ["bad-name"] = Contract.event() })
			end).toThrow("Endpoint name")
			expect(function()
				Contract.define({ Namespace = "Shop", Fake = { Kind = "Event", Schema = {} } })
			end).toThrow("Contract.event or Contract.fn")
			expect(function()
				Contract.fn(nil :: any)
			end).toThrow("needs a Schema")
			expect(function()
				Contract.event({ "not a validator" } :: any)
			end).toThrow("array of validators")
			expect(function()
				Contract.event({ [2] = Check.any() } :: any)
			end).toThrow("array of validators")
		end)

		t.it("refuses an endpoint used in two contracts", function()
			local shared = Contract.event()
			Contract.define({ Namespace = "A", Ping = shared })
			expect(function()
				Contract.define({ Namespace = "B", Ping = shared })
			end).toThrow("already")
		end)

		t.it("a hand-made table never passes as an endpoint", function()
			local server = newServer()
			local fake = { Kind = "Event", Name = "Buy", Namespace = "Shop", Schema = {} }
			expect(function()
				server:EventOf(fake)
			end).toThrow("Contract.event")
			expect(Contract.is(fake)).toBe(false)
		end)
	end)

	t.describe("Server:EventOf / FunctionOf", function()
		t.it("creates the same remotes as Event and Function", function()
			local shop = shopContract()
			local server, parent = newServer()
			server:FunctionOf(shop.Purchase)
			server:EventOf(shop.Announce)
			server:EventOf(shop.Buy, { Unreliable = true })
			local folder = parent:FindFirstChild("Shop")
			expect(folder:FindFirstChild("Purchase").ClassName).toBe("RemoteFunction")
			expect(folder:FindFirstChild("Announce").ClassName).toBe("RemoteEvent")
			expect(folder:FindFirstChild("Buy").ClassName).toBe("UnreliableRemoteEvent")
			server:Destroy()
		end)

		t.it("runs every gate in order, with the contract's Schema", function()
			local shop = shopContract()
			local now = 0
			local rejections = {}
			local server = newServer("Shop", {
				Clock = function()
					return now
				end,
				OnReject = function(_, endpoint, reason)
					table.insert(rejections, endpoint .. ":" .. reason)
				end,
			})
			local buy = server:EventOf(shop.Buy, {
				RateLimit = { Count = 3, Per = 1 },
				MaxPayloadBytes = 64,
				Authorize = function(_, itemId)
					return itemId ~= "Forbidden"
				end,
			})
			local accepted = {}
			buy:Connect(function(_, itemId)
				table.insert(accepted, itemId)
			end)
			local player = t.fakePlayer()
			buy:_receive(player, "Sword") -- accepted
			buy:_receive(player, 5) -- InvalidArguments (Schema from the contract)
			buy:_receive(player, "Forbidden") -- Unauthorized
			buy:_receive(player, "Shield") -- RateLimited (4th in the same second)
			now = 10
			buy:_receive(player, string.rep("x", 100)) -- PayloadTooLarge before the Schema
			buy:_receive(player, "Sword", "extra") -- InvalidArguments (extra argument)
			expect(accepted).toEqual({ "Sword" })
			expect(rejections).toEqual({
				"Buy:InvalidArguments",
				"Buy:Unauthorized",
				"Buy:RateLimited",
				"Buy:PayloadTooLarge",
				"Buy:InvalidArguments",
			})
		end)

		t.it("an event without a Schema rejects client fires", function()
			local shop = shopContract()
			local server = newServer()
			local announce = server:EventOf(shop.Announce)
			local received = 0
			announce:Connect(function()
				received += 1
			end)
			announce:_receive(t.fakePlayer(), "hello")
			expect(received).toBe(0)
			expect(server:GetStats().Announce.Rejected.NotAccepted).toBe(1)
		end)

		t.it("answers functions through the contract's Schema", function()
			local shop = shopContract()
			local server = newServer()
			local purchase = server:FunctionOf(shop.Purchase)
			purchase:SetHandler(function(_, itemId, amount)
				return itemId, amount * 2
			end)
			local player = t.fakePlayer()
			local ok, item, total = purchase:_invoke(player, "Sword", 3)
			expect(ok).toBe(true)
			expect(item).toBe("Sword")
			expect(total).toBe(6)
			local rejected, code = purchase:_invoke(player, "Sword", 0)
			expect(rejected).toBe(false)
			expect(code).toBe("Rejected")
		end)

		t.it("refuses a Schema in the config, a foreign namespace and the wrong kind", function()
			local shop = shopContract()
			local server = newServer()
			expect(function()
				server:EventOf(shop.Buy, { Schema = { Check.any() } })
			end).toThrow("takes its Schema from the contract")
			expect(function()
				server:EventOf(shop.Purchase)
			end).toThrow("EventOf expects")
			expect(function()
				server:FunctionOf(shop.Buy)
			end).toThrow("FunctionOf expects")
			local other = newServer("Other")
			expect(function()
				other:EventOf(shop.Buy)
			end).toThrow("belongs to namespace 'Shop'")
			expect(function()
				server:EventOf(shop.Buy, "fast" :: any)
			end).toThrow("config must be a table")
		end)

		t.it("doesn't change the caller's config table", function()
			local shop = shopContract()
			local server = newServer()
			local config = { RateLimit = false }
			server:EventOf(shop.Buy, config)
			expect((config :: any).Schema).toBeNil()
		end)

		t.it("refuses the same endpoint twice, like Event does", function()
			local shop = shopContract()
			local server = newServer()
			server:EventOf(shop.Buy)
			expect(function()
				server:EventOf(shop.Buy)
			end).toThrow("already exists")
			expect(function()
				server:Event("Buy")
			end).toThrow("already exists")
		end)

		t.it("errors point at the caller", function()
			local shop = shopContract()
			local server = newServer()
			local ok, message = pcall(function()
				server:EventOf(shop.Purchase) -- this line
			end)
			expect(ok).toBe(false)
			expect(string.find(tostring(message), "Contract.spec", 1, true) ~= nil).toBe(true)
		end)

		t.it("destroyed contract endpoints keep nothing alive", function()
			local shop = shopContract()
			local server = newServer()
			local alive = t.leaked(function()
				local objects = {}
				for _ = 1, 50 do
					local event = server:EventOf(shop.Buy)
					local purchase = server:FunctionOf(shop.Purchase)
					purchase:SetHandler(function() end)
					table.insert(objects, event)
					table.insert(objects, purchase)
					event:Destroy()
					purchase:Destroy()
				end
				return objects
			end)
			expect(alive).toBe(0)
			expect(next(server._endpoints)).toBeNil()
		end)
	end)

	t.describe("Client:EventOf / FunctionOf", function()
		-- The suite also runs on a live server, where Client.new refuses to
		-- run, so the client is built over the server's folder directly.
		local function pair()
			local shop = shopContract()
			local server, parent = newServer()
			server:FunctionOf(shop.Purchase)
			server:EventOf(shop.Buy)
			local client = Network.Client._newClient("Shop", parent:FindFirstChild("Shop"), 1)
			return shop, server, client
		end

		t.it("finds the remotes the contract names", function()
			local shop, _, client = pair()
			local buy = client:EventOf(shop.Buy)
			local purchase = client:FunctionOf(shop.Purchase, { Timeout = 2, MaxInFlight = 3 })
			expect(buy.Name).toBe("Buy")
			expect(purchase.Name).toBe("Purchase")
			expect(purchase:GetInFlight()).toBe(0)
		end)

		t.it("refuses the wrong kind, a foreign namespace and hand-made tables", function()
			local shop, _, client = pair()
			expect(function()
				client:EventOf(shop.Purchase)
			end).toThrow("EventOf expects")
			expect(function()
				client:FunctionOf(shop.Buy)
			end).toThrow("FunctionOf expects")
			local other = Contract.define({ Namespace = "Other", Buy = Contract.event() })
			expect(function()
				client:EventOf(other.Buy)
			end).toThrow("belongs to namespace 'Other'")
			expect(function()
				client:EventOf({ Kind = "Event", Name = "Buy", Namespace = "Shop" })
			end).toThrow("Contract.event")
		end)
	end)

	t.describe("client events (0.4.0 fixes)", function()
		-- A server can't connect to a real RemoteEvent's OnClientEvent, so the
		-- events use a BindableEvent in its place: its connections are real
		-- RBXScriptConnections.
		local function setup()
			return Network.Client._newClient("Events", Instance.new("Folder"), 1)
		end
		local function eventOf(client)
			-- The stand-in keeps the Instance itself: a BindableEvent that is
			-- only reachable through its Event signal can be collected, and
			-- that disconnects everything connected to it.
			local bindable = Instance.new("BindableEvent")
			return Network.Client._newEvent(client, "Ping", { OnClientEvent = bindable.Event, Instance = bindable })
		end

		t.it("an event that was looked up and destroyed isn't kept by the client", function()
			local client = setup()
			local alive = t.leaked(function()
				local events = {}
				for _ = 1, 200 do
					local event = eventOf(client)
					event:Connect(function() end)
					event:Destroy()
					table.insert(events, event)
				end
				return events
			end)
			expect(alive).toBe(0)
			expect(next(client._events)).toBeNil()
		end)

		t.it("an event that was never connected isn't kept either", function()
			-- Through the real lookup, which used to keep every event.
			local server, parent = newServer("Lookups")
			server:Event("Ping")
			local client = Network.Client._newClient("Lookups", parent:FindFirstChild("Lookups"), 1)
			local alive = t.leaked(function()
				local events = {}
				for _ = 1, 200 do
					table.insert(events, client:Event("Ping"))
				end
				return events
			end)
			expect(alive).toBe(0)
			expect(next(client._events)).toBeNil()
		end)

		t.it("drops connections the game disconnected itself", function()
			local client = setup()
			local event = eventOf(client)
			for _ = 1, 2000 do
				event:Connect(function() end):Disconnect()
			end
			expect(#event._connections < 32).toBe(true)
		end)

		t.it("keeps live connections while pruning, and client:Destroy still disconnects them", function()
			local client = setup()
			local event = eventOf(client)
			local live = {}
			for index = 1, 100 do
				local connection = event:Connect(function() end)
				if index % 10 == 0 then
					table.insert(live, connection)
				else
					connection:Disconnect()
				end
			end
			for _, connection in live do
				expect(connection.Connected).toBe(true)
			end
			client:Destroy()
			for _, connection in live do
				expect(connection.Connected).toBe(false)
			end
		end)

		t.it("an event connected again after Destroy is still covered by client:Destroy", function()
			local client = setup()
			local event = eventOf(client)
			event:Destroy()
			local connection = event:Connect(function() end)
			client:Destroy()
			expect(connection.Connected).toBe(false)
		end)
	end)

	t.describe("RateLimiter.GetTokens (0.4.0 fix)", function()
		t.it("reports the capacity of an unknown key without storing it", function()
			local limiter = Network.RateLimiter.new({ Count = 5, Per = 1 })
			for index = 1, 1000 do
				expect(limiter:GetTokens({ index })).toBe(5)
			end
			expect(next(limiter._buckets)).toBeNil()
		end)

		t.it("still refills a key that has consumed", function()
			local now = 0
			local limiter = Network.RateLimiter.new({ Count = 4, Per = 1 }, function()
				return now
			end)
			local key = {}
			expect(limiter:Consume(key)).toBe(true)
			expect(limiter:GetTokens(key)).toBe(3)
			now = 0.5
			expect(limiter:GetTokens(key)).toBe(4)
		end)
	end)
end
