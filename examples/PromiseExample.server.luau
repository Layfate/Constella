--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Promise = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"):WaitForChild("Promise"))

-- Pretend to fetch something slow and flaky.
local attempts = 0
local function fetchLeaderboard()
	return Promise.new(function(resolve, reject)
		attempts += 1
		task.wait(0.2)
		if attempts < 2 then
			reject("service busy")
		else
			resolve({ "Ana", "Ben", "Cy" })
		end
	end)
end

-- Retry with backoff, give up after 3 seconds, and always log the outcome.
Promise.retry(fetchLeaderboard, { Attempts = 3, Delay = 0.1 })
	:Timeout(3)
	:Then(function(names: { string })
		print("[Promise] leaderboard after", attempts, "attempts:", table.concat(names, ", "))
	end)
	:Catch(function(reason)
		warn("[Promise] failed:", tostring(reason))
	end)
	:Finally(function(status)
		print("[Promise] finished with status", status)
	end)

-- Run work in parallel and wait for all of it.
local ok, results = Promise.all({
	Promise.delay(0.1):Then(function()
		return "map loaded"
	end),
	Promise.delay(0.2):Then(function()
		return "music loaded"
	end),
}):Await()
print("[Promise] all:", ok, table.concat(results, ", "))

-- Cancellation stops the work behind a chain.
local countdown = Promise.new(function(resolve, _, onCancel)
	local thread = task.delay(10, resolve)
	onCancel(function()
		task.cancel(thread)
		print("[Promise] countdown cancelled")
	end)
end)
countdown:Cancel()
