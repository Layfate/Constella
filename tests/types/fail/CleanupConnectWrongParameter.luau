--!strict
-- Type test: luau-lsp must report the error named on the expect line.
-- expect: Expected this to be 'string', but got 'number'
-- Never run: this file isn't part of any place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constella = require(ReplicatedStorage.Packages.Constella)

local cleanup = Constella.Cleanup.new()
local scored: Constella.Signal<number> = Constella.Signal.new()
-- The signal passes a number.
cleanup:Connect(scored, function(points: string)
	print(points)
end)
