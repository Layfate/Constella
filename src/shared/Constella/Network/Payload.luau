--!strict
--[=[
	Constella.Network.Payload

	Estimates how many bytes a set of remote arguments occupies, so oversized
	or deeply nested client payloads can be rejected before any validation or
	game logic runs. The numbers are conservative approximations of Roblox's
	wire format, not exact sizes.
]=]

export type Limits = {
	MaxBytes: number,
	MaxDepth: number?,
	MaxNodes: number?,
}

local DEFAULT_MAX_DEPTH = 8
local DEFAULT_MAX_NODES = 512

local FIXED_SIZES: { [string]: number } = {
	["nil"] = 1,
	boolean = 1,
	number = 9,
	Vector2 = 9,
	Vector3 = 13,
	CFrame = 49,
	Color3 = 13,
	UDim = 9,
	UDim2 = 17,
	EnumItem = 5,
	Instance = 9,
	BrickColor = 5,
	Vector2int16 = 5,
	Vector3int16 = 7,
	Rect = 17,
	NumberRange = 9,
	buffer = 5, -- plus its length, added below
}

local Payload = {}

-- Adds `value` to the running totals. Returns the new (total, nodes), plus a
-- reason once a limit is exceeded. The totals are passed along instead of
-- captured, so measuring a request allocates nothing.
local function visit(
	value: any,
	depth: number,
	total: number,
	nodes: number,
	maxBytes: number,
	maxDepth: number,
	maxNodes: number
): (number, number, string?)
	nodes += 1
	if nodes > maxNodes then
		return total, nodes, ("payload has more than %d values"):format(maxNodes)
	end
	local valueType = typeof(value)
	if valueType == "string" then
		total += #value + 4
	elseif valueType == "table" then
		if depth >= maxDepth then
			return total, nodes, ("payload is nested deeper than %d levels"):format(maxDepth)
		end
		total += 4
		local failure: string?
		for key, item in value do
			total, nodes, failure = visit(key, depth + 1, total, nodes, maxBytes, maxDepth, maxNodes)
			if failure then
				return total, nodes, failure
			end
			total, nodes, failure = visit(item, depth + 1, total, nodes, maxBytes, maxDepth, maxNodes)
			if failure then
				return total, nodes, failure
			end
		end
	elseif valueType == "buffer" then
		total += 5 + buffer.len(value)
	else
		total += FIXED_SIZES[valueType] or 16
	end
	if total > maxBytes then
		return total, nodes, ("payload exceeds %d bytes"):format(maxBytes)
	end
	return total, nodes, nil
end

-- Like visit, and also refuses what can't be replicated: functions, threads,
-- userdata and tables with metatables. Used by Replication, so checking and
-- measuring a value takes one walk instead of two.
local function visitReplicable(
	value: any,
	depth: number,
	total: number,
	nodes: number,
	maxBytes: number,
	maxDepth: number,
	maxNodes: number
): (number, number, string?)
	nodes += 1
	if nodes > maxNodes then
		return total, nodes, ("payload has more than %d values"):format(maxNodes)
	end
	local valueType = typeof(value)
	if valueType == "string" then
		total += #value + 4
	elseif valueType == "table" then
		if getmetatable(value) ~= nil then
			return total, nodes, "tables with metatables cannot be replicated"
		end
		if depth >= maxDepth then
			return total, nodes, ("payload is nested deeper than %d levels"):format(maxDepth)
		end
		total += 4
		local failure: string?
		for key, item in value do
			total, nodes, failure = visitReplicable(key, depth + 1, total, nodes, maxBytes, maxDepth, maxNodes)
			if failure then
				return total, nodes, failure
			end
			total, nodes, failure = visitReplicable(item, depth + 1, total, nodes, maxBytes, maxDepth, maxNodes)
			if failure then
				return total, nodes, failure
			end
		end
	elseif valueType == "function" or valueType == "thread" or valueType == "userdata" then
		return total, nodes, ("%s values cannot be replicated"):format(valueType)
	elseif valueType == "buffer" then
		total += 5 + buffer.len(value)
	else
		total += FIXED_SIZES[valueType] or 16
	end
	if total > maxBytes then
		return total, nodes, ("payload exceeds %d bytes"):format(maxBytes)
	end
	return total, nodes, nil
end

--- Returns the estimated size in bytes, or nil and a reason if the payload
--- exceeds `limits` (size, nesting depth or number of values).
function Payload.measure(limits: Limits, ...: any): (number?, string?)
	local maxBytes = limits.MaxBytes
	local maxDepth = limits.MaxDepth or DEFAULT_MAX_DEPTH
	local maxNodes = limits.MaxNodes or DEFAULT_MAX_NODES
	local total, nodes = 0, 0
	local failure: string?
	for index = 1, select("#", ...) do
		total, nodes, failure = visit((select(index, ...)), 0, total, nodes, maxBytes, maxDepth, maxNodes)
		if failure then
			return nil, failure
		end
	end
	return total
end

--- Like `measure` for one value, and also returns nil and a reason for
--- anything that can't be replicated (functions, threads, userdata, tables
--- with metatables).
function Payload.measureReplicable(limits: Limits, value: any): (number?, string?)
	local total, _, failure = visitReplicable(
		value,
		0,
		0,
		0,
		limits.MaxBytes,
		limits.MaxDepth or DEFAULT_MAX_DEPTH,
		limits.MaxNodes or DEFAULT_MAX_NODES
	)
	if failure then
		return nil, failure
	end
	return total
end

return table.freeze(Payload)
