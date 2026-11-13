--!strict
-- Walk your character onto the green pad to see enter/exit messages.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Zone = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"):WaitForChild("Zone"))

local pad = Instance.new("Part")
pad.Name = "ConstellaZonePad"
pad.Anchored = true
pad.CanCollide = false
pad.Transparency = 0.6
pad.Color = Color3.fromRGB(80, 220, 120)
pad.Size = Vector3.new(12, 8, 12)
pad.Position = Vector3.new(0, 4, 20)
pad.Parent = workspace

-- The zone follows the pad and is destroyed with it.
local zone = Zone.new(pad, { Interval = 0.1, ExitPadding = 1 })
zone:TrackPlayers()

zone.Entered:Connect(function(player: Player)
	print("[Zone]", player.Name, "entered the pad")
end)
zone.Exited:Connect(function(player: Player)
	print("[Zone]", player.Name, "left the pad")
end)
