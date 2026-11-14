--!nonstrict
return function(t, Constella)
	local App = Constella.App
	local expect = t.expect

	local function newApp(options)
		local opts = options or {}
		opts.Environment = opts.Environment or "Server"
		return App.new(opts)
	end

	-- Builds a definition that records lifecycle calls into `log`.
	local function tracked(log, name, dependencies, extra)
		local definition = {
			Name = name,
			Dependencies = dependencies,
			Init = function()
				table.insert(log, "init:" .. name)
			end,
			Start = function()
				table.insert(log, "start:" .. name)
			end,
			Stop = function()
				table.insert(log, "stop:" .. name)
			end,
		}
		for key, value in extra or {} do
			definition[key] = value
		end
		return definition
	end

	t.describe("ordering", function()
		t.it("runs Init then Start in dependency order regardless of registration order", function()
			local log = {}
			local app = newApp()
			app:Add(tracked(log, "C", { "B" }))
			app:Add(tracked(log, "B", { "A" }))
			app:Add(tracked(log, "A"))
			app:Start()
			expect(log).toEqual({ "init:A", "init:B", "init:C", "start:A", "start:B", "start:C" })
			expect(app:GetOrder()).toEqual({ "A", "B", "C" })
			expect(app:GetState()).toBe("Running")
		end)

		t.it("orders independent definitions by registration order", function()
			local log = {}
			local app = newApp()
			app:Add(tracked(log, "X"))
			app:Add(tracked(log, "Y"))
			app:Start()
			expect(app:GetOrder()).toEqual({ "X", "Y" })
		end)

		t.it("stops in reverse dependency order and is idempotent", function()
			local log = {}
			local app = newApp()
			app:Add(tracked(log, "B", { "A" }))
			app:Add(tracked(log, "A"))
			app:Start()
			table.clear(log)
			app:Stop()
			app:Stop()
			expect(log).toEqual({ "stop:B", "stop:A" })
			expect(app:GetState()).toBe("Stopped")
		end)
	end)

	t.describe("validation", function()
		t.it("rejects duplicate names", function()
			local app = newApp()
			app:Add({ Name = "Same" })
			expect(function()
				app:Add({ Name = "Same" })
			end).toThrow("already added")
		end)

		t.it("rejects malformed definitions", function()
			local app = newApp()
			expect(function()
				app:Add({})
			end).toThrow("non-empty string Name")
			expect(function()
				app:Add({ Name = "Bad", Init = 5 })
			end).toThrow("Init must be a function")
			expect(function()
				app:Add({ Name = "Self", Dependencies = { "Self" } })
			end).toThrow("cannot depend on itself")
		end)

		t.it("rejects missing dependencies before running any user code", function()
			local log = {}
			local app = newApp()
			app:Add(tracked(log, "A", { "Ghost" }))
			expect(function()
				app:Start()
			end).toThrow("'A' -> 'Ghost'")
			expect(log).toEqual({})
			expect(app:GetState()).toBe("Failed")
		end)

		t.it("detects cycles and reports the path", function()
			local log = {}
			local app = newApp()
			app:Add(tracked(log, "A", { "B" }))
			app:Add(tracked(log, "B", { "C" }))
			app:Add(tracked(log, "C", { "A" }))
			expect(function()
				app:Start()
			end).toThrow("Circular dependency: A -> B -> C -> A")
			expect(log).toEqual({})
		end)

		t.it("rejects a second Start", function()
			local app = newApp()
			app:Start()
			expect(function()
				app:Start()
			end).toThrow("can only be started once")
		end)

		t.it("rejects Add after Start", function()
			local app = newApp()
			app:Start()
			expect(function()
				app:Add({ Name = "Late" })
			end).toThrow("already been started")
		end)

		t.it("keeps client-only definitions out of a server app and vice versa", function()
			local server = newApp({ Environment = "Server" })
			expect(function()
				server:Add({ Name = "HudController", Environment = "Client" })
			end).toThrow("client-only")
			local client = newApp({ Environment = "Client" })
			expect(function()
				client:Add({ Name = "DataService", Environment = "Server" })
			end).toThrow("server-only")
			expect(function()
				client:Add({ Name = "Util", Environment = "Shared" })
			end).toNotThrow()
		end)
	end)

	t.describe("dependency injection", function()
		t.it("gives access to declared dependencies only", function()
			local app = newApp()
			local resolved
			app:Add({ Name = "Store" })
			app:Add({ Name = "Other" })
			app:Add({
				Name = "Consumer",
				Dependencies = { "Store" },
				Init = function(_, context)
					resolved = context:Get("Store")
					context:Get("Other")
				end,
			})
			expect(function()
				app:Start()
			end).toThrow("without listing it in Dependencies")
			expect(resolved).toBe(app:Get("Store"))
		end)

		t.it("passes the definition as self", function()
			local app = newApp()
			local definition = { Name = "Counter", Count = 0 }
			function definition:Init()
				self.Count += 1
			end
			app:Add(definition)
			app:Start()
			expect(definition.Count).toBe(1)
		end)
	end)

	t.describe("failures", function()
		t.it("rolls back initialized definitions when an Init fails", function()
			local log = {}
			local cleaned = {}
			local app = newApp()
			app:Add(tracked(log, "A", nil, {
				Init = function(_, context)
					table.insert(log, "init:A")
					context.Cleanup:Add(function()
						table.insert(cleaned, "A")
					end)
				end,
			}))
			app:Add(tracked(log, "B", { "A" }, {
				Init = function()
					error("database offline")
				end,
			}))
			app:Add(tracked(log, "C", { "B" }))
			expect(function()
				app:Start()
			end).toThrow("Init failed for 'B'")
			expect(log).toEqual({ "init:A", "stop:B", "stop:A" })
			expect(cleaned).toEqual({ "A" })
			expect(app:GetState()).toBe("Failed")
		end)

		t.it("fails startup when Start errors before yielding", function()
			local log = {}
			local app = newApp()
			app:Add(tracked(log, "A"))
			app:Add(tracked(log, "B", { "A" }, {
				Start = function()
					error("bad start")
				end,
			}))
			expect(function()
				app:Start()
			end).toThrow("Start failed for 'B'")
			expect(log).toEqual({ "init:A", "init:B", "start:A", "stop:B", "stop:A" })
		end)

		t.it("reports Start errors raised after a yield without failing the app", function()
			local reported = {}
			local app = newApp({
				OnError = function(message)
					table.insert(reported, message)
				end,
			})
			app:Add({
				Name = "Late",
				Start = function()
					task.wait()
					error("late failure")
				end,
			})
			app:Start()
			expect(app:GetState()).toBe("Running")
			task.wait()
			task.wait()
			expect(#reported).toBe(1)
			expect(string.find(reported[1], "late failure", 1, true) ~= nil).toBe(true)
		end)

		t.it("collects Stop errors and still stops everything", function()
			local log = {}
			local app = newApp()
			app:Add(tracked(log, "A"))
			app:Add(tracked(log, "B", { "A" }, {
				Stop = function()
					error("stop exploded")
				end,
			}))
			app:Start()
			table.clear(log)
			expect(function()
				app:Stop()
			end).toThrow("stop exploded")
			expect(log).toEqual({ "stop:A" })
			expect(app:GetState()).toBe("Stopped")
		end)
	end)

	t.describe("signals and waiting", function()
		t.it("fires Started and resumes AwaitStart", function()
			local app = newApp()
			local started = false
			app.Started:Connect(function()
				started = true
			end)
			local resumed = false
			task.spawn(function()
				app:AwaitStart()
				resumed = true
			end)
			expect(resumed).toBe(false)
			app:Start()
			expect(started).toBe(true)
			expect(resumed).toBe(true)
		end)

		t.it("AwaitStart raises after a failed startup", function()
			local app = newApp()
			app:Add({ Name = "A", Dependencies = { "Missing" } })
			pcall(function()
				app:Start()
			end)
			expect(function()
				app:AwaitStart()
			end).toThrow("failed to start")
		end)
	end)

	t.describe("running Start threads", function()
		local function looper(name, counter, dependencies)
			return {
				Name = name,
				Dependencies = dependencies,
				Start = function()
					while true do
						counter.ticks += 1
						task.wait()
					end
				end,
			}
		end

		t.it("cancels a Start that is still running when the app stops", function()
			local counter = { ticks = 0 }
			local stopped = false
			local app = newApp()
			local definition = looper("Looper", counter)
			definition.Stop = function()
				stopped = true
			end
			app:Add(definition)
			app:Start()
			task.wait()
			task.wait()
			app:Stop()
			expect(stopped).toBe(true)
			local atStop = counter.ticks
			task.wait()
			task.wait()
			task.wait()
			expect(counter.ticks).toBe(atStop)
		end)

		t.it("cancels running Starts when a later Start fails", function()
			local counter = { ticks = 0 }
			local app = newApp()
			app:Add(looper("Looper", counter))
			app:Add({
				Name = "Broken",
				Dependencies = { "Looper" },
				Start = function()
					error("boom")
				end,
			})
			local ok = pcall(app.Start, app)
			expect(ok).toBe(false)
			local atFailure = counter.ticks
			task.wait()
			task.wait()
			task.wait()
			expect(counter.ticks).toBe(atFailure)
		end)
	end)

	t.describe("WaitForStart", function()
		t.it("waits for a yielding Start before later Starts and Running", function()
			local log = {}
			local app = newApp()
			app:Add({
				Name = "Database",
				WaitForStart = true,
				Start = function()
					task.wait(0.05)
					table.insert(log, "database ready")
				end,
			})
			app:Add({
				Name = "Shop",
				Dependencies = { "Database" },
				Start = function()
					table.insert(log, "shop start")
				end,
			})
			app:Start()
			expect(log).toEqual({ "database ready", "shop start" })
			expect(app:GetState()).toBe("Running")
		end)

		t.it("fails startup and rolls back when Start errors after yielding", function()
			local log = {}
			local reported = {}
			local app = newApp({
				OnError = function(message)
					table.insert(reported, message)
				end,
			})
			app:Add(tracked(log, "A"))
			app:Add(tracked(log, "Critical", { "A" }, {
				WaitForStart = true,
				Start = function()
					task.wait()
					error("connection refused")
				end,
			}))
			expect(function()
				app:Start()
			end).toThrow("connection refused")
			expect(app:GetState()).toBe("Failed")
			expect(log).toEqual({ "init:A", "init:Critical", "start:A", "stop:Critical", "stop:A" })
			expect(#reported).toBe(0)
		end)

		t.it("fails startup when Start exceeds StartTimeout and stops the stuck Start", function()
			local log = {}
			local finished = false
			local app = newApp()
			app:Add(tracked(log, "Slow", nil, {
				WaitForStart = true,
				StartTimeout = 0.05,
				Start = function()
					task.wait(5)
					finished = true
				end,
			}))
			expect(function()
				app:Start()
			end).toThrow("did not finish within 0.05 seconds")
			expect(app:GetState()).toBe("Failed")
			expect(log).toEqual({ "init:Slow", "stop:Slow" })
			task.wait(0.1)
			expect(finished).toBe(false)
		end)

		t.it("validates WaitForStart and StartTimeout", function()
			local app = newApp()
			expect(function()
				app:Add({ Name = "X", WaitForStart = "yes" })
			end).toThrow("WaitForStart must be a boolean")
			expect(function()
				app:Add({ Name = "Y", StartTimeout = -1 })
			end).toThrow("StartTimeout must be a positive number")
		end)
	end)
end
