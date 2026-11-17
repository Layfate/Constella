--!strict
-- The public types re-exported by the root module. Most of this file is
-- checked by luau-lsp in CI; the runtime checks make sure the re-exports cost
-- nothing at runtime.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Bound directly to require so its exported types can be read.
local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))

type PlayerData = { Coins: number }

return function(t: any, _: any)
	local expect = t.expect

	t.it("requiring the root module loads no submodule", function()
		-- A copy with every submodule removed. If any of the type-only
		-- requires at the end of init.luau ran, requiring it would fail.
		local copy = (ReplicatedStorage :: any).Packages.Constella:Clone()
		copy:ClearAllChildren()
		local root = (require :: any)(copy)
		expect(root.Version).toBe(Constella.Version)
		expect(function()
			return root.Signal
		end).toThrow()
		copy:Destroy()
	end)

	t.it("annotates values with the root types", function()
		local cleanup: Constella.Cleanup = Constella.Cleanup.new()
		local coins: Constella.Value<number> = cleanup:Add(Constella.State.new(5))
		local doubled: Constella.Computed<number> = cleanup:Add(Constella.State.computed({ coins }, function(n)
			return n * 2
		end))
		local changed: Constella.Signal<number> = cleanup:Add(Constella.Signal.new())
		local seen: { number } = {}
		local connection: Constella.Connection = changed:Connect(function(value: number)
			table.insert(seen, value)
		end)
		changed:Fire(1)
		connection:Disconnect()

		local loot: Constella.LootTable<string> = Constella.Random.lootTable({ { Value = "Common", Weight = 1 } })
		local promise: Constella.Promise<number> = Constella.Promise.resolve(3)
		local logger: Constella.Logger = Constella.Debug.Logger.new("Types", { Level = "None" })
		local store: Constella.Store<PlayerData>? = nil
		local profile: Constella.Profile<PlayerData>? = nil

		local app: Constella.App = Constella.App.new({ Name = "TypesApp", Environment = "Server" })
		local service = {
			Name = "TypedService",
			Started = false,
		}
		function service.Start(self: typeof(service), context: Constella.Context)
			self.Started = context.Name == "TypedService"
		end
		app:Add(service)
		app:Start()
		app:Stop()

		expect(doubled:Get()).toBe(10)
		expect(seen).toEqual({ 1 })
		expect(loot:Roll()).toBe("Common")
		expect(select(2, promise:Await())).toBe(3)
		expect(logger ~= nil).toBe(true)
		expect(store == nil and profile == nil).toBe(true)
		expect(service.Started).toBe(true)
		cleanup:Destroy()
	end)
end
