# Random

```lua
local R = require(Packages.Constella.Random)

local chest = R.lootTable({
	{ Value = "Wood Sword", Weight = 60 },
	{ Value = "Star Blade", Weight = 9 },
})
local item = chest:Roll()                   -- uses a private Random.new()
local seeded = chest:Roll(Random.new(1234)) -- deterministic
local lucky = chest:Roll(nil, { Luck = 0.5 })
```

Roll rewards **on the server**. Never accept a roll result, luck value or multiplier from a client.

## The math

- Weights must be finite numbers ≥ 0. NaN, negatives, infinities and non-numbers raise an error that names the entry. At least one weight has to be positive, and every entry needs a non-nil `Value` (use a sentinel like `false` or `"Nothing"` for empty drops).
- **P(i) = wᵢ / Σw.** Entries with weight 0 are never chosen.
- A roll is `r = rng:NextNumber() × Σw`. The result is the first entry whose running total is greater than `r`.
- **Luck L** (finite, ≥ 0): each positive weight becomes `(wᵢ / w_max)^(1 − L)`.
  - `L = 0` keeps the base odds.
  - `L = 0.5` uses square-root weights. For 75/20/5, Legendary goes from 5% to about 14.5%.
  - `L = 1` makes every possible entry equally likely.
  - `L > 1` makes rarer entries more likely than common ones.
  - Dividing by `w_max` doesn't change the odds (it cancels out). It only prevents overflow.
- **Multipliers** `{ [value] = m }` (finite, ≥ 0) apply after luck: `wᵢ' = luckWeightᵢ × m`.
- Modifiers never make a 0-weight entry possible. If modifiers leave no positive weight, that's an error.

## RNG

Every function takes an optional `rng`. It can be a Roblox `Random` object, or any table whose `NextNumber()` returns a number in [0, 1). Values outside that range raise an error. Tests use a fixed-value table so boundaries can be checked exactly.

## API

| Member | Description |
| --- | --- |
| `R.choose(entries, rng?, modifiers?)` | Returns a `Value`. O(n) |
| `R.chooseIndex(weights, rng?)` | Returns an index into a plain array of weights |
| `R.lootTable(entries)` | A validated, immutable table. Rolls without modifiers are O(log n) |
| `loot:Roll(rng?, modifiers?)` | |
| `loot:RollMany(count, rng?, modifiers?)` | |
| `loot:GetChance(value, modifiers?)` | Probability in [0, 1]. Sums entries that share a value |
| `loot:GetChances(modifiers?)` | `{ { Value, Chance } }` in entry order |
| `loot:GetEntries()` | A copy of the validated entries |
| `R.chance(p, rng?)` | `true` with probability `p` (0..1) |
| `R.shuffle(array, rng?)` | Shuffled copy (Fisher–Yates). The input isn't modified |
