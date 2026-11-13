--!nonstrict
return function(t, Constella)
	local Pool = Constella.Pool
	local expect = t.expect

	local function counterPool(options)
		local nextId = 0
		local destroyed = {}
		local opts = {
			Create = function()
				nextId += 1
				return { Id = nextId, Dirty = false }
			end,
			Destroy = function(object)
				table.insert(destroyed, object.Id)
			end,
		}
		for key, value in options or {} do
			opts[key] = value
		end
		return Pool.new(opts), destroyed
	end

	t.it("creates on demand and reuses released objects", function()
		local pool = counterPool()
		local a = pool:Acquire()
		pool:Release(a)
		local b = pool:Acquire()
		expect(b).toBe(a)
		local stats = pool:GetStats()
		expect(stats.Created).toBe(1)
		expect(stats.Reused).toBe(1)
		expect(stats.Active).toBe(1)
	end)

	t.it("runs Reset on release and OnAcquire on every acquire", function()
		local acquired = 0
		local pool = counterPool({
			Reset = function(object)
				object.Dirty = false
			end,
			OnAcquire = function()
				acquired += 1
			end,
		})
		local object = pool:Acquire()
		object.Dirty = true
		pool:Release(object)
		expect(object.Dirty).toBe(false)
		pool:Acquire()
		expect(acquired).toBe(2)
	end)

	t.it("rejects double release and foreign objects", function()
		local pool = counterPool()
		local object = pool:Acquire()
		pool:Release(object)
		expect(function()
			pool:Release(object)
		end).toThrow("not currently acquired")
		expect(function()
			pool:Release({})
		end).toThrow("not currently acquired")
	end)

	t.it("enforces MaxActive", function()
		local pool = counterPool({ MaxActive = 2 })
		pool:Acquire()
		local second = pool:Acquire()
		expect(pool:TryAcquire()).toBeNil()
		expect(function()
			pool:Acquire()
		end).toThrow("exhausted")
		pool:Release(second)
		expect(pool:TryAcquire() ~= nil).toBe(true)
	end)

	t.it("bounds idle memory with MaxIdle", function()
		local pool, destroyed = counterPool({ MaxIdle = 1 })
		local a, b = pool:Acquire(), pool:Acquire()
		pool:Release(a)
		pool:Release(b)
		expect(pool:GetStats().Idle).toBe(1)
		expect(destroyed).toEqual({ b.Id })
	end)

	t.it("destroys an object whose Reset fails instead of reusing it", function()
		local pool, destroyed = counterPool({
			Reset = function()
				error("reset broke")
			end,
		})
		local object = pool:Acquire()
		expect(function()
			pool:Release(object)
		end).toThrow("reset broke")
		expect(destroyed).toEqual({ object.Id })
		expect(pool:GetStats().Idle).toBe(0)
		expect(pool:GetStats().Active).toBe(0)
	end)

	t.it("prewarms up to MaxIdle", function()
		local pool = counterPool({ Prewarm = 3, MaxIdle = 2 })
		local stats = pool:GetStats()
		expect(stats.Idle).toBe(2)
		expect(stats.Created).toBe(2)
	end)

	t.it("Destroy clears idle objects and destroys late releases", function()
		local pool, destroyed = counterPool()
		local kept = pool:Acquire()
		local idle = pool:Acquire()
		pool:Release(idle)
		pool:Destroy()
		expect(destroyed).toEqual({ idle.Id })
		pool:Release(kept)
		expect(destroyed).toEqual({ idle.Id, kept.Id })
		expect(function()
			pool:Acquire()
		end).toThrow("destroyed")
	end)

	t.it("validates options", function()
		expect(function()
			Pool.new({})
		end).toThrow("Create must be a function")
		expect(function()
			Pool.new({ Create = function() end, MaxActive = 0 })
		end).toThrow("MaxActive must be a positive integer")
		expect(function()
			Pool.new({ Create = function() end, MaxIdle = -1 })
		end).toThrow("MaxIdle must be a non-negative integer")
	end)

	t.it("Pool.instances clones a template and unparents released clones", function()
		local template = Instance.new("Part")
		template.Name = "Bullet"
		local folder = Instance.new("Folder")
		local pool = Pool.instances(template, { MaxIdle = 4 })
		local bullet = pool:Acquire()
		expect(bullet.Name).toBe("Bullet")
		expect(bullet ~= template).toBe(true)
		bullet.Parent = folder
		pool:Release(bullet)
		expect(bullet.Parent).toBeNil()
		expect(pool:Acquire()).toBe(bullet)
		pool:Destroy()
		template:Destroy()
		folder:Destroy()
	end)

	t.it("stays bounded over a long session with fluctuating demand", function()
		local maxIdle, maxActive = 8, 20
		local pool = counterPool({ MaxIdle = maxIdle, MaxActive = maxActive })
		local rng = Random.new(42)
		local out = {}
		local peakActive = 0
		for _ = 1, 20000 do
			if #out > 0 and (rng:NextNumber() < 0.5 or #out >= maxActive) then
				pool:Release(table.remove(out, rng:NextInteger(1, #out)))
			else
				local object = pool:TryAcquire()
				if object then
					table.insert(out, object)
				end
			end
			peakActive = math.max(peakActive, #out)
			local stats = pool:GetStats()
			assert(stats.Idle <= maxIdle, "idle objects exceeded MaxIdle")
			assert(stats.Active <= maxActive, "active objects exceeded MaxActive")
		end
		for _, object in out do
			pool:Release(object)
		end
		local stats = pool:GetStats()
		expect(stats.Active).toBe(0)
		expect(stats.Idle <= maxIdle).toBe(true)
		-- Every object ever created is either idle now or was destroyed.
		expect(stats.Created - stats.Destroyed).toBe(stats.Idle)
		-- Reuse dominates: most acquisitions were served from idle objects.
		-- (Some re-creation is expected: when demand drops, objects beyond
		-- MaxIdle are destroyed, and they are recreated when demand rises.)
		expect(stats.Reused > stats.Created * 5).toBe(true)
		expect(peakActive <= maxActive).toBe(true)
	end)
end
