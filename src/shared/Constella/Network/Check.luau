--!strict
--[=[
	Constella.Network.Check

	Validators for data that comes from clients. Every factory returns a
	`Validator`: a function `(value) -> (ok, reason?)`. Validators never
	throw on bad input; they return false and a short reason that is logged
	on the server (never sent to the client).

	Assume every value can be anything: nil, NaN, a huge string, a table with
	extra keys or holes, or an Instance the client should not reference.
]=]

export type Validator = (value: any) -> (boolean, string?)

local Check = {}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function checkBounds(value: number, min: number?, max: number?): (boolean, string?)
	if min ~= nil and value < min then
		return false, ("number %s is below minimum %s"):format(tostring(value), tostring(min))
	end
	if max ~= nil and value > max then
		return false, ("number %s is above maximum %s"):format(tostring(value), tostring(max))
	end
	return true
end

--- Accepts any value, including nil. Avoid for client input.
function Check.any(): Validator
	return function(_)
		return true
	end
end

--- A string of at most `maxLength` bytes (default 200) that is valid UTF-8.
function Check.string(maxLength: number?): Validator
	local limit = maxLength or 200
	return function(value)
		if type(value) ~= "string" then
			return false, ("expected string, got %s"):format(typeof(value))
		end
		if #value > limit then
			return false, ("string is %d bytes, maximum is %d"):format(#value, limit)
		end
		if utf8.len(value) == nil then
			return false, "string is not valid UTF-8"
		end
		return true
	end
end

--- A finite number (NaN and infinities are rejected), optionally bounded.
function Check.number(min: number?, max: number?): Validator
	return function(value)
		if type(value) ~= "number" then
			return false, ("expected number, got %s"):format(typeof(value))
		end
		if not isFinite(value) then
			return false, "number is NaN or infinite"
		end
		return checkBounds(value, min, max)
	end
end

--- A whole, finite number, optionally bounded.
function Check.integer(min: number?, max: number?): Validator
	return function(value)
		if type(value) ~= "number" then
			return false, ("expected integer, got %s"):format(typeof(value))
		end
		if not isFinite(value) or value % 1 ~= 0 then
			return false, ("expected integer, got %s"):format(tostring(value))
		end
		return checkBounds(value, min, max)
	end
end

function Check.boolean(): Validator
	return function(value)
		if type(value) ~= "boolean" then
			return false, ("expected boolean, got %s"):format(typeof(value))
		end
		return true
	end
end

--- One of the given values (compared with ==).
function Check.literal(...: any): Validator
	local allowed = table.pack(...)
	return function(value)
		for index = 1, allowed.n do
			if allowed[index] == value then
				return true
			end
		end
		return false, ("value %s is not one of the allowed values"):format(tostring(value))
	end
end

--- nil, or a value accepted by `validator`.
function Check.optional(validator: Validator): Validator
	return function(value)
		if value == nil then
			return true
		end
		return validator(value)
	end
end

--- Accepted if any validator accepts it.
function Check.union(...: Validator): Validator
	local validators = { ... }
	return function(value)
		for _, validator in validators do
			if validator(value) then
				return true
			end
		end
		return false, "value matched none of the allowed types"
	end
end

--- A dense array (keys 1..n only) of at most `maxLength` items (default 50).
function Check.array(itemValidator: Validator, maxLength: number?): Validator
	local limit = maxLength or 50
	return function(value)
		if type(value) ~= "table" then
			return false, ("expected array, got %s"):format(typeof(value))
		end
		local count = 0
		for key in value do
			count += 1
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
				return false, "array has a non-integer key"
			end
			if count > limit then
				return false, ("array has more than %d items"):format(limit)
			end
		end
		if count ~= #value then
			return false, "array has holes"
		end
		for index = 1, count do
			local ok, reason = itemValidator(value[index])
			if not ok then
				return false, ("item %d: %s"):format(index, reason or "invalid")
			end
		end
		return true
	end
end

--- A table with exactly these string keys (missing keys are validated as
--- nil, so wrap optional fields in Check.optional). Unknown keys are rejected.
function Check.record(shape: { [string]: Validator }): Validator
	return function(value)
		if type(value) ~= "table" then
			return false, ("expected table, got %s"):format(typeof(value))
		end
		for key in value do
			if type(key) ~= "string" or shape[key] == nil then
				return false, ("unexpected key %s"):format(tostring(key))
			end
		end
		for key, validator in shape do
			local ok, reason = validator(value[key])
			if not ok then
				return false, ("field %s: %s"):format(key, reason or "invalid")
			end
		end
		return true
	end
end

--- A table whose keys and values match the given validators, with at most
--- `maxEntries` entries (default 50).
function Check.map(keyValidator: Validator, valueValidator: Validator, maxEntries: number?): Validator
	local limit = maxEntries or 50
	return function(value)
		if type(value) ~= "table" then
			return false, ("expected table, got %s"):format(typeof(value))
		end
		local count = 0
		for key, item in value do
			count += 1
			if count > limit then
				return false, ("table has more than %d entries"):format(limit)
			end
			local keyOk, keyReason = keyValidator(key)
			if not keyOk then
				return false, ("key: %s"):format(keyReason or "invalid")
			end
			local valueOk, valueReason = valueValidator(item)
			if not valueOk then
				return false, ("value at %s: %s"):format(tostring(key), valueReason or "invalid")
			end
		end
		return true
	end
end

--- An Instance that IsA `className` (default "Instance"). Optionally it
--- must be a descendant of `ancestor` - use this to stop clients from
--- referencing objects outside the area you expect.
function Check.instance(className: string?, ancestor: Instance?): Validator
	local class = className or "Instance"
	return function(value)
		if typeof(value) ~= "Instance" then
			return false, ("expected Instance, got %s"):format(typeof(value))
		end
		if not value:IsA(class) then
			return false, ("expected %s, got %s"):format(class, value.ClassName)
		end
		if ancestor ~= nil and not value:IsDescendantOf(ancestor) then
			return false, ("instance is not inside %s"):format(ancestor:GetFullName())
		end
		return true
	end
end

--- A Vector3 with finite components and, optionally, a maximum magnitude.
function Check.vector3(maxMagnitude: number?): Validator
	return function(value)
		if typeof(value) ~= "Vector3" then
			return false, ("expected Vector3, got %s"):format(typeof(value))
		end
		if not (isFinite(value.X) and isFinite(value.Y) and isFinite(value.Z)) then
			return false, "Vector3 has NaN or infinite components"
		end
		if maxMagnitude ~= nil and value.Magnitude > maxMagnitude then
			return false, ("Vector3 magnitude exceeds %s"):format(tostring(maxMagnitude))
		end
		return true
	end
end

--- A CFrame with finite components.
function Check.cframe(): Validator
	return function(value)
		if typeof(value) ~= "CFrame" then
			return false, ("expected CFrame, got %s"):format(typeof(value))
		end
		for _, component in { value:GetComponents() } do
			if not isFinite(component) then
				return false, "CFrame has NaN or infinite components"
			end
		end
		return true
	end
end

--- An EnumItem of the given Enum, e.g. Check.enum(Enum.KeyCode).
function Check.enum(enumType: Enum): Validator
	return function(value)
		if typeof(value) ~= "EnumItem" or value.EnumType ~= enumType then
			return false, ("expected %s"):format(tostring(enumType))
		end
		return true
	end
end

--- Accepted when `validator` accepts it and `predicate(value)` returns true.
function Check.refine(validator: Validator, predicate: (any) -> boolean, reason: string?): Validator
	return function(value)
		local ok, why = validator(value)
		if not ok then
			return false, why
		end
		if not predicate(value) then
			return false, reason or "value failed a custom check"
		end
		return true
	end
end

--- Validates an argument list against an array of validators. Extra
--- arguments are rejected.
function Check.arguments(schema: { Validator }, ...: any): (boolean, string?)
	local count = select("#", ...)
	if count > #schema then
		return false, ("expected at most %d arguments, got %d"):format(#schema, count)
	end
	for index, validator in schema do
		local ok, reason = validator((select(index, ...)))
		if not ok then
			return false, ("argument %d: %s"):format(index, reason or "invalid")
		end
	end
	return true
end

return table.freeze(Check)
