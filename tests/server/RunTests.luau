--!nonstrict
--[=[
	Runs every `*.spec` ModuleScript next to this module.

	```lua
	local results = require(game.ServerScriptService.ConstellaTests.RunTests)()
	print(results.passed, results.failed)
	```
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TestKit = require(script.Parent.TestKit)

return function(options: { Silent: boolean? }?)
	local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))

	local specs = {}
	for _, child in script.Parent:GetChildren() do
		if child:IsA("ModuleScript") and string.match(child.Name, "%.spec$") then
			table.insert(specs, {
				name = (string.gsub(child.Name, "%.spec$", "")),
				run = require(child),
			})
		end
	end
	table.sort(specs, function(a, b)
		return a.name < b.name
	end)

	return TestKit.run(specs, Constella, options)
end
