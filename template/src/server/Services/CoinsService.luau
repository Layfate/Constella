--!strict
-- Owns every player's coins and items. Each value lives in the profile (so
-- it saves), in a State (so other code can react) and is replicated to that
-- player only. Other services change them through this module's API.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Rewards = require(ServerStorage:WaitForChild("Config"):WaitForChild("Rewards"))

-- A type-only import: nothing is required at runtime. The instance comes
-- from context:Get, so the App still controls the startup order.
type PlayerDataService = typeof(require(script.Parent.PlayerDataService))

type Session = {
	Cleanup: Types.Cleanup,
	Coins: Types.Value<number>,
	Items: Types.Value<{ [string]: true }>,
}

local WELCOME_REWARD = Constella.Random.lootTable(Rewards.WelcomeReward)

local CoinsService = {
	Name = "CoinsService",
	Environment = "Server",
	Dependencies = { "PlayerDataService" },

	_sessions = {} :: { [Player]: Session },
}

export type CoinsService = typeof(CoinsService)

export type BuyResult = "Purchased" | "NotEnoughCoins" | "AlreadyOwned" | "NotLoaded"

local function isPositiveInteger(value: unknown): boolean
	return type(value) == "number" and value == value and value > 0 and value % 1 == 0
end

function CoinsService.Init(self: CoinsService, context: Types.Context)
	local playerData: PlayerDataService = context:Get("PlayerDataService")
	local store = playerData.Store
	local replicator = context.Cleanup:Add(Constella.Replication.Server.new(Net.Player.Namespace))

	-- Signal:Connect keeps the listener's types; Cleanup:Add disconnects it on Stop.
	context.Cleanup:Add(store.Loaded:Connect(function(player, profile)
		local cleanup = Constella.Cleanup.new()
		local session: Session = {
			Cleanup = cleanup,
			Coins = cleanup:Add(Constella.State.new(profile.Data.Coins)),
			Items = cleanup:Add(Constella.State.new(table.clone(profile.Data.Items))),
		}
		self._sessions[player] = session
		cleanup:Add(function()
			self._sessions[player] = nil
		end)

		-- Every change is written to the profile (saved by the store)...
		cleanup:Add(session.Coins:Subscribe(function(value)
			if profile:IsActive() then
				profile:Set("Coins", value)
			end
		end))
		cleanup:Add(session.Items:Subscribe(function(value)
			if profile:IsActive() then
				profile:Set("Items", table.clone(value))
			end
		end))
		-- ...and replicated to this player only.
		cleanup:Add(replicator:ShareWith(player, Net.Player.Coins, session.Coins), "Stop")
		cleanup:Add(replicator:ShareWith(player, Net.Player.Items, session.Items), "Stop")

		if not profile.Data.WelcomeClaimed then
			profile:Set("WelcomeClaimed", true)
			self:AddCoins(player, WELCOME_REWARD:Roll())
		end
	end))

	context.Cleanup:Add(store.Released:Connect(function(player)
		local session = self._sessions[player]
		if session then
			session.Cleanup:Destroy()
		end
	end))
end

--- Server-only. Amounts are checked here because callers may pass on values
--- that came from a client.
function CoinsService.AddCoins(self: CoinsService, player: Player, amount: number)
	if not isPositiveInteger(amount) or amount > Rewards.MaxGrant then
		error(("[CoinsService] Invalid coin amount: %s"):format(tostring(amount)), 2)
	end
	local session = self._sessions[player]
	if not session then
		error(("[CoinsService] %s has no loaded profile"):format(player.Name), 2)
	end
	session.Coins:Update(function(current)
		return current + amount
	end)
end

--- Takes `price` coins and grants `itemId` in one step. Changes nothing
--- unless the result is "Purchased".
function CoinsService.Buy(self: CoinsService, player: Player, itemId: string, price: number): BuyResult
	if not isPositiveInteger(price) then
		error(("[CoinsService] Invalid price: %s"):format(tostring(price)), 2)
	end
	local session = self._sessions[player]
	if not session then
		return "NotLoaded"
	elseif session.Items:Get()[itemId] then
		return "AlreadyOwned"
	elseif session.Coins:Get() < price then
		return "NotEnoughCoins"
	end
	session.Coins:Update(function(current)
		return current - price
	end)
	session.Items:Update(function(current)
		local items = table.clone(current)
		items[itemId] = true
		return items
	end)
	return "Purchased"
end

function CoinsService.GetCoins(self: CoinsService, player: Player): number?
	local session = self._sessions[player]
	return if session then session.Coins:Get() else nil
end

return CoinsService
