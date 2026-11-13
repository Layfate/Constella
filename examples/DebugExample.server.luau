--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debug = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"):WaitForChild("Debug"))

local logger = Debug.Logger.new("Example", { Level = "Debug" })
logger:Info("Server started", { Players = #game:GetService("Players"):GetPlayers() })
logger:Debug(function()
	-- Only built when Debug is enabled.
	return "expensive diagnostic: " .. string.rep("*", 10)
end)

local combat = logger:Child("Combat")
combat:Warn("Damage clamped", { Requested = 9999, Applied = 100 })

local metrics = Debug.Metrics.new()
for _ = 1, 5 do
	metrics:Increment("Ticks")
	metrics:Time("SortBenchmark", function()
		local values = table.create(2000)
		for index = 1, 2000 do
			values[index] = math.random()
		end
		table.sort(values)
	end)
end

local snapshot = metrics:Snapshot()
local sort = snapshot.Observations.SortBenchmark
logger:Info("Metrics", {
	Ticks = snapshot.Counters.Ticks,
	SortMeanMs = math.floor(sort.Mean * 1000) / 1000,
	SortMaxMs = math.floor(sort.Max * 1000) / 1000,
	HeapKB = math.floor(Debug.getMemoryKB()),
})
