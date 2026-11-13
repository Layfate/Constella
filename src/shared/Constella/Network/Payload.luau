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

--- Returns the estimated size in bytes, or nil and a reason if the payload
--- exceeds `limits` (size, nesting depth or number of values).
function Payload.measure(limits: Limits, ...: any): (number?, string?)
	local maxBytes = limits.MaxBytes
	local maxDepth = limits.MaxDepth or DEFAULT_MAX_DEPTH
	local maxNodes = limits.MaxNodes or DEFAULT_MAX_NODES
	local total = 0
	local nodes = 0
	local failure: string? = nil

	local function visit(value: any, depth: number)
		if failure then
			return
		end
		nodes += 1
		if nodes > maxNodes then
			failure = ("payload has more than %d values"):format(maxNodes)
			return
		end
		local valueType = typeof(value)
		if valueType == "string" then
			total += #value + 4
		elseif valueType == "table" then
			if depth >= maxDepth then
				failure = ("payload is nested deeper than %d levels"):format(maxDepth)
				return
			end
			total += 4
			for key, item in value do
				visit(key, depth + 1)
				visit(item, depth + 1)
				if failure then
					return
				end
			end
		elseif valueType == "buffer" then
			total += 5 + buffer.len(value)
		else
			total += FIXED_SIZES[valueType] or 16
		end
		if total > maxBytes then
			failure = ("payload exceeds %d bytes"):format(maxBytes)
		end
	end

	for index = 1, select("#", ...) do
		visit((select(index, ...)), 0)
		if failure then
			return nil, failure
		end
	end
	return total
end

return table.freeze(Payload)
