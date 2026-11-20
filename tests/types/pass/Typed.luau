--!strict
-- Type test: everything here must type-check cleanly (luau-lsp, CI).
-- Never run: this file isn't part of any place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constella = require(ReplicatedStorage.Packages.Constella)
local Contract = Constella.Network.Contract
local Check = Constella.Network.Check

-- Network contracts ------------------------------------------------------------

local Shop = Contract.define({
	Namespace = "Shop",
	Purchase = Contract.fn({ Check.string(20) }) :: Constella.ContractFunction<(string), (string, number)>,
	CoinsChanged = Contract.event() :: Constella.ContractEvent<(number)>,
	Ping = Contract.event({}) :: Constella.ContractEvent<()>,
})

local server = Constella.Network.Server.new(Shop.Namespace)
local purchase: Constella.TypedServerFunction<(string), (string, number)> = server:FunctionOf(Shop.Purchase, {
	RateLimit = { Count = 2, Per = 1 },
	Authorize = function(player: Player, itemId: string): boolean
		return player.UserId > 0 and #itemId > 0
	end,
})
purchase:SetHandler(function(_player, itemId)
	local id: string = itemId
	return id, 90
end)

local coinsChanged = server:EventOf(Shop.CoinsChanged)
coinsChanged:Fire(Players:GetPlayers()[1], 90)
coinsChanged:FireAll(10)
coinsChanged:FireList(Players:GetPlayers(), 5)
local ping = server:EventOf(Shop.Ping)
ping:Connect(function(player: Player)
	print(player.Name)
end)

local client = Constella.Network.Client.new(Shop.Namespace)
local ok, result = client:FunctionOf(Shop.Purchase, { Timeout = 5 }):Invoke("Sword")
if ok then
	print(result)
end
client:EventOf(Shop.CoinsChanged):Connect(function(coins: number)
	print(coins + 1)
end)
client:EventOf(Shop.Ping):Fire()

-- Untyped endpoints keep working exactly as before.
local legacy = server:Event("Legacy", { Schema = { Check.number() } })
legacy:Fire(Players:GetPlayers()[1], "anything", 1, true)

-- Data -------------------------------------------------------------------------

type PlayerData = { Coins: number, Owned: { [string]: boolean } }
local template: PlayerData = { Coins = 0, Owned = {} }

local adapter: Constella.MemoryAdapter = Constella.Data.MemoryAdapter.new()
adapter:SimulateFailures({ Loads = 1 })
local store: Constella.Store<PlayerData> = Constella.Data.Store.new({
	Name = "PlayerData",
	Template = template,
	Adapter = adapter,
	Validate = Check.record({ Coins = Check.number(0), Owned = Check.map(Check.string(), Check.boolean()) }),
	CheckWrites = true,
	Migrations = {
		[0] = function(data)
			data.Coins = data.Coins or 0
			return data
		end,
	},
})
local profile = store:Get(Players:GetPlayers()[1])
if profile then
	profile:Mutate(function(data)
		data.Coins += 5
		data.Owned.Sword = true
	end)
	profile:Mutate(function(data)
		data.Coins -= 1
	end, { Keys = { "Coins" } })
end

-- A custom backend written against the exported types.
local session: Constella.DataSession = {
	Data = {},
	IsActive = function(_self)
		return true
	end,
	OnSessionEnd = function(_self, _callback) end,
	Save = function(_self)
		return true, nil
	end,
	End = function(_self)
		return true, nil
	end,
}
local backend: Constella.DataBackend = {
	StartSession = function(_self, _key, _options)
		return session, nil
	end,
}
local custom: Constella.DataAdapter = {
	Open = function(_self, _name, _template)
		return backend
	end,
}
local _ = Constella.Data.Store.new({ Name = "Custom", Template = template, Adapter = custom })
local _ = Constella.Data.Store.new({
	Name = "Production",
	Template = template,
	Adapter = Constella.Data.ProfileStoreAdapter.new({ New = function() end }),
})

-- Loggers ------------------------------------------------------------------------

local logger: Constella.Logger = Constella.Debug.Logger.new("Types")
local _ = Constella.Network.Server.new("Logged", { Logger = logger })
local _ = Constella.Replication.Server.new("LoggedReplication", { Logger = logger })

-- Cleanup:Connect ----------------------------------------------------------------

local cleanup = Constella.Cleanup.new()
local scored: Constella.Signal<string, number> = Constella.Signal.new()
cleanup:Connect(scored, function(name: string, points: number)
	print(name, points + 1)
end)
cleanup:Connect(Players.PlayerAdded, function(player: Player)
	print(player.UserId)
end)
cleanup:Connect(workspace.ChildAdded, function(child)
	print(child.Name)
end)
-- Any object with a Connect method (another signal library, say).
local custom_signal = {
	Connect = function(_self: any, _callback: (...any) -> ()): any
		return { Disconnect = function() end }
	end,
}
cleanup:Connect(custom_signal, function(...)
	print(...)
end)
