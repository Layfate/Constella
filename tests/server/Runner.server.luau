--!nonstrict
-- Runs the Constella test suite when you press Play in Studio.
-- Results are printed and also stored as attributes on this script.

local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local results = require(script.Parent.RunTests)()
script:SetAttribute("Passed", results.passed)
script:SetAttribute("Failed", results.failed)
