--!strict
-- Server-authoritative coins: stored in the player's profile, mirrored into
-- a State, and replicated to that player only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Constella = require(Packages:WaitForChild("Constella"))

-- A type-only import: nothing is required at runtime. The instance itself
-- comes from context:Get, so the App still controls the startup order.
type PlayerDataService = typeof(require(script.Parent.PlayerDataService))

local WELCOME_REWARD = Constella.Random.lootTable({
	{ Value = 10, Weight = 70 },
	{ Value = 50, Weight = 25 },
	{ Value = 250, Weight = 5 },
})

local RewardService = {
	Name = "RewardService",
	Environment = "Server",
	Dependencies = { "PlayerDataService" },

	_coins = {} :: { [Player]: Constella.Value<number> },
	_sessions = {} :: { [Player]: Constella.Cleanup },
}

export type RewardService = typeof(RewardService)

function RewardService.Init(self: RewardService, context: Constella.Context)
	local playerData: PlayerDataService = context:Get("PlayerDataService")
	local store = playerData.Store
	local replicator = context.Cleanup:Add(Constella.Replication.Server.new("Player"))

	-- Signal:Connect keeps the listener's types (Cleanup:Connect takes any signal,
	-- so it can't), and Cleanup:Add disconnects it when the service stops.
	context.Cleanup:Add(store.Loaded:Connect(function(player, profile)
		local session = Constella.Cleanup.new()
		self._sessions[player] = session

		local coins: Constella.Value<number> = session:Add(Constella.State.new(profile.Data.Coins))
		self._coins[player] = coins
		session:Add(function()
			self._coins[player] = nil
		end)

		-- Every change is written to the profile (saved by the store)...
		session:Add(coins:Subscribe(function(value: number)
			if profile:IsActive() then
				profile:Set("Coins", value)
			end
		end))
		-- ...and replicated to this player only.
		session:Add(replicator:ShareWith(player, "Coins", coins), "Stop")

		if not profile.Data.WelcomeClaimed then
			profile:Set("WelcomeClaimed", true)
			local reward = WELCOME_REWARD:Roll()
			self:AddCoins(player, reward)
			print(("[Demo] %s received a welcome reward of %d coins"):format(player.Name, reward))
		end
	end))

	context.Cleanup:Add(store.Released:Connect(function(player)
		local session = self._sessions[player]
		if session then
			self._sessions[player] = nil
			session:Destroy()
		end
	end))
end

--- Server-only API. Amounts are validated here because callers may forward
--- values that originated from a client.
function RewardService.AddCoins(self: RewardService, player: Player, amount: number)
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount % 1 ~= 0 or amount > 1e6 then
		error(("[RewardService] Invalid coin amount: %s"):format(tostring(amount)), 2)
	end
	local coins = self._coins[player]
	if not coins then
		error(("[RewardService] %s has no loaded profile"):format(player.Name), 2)
	end
	coins:Update(function(current: number)
		return current + amount
	end)
end

--- Removes coins if the player can afford it. Returns false otherwise.
function RewardService.SpendCoins(self: RewardService, player: Player, amount: number): boolean
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount % 1 ~= 0 then
		error(("[RewardService] Invalid coin amount: %s"):format(tostring(amount)), 2)
	end
	local coins = self._coins[player]
	if not coins or coins:Get() < amount then
		return false
	end
	coins:Update(function(current: number)
		return current - amount
	end)
	return true
end

function RewardService.GetCoins(self: RewardService, player: Player): number?
	local coins = self._coins[player]
	return if coins then coins:Get() else nil
end

return RewardService
