--!strict
-- Type test: luau-lsp must report the error named on the expect line.
-- expect: Expected this to be exactly 'Logger', but got 'string'
-- Never run: this file isn't part of any place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constella = require(ReplicatedStorage.Packages.Constella)

-- Logger must be a Constella.Debug logger.
local _ = Constella.Network.Server.new("Logged", { Logger = "verbose" })
