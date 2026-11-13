--!strict
--[=[
	Constella.Network

	- Network.Server  - server-only: creates and guards remotes
	- Network.Client  - client-only: finds remotes the server created
	- Network.Check   - validators for client input
	- Network.RateLimiter, Network.Payload - building blocks used by Server

	Each part loads on first access, so a client never runs server code.
	(The Server module replicates like any shared code, but it holds no
	secrets: your handlers live in server-only scripts.)
]=]

export type Network = {
	Server: typeof(require(script.Server)),
	Client: typeof(require(script.Client)),
	Check: typeof(require(script.Check)),
	RateLimiter: typeof(require(script.RateLimiter)),
	Payload: typeof(require(script.Payload)),
}

local PARTS = {
	Server = true,
	Client = true,
	Check = true,
	RateLimiter = true,
	Payload = true,
}

local loaded: { [string]: any } = {}

local Network = setmetatable({}, {
	__index = function(_: any, key: any): any
		local cached = loaded[key]
		if cached ~= nil then
			return cached
		end
		if PARTS[key] then
			local module = require(script:FindFirstChild(key) :: any) :: any
			loaded[key] = module
			return module
		end
		error(("[Constella.Network] '%s' is not part of Constella.Network"):format(tostring(key)), 2)
	end,
	__newindex = function()
		error("[Constella.Network] Constella.Network is read-only", 2)
	end,
})

return (Network :: any) :: Network
