--!strict
--[=[
	Constella.Network.RateLimiter

	A token bucket per key (usually a Player). Each key may spend `Count`
	requests at once, and regains `Count` tokens every `Per` seconds
	(continuously). Keys must be forgotten when they leave (the Network
	server does this on PlayerRemoving), so state never leaks across
	sessions: a rejoining player starts with a fresh, full bucket.
]=]

export type Config = {
	Count: number,
	Per: number,
}

export type RateLimiter = {
	Consume: (self: any, key: any, cost: number?) -> boolean,
	Forget: (self: any, key: any) -> (),
	GetTokens: (self: any, key: any) -> number,
	Clear: (self: any) -> (),
}

local PREFIX = "[Constella.Network] "

local RateLimiterClass = {}
RateLimiterClass.__index = RateLimiterClass

local function refill(self: any, key: any): any
	local now = self._clock()
	local bucket = self._buckets[key]
	if bucket == nil then
		bucket = { tokens = self._capacity, updated = now }
		self._buckets[key] = bucket
	else
		local elapsed = math.max(0, now - bucket.updated)
		bucket.tokens = math.min(self._capacity, bucket.tokens + elapsed * self._rate)
		bucket.updated = now
	end
	return bucket
end

--- Spends `cost` tokens (default 1). Returns false when not enough remain.
function RateLimiterClass.Consume(self: any, key: any, cost: number?): boolean
	local bucket = refill(self, key)
	local amount = cost or 1
	if bucket.tokens < amount then
		return false
	end
	bucket.tokens -= amount
	return true
end

function RateLimiterClass.Forget(self: any, key: any)
	self._buckets[key] = nil
end

function RateLimiterClass.GetTokens(self: any, key: any): number
	return refill(self, key).tokens
end

function RateLimiterClass.Clear(self: any)
	table.clear(self._buckets)
end

local RateLimiter = {}

local function isPositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value ~= math.huge
end

--- `clock` defaults to os.clock and exists so tests can control time.
function RateLimiter.new(config: Config, clock: (() -> number)?): RateLimiter
	if type(config) ~= "table" or not isPositive(config.Count) or not isPositive(config.Per) then
		error(PREFIX .. "RateLimit must be { Count = positive number, Per = positive seconds }", 2)
	end
	local self = setmetatable({
		_capacity = config.Count,
		_rate = config.Count / config.Per,
		_clock = clock or os.clock,
		_buckets = {},
	}, RateLimiterClass)
	return (self :: any) :: RateLimiter
end

return table.freeze(RateLimiter)
