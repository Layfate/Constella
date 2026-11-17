--!strict
-- The only server Script. Every feature is a ModuleScript in ./Services;
-- the App loads them, injects their dependencies and runs Init, Start and
-- Stop in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))

local app = Constella.App.new({ Name = "Server" })

-- Recursive lets you group services in subfolders. The filter skips helper
-- modules that sit next to them, so only "...Service" modules are added.
app:AddModules(script.Parent:WaitForChild("Services"), {
	Recursive = true,
	Filter = function(module: ModuleScript): boolean
		return string.match(module.Name, "Service$") ~= nil
	end,
})

app:Start()

game:BindToClose(function()
	app:Stop()
end)
