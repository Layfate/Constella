--!strict
-- The Network contract used by the Play-mode integration test. Both halves
-- require it: the server binds its endpoints with EventOf/FunctionOf, and
-- the hostile client half calls them through the typed client API.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constella = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"))
local Contract = Constella.Network.Contract
local Check = Constella.Network.Check

return Contract.define({
	Namespace = "ConstellaIntegration",
	-- (item, quantity) -> receipt
	Order = Contract.fn({ Check.string(20), Check.integer(1, 5) }) :: Constella.ContractFunction<(string, number), (string)>,
	-- client -> server, a short message
	Shout = Contract.event({ Check.string(10) }) :: Constella.ContractEvent<(string)>,
})
