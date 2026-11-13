--!strict
--[=[
	Constella.Replication

	Explicit, server-authorised replication of State values to clients.

	Server
	```lua
	local replicator = Replication.Server.new("Game")
	replicator:Share("RoundTime", roundTime)                 -- every player
	replicator:ShareWith(player, "Coins", profileCoinsState) -- only this player
	```

	Client
	```lua
	local replica = Replication.Client.new("Game")
	State.bind(label, "Text", replica:Get("Coins"), tostring)
	```

	Rules
	- Nothing replicates unless the server shares it. A private share is
	  only ever sent to, and only visible in snapshots for, its player.
	- Data flows one way. The update channel accepts nothing from clients;
	  the only client request is a rate-limited snapshot fetch with no
	  arguments.
	- Values must be replicable (no functions, threads or metatables) and at
	  most MaxValueBytes (default 16 KB). Invalid values are reported on the
	  server and not sent.
	- Versions come from one increasing counter per replicator, so an initial
	  snapshot can never overwrite a newer update that arrived first, and a
	  share that is stopped and recreated is never mistaken for stale data.
	- Snapshots only contain values that passed validation: a rejected update
	  is reported and the last valid value keeps being served.
	- Tables are compared by reference (State semantics): set a new table
	  to replicate a change.
]=]

local Players = game:GetService("Players")

local State = require(script.Parent.State)
local Network = require(script.Parent.Network)

export type ServerOptions = {
	Parent: Instance?,
	Logger: any?,
	OnError: ((message: string) -> ())?,
	--- Largest value that may be sent, in estimated bytes. Defaults to 16384.
	MaxValueBytes: number?,
}

export type ClientOptions = {
	Parent: Instance?,
	Timeout: number?,
}

export type Share = {
	Name: string,
	Stop: (self: any) -> (),
}

export type ReplicationServer = {
	Share: (self: any, name: string, state: any) -> Share,
	ShareWith: (self: any, player: Player, name: string, state: any) -> Share,
	Destroy: (self: any) -> (),
}

export type ReplicationClient = {
	Get: (self: any, name: string) -> State.Computed<any>,
	Observe: (self: any, name: string, callback: (value: any) -> ()) -> State.Connection,
	Destroy: (self: any) -> (),
}

local PREFIX = "[Constella.Replication] "
local DEFAULT_MAX_VALUE_BYTES = 16384

local function checkName(name: any, level: number)
	if type(name) ~= "string" or #name == 0 or #name > 50 then
		error(PREFIX .. "Share name must be a string of 1-50 characters", level)
	end
end

-- Returns nil when `value` can be sent, otherwise the reason it cannot.
local function unsupported(value: any, depth: number?): string?
	local valueType = typeof(value)
	if valueType == "function" or valueType == "thread" or valueType == "userdata" then
		return ("%s values cannot be replicated"):format(valueType)
	end
	if valueType == "table" then
		if getmetatable(value) ~= nil then
			return "tables with metatables cannot be replicated"
		end
		local level = depth or 0
		if level > 16 then
			return "table is nested too deeply"
		end
		for key, item in value do
			local reason = unsupported(key, level + 1) or unsupported(item, level + 1)
			if reason then
				return reason
			end
		end
	end
	return nil
end

-- Server -------------------------------------------------------------------

local ShareClass = {}
ShareClass.__index = ShareClass

function ShareClass.Stop(self: any)
	if not self._active then
		return
	end
	self._server:_removeShare(self)
end

local ServerClass = {}
ServerClass.__index = ServerClass

function ServerClass._report(self: any, message: string)
	self._onError(PREFIX .. message)
end

function ServerClass._audience(_self: any, share: any): { any }
	if share.player ~= nil then
		return { share.player }
	end
	return Players:GetPlayers()
end

-- Returns nil when `value` may be sent, otherwise why it may not.
function ServerClass._validate(self: any, value: any): string?
	local reason = unsupported(value)
	if reason ~= nil then
		return reason
	end
	local size, sizeReason =
		Network.Payload.measure({ MaxBytes = self._maxBytes, MaxDepth = 16, MaxNodes = 4096 }, value)
	if size == nil then
		return sizeReason
	end
	return nil
end

-- Versions come from one counter per replicator that only ever increases,
-- so a share that is stopped and recreated under the same name always
-- continues above every version a client has already seen.
function ServerClass._nextVersion(self: any): number
	self._clock += 1
	return self._clock
end

function ServerClass._broadcast(self: any, share: any, removed: boolean)
	self._update:FireList(self:_audience(share), share.name, share.value, share.version, removed)
end

-- Applies a new value: validated first, then cached and sent. A rejected
-- value is reported and never cached, so snapshots keep serving the last
-- value that passed validation.
function ServerClass._publish(self: any, share: any, value: any)
	local reason = self:_validate(value)
	if reason then
		self:_report(("'%s' was not replicated: %s"):format(share.name, reason))
		return
	end
	share.value = value
	share.version = self:_nextVersion()
	self:_broadcast(share, false)
end

function ServerClass._addShare(self: any, player: any, name: string, state: any, level: number): Share
	if self._destroyed then
		error(PREFIX .. "This replicator has been destroyed", level)
	end
	checkName(name, level + 1)
	if not State.is(state) then
		error(PREFIX .. ("'%s' must be a Constella state"):format(name), level)
	end
	local kind = if player == nil then "public" else "private"
	local existingKind = self._nameKinds[name]
	if existingKind ~= nil and existingKind ~= kind then
		error(PREFIX .. ("'%s' is already shared as %s"):format(name, existingKind), level)
	end
	local initial = state:Get()
	local reason = self:_validate(initial)
	if reason then
		error(PREFIX .. ("'%s' cannot be replicated: %s"):format(name, reason), level)
	end

	local bucket
	if player == nil then
		bucket = self._public
	else
		bucket = self._private[player]
		if bucket == nil then
			bucket = {}
			self._private[player] = bucket
		end
	end
	if bucket[name] then
		error(PREFIX .. ("'%s' is already shared%s"):format(name, if player then " with this player" else ""), level)
	end

	local share = setmetatable({
		Name = name,
		name = name,
		player = player,
		state = state,
		value = initial, -- last value that passed validation
		version = self:_nextVersion(),
		_active = true,
		_server = self,
	}, ShareClass)
	bucket[name] = share
	self._nameKinds[name] = kind
	self._nameCounts[name] = (self._nameCounts[name] or 0) + 1

	share.connection = state:Subscribe(function(value)
		self:_publish(share, value)
	end)
	-- Clients that are already connected learn about the new share now.
	self:_broadcast(share, false)
	return (share :: any) :: Share
end

function ServerClass._removeShare(self: any, share: any)
	share._active = false
	share.connection:Disconnect()
	local bucket = if share.player == nil then self._public else self._private[share.player]
	if bucket and bucket[share.name] == share then
		bucket[share.name] = nil
	end
	if share.player ~= nil and bucket and next(bucket) == nil then
		self._private[share.player] = nil
	end
	self._nameCounts[share.name] -= 1
	if self._nameCounts[share.name] == 0 then
		self._nameCounts[share.name] = nil
		self._nameKinds[share.name] = nil
	end
	if not self._destroyed then
		share.value = nil
		share.version = self:_nextVersion()
		self:_broadcast(share, true)
	end
end

--- Replicates `state` to every player, now and in the future.
function ServerClass.Share(self: any, name: string, state: any): Share
	return self:_addShare(nil, name, state, 3)
end

--- Replicates `state` to `player` only. Removed when the player leaves.
function ServerClass.ShareWith(self: any, player: Player, name: string, state: any): Share
	if (player :: any) == nil then
		error(PREFIX .. "ShareWith needs a player", 2)
	end
	return self:_addShare(player, name, state, 3)
end

--- Internal: the values `player` is allowed to see, keyed by name.
function ServerClass._snapshotFor(self: any, player: any): { [string]: { any } }
	local snapshot = {}
	for name, share in self._public do
		snapshot[name] = { share.value, share.version }
	end
	local private = self._private[player]
	if private then
		for name, share in private do
			snapshot[name] = { share.value, share.version }
		end
	end
	return snapshot
end

--- Internal: drops every private share of a player. Called on PlayerRemoving.
function ServerClass._forgetPlayer(self: any, player: any)
	local private = self._private[player]
	if private == nil then
		return
	end
	local shares = {}
	for _, share in private do
		table.insert(shares, share)
	end
	for _, share in shares do
		share._active = false
		share.connection:Disconnect()
		private[share.name] = nil
		self._nameCounts[share.name] -= 1
		if self._nameCounts[share.name] == 0 then
			self._nameCounts[share.name] = nil
			self._nameKinds[share.name] = nil
		end
	end
	self._private[player] = nil
end

function ServerClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, share in self._public do
		share._active = false
		share.connection:Disconnect()
	end
	for _, private in self._private do
		for _, share in private do
			share._active = false
			share.connection:Disconnect()
		end
	end
	table.clear(self._public)
	table.clear(self._private)
	self._playerRemoving:Disconnect()
	self._net:Destroy()
end

local Server = {}

function Server.new(namespace: string, options: ServerOptions?): ReplicationServer
	local opts: ServerOptions = options or {}
	local onError = opts.OnError or function(message: string)
		task.spawn(error, message, 0)
	end
	local maxBytes = opts.MaxValueBytes or DEFAULT_MAX_VALUE_BYTES
	if type(maxBytes) ~= "number" or not (maxBytes > 0) or maxBytes == math.huge then
		error(PREFIX .. "MaxValueBytes must be a positive number", 2)
	end
	local net = Network.Server.new(namespace, {
		Parent = opts.Parent,
		Logger = opts.Logger,
		OnError = onError,
	})
	local self = setmetatable({
		_net = net,
		_public = {},
		_private = {},
		_nameKinds = {},
		_nameCounts = {},
		_maxBytes = maxBytes,
		_clock = 0,
		_destroyed = false,
		_onError = onError,
	}, ServerClass)

	-- Server -> client only: no Schema, so client fires are rejected.
	self._update = net:Event("Update")
	self._fetch = net:Function("Fetch", { Schema = {}, RateLimit = { Count = 5, Per = 10 } })
	self._fetch:SetHandler(function(player: Player)
		return self:_snapshotFor(player)
	end)
	self._playerRemoving = Players.PlayerRemoving:Connect(function(player: Player)
		self:_forgetPlayer(player)
	end)
	return (self :: any) :: ReplicationServer
end

-- Client -------------------------------------------------------------------

-- Holds the client-side copies. Separate from the transport so it can be
-- tested without a running client.
local MirrorClass = {}
MirrorClass.__index = MirrorClass

function MirrorClass._entry(self: any, name: string): any
	local entry = self._entries[name]
	if entry == nil then
		local value = State.new(nil)
		entry = {
			value = value,
			readOnly = State.select(value, function(current)
				return current
			end),
			version = 0,
		}
		self._entries[name] = entry
	end
	return entry
end

--- Applies an update unless a newer version was already applied.
function MirrorClass.Apply(self: any, name: any, value: any, version: any)
	if type(name) ~= "string" or type(version) ~= "number" then
		return
	end
	local entry = self:_entry(name)
	if version <= entry.version then
		return
	end
	entry.version = version
	entry.value:Set(value)
end

function MirrorClass.Get(self: any, name: string): any
	checkName(name, 3)
	return self:_entry(name).readOnly
end

function MirrorClass.Destroy(self: any)
	for _, entry in self._entries do
		entry.readOnly:Destroy()
		entry.value:Destroy()
	end
	table.clear(self._entries)
end

local function newMirror(): any
	return setmetatable({ _entries = {} }, MirrorClass)
end

local ClientClass = {}
ClientClass.__index = ClientClass

--- A read-only state that follows the server's value (nil until known).
function ClientClass.Get(self: any, name: string): any
	return self._mirror:Get(name)
end

function ClientClass.Observe(self: any, name: string, callback: (any) -> ()): any
	return self._mirror:Get(name):Observe(callback)
end

function ClientClass.Destroy(self: any)
	self._net:Destroy()
	self._mirror:Destroy()
end

local Client = {}

--- Connects to a replicator and loads the initial snapshot. Yields.
function Client.new(namespace: string, options: ClientOptions?): ReplicationClient
	local net = Network.Client.new(namespace, options)
	local mirror = newMirror()
	local self = setmetatable({ _net = net, _mirror = mirror }, ClientClass)

	-- Listen before fetching so updates sent during the fetch are kept.
	net:Event("Update"):Connect(function(name, value, version)
		mirror:Apply(name, value, version)
	end)

	local timeout = if options and options.Timeout then options.Timeout else 10
	local ok, snapshot = net:Function("Fetch", { Timeout = timeout }):Invoke()
	if not ok then
		error(PREFIX .. ("Initial sync for '%s' failed: %s"):format(namespace, tostring(snapshot)), 2)
	end
	if type(snapshot) == "table" then
		for name, entry in snapshot do
			if type(entry) == "table" then
				mirror:Apply(name, entry[1], entry[2])
			end
		end
	end
	return (self :: any) :: ReplicationClient
end

return table.freeze({
	Server = table.freeze(Server),
	Client = table.freeze(Client),
	_newMirror = newMirror,
})
