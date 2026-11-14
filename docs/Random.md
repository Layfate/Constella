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

## Server-authoritative rewards

The client only says *what* it wants to open. The price, the odds, the roll and the reward all stay on the server, and the client gets the result to display:

```lua
-- Server (inside a service)
local Network = Constella.Network
local Check = Network.Check
local R = Constella.Random

local CHESTS = {
	Basic = {
		Price = 100,
		Loot = R.lootTable({
			{ Value = "Wood Sword", Weight = 60 },
			{ Value = "Star Blade", Weight = 9 },
		}),
	},
}

local server = context.Cleanup:Add(Network.Server.new("Chests"))
local open = server:Function("Open", {
	Schema = { Check.literal("Basic") }, -- only chests that exist
	RateLimit = { Count = 2, Per = 1 },
})

open:SetHandler(function(player, chestId)
	local profile = store:Get(player) -- a Data profile; nil until loaded
	if profile == nil then
		return "NotReady"
	end
	local chest = CHESTS[chestId]
	if profile:Get("Coins") < chest.Price then
		return "NotEnoughCoins"
	end
	-- Pay and roll in the same handler call, before anything yields,
	-- so two quick requests can't both pass the price check.
	profile:Update("Coins", function(coins)
		return coins - chest.Price
	end)
	local item = chest.Loot:Roll()
	profile:Update("Inventory", function(inventory)
		local updated = table.clone(inventory)
		table.insert(updated, item)
		return updated
	end)
	return "Opened", item
end)
```

```lua
-- Client: only shows what the server decided
local ok, status, item = chests:Function("Open", { Timeout = 5 }):Invoke("Basic")
```

- **Validate the request, not the result.** `Check.literal` rejects unknown chest ids before the handler runs, and the rate limit stops spamming.
- **Check and pay before anything yields.** Handlers run on their own threads, so a check that yields before paying lets a second request see the old balance.
- **Keep the odds server-side.** Use `chest.Loot:GetChances()` to send the odds to the client for display if you want to show them.
- **Don't seed from anything the client controls.** The default `Random.new()` per table is fine. A seed the client can predict lets it predict rolls.

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
