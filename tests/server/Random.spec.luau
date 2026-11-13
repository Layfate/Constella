--!nonstrict
return function(t, Constella)
	local R = Constella.Random
	local expect = t.expect

	local RARITIES = {
		{ Value = "Common", Weight = 75 },
		{ Value = "Rare", Weight = 20 },
		{ Value = "Legendary", Weight = 5 },
	}

	-- An rng that always returns the given number, for exact boundary tests.
	local function fixed(value: number)
		return {
			NextNumber = function()
				return value
			end,
		}
	end

	t.describe("choose", function()
		t.it("maps the roll onto cumulative weight ranges", function()
			expect(R.choose(RARITIES, fixed(0))).toBe("Common")
			expect(R.choose(RARITIES, fixed(0.7499))).toBe("Common")
			expect(R.choose(RARITIES, fixed(0.75))).toBe("Rare")
			expect(R.choose(RARITIES, fixed(0.9499))).toBe("Rare")
			expect(R.choose(RARITIES, fixed(0.95))).toBe("Legendary")
			expect(R.choose(RARITIES, fixed(0.999999))).toBe("Legendary")
		end)

		t.it("never picks a zero-weight entry", function()
			local entries = {
				{ Value = "never", Weight = 0 },
				{ Value = "a", Weight = 1 },
				{ Value = "also never", Weight = 0 },
			}
			expect(R.choose(entries, fixed(0))).toBe("a")
			expect(R.choose(entries, fixed(0.999999))).toBe("a")
		end)

		t.it("is deterministic with a seeded Random", function()
			local first, second = Random.new(1234), Random.new(1234)
			for _ = 1, 50 do
				expect(R.choose(RARITIES, first)).toBe(R.choose(RARITIES, second))
			end
		end)

		t.it("matches the configured distribution over many rolls", function()
			local rng = Random.new(42)
			local counts = { Common = 0, Rare = 0, Legendary = 0 }
			local rolls = 20000
			for _ = 1, rolls do
				local value = R.choose(RARITIES, rng)
				counts[value] += 1
			end
			expect(counts.Common / rolls).toBeCloseTo(0.75, 0.02)
			expect(counts.Rare / rolls).toBeCloseTo(0.20, 0.02)
			expect(counts.Legendary / rolls).toBeCloseTo(0.05, 0.01)
		end)

		t.it("rejects invalid weights and entries", function()
			local function with(weight)
				return { { Value = "a", Weight = 1 }, { Value = "b", Weight = weight } }
			end
			expect(function()
				R.choose(with(-1))
			end).toThrow("must not be negative")
			expect(function()
				R.choose(with(0 / 0))
			end).toThrow("NaN")
			expect(function()
				R.choose(with(math.huge))
			end).toThrow("finite")
			expect(function()
				R.choose(with("10"))
			end).toThrow("must be a number")
			expect(function()
				R.choose({})
			end).toThrow("must not be empty")
			expect(function()
				R.choose({ { Value = "a", Weight = 0 } })
			end).toThrow("positive weight")
			expect(function()
				R.choose({ { Weight = 1 } })
			end).toThrow("has no Value")
		end)

		t.it("rejects an invalid rng", function()
			expect(function()
				R.choose(RARITIES, {})
			end).toThrow("rng must be")
			expect(function()
				R.choose(RARITIES, fixed(1))
			end).toThrow("[0, 1)")
		end)
	end)

	t.describe("modifiers", function()
		t.it("Luck = 0 keeps the base odds", function()
			local loot = R.lootTable(RARITIES)
			expect(loot:GetChance("Legendary", { Luck = 0 })).toBeCloseTo(0.05)
		end)

		t.it("Luck = 1 makes every possible entry equally likely", function()
			local loot = R.lootTable({
				{ Value = "a", Weight = 75 },
				{ Value = "b", Weight = 20 },
				{ Value = "c", Weight = 5 },
				{ Value = "never", Weight = 0 },
			})
			expect(loot:GetChance("a", { Luck = 1 })).toBeCloseTo(1 / 3)
			expect(loot:GetChance("c", { Luck = 1 })).toBeCloseTo(1 / 3)
			expect(loot:GetChance("never", { Luck = 1 })).toBe(0)
		end)

		t.it("Luck = 0.5 follows the documented formula", function()
			local loot = R.lootTable(RARITIES)
			local a, b, c = math.sqrt(75), math.sqrt(20), math.sqrt(5)
			expect(loot:GetChance("Legendary", { Luck = 0.5 })).toBeCloseTo(c / (a + b + c))
		end)

		t.it("Multipliers scale individual entries", function()
			local loot = R.lootTable(RARITIES)
			-- Legendary 5 * 3 = 15 out of 75 + 20 + 15 = 110
			expect(loot:GetChance("Legendary", { Multipliers = { Legendary = 3 } })).toBeCloseTo(15 / 110)
		end)

		t.it("rejects invalid modifiers", function()
			expect(function()
				R.choose(RARITIES, nil, { Luck = -1 })
			end).toThrow("must not be negative")
			expect(function()
				R.choose(RARITIES, nil, { Multipliers = { Rare = 0 / 0 } })
			end).toThrow("NaN")
			expect(function()
				R.choose(RARITIES, nil, { Multipliers = { Common = 0, Rare = 0, Legendary = 0 } })
			end).toThrow("no entry with a positive weight")
		end)
	end)

	t.describe("lootTable", function()
		t.it("rolls the same results as choose", function()
			local loot = R.lootTable(RARITIES)
			for _, roll in { 0, 0.5, 0.8, 0.97 } do
				expect(loot:Roll(fixed(roll))).toBe(R.choose(RARITIES, fixed(roll)))
			end
		end)

		t.it("reports chances that sum to 1", function()
			local loot = R.lootTable(RARITIES)
			local sum = 0
			for _, chance in loot:GetChances() do
				sum += chance.Chance
			end
			expect(sum).toBeCloseTo(1)
			expect(loot:GetChance("Rare")).toBeCloseTo(0.2)
		end)

		t.it("is not affected by later changes to the input table", function()
			local entries = table.clone(RARITIES)
			entries[1] = { Value = "Common", Weight = 75 }
			local loot = R.lootTable(entries)
			entries[1].Weight = 0
			expect(loot:GetChance("Common")).toBeCloseTo(0.75)
		end)

		t.it("RollMany returns count results and validates count", function()
			local loot = R.lootTable(RARITIES)
			expect(#loot:RollMany(10, Random.new(1))).toBe(10)
			expect(function()
				loot:RollMany(-1)
			end).toThrow("non-negative integer")
		end)
	end)

	t.describe("helpers", function()
		t.it("chance respects probability bounds", function()
			expect(R.chance(0, fixed(0))).toBe(false)
			expect(R.chance(1, fixed(0.999999))).toBe(true)
			expect(R.chance(0.25, fixed(0.24))).toBe(true)
			expect(R.chance(0.25, fixed(0.25))).toBe(false)
			expect(function()
				R.chance(1.5)
			end).toThrow("between 0 and 1")
		end)

		t.it("shuffle returns a deterministic permutation without mutating the input", function()
			local input = { 1, 2, 3, 4, 5, 6, 7, 8 }
			local a = R.shuffle(input, Random.new(7))
			local b = R.shuffle(input, Random.new(7))
			expect(a).toEqual(b)
			expect(input).toEqual({ 1, 2, 3, 4, 5, 6, 7, 8 })
			table.sort(a)
			expect(a).toEqual(input)
		end)

		t.it("chooseIndex picks from plain weights", function()
			expect(R.chooseIndex({ 0, 3, 1 }, fixed(0))).toBe(2)
			expect(R.chooseIndex({ 0, 3, 1 }, fixed(0.9))).toBe(3)
		end)
	end)

	t.describe("statistics", function()
		-- Pearson's chi-squared goodness-of-fit test. With a fixed seed the
		-- result is deterministic; the threshold is the 99.9th percentile of
		-- the chi-squared distribution, so a correct implementation passes
		-- and a biased one (e.g. an off-by-one in the cumulative search)
		-- fails by a wide margin.
		local function chiSquared(observed, expected)
			local sum = 0
			for key, expectedCount in expected do
				local difference = (observed[key] or 0) - expectedCount
				sum += difference * difference / expectedCount
			end
			return sum
		end

		t.it("matches the weights (chi-squared, 3 degrees of freedom)", function()
			local loot = R.lootTable({
				{ Value = "a", Weight = 50 },
				{ Value = "b", Weight = 30 },
				{ Value = "c", Weight = 15 },
				{ Value = "d", Weight = 5 },
			})
			local rolls = 50000
			local observed = {}
			for _, value in loot:RollMany(rolls, Random.new(20261113)) do
				observed[value] = (observed[value] or 0) + 1
			end
			local expected = { a = rolls * 0.5, b = rolls * 0.3, c = rolls * 0.15, d = rolls * 0.05 }
			expect(chiSquared(observed, expected)).toBeLessThan(16.27) -- p = 0.001, df = 3
		end)

		t.it("matches the Luck formula (chi-squared, 2 degrees of freedom)", function()
			local loot = R.lootTable({
				{ Value = "common", Weight = 75 },
				{ Value = "rare", Weight = 20 },
				{ Value = "legendary", Weight = 5 },
			})
			local rolls = 50000
			local observed = {}
			for _, value in loot:RollMany(rolls, Random.new(7), { Luck = 0.5 }) do
				observed[value] = (observed[value] or 0) + 1
			end
			local expected = {}
			for _, chance in loot:GetChances({ Luck = 0.5 }) do
				expected[chance.Value] = rolls * chance.Chance
			end
			expect(chiSquared(observed, expected)).toBeLessThan(13.82) -- p = 0.001, df = 2
		end)

		t.it("shuffle places every item in every position equally often", function()
			local rng = Random.new(99)
			local counts = {}
			local shuffles = 24000
			for _ = 1, shuffles do
				local result = R.shuffle({ 1, 2, 3, 4 }, rng)
				local key = result[1] .. ":1"
				counts[key] = (counts[key] or 0) + 1
			end
			local expected = {}
			for item = 1, 4 do
				expected[item .. ":1"] = shuffles / 4
			end
			expect(chiSquared(counts, expected)).toBeLessThan(16.27) -- p = 0.001, df = 3
		end)
	end)
end
