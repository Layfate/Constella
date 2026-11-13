--!nonstrict
return function(t, Constella)
	local Debug = Constella.Debug
	local expect = t.expect

	local function capture(level)
		local records = {}
		local logger = Debug.Logger.new("Test", {
			Level = level,
			Sink = function(record)
				table.insert(records, record)
			end,
		})
		return logger, records
	end

	t.describe("Logger", function()
		t.it("emits records at or above the configured level", function()
			local logger, records = capture("Warn")
			logger:Info("hidden")
			logger:Warn("shown", { Code = 7 })
			logger:Error("also shown")
			expect(#records).toBe(2)
			expect(records[1].Level).toBe("Warn")
			expect(records[1].Message).toBe("shown")
			expect(records[1].Fields.Code).toBe(7)
			expect(records[1].Logger).toBe("Test")
		end)

		t.it("does not evaluate lazy messages for disabled levels", function()
			local logger, records = capture("Info")
			local evaluated = false
			logger:Debug(function()
				evaluated = true
				return "expensive"
			end)
			expect(evaluated).toBe(false)
			logger:Info(function()
				return "computed"
			end)
			expect(records[1].Message).toBe("computed")
		end)

		t.it("None disables everything and SetLevel changes it at runtime", function()
			local logger, records = capture("None")
			logger:Error("nope")
			expect(#records).toBe(0)
			logger:SetLevel("Trace")
			logger:Trace("yes")
			expect(#records).toBe(1)
			expect(logger:IsEnabled("Debug")).toBe(true)
			expect(logger:GetLevel()).toBe("Trace")
		end)

		t.it("rejects unknown levels", function()
			expect(function()
				Debug.Logger.new("X", { Level = "Loud" })
			end).toThrow("Unknown log level")
			local logger = capture("Info")
			expect(function()
				logger:SetLevel("Verbose")
			end).toThrow("Unknown log level")
		end)

		t.it("formats fields in sorted key order", function()
			local line = Debug.format({
				Level = "Info",
				Logger = "Shop",
				Message = "bought",
				Fields = { Item = "Sword", Cost = 10, Note = "two words" },
				Time = 0,
			})
			expect(line).toBe('[Shop] INFO bought Cost=10 Item=Sword Note="two words"')
		end)

		t.it("Child loggers prefix the name and share level and sink", function()
			local logger, records = capture("Info")
			local child = logger:Child("Inventory")
			child:Info("hi")
			child:Debug("hidden")
			expect(#records).toBe(1)
			expect(records[1].Logger).toBe("Test/Inventory")
		end)
	end)

	t.describe("Metrics", function()
		t.it("counts and observes", function()
			local metrics = Debug.Metrics.new()
			metrics:Increment("hits")
			metrics:Increment("hits", 2)
			metrics:Observe("latency", 10)
			metrics:Observe("latency", 30)
			local snapshot = metrics:Snapshot()
			expect(snapshot.Counters.hits).toBe(3)
			expect(snapshot.Observations.latency.Count).toBe(2)
			expect(snapshot.Observations.latency.Mean).toBe(20)
			expect(snapshot.Observations.latency.Min).toBe(10)
			expect(snapshot.Observations.latency.Max).toBe(30)
		end)

		t.it("Time returns results, records duration and rethrows errors", function()
			local metrics = Debug.Metrics.new()
			local a, b = metrics:Time("work", function(x)
				return x * 2, "done"
			end, 21)
			expect(a).toBe(42)
			expect(b).toBe("done")
			expect(function()
				metrics:Time("work", function()
					error("failed work")
				end)
			end).toThrow("failed work")
			expect(metrics:Snapshot().Observations.work.Count).toBe(2)
		end)

		t.it("is a no-op when disabled and can be reset", function()
			local metrics = Debug.Metrics.new({ Enabled = false })
			metrics:Increment("x")
			expect(metrics:Snapshot().Counters.x).toBeNil()
			metrics:SetEnabled(true)
			metrics:Increment("x")
			metrics:Reset()
			expect(metrics:Snapshot().Counters.x).toBeNil()
		end)
	end)

	t.it("reports memory usage", function()
		expect(Debug.getMemoryKB()).toBeGreaterThan(0)
	end)
end
