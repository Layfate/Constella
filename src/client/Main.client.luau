--!strict
-- Demo client bootstrap: a separate app that only accepts client-safe controllers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))

local app = Constella.App.new({ Name = "DemoClient" })
app:AddModules(script.Parent:WaitForChild("Controllers"))
app:Start()
