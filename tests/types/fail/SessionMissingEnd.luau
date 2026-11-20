--!strict
-- Type test: luau-lsp must report the error named on the expect line.
-- expect: is missing field 'End'
-- Never run: this file isn't part of any place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constella = require(ReplicatedStorage.Packages.Constella)

-- A custom backend's session must implement End.
local session: Constella.DataSession = {
	Data = {},
	IsActive = function(_self)
		return true
	end,
	OnSessionEnd = function(_self, _callback) end,
	Save = function(_self)
		return true, nil
	end,
}
local _ = session
