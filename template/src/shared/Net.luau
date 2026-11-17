--!strict
-- Names shared by the server and the client, so the two sides can't drift
-- apart. Only names live here: schemas, rate limits and handlers stay on
-- the server.

return table.freeze({
	-- Network namespaces and their endpoints.
	Shop = table.freeze({
		Namespace = "Shop",
		Purchase = "Purchase",
	}),

	-- Replication namespace and the values shared through it.
	Player = table.freeze({
		Namespace = "Player",
		Coins = "Coins",
		Items = "Items",
	}),
})
