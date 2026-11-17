--!strict
-- Server-only tuning. ServerStorage never replicates, so clients can't read
-- this module. Put drop rates, admin lists, webhook URLs and anything else
-- players must not see here, never in ReplicatedStorage.

return table.freeze({
	--- Rolled once, the first time a player joins.
	WelcomeReward = table.freeze({
		table.freeze({ Value = 10, Weight = 70 }),
		table.freeze({ Value = 50, Weight = 25 }),
		table.freeze({ Value = 250, Weight = 5 }),
	}),

	--- The most coins one AddCoins call may grant.
	MaxGrant = 1e6,
})
