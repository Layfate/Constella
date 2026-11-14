--!strict
--[=[
	Constella.Random

	Weighted selection, loot tables and chance helpers.

	Every function takes an optional `rng`: a Roblox `Random` object (for
	example `Random.new(1234)` for deterministic, seeded results) or any
	table with a `NextNumber()` method that returns a number in [0, 1).
	Without one, a module-private `Random.new()` is used.

	Weights
	- Must be finite numbers >= 0. NaN, negatives, infinities and non-numbers
	  are rejected with an error naming the entry.
	- Entries with weight 0 are never chosen.
	- At least one entry must have a positive weight.
	- P(entry i) = w_i / sum(w).

	Modifiers (all optional)
	- Luck = L (finite, >= 0). Each positive weight becomes
	  (w_i / w_max) ^ (1 - L). L = 0 keeps the base odds, L = 1 makes every
	  possible entry equally likely, L > 1 makes rarer entries MORE likely
	  than common ones. Dividing by w_max does not change the odds (it
	  cancels out on normalisation); it only avoids overflow.
	- Multipliers = { [value] = m } (finite, >= 0). Applied after luck:
	  w_i' = luckWeight_i * (Multipliers[Value_i] or 1).
	Modifiers never turn a 0 weight into a positive one.

	Server authority: roll rewards on the server. Never accept a roll, luck
	value or multiplier from a client.
]=]

export type Entry<T> = {
	Value: T,
	Weight: number,
}

export type Modifiers = {
	Luck: number?,
	Multipliers: { [any]: number }?,
}

export type Chance<T> = {
	Value: T,
	Chance: number,
}

export type LootTable<T> = {
	Roll: (self: LootTable<T>, rng: any?, modifiers: Modifiers?) -> T,
	RollMany: (self: LootTable<T>, count: number, rng: any?, modifiers: Modifiers?) -> { T },
	GetChance: (self: LootTable<T>, value: T, modifiers: Modifiers?) -> number,
	GetChances: (self: LootTable<T>, modifiers: Modifiers?) -> { Chance<T> },
	GetEntries: (self: LootTable<T>) -> { Entry<T> },
}

local PREFIX = "[Constella.Random] "

local defaultRng = Random.new()

local function resolveRng(rng: any, level: number): any
	if rng == nil then
		return defaultRng
	end
	if typeof(rng) == "Random" then
		return rng
	end
	if type(rng) == "table" and type(rng.NextNumber) == "function" then
		return rng
	end
	error(PREFIX .. ("rng must be a Random object or a table with NextNumber, got %s"):format(typeof(rng)), level)
end

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function checkNumber(value: any, label: string, level: number)
	if type(value) ~= "number" then
		error(PREFIX .. ("%s must be a number, got %s"):format(label, typeof(value)), level)
	end
	if value ~= value then
		error(PREFIX .. ("%s is NaN"):format(label), level)
	end
	if not isFinite(value) then
		error(PREFIX .. ("%s must be finite"):format(label), level)
	end
	if value < 0 then
		error(PREFIX .. ("%s must not be negative (got %s)"):format(label, tostring(value)), level)
	end
end

local function validateEntries(entries: any, level: number): ({ any }, { number })
	if type(entries) ~= "table" then
		error(PREFIX .. ("entries must be an array, got %s"):format(typeof(entries)), level)
	end
	local count = #entries
	if count == 0 then
		error(PREFIX .. "entries must not be empty", level)
	end
	local values = table.create(count)
	local weights = table.create(count)
	local total = 0
	for index = 1, count do
		local entry = entries[index]
		if type(entry) ~= "table" then
			error(PREFIX .. ("entry #%d must be a table { Value = ..., Weight = number }"):format(index), level)
		end
		if entry.Value == nil then
			error(
				PREFIX
					.. ('entry #%d has no Value (use a sentinel such as false or "Nothing" for empty drops)'):format(
						index
					),
				level
			)
		end
		checkNumber(entry.Weight, ("entry #%d Weight"):format(index), level + 1)
		values[index] = entry.Value
		weights[index] = entry.Weight
		total += entry.Weight
	end
	if not (total > 0) then
		error(PREFIX .. "at least one entry must have a positive weight", level)
	end
	if not isFinite(total) then
		error(PREFIX .. "the sum of all weights must be finite", level)
	end
	return values, weights
end

local function applyModifiers(values: { any }, weights: { number }, modifiers: any, level: number): { number }
	if modifiers == nil then
		return weights
	end
	if type(modifiers) ~= "table" then
		error(PREFIX .. ("modifiers must be a table, got %s"):format(typeof(modifiers)), level)
	end

	local result = table.clone(weights)

	local luck = modifiers.Luck
	if luck ~= nil then
		checkNumber(luck, "Luck", level + 1)
		if luck ~= 0 then
			local maxWeight = 0
			for _, weight in result do
				maxWeight = math.max(maxWeight, weight)
			end
			local exponent = 1 - luck
			for index, weight in result do
				if weight > 0 then
					result[index] = (weight / maxWeight) ^ exponent
				end
			end
		end
	end

	local multipliers = modifiers.Multipliers
	if multipliers ~= nil then
		if type(multipliers) ~= "table" then
			error(PREFIX .. "Multipliers must be a table { [value] = number }", level)
		end
		for value, multiplier in multipliers do
			checkNumber(multiplier, ("Multipliers[%s]"):format(tostring(value)), level + 1)
		end
		for index, value in values do
			local multiplier = multipliers[value]
			if multiplier ~= nil then
				result[index] *= multiplier
			end
		end
	end

	local total = 0
	for _, weight in result do
		if not isFinite(weight) then
			error(PREFIX .. "modifiers produced a non-finite weight; reduce Luck or the multipliers", level)
		end
		total += weight
	end
	if not (total > 0) then
		error(PREFIX .. "modifiers left no entry with a positive weight", level)
	end
	return result
end

type Cumulative = { sums: { number }, total: number, lastPositive: number }

local function buildCumulative(weights: { number }): Cumulative
	local sums = table.create(#weights)
	local total = 0
	local lastPositive = 0
	for index, weight in weights do
		total += weight
		sums[index] = total
		if weight > 0 then
			lastPositive = index
		end
	end
	return { sums = sums, total = total, lastPositive = lastPositive }
end

local function pick(cumulative: Cumulative, rng: any): number
	local roll = rng:NextNumber()
	if type(roll) ~= "number" or not (roll >= 0 and roll < 1) then
		error(PREFIX .. ("rng:NextNumber() must return a number in [0, 1), got %s"):format(tostring(roll)), 0)
	end
	local target = roll * cumulative.total
	local sums = cumulative.sums
	-- Smallest index whose running sum is strictly greater than target.
	-- Zero-weight entries share their predecessor's sum, so they are skipped.
	local low, high = 1, #sums
	while low < high do
		local middle = (low + high) // 2
		if sums[middle] > target then
			high = middle
		else
			low = middle + 1
		end
	end
	if sums[low] <= target then
		-- Only reachable through floating point rounding at the very top.
		return cumulative.lastPositive
	end
	return low
end

local function checkCount(count: any, level: number)
	if type(count) ~= "number" or count ~= count or count < 0 or count % 1 ~= 0 or count == math.huge then
		error(PREFIX .. ("count must be a non-negative integer, got %s"):format(tostring(count)), level)
	end
end

local LootTableClass = {}
LootTableClass.__index = LootTableClass

local function cumulativeFor(self: any, modifiers: any, level: number): Cumulative
	if modifiers == nil then
		return self._cumulative
	end
	return buildCumulative(applyModifiers(self._values, self._weights, modifiers, level + 1))
end

function LootTableClass.Roll(self: any, rng: any?, modifiers: Modifiers?): any
	local source = resolveRng(rng, 3)
	local cumulative = cumulativeFor(self, modifiers, 3)
	return self._values[pick(cumulative, source)]
end

function LootTableClass.RollMany(self: any, count: number, rng: any?, modifiers: Modifiers?): { any }
	checkCount(count, 3)
	local source = resolveRng(rng, 3)
	local cumulative = cumulativeFor(self, modifiers, 3)
	local results = table.create(count)
	for index = 1, count do
		results[index] = self._values[pick(cumulative, source)]
	end
	return results
end

function LootTableClass.GetChance(self: any, value: any, modifiers: Modifiers?): number
	local cumulative = cumulativeFor(self, modifiers, 3)
	local weights = if modifiers == nil then self._weights else nil
	local sum = 0
	local previous = 0
	for index, candidate in self._values do
		local weight = if weights then weights[index] else cumulative.sums[index] - previous
		previous = cumulative.sums[index]
		if candidate == value then
			sum += weight
		end
	end
	return sum / cumulative.total
end

function LootTableClass.GetChances(self: any, modifiers: Modifiers?): { Chance<any> }
	local cumulative = cumulativeFor(self, modifiers, 3)
	local chances = table.create(#self._values)
	local previous = 0
	for index, value in self._values do
		local sum = cumulative.sums[index]
		table.insert(chances, { Value = value, Chance = (sum - previous) / cumulative.total })
		previous = sum
	end
	return chances
end

function LootTableClass.GetEntries(self: any): { Entry<any> }
	local entries = table.create(#self._values)
	for index, value in self._values do
		entries[index] = { Value = value, Weight = self._weights[index] }
	end
	return entries
end

local RandomLib = {}

--- Picks one entry's Value according to its Weight.
function RandomLib.choose<T>(entries: { Entry<T> }, rng: any?, modifiers: Modifiers?): T
	local values, weights = validateEntries(entries, 3)
	local source = resolveRng(rng, 3)
	local cumulative = buildCumulative(applyModifiers(values, weights, modifiers, 3))
	return values[pick(cumulative, source)]
end

--- Picks an index from a plain array of weights.
function RandomLib.chooseIndex(weights: { number }, rng: any?): number
	if type(weights) ~= "table" then
		error(PREFIX .. ("weights must be an array, got %s"):format(typeof(weights)), 2)
	end
	local entries = table.create(#weights)
	for index, weight in weights do
		entries[index] = { Value = index, Weight = weight }
	end
	local values, validated = validateEntries(entries, 3)
	return values[pick(buildCumulative(validated), resolveRng(rng, 3))]
end

--- Returns true with the given probability (0..1).
function RandomLib.chance(probability: number, rng: any?): boolean
	checkNumber(probability, "probability", 3)
	if probability > 1 then
		error(PREFIX .. ("probability must be between 0 and 1, got %s"):format(tostring(probability)), 2)
	end
	return resolveRng(rng, 3):NextNumber() < probability
end

--- Returns a shuffled copy of `array` (Fisher-Yates). The input is not modified.
function RandomLib.shuffle<T>(array: { T }, rng: any?): { T }
	if type(array) ~= "table" then
		error(PREFIX .. ("shuffle expects an array, got %s"):format(typeof(array)), 2)
	end
	local source = resolveRng(rng, 3)
	local result = table.clone(array)
	for index = #result, 2, -1 do
		local swap = math.floor(source:NextNumber() * index) + 1
		result[index], result[swap] = result[swap], result[index]
	end
	return result
end

--- Creates a validated, immutable loot table. Rolls without modifiers are O(log n).
function RandomLib.lootTable<T>(entries: { Entry<T> }): LootTable<T>
	local values, weights = validateEntries(entries, 3)
	local self = setmetatable({
		_values = values,
		_weights = weights,
		_cumulative = buildCumulative(weights),
	}, LootTableClass)
	return (self :: any) :: LootTable<T>
end

return table.freeze(RandomLib)
