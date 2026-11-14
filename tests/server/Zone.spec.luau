--!nonstrict
return function(t, Constella)
	local Zone = Constella.Zone
	local expect = t.expect

	-- A movable point that Zone can track.
	local function point(position)
		local item = { Position = position }
		return item, function()
			return item.Position
		end
	end

	local function box(size)
		return Zone.new({ CFrame = CFrame.new(), Size = size or Vector3.new(10, 10, 10) }, { AutoUpdate = false })
	end

	t.describe("geometry", function()
		t.it("tests points against a rotated box", function()
			local zone = Zone.new({
				CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(45), 0),
				Size = Vector3.new(10, 2, 2),
			}, { AutoUpdate = false })
			-- Along the rotated long axis: inside. Along world X: outside.
			local axis = (CFrame.Angles(0, math.rad(45), 0)).RightVector
			expect(zone:Contains(axis * 4)).toBe(true)
			expect(zone:Contains(Vector3.new(4, 0, 0))).toBe(false)
			zone:Destroy()
		end)

		t.it("tests points against a sphere", function()
			local zone = Zone.new({ Position = Vector3.new(0, 0, 0), Radius = 5 }, { AutoUpdate = false })
			expect(zone:Contains(Vector3.new(0, 4.9, 0))).toBe(true)
			expect(zone:Contains(Vector3.new(0, 5.1, 0))).toBe(false)
			expect(zone:Contains(Vector3.new(0, 5.1, 0), 1)).toBe(true)
			zone:Destroy()
		end)

		t.it("rejects invalid shapes and options", function()
			expect(function()
				Zone.new({})
			end).toThrow("Zone shape must be")
			expect(function()
				Zone.new(Instance.new("Folder"))
			end).toThrow("Zone shape must be a BasePart")
			expect(function()
				Zone.new({ Position = Vector3.zero, Radius = 1 }, { ExitPadding = -1 })
			end).toThrow("ExitPadding")
		end)
	end)

	t.describe("enter and exit", function()
		t.it("fires Entered and Exited once per transition", function()
			local zone = box()
			local item, getPosition = point(Vector3.new(100, 0, 0))
			local log = {}
			zone.Entered:Connect(function(entered)
				table.insert(log, { "enter", entered })
			end)
			zone.Exited:Connect(function(exited)
				table.insert(log, { "exit", exited })
			end)
			zone:Track(item, getPosition)
			zone:Step()
			item.Position = Vector3.new(1, 0, 0)
			zone:Step()
			zone:Step()
			expect(zone:IsInside(item)).toBe(true)
			expect(zone:GetInside()).toEqual({ item })
			item.Position = Vector3.new(100, 0, 0)
			zone:Step()
			expect(log).toEqual({ { "enter", item }, { "exit", item } })
			zone:Destroy()
		end)

		t.it("ExitPadding keeps items inside until they move past the padding", function()
			local zone = Zone.new({ CFrame = CFrame.new(), Size = Vector3.new(10, 10, 10) }, {
				AutoUpdate = false,
				ExitPadding = 2,
			})
			local item, getPosition = point(Vector3.new(4, 0, 0))
			zone:Track(item, getPosition)
			zone:Step()
			expect(zone:IsInside(item)).toBe(true)
			item.Position = Vector3.new(6, 0, 0) -- outside the box, inside the padding
			zone:Step()
			expect(zone:IsInside(item)).toBe(true)
			item.Position = Vector3.new(7.5, 0, 0)
			zone:Step()
			expect(zone:IsInside(item)).toBe(false)
			-- Re-entering uses the real boundary, not the padded one.
			item.Position = Vector3.new(6, 0, 0)
			zone:Step()
			expect(zone:IsInside(item)).toBe(false)
			zone:Destroy()
		end)

		t.it("treats a missing position as outside", function()
			local zone = box()
			local item, getPosition = point(Vector3.zero)
			zone:Track(item, getPosition)
			zone:Step()
			item.Position = nil
			local exited = false
			zone.Exited:Connect(function()
				exited = true
			end)
			zone:Step()
			expect(exited).toBe(true)
			zone:Destroy()
		end)

		t.it("Untrack fires Exited for an item that was inside", function()
			local zone = box()
			local item, getPosition = point(Vector3.zero)
			zone:Track(item, getPosition)
			zone:Step()
			local exited
			zone.Exited:Connect(function(value)
				exited = value
			end)
			zone:Untrack(item)
			expect(exited).toBe(item)
			expect(zone:IsInside(item)).toBe(false)
			zone:Destroy()
		end)

		t.it("lets handlers untrack other items during a step", function()
			local zone = box()
			local a, getA = point(Vector3.zero)
			local b, getB = point(Vector3.zero)
			zone:Track(a, getA)
			zone:Track(b, getB)
			local entered = {}
			zone.Entered:Connect(function(item)
				table.insert(entered, item)
				if item == a then
					zone:Untrack(b)
				end
			end)
			zone:Step()
			expect(entered).toEqual({ a })
			zone:Destroy()
		end)

		t.it("reports position callback errors and treats the item as outside", function()
			local errors = {}
			local zone = Zone.new({ CFrame = CFrame.new(), Size = Vector3.one }, {
				AutoUpdate = false,
				OnError = function(message)
					table.insert(errors, message)
				end,
			})
			zone:Track("broken", function()
				error("no position")
			end)
			zone:Step()
			expect(zone:IsInside("broken")).toBe(false)
			expect(#errors).toBe(1)
			zone:Destroy()
		end)

		t.it("keeps working when OnError raises or a callback steps the zone again", function()
			local raise = true
			local zone = Zone.new({ CFrame = CFrame.new(), Size = Vector3.new(10, 10, 10) }, {
				AutoUpdate = false,
				OnError = function()
					if raise then
						error("handler failed")
					end
				end,
			})
			local a, getA = point(Vector3.zero)
			zone:Track(a, getA)
			zone:Track("broken", function()
				error("no position")
			end)
			expect(function()
				zone:Step()
			end).toThrow("handler failed")
			expect(zone:IsInside(a)).toBe(true)
			raise = false

			-- A callback that steps the zone again must not disturb the step
			-- in progress.
			local nested = 0
			local b = { Position = Vector3.new(1, 0, 0) }
			zone:Track(b, function()
				nested += 1
				if nested == 1 then
					zone:Step()
				end
				return b.Position
			end)
			zone:Step()
			expect(zone:IsInside(b)).toBe(true)
			a.Position = Vector3.new(100, 0, 0)
			zone:Step()
			expect(zone:IsInside(a)).toBe(false)
			zone:Destroy()
		end)

		t.it("does not keep untracked items alive", function()
			local zone = box()
			local weak = setmetatable({}, { __mode = "k" })
			task.spawn(function()
				local item = { Position = Vector3.zero }
				weak[item] = true
				zone:Track(item, function()
					return item.Position
				end)
				zone:Step()
				zone:Untrack(item)
			end)
			zone:Step()
			expect(t.collected(weak)).toBe(true)
			zone:Destroy()
		end)
	end)

	t.describe("instances", function()
		t.it("tracks a BasePart by its position and untracks it when destroyed", function()
			local zone = box()
			local part = Instance.new("Part")
			part.Position = Vector3.zero
			zone:Track(part)
			zone:Step()
			expect(zone:IsInside(part)).toBe(true)
			part:Destroy()
			task.wait()
			expect(zone:IsInside(part)).toBe(false)
			expect(#zone:GetInside()).toBe(0)
			zone:Destroy()
		end)

		t.it("follows a moving BasePart zone and dies with it", function()
			local zonePart = Instance.new("Part")
			zonePart.Size = Vector3.new(4, 4, 4)
			zonePart.CFrame = CFrame.new(0, 0, 0)
			local zone = Zone.new(zonePart, { AutoUpdate = false })
			expect(zone:Contains(Vector3.new(0, 0, 0))).toBe(true)
			zonePart.CFrame = CFrame.new(50, 0, 0)
			expect(zone:Contains(Vector3.new(0, 0, 0))).toBe(false)
			expect(zone:Contains(Vector3.new(50, 0, 0))).toBe(true)
			local destroyed = false
			zone.Entered:Connect(function() end)
			zonePart:Destroy()
			task.wait()
			destroyed = zone.Entered:IsDestroyed()
			expect(destroyed).toBe(true)
		end)

		t.it("requires getPosition for unknown item types", function()
			local zone = box()
			expect(function()
				zone:Track({})
			end).toThrow("pass getPosition")
			zone:Destroy()
		end)
	end)

	t.it("updates automatically on Heartbeat", function()
		local zone = Zone.new({ CFrame = CFrame.new(), Size = Vector3.new(10, 10, 10) }, { Interval = 0 })
		local item, getPosition = point(Vector3.zero)
		zone:Track(item, getPosition)
		local deadline = os.clock() + 2
		while not zone:IsInside(item) and os.clock() < deadline do
			task.wait()
		end
		expect(zone:IsInside(item)).toBe(true)
		zone:Destroy()
	end)
end
