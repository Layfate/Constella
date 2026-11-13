--!strict
-- Demo server bootstrap: an explicit app that owns the services in ./Services.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))

local app = Constella.App.new({ Name = "DemoServer" })
app:AddModules(script.Parent:WaitForChild("Services"))
app:Start()

print(("[Demo] %s running: %s"):format(app.Name, table.concat(app:GetOrder(), " -> ")))

game:BindToClose(function()
	app:Stop()
end)
