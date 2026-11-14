--!strict
-- Table helpers shared by Data modules.

local Util = {}

-- The general copy: rebuilds key by key, copying table keys too. Used for
-- tables with a metatable (the copy never has one) or with table keys.
local function copyGeneral(value: { [any]: any }, deepCopy: (any) -> any): { [any]: any }
	local copy = {}
	for key, item in value do
		copy[deepCopy(key)] = deepCopy(item)
	end
	return copy
end

--- Deep-copies plain tables (keys and values). Other values are returned as
--- is. The copy never has a metatable.
function Util.deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	if getmetatable(value) ~= nil then
		return copyGeneral(value, Util.deepCopy)
	end
	-- Fast path: clone in one allocation (no rehashing as keys are added),
	-- then copy only the nested tables. Data is mostly strings and numbers,
	-- which need no work at all.
	local copy = table.clone(value)
	for key, item in value do
		if type(key) == "table" then
			return copyGeneral(value, Util.deepCopy)
		end
		if type(item) == "table" then
			copy[key] = Util.deepCopy(item)
		end
	end
	return copy
end

local function isArray(value: { [any]: any }): boolean
	local count = 0
	for _ in value do
		count += 1
	end
	return count == #value
end

--- Adds keys that exist in `template` but are missing (nil) in `target`,
--- recursing into nested dictionaries. Existing values are never changed,
--- and arrays are treated as values (not merged item by item).
function Util.reconcile(target: { [any]: any }, template: { [any]: any })
	for key, templateValue in template do
		local current = target[key]
		if current == nil then
			target[key] = Util.deepCopy(templateValue)
		elseif type(current) == "table" and type(templateValue) == "table" and not isArray(templateValue) then
			Util.reconcile(current, templateValue)
		end
	end
end

--- Replaces the contents of `target` with the contents of `source`, keeping
--- the `target` table itself (other code may hold a reference to it).
function Util.replaceContents(target: { [any]: any }, source: { [any]: any })
	table.clear(target)
	for key, value in source do
		target[key] = value
	end
end

return table.freeze(Util)
