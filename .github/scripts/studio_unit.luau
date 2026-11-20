-- Runs the unit suite in Edit mode through Studio's RunScript task, for
-- .github/scripts/studio_tests.ps1 (see CONTRIBUTING.md, "Tests").
local results = require(game.ServerStorage.ConstellaTests.RunTests)()
assert(type(results) == "table" and results.failed == 0, game:GetService("HttpService"):JSONEncode(results))
print("CONSTELLA_UNIT_PASS " .. results.passed .. " passed, " .. results.skipped .. " skipped")
print("CONSTELLA_UNIT_PASS")
