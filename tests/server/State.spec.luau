--!nonstrict
return function(t, Constella)
	local State = Constella.State
	local Cleanup = Constella.Cleanup
	local expect = t.expect

	t.describe("Value", function()
		t.it("notifies subscribers with the new and old value", function()
			local state = State.new(1)
			local seen = {}
			state:Subscribe(function(new, old)
				table.insert(seen, { new, old })
			end)
			state:Set(2)
			state:Update(function(current)
				return current * 10
			end)
			expect(state:Get()).toBe(20)
			expect(seen).toEqual({ { 2, 1 }, { 20, 2 } })
		end)

		t.it("never notifies for equality-preserving sets (including NaN and same table)", function()
			local nan = 0 / 0
			local shared = {}
			local numberState = State.new(5)
			local nanState = State.new(nan)
			local tableState = State.new(shared)
			local count = 0
			local function bump()
				count += 1
			end
			numberState:Subscribe(bump)
			nanState:Subscribe(bump)
			tableState:Subscribe(bump)
			numberState:Set(5)
			nanState:Set(0 / 0)
			tableState:Set(shared)
			expect(count).toBe(0)
		end)

		t.it("supports a custom Equals option", function()
			local state = State.new({ x = 1 }, {
				Equals = function(a, b)
					return a.x == b.x
				end,
			})
			local count = 0
			state:Subscribe(function()
				count += 1
			end)
			state:Set({ x = 1 })
			expect(count).toBe(0)
			state:Set({ x = 2 })
			expect(count).toBe(1)
		end)

		t.it("Observe runs immediately and on every change", function()
			local state = State.new("a")
			local seen = {}
			state:Observe(function(value)
				table.insert(seen, value)
			end)
			state:Set("b")
			expect(seen).toEqual({ "a", "b" })
		end)

		t.it("works with Cleanup (the README example)", function()
			local cleanup = Cleanup.new()
			local state = State.new(0)
			local seen = {}
			cleanup:Add(state:Subscribe(function(newValue)
				table.insert(seen, newValue)
			end))
			state:Set(10)
			cleanup:Destroy()
			state:Set(20)
			expect(seen).toEqual({ 10 })
		end)

		t.it("Destroy releases subscriptions and rejects further writes", function()
			local state = State.new(0)
			local connection = state:Subscribe(function() end)
			state:Destroy()
			state:Destroy()
			expect(connection.Connected).toBe(false)
			expect(state:IsDestroyed()).toBe(true)
			expect(function()
				state:Set(1)
			end).toThrow("destroyed")
		end)
	end)

	t.describe("computed", function()
		t.it("derives from sources and updates when they change", function()
			local price = State.new(3)
			local quantity = State.new(2)
			local total = State.computed({ price, quantity }, function(p, q)
				return p * q
			end)
			expect(total:Get()).toBe(6)
			quantity:Set(5)
			expect(total:Get()).toBe(15)
		end)

		t.it("is read-only", function()
			local source = State.new(1)
			local derived = State.select(source, function(value)
				return value + 1
			end)
			expect(derived.Set).toBeNil()
			expect(derived.Update).toBeNil()
		end)

		t.it("does not notify when the derived value is unchanged", function()
			local number = State.new(2)
			local isEven = State.select(number, function(value)
				return value % 2 == 0
			end)
			local count = 0
			isEven:Subscribe(function()
				count += 1
			end)
			number:Set(4)
			expect(count).toBe(0)
			number:Set(5)
			expect(count).toBe(1)
		end)

		t.it("notifies once per change in a diamond dependency graph", function()
			local a = State.new(1)
			local b = State.select(a, function(value)
				return value + 1
			end)
			local c = State.select(a, function(value)
				return value * 2
			end)
			local d = State.computed({ b, c }, function(bValue, cValue)
				return bValue + cValue
			end)
			local seen = {}
			d:Subscribe(function(new, old)
				table.insert(seen, { new, old })
			end)
			a:Set(2)
			expect(d:Get()).toBe(7)
			expect(seen).toEqual({ { 7, 4 } })
		end)

		t.it("stops updating after Destroy", function()
			local source = State.new(1)
			local derived = State.select(source, function(value)
				return value
			end)
			derived:Destroy()
			source:Set(2)
			expect(derived:Get()).toBe(1)
		end)

		t.it("validates its sources", function()
			expect(function()
				State.computed({}, function() end)
			end).toThrow("non-empty")
			expect(function()
				State.computed({ 5 }, function() end)
			end).toThrow("not a Constella state")
		end)
	end)

	t.describe("batch", function()
		t.it("coalesces several writes into one notification per state", function()
			local state = State.new(0)
			local seen = {}
			state:Subscribe(function(new, old)
				table.insert(seen, { new, old })
			end)
			State.batch(function()
				state:Set(1)
				state:Set(2)
				state:Set(3)
			end)
			expect(seen).toEqual({ { 3, 0 } })
		end)

		t.it("skips states that change and change back", function()
			local state = State.new("idle")
			local count = 0
			state:Subscribe(function()
				count += 1
			end)
			State.batch(function()
				state:Set("busy")
				state:Set("idle")
			end)
			expect(count).toBe(0)
		end)

		t.it("delivers notifications and then re-raises errors", function()
			local state = State.new(0)
			local seen
			state:Subscribe(function(new)
				seen = new
			end)
			expect(function()
				State.batch(function()
					state:Set(1)
					error("inside batch")
				end)
			end).toThrow("inside batch")
			expect(seen).toBe(1)
			-- Batching must be fully unwound: a plain Set notifies immediately again.
			state:Set(2)
			expect(seen).toBe(2)
		end)
	end)

	t.describe("bind", function()
		t.it("keeps a property in sync, with an optional transform", function()
			local label = Instance.new("TextLabel")
			local coins = State.new(5)
			State.bind(label, "Text", coins, function(value)
				return "Coins: " .. value
			end)
			expect(label.Text).toBe("Coins: 5")
			coins:Set(12)
			expect(label.Text).toBe("Coins: 12")
			label:Destroy()
		end)

		t.it("stops on Disconnect and when the instance is destroyed", function()
			local label = Instance.new("TextLabel")
			local text = State.new("a")
			local binding = State.bind(label, "Text", text)
			binding:Disconnect()
			text:Set("b")
			expect(label.Text).toBe("a")

			local other = Instance.new("TextLabel")
			local second = State.bind(other, "Text", text)
			other:Destroy()
			task.wait()
			expect(second.Connected).toBe(false)
		end)

		t.it("fails immediately for an invalid property or source", function()
			local label = Instance.new("TextLabel")
			expect(function()
				State.bind(label, "NotAProperty", State.new(1))
			end).toThrow("Cannot bind")
			expect(function()
				State.bind(label, "Text", "plain value")
			end).toThrow("Constella state")
			label:Destroy()
		end)

		t.it("works with computed states", function()
			local frame = Instance.new("Frame")
			local health = State.new(50)
			local fraction = State.select(health, function(value)
				return value / 100
			end)
			State.bind(frame, "Size", fraction, function(value)
				return UDim2.fromScale(value, 1)
			end)
			health:Set(25)
			expect(frame.Size.X.Scale).toBeCloseTo(0.25)
			frame:Destroy()
		end)
	end)
end
