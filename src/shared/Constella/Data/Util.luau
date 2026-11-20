--!strict
-- Table helpers and backend types shared by Data modules.

--- One player's stored data while a server holds it. `Data` is the table
--- that gets saved: Constella replaces its contents in place.
export type Session = {
	Data: { [any]: any },
	IsActive: (self: Session) -> boolean,
	--- Called once when the backend ends the session (for example another
	--- server took it over).
	OnSessionEnd: (self: Session, callback: () -> ()) -> (),
	--- Saves now. Yields. Returns false and a reason on failure.
	Save: (self: Session) -> (boolean, string?),
	--- Saves for the last time and releases the session. Yields.
	End: (self: Session) -> (boolean, string?),
}

export type SessionOptions = {
	UserId: number?,
	--- Polled while starting; true means give up.
	ShouldCancel: (() -> boolean)?,
}

--- One named store on a backend.
export type Backend = {
	--- Starts a session for `key`. Yields. Returns nil and a reason on failure.
	StartSession: (self: Backend, key: string, options: SessionOptions?) -> (Session?, string?),
}

--- What a Data backend provides. `Data.ProfileStoreAdapter` and
--- `Data.MemoryAdapter` both implement it.
export type Adapter = {
	Open: (self: Adapter, name: string, template: { [any]: any }) -> Backend,
}

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

-- Deepest nesting accepted by the storable check. Deeper data (or a table
-- that contains itself) is reported instead of recursing forever.
local MAX_STORABLE_DEPTH = 32

local function describeKey(path: string, key: any): string
	if type(key) == "string" and string.match(key, "^[%a_][%w_]*$") then
		return if path == "" then key else path .. "." .. key
	end
	return ("%s[%s]"):format(path, if type(key) == "string" then ("%q"):format(key) else tostring(key))
end

local function checkStorable(value: any, path: string, depth: number): string?
	local valueType = typeof(value)
	if valueType == "nil" or valueType == "boolean" or valueType == "buffer" then
		return nil
	elseif valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return ("%s is %s, which can't be saved"):format(path, tostring(value))
		end
		return nil
	elseif valueType == "string" then
		if utf8.len(value) == nil then
			return ("%s is a string that isn't valid UTF-8"):format(path)
		end
		return nil
	elseif valueType ~= "table" then
		return ("%s is a %s, which DataStores can't save"):format(path, valueType)
	end
	if getmetatable(value) ~= nil then
		return ("%s has a metatable, which DataStores can't save"):format(path)
	end
	if depth > MAX_STORABLE_DEPTH then
		return ("%s is nested deeper than %d levels (or contains itself)"):format(path, MAX_STORABLE_DEPTH)
	end
	-- A saved table is either an array (keys 1..n) or a dictionary (string
	-- keys only); anything else is changed or dropped when it's encoded.
	local count, hasString, hasNumber = 0, false, false
	for key, item in value do
		count += 1
		if type(key) == "string" then
			hasString = true
			if utf8.len(key) == nil then
				return ("%s has a key that isn't valid UTF-8"):format(path)
			end
		elseif type(key) == "number" then
			hasNumber = true
			if key % 1 ~= 0 or key < 1 then
				return ("%s has the key %s; arrays must use keys 1, 2, 3, ..."):format(path, tostring(key))
			end
		else
			return ("%s has a %s key; only string keys or array indices can be saved"):format(path, typeof(key))
		end
		local problem = checkStorable(item, describeKey(path, key), depth + 1)
		if problem then
			return problem
		end
	end
	if hasString and hasNumber then
		return ("%s mixes array items and string keys, which can't be saved together"):format(path)
	end
	if hasNumber and count ~= #value then
		return ("%s is an array with holes, which can't be saved"):format(path)
	end
	return nil
end

--- Returns nil if `value` can be saved to a DataStore (nil, booleans,
--- finite numbers, UTF-8 strings, buffers, and arrays or string-keyed
--- tables of those), otherwise a reason that names where in `value` the
--- problem is. `path` names the value itself.
function Util.checkStorable(value: any, path: string): string?
	return checkStorable(value, path, 1)
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
