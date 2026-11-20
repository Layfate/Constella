--!nonstrict
-- Lazy loading, enforced: each module is required from a copy of the
-- package that contains only the modules it is documented to depend on
-- (docs/Architecture.md, "Module dependencies"). A require of anything else
-- fails, because that module isn't in the copy.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function(t, _Constella)
	local expect = t.expect
	local package = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella")

	-- A copy of the package with only `keep` (module name -> true, or a
	-- list of the parts to keep inside a folder module).
	local function isolate(keep: { [string]: any }): Instance
		local copy = package:Clone()
		for _, child in copy:GetChildren() do
			local rule = keep[child.Name]
			if rule == nil then
				child:Destroy()
			elseif type(rule) == "table" then
				local parts = {}
				for _, name in rule do
					parts[name] = true
				end
				for _, part in child:GetChildren() do
					if not parts[part.Name] then
						part:Destroy()
					end
				end
			end
		end
		return copy
	end

	local function load(copy: Instance, name: string): any
		return (require :: any)(copy:FindFirstChild(name))
	end

	-- The table in docs/Architecture.md.
	local DEPENDENCIES = {
		Signal = {},
		Cleanup = {},
		Random = {},
		Pool = {},
		Debug = {},
		Promise = {},
		State = { "Signal" },
		Core = { "Signal", "Cleanup" },
		Zone = { "Signal", "Cleanup" },
		Component = { "Signal", "Cleanup" },
		Network = { "Signal" },
		Data = { "Signal", "Promise" },
		Replication = { "State", "Network", "Signal" },
	}

	t.describe("each module loads with only its documented dependencies", function()
		for name, dependencies in DEPENDENCIES do
			t.it(name, function()
				local keep = { [name] = true }
				for _, dependency in dependencies do
					keep[dependency] = true
				end
				local copy = isolate(keep)
				local module
				expect(function()
					module = load(copy, name)
				end).toNotThrow()
				expect(module).toBeTruthy()
				copy:Destroy()
			end)
		end
	end)

	t.describe("Network parts", function()
		local PARTS = {
			-- What each part may load from inside Network.
			Check = {},
			Contract = {},
			Payload = {},
			RateLimiter = {},
			Client = { "Contract" },
			Server = { "Check", "Contract", "Payload", "RateLimiter" },
		}
		for part, siblings in PARTS do
			t.it(
				("Network.%s loads only %s"):format(
					part,
					if #siblings == 0 then "itself" else table.concat(siblings, ", ")
				),
				function()
					local inside = { part }
					for _, sibling in siblings do
						table.insert(inside, sibling)
					end
					local copy = isolate({ Network = inside, Signal = true })
					local network = load(copy, "Network")
					local loaded
					expect(function()
						loaded = network[part]
					end).toNotThrow()
					expect(loaded).toBeTruthy()
					copy:Destroy()
				end
			)
		end

		t.it("a contract loads no validators: Contract works without Check", function()
			local copy = isolate({ Network = { "Contract" } })
			local Contract = load(copy, "Network").Contract
			local shop = Contract.define({ Namespace = "Shop", Ping = Contract.event() })
			expect(shop.Ping.Name).toBe("Ping")
			copy:Destroy()
		end)
	end)

	t.describe("Data parts", function()
		local PARTS = {
			MemoryAdapter = { inside = { "Util" }, outside = {} },
			ProfileStoreAdapter = { inside = { "Util" }, outside = {} },
			Store = { inside = { "Util" }, outside = { "Signal", "Promise" } },
		}
		for part, rule in PARTS do
			t.it(("Data.%s loads only what it needs"):format(part), function()
				local inside = table.clone(rule.inside)
				table.insert(inside, part)
				local keep: { [string]: any } = { Data = inside }
				for _, name in rule.outside do
					keep[name] = true
				end
				local copy = isolate(keep)
				local data = load(copy, "Data")
				local loaded
				expect(function()
					loaded = data[part]
				end).toNotThrow()
				expect(loaded).toBeTruthy()
				copy:Destroy()
			end)
		end

		t.it("Data never loads Network or Debug, even with Validate and CheckWrites", function()
			local copy = isolate({ Data = { "Store", "MemoryAdapter", "Util" }, Signal = true, Promise = true })
			local Data = load(copy, "Data")
			local store = Data.Store.new({
				Name = "Lazy",
				Template = { Coins = 0 },
				Adapter = Data.MemoryAdapter.new(),
				Validate = function(value)
					return type(value.Coins) == "number"
				end,
				CheckWrites = true,
				KickOnFailure = false,
				OnError = function() end,
			})
			local player = { Name = "Lazy", UserId = 1, Parent = true, Kick = function() end }
			local ok, profile = store:LoadAsync(player):Await()
			expect(ok).toBe(true)
			profile:Mutate(function(data)
				data.Coins += 1
			end)
			expect(profile.Data.Coins).toBe(1)
			store:Release(player)
			copy:Destroy()
		end)
	end)

	t.it("Replication's client side loads no Network server code", function()
		-- Requiring Replication on a client must not pull in Network.Server
		-- or its building blocks.
		local copy = isolate({ Replication = true, State = true, Signal = true, Network = { "Client", "Contract" } })
		expect(function()
			load(copy, "Replication")
		end).toNotThrow()
		copy:Destroy()
	end)
end
