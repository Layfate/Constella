--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Random_ = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"):WaitForChild("Random"))

local chest = Random_.lootTable({
	{ Value = "Wood Sword", Weight = 60 },
	{ Value = "Iron Sword", Weight = 30 },
	{ Value = "Star Blade", Weight = 9 },
	{ Value = "Constellation", Weight = 1 },
})

for _, chance in chest:GetChances() do
	print(("[Random] %-14s %.2f%%"):format(chance.Value, chance.Chance * 100))
end

-- Seeded: the same seed always produces the same rolls.
local rng = Random.new(2026)
print("[Random] five seeded rolls:", table.concat(chest:RollMany(5, rng), ", "))

-- Luck 0.5 = square-root weights: rare items become more likely.
print(("[Random] Constellation chance with Luck 0.5: %.2f%%"):format(chest:GetChance("Constellation", { Luck = 0.5 }) * 100))

print("[Random] 25% chance:", Random_.chance(0.25))
print("[Random] shuffled:", table.concat(Random_.shuffle({ "a", "b", "c", "d" }, Random.new(1)), ""))
