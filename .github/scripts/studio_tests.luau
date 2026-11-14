-- Executed at command-bar permission level by Studio's documented RunScript task.
-- https://create.roblox.com/docs/studio/command-line-interface
local StudioTestService = game:GetService("StudioTestService")
local results = StudioTestService:ExecuteMultiplayerTestAsync(2, {
	Suite = "ConstellaMultiplayer",
	Clients = 2,
})
assert(
	type(results) == "table" and results.Passed == true,
	"Multiplayer integration failed: " .. tostring(if type(results) == "table" then results.Message else results)
)
print("CONSTELLA_MULTIPLAYER_PASS")
