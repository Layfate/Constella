--!strict
-- The item catalog. It's in ReplicatedStorage so the client can show names
-- and prices. That's safe: the server reads the same table and makes every
-- decision, so editing a client's copy changes nothing.

export type ItemId = "Sword" | "Shield"

export type Item = {
	Id: ItemId,
	DisplayName: string,
	Price: number,
}

local ITEMS: { Item } = {
	{ Id = "Sword", DisplayName = "Sword", Price = 10 },
	{ Id = "Shield", DisplayName = "Shield", Price = 100 },
}

local byId: { [string]: Item } = {}
local ids: { ItemId } = {}
for _, item in ITEMS do
	byId[item.Id] = item
	table.insert(ids, item.Id)
end

table.freeze(byId)
table.freeze(ids)
for _, item in ITEMS do
	table.freeze(item)
end
table.freeze(ITEMS)

return table.freeze({
	--- Every item, in display order.
	List = ITEMS,
	--- Every item id, for building a Check.literal schema.
	Ids = ids,
	--- Returns the item, or nil for an unknown id.
	get = function(id: string): Item?
		return byId[id]
	end,
})
