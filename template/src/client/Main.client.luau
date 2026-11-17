--!strict
-- The only client Script. Every feature is a ModuleScript in ./Controllers.
-- The client App refuses definitions marked Environment = "Server".

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))

local app = Constella.App.new({ Name = "Client" })

app:AddModules(script.Parent:WaitForChild("Controllers"), {
	Recursive = true,
	Filter = function(module: ModuleScript): boolean
		return string.match(module.Name, "Controller$") ~= nil
	end,
})

app:Start()
