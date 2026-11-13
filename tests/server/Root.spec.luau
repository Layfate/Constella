--!nonstrict
-- Cross-module behaviour and the root entry point.
return function(t, Constella)
	local expect = t.expect

	t.it("exposes the version and author", function()
		expect(Constella.Version).toBe("0.1.0")
		expect(Constella.Author).toBe("Zense")
	end)

	t.it("loads every module", function()
		for _, name in {
			"Core",
			"Signal",
			"Cleanup",
			"State",
			"Random",
			"Network",
			"Component",
			"Pool",
			"Zone",
			"Debug",
			"Promise",
			"Data",
			"Replication",
		} do
			expect(type(Constella[name])).toBe("table")
		end
	end)

	t.it("exposes App as an alias of Core.App", function()
		expect(Constella.App).toBe(Constella.Core.App)
	end)

	t.it("raises for unknown modules and is read-only", function()
		expect(function()
			return Constella.Nope
		end).toThrow("not a Constella module")
		expect(function()
			Constella.Signal = {}
		end).toThrow("read-only")
	end)

	t.it("runs the README quick-start example", function()
		local cleanup = Constella.Cleanup.new()
		local state = Constella.State.new(0)
		local seen = {}
		cleanup:Add(state:Subscribe(function(newValue)
			table.insert(seen, newValue)
		end))
		state:Set(10)
		local rarity = Constella.Random.choose({
			{ Value = "Common", Weight = 75 },
			{ Value = "Rare", Weight = 20 },
			{ Value = "Legendary", Weight = 5 },
		}, Random.new(1234))
		cleanup:Destroy()
		expect(seen).toEqual({ 10 })
		expect(rarity == "Common" or rarity == "Rare" or rarity == "Legendary").toBe(true)
	end)

	t.it("ties a service's state and subscriptions to the app lifecycle", function()
		local app = Constella.App.new({ Environment = "Server" })
		local score = Constella.State.new(0)
		local seen = {}
		app:Add({
			Name = "ScoreService",
			Start = function(_, context)
				context.Cleanup:Add(score:Subscribe(function(value)
					table.insert(seen, value)
				end))
			end,
		})
		app:Start()
		score:Set(1)
		app:Stop()
		score:Set(2)
		expect(seen).toEqual({ 1 })
	end)
end
