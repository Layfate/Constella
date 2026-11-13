--!nonstrict
-- Uses unique tags and a private folder in Workspace so it never touches
-- the rest of the place. Tag and ancestry events may be deferred, so the
-- tests wait a frame after each change.
return function(t, Constella)
	local CollectionService = game:GetService("CollectionService")
	local HttpService = game:GetService("HttpService")
	local Component = Constella.Component
	local expect = t.expect

	local function setup()
		local folder = Instance.new("Folder")
		folder.Name = "ConstellaComponentTest"
		folder.Parent = workspace
		local outside = Instance.new("Folder")
		outside.Name = "ConstellaComponentOutside"
		outside.Parent = workspace
		local tag = "ConstellaTest_" .. HttpService:GenerateGUID(false)
		local function tagged(parent)
			local part = Instance.new("Part")
			part.Anchored = true
			part.Parent = parent or folder
			CollectionService:AddTag(part, tag)
			return part
		end
		local function teardown()
			folder:Destroy()
			outside:Destroy()
		end
		return folder, outside, tag, tagged, teardown
	end

	local function frame()
		task.wait()
		task.wait()
	end

	t.it("attaches to existing and new tagged instances with Instance and Cleanup", function()
		local folder, _, tag, tagged, teardown = setup()
		local existing = tagged()
		local started = {}
		local definition = { Tag = tag, Ancestors = { folder } }
		function definition:Start()
			table.insert(started, self.Instance)
			expect(self.Cleanup ~= nil).toBe(true)
		end
		local manager = Component.new(definition)
		manager:Run()
		expect(started).toEqual({ existing })
		local added = tagged()
		frame()
		expect(started).toEqual({ existing, added })
		expect(manager:Get(added).Instance).toBe(added)
		expect(#manager:GetAll()).toBe(2)
		manager:Destroy()
		teardown()
	end)

	t.it("detaches on tag removal: Stop, then Cleanup, then Removed", function()
		local folder, _, tag, tagged, teardown = setup()
		local part = tagged()
		local log = {}
		local definition = { Tag = tag, Ancestors = { folder } }
		function definition:Start()
			self.Cleanup:Add(function()
				table.insert(log, "cleanup")
			end)
		end
		function definition:Stop()
			table.insert(log, "stop")
		end
		local manager = Component.new(definition)
		manager.Removed:Connect(function(object)
			table.insert(log, "removed:" .. object.Instance.Name)
		end)
		manager:Run()
		CollectionService:RemoveTag(part, tag)
		frame()
		expect(log).toEqual({ "stop", "cleanup", "removed:Part" })
		expect(manager:Get(part)).toBeNil()
		manager:Destroy()
		teardown()
	end)

	t.it("only attaches inside Ancestors and follows reparenting", function()
		local folder, outside, tag, tagged, teardown = setup()
		local part = tagged(outside)
		local manager = Component.new({ Tag = tag, Ancestors = { folder } })
		manager:Run()
		expect(manager:Get(part)).toBeNil()
		part.Parent = folder
		frame()
		expect(manager:Get(part) ~= nil).toBe(true)
		part.Parent = outside
		frame()
		expect(manager:Get(part)).toBeNil()
		manager:Destroy()
		teardown()
	end)

	t.it("applies Filter and exposes definition methods on objects", function()
		local folder, _, tag, tagged, teardown = setup()
		local part = tagged()
		local model = Instance.new("Model")
		model.Parent = folder
		CollectionService:AddTag(model, tag)
		local definition = {
			Tag = tag,
			Ancestors = { folder },
			Filter = function(instance)
				return instance:IsA("BasePart")
			end,
		}
		function definition:Describe()
			return "spinner on " .. self.Instance.ClassName
		end
		local manager = Component.new(definition)
		manager:Run()
		expect(manager:Get(model)).toBeNil()
		expect(manager:Get(part):Describe()).toBe("spinner on Part")
		manager:Destroy()
		teardown()
	end)

	t.it("does not add an object whose Start fails, and reports the error", function()
		local folder, _, tag, tagged, teardown = setup()
		local part = tagged()
		local errors = {}
		local addedCount = 0
		local stopped = false
		local manager = Component.new({
			Tag = tag,
			Ancestors = { folder },
			Start = function()
				error("start broke")
			end,
			Stop = function()
				stopped = true
			end,
		}, {
			OnError = function(message)
				table.insert(errors, message)
			end,
		})
		manager.Added:Connect(function()
			addedCount += 1
		end)
		manager:Run()
		expect(manager:Get(part)).toBeNil()
		expect(addedCount).toBe(0)
		expect(stopped).toBe(false)
		expect(#errors).toBe(1)
		manager:Destroy()
		teardown()
	end)

	t.it("Destroy detaches everything and stops observing", function()
		local folder, _, tag, tagged, teardown = setup()
		tagged()
		tagged()
		local stops = 0
		local manager = Component.new({
			Tag = tag,
			Ancestors = { folder },
			Start = function() end,
			Stop = function()
				stops += 1
			end,
		})
		manager:Run()
		manager:Destroy()
		expect(stops).toBe(2)
		expect(#manager:GetAll()).toBe(0)
		tagged()
		frame()
		expect(#manager:GetAll()).toBe(0)
		teardown()
	end)

	t.it("rejects invalid definitions and double Run", function()
		expect(function()
			Component.new({})
		end).toThrow("non-empty string Tag")
		expect(function()
			Component.new({ Tag = "X", Start = 5 })
		end).toThrow("Start must be a function")
		local manager = Component.new({ Tag = "ConstellaTest_Unused" })
		manager:Run()
		expect(function()
			manager:Run()
		end).toThrow("already running")
		manager:Destroy()
	end)
end
