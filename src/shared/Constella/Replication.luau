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
	- With `Delta = true`, a change from one table to another is sent as a
	  patch (only the keys that changed, recursively) whenever that is
	  smaller than the whole value. Patches are built from arrays and
	  string-keyed fields, so they survive RemoteEvent serialization. A
	  client that receives a patch before the value it builds on (during
	  the initial sync) keeps it until that value arrives; if it can't be
	  applied, the client fetches a fresh snapshot. Use it for tables that
	  are arrays or string-keyed dictionaries, which is what remotes carry
	  faithfully anyway.
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
	--- Send table changes as patches when that is smaller. Defaults to false.
	Delta: boolean?,
}

export type ClientOptions = {
	Parent: Instance?,
	Timeout: number?,
}

export type Share = {
	Name: string,
	Stop: (self: Share) -> (),
}

export type ReplicationServer = {
	Share: (self: ReplicationServer, name: string, state: any) -> Share,
	ShareWith: (self: ReplicationServer, player: Player, name: string, state: any) -> Share,
	Destroy: (self: ReplicationServer) -> (),
}

export type ReplicationClient = {
	Get: (self: ReplicationClient, name: string) -> State.Computed<any>,
	Observe: (self: ReplicationClient, name: string, callback: (value: any) -> ()) -> State.Connection,
	Destroy: (self: ReplicationClient) -> (),
}

local PREFIX = "[Constella.Replication] "
local DEFAULT_MAX_VALUE_BYTES = 16384

local function checkName(name: any, level: number)
	if type(name) ~= "string" or #name == 0 or #name > 50 then
		error(PREFIX .. "Share name must be a string of 1-50 characters", level)
	end
end

-- Delta patches ---------------------------------------------------------------
-- A patch turns one table into another:
--   k, v  parallel arrays: keys set to a new value
--   r     array: keys removed
--   n, p  parallel arrays: keys whose table value changed, with a patch each
-- Missing fields mean "nothing of that kind". Only arrays and string keys
-- are used, so a patch arrives intact through a RemoteEvent.
local MAX_PATCH_DEPTH = 16

-- A copy of a replicable value that the server's own code can't reach, so
-- mutating a shared table in place can't hide a change from the next diff.
local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = table.clone(value)
	for key, item in copy do
		if type(item) == "table" then
			copy[key] = deepCopy(item)
		end
	end
	return copy
end

-- Compares `old` (the private copy of what clients have) with the game's
-- new value. Returns the patch (nil if nothing changed) and the new private
-- copy, which reuses every unchanged part of `old`, so an update only walks
-- the value once and only copies what changed.
local function diffCopy(old: { [any]: any }, new: { [any]: any }, depth: number): ({ [string]: any }?, { [any]: any })
	local patch: { [string]: any }? = nil
	local changedTables: { [any]: any }? = nil
	for key, value in new do
		local previous = old[key]
		if type(value) == "table" then
			if type(previous) == "table" and depth < MAX_PATCH_DEPTH then
				local nested, nestedCopy = diffCopy(previous, value, depth + 1)
				if nested then
					local target: { [string]: any } = patch or {}
					patch = target
					if target.n == nil then
						target.n, target.p = {}, {}
					end
					table.insert(target.n, key)
					table.insert(target.p, nested)
					local copies = changedTables or {}
					changedTables = copies
					copies[key] = nestedCopy
				end
			else
				local target: { [string]: any } = patch or {}
				patch = target
				if target.k == nil then
					target.k, target.v = {}, {}
				end
				table.insert(target.k, key)
				table.insert(target.v, value)
				local copies = changedTables or {}
				changedTables = copies
				copies[key] = deepCopy(value)
			end
		elseif previous ~= value then
			local target: { [string]: any } = patch or {}
			patch = target
			if target.k == nil then
				target.k, target.v = {}, {}
			end
			table.insert(target.k, key)
			table.insert(target.v, value)
		end
	end
	for key in old do
		if new[key] == nil then
			local target: { [string]: any } = patch or {}
			patch = target
			if target.r == nil then
				target.r = {}
			end
			table.insert(target.r, key)
		end
	end
	if patch == nil then
		return nil, old
	end
	local copy = table.clone(new)
	for key, value in copy do
		if type(value) == "table" then
			copy[key] = if changedTables and changedTables[key] ~= nil then changedTables[key] else old[key]
		end
	end
	return patch, copy
end

-- Returns a new table: `base` with `patch` applied (unchanged nested tables
-- are shared), or nil if the patch is malformed.
local function applyPatch(base: { [any]: any }, patch: any, depth: number): { [any]: any }?
	if type(patch) ~= "table" or depth > MAX_PATCH_DEPTH then
		return nil
	end
	local result = table.clone(base)
	local keys, values = patch.k, patch.v
	if keys ~= nil then
		if type(keys) ~= "table" or type(values) ~= "table" then
			return nil
		end
		for index, key in keys do
			result[key] = values[index]
		end
	end
	local removed = patch.r
	if removed ~= nil then
		if type(removed) ~= "table" then
			return nil
		end
		for _, key in removed do
			result[key] = nil
		end
	end
	local nestedKeys, nestedPatches = patch.n, patch.p
	if nestedKeys ~= nil then
		if type(nestedKeys) ~= "table" or type(nestedPatches) ~= "table" then
			return nil
		end
		for index, key in nestedKeys do
			local current = result[key]
			local updated =
				applyPatch(if type(current) == "table" then current else {}, nestedPatches[index], depth + 1)
			if updated == nil then
				return nil
			end
			result[key] = updated
		end
	end
	return result
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

-- Returns nil and the estimated size when `value` may be sent, otherwise
-- why it may not.
function ServerClass._validate(self: any, value: any): (string?, number?)
	local size, reason = Network.Payload.measureReplicable(self._limits, value)
	if size == nil then
		return reason, nil
	end
	return nil, size
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
	local reason, size = self:_validate(value)
	if reason then
		self:_report(("'%s' was not replicated: %s"):format(share.name, reason))
		return
	end
	local sent, base = share.sent, share.version
	share.value = value
	share.version = self:_nextVersion()
	if self._delta then
		-- `sent` is what clients hold, at version `base`: a private copy,
		-- because the game may have mutated the old table in place before
		-- setting a new one.
		if type(sent) == "table" and type(value) == "table" then
			local patch, copy = diffCopy(sent, value, 1)
			share.sent = copy
			-- An empty patch still moves clients to the new version (and to a
			-- new table, like the server's state).
			local message = patch or {}
			local patchSize = Network.Payload.measure(self._limits, message)
			if patchSize ~= nil and patchSize < (size :: number) then
				self._update:FireList(self:_audience(share), share.name, message, share.version, false, base)
				return
			end
		else
			share.sent = deepCopy(value)
		end
	end
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
		-- With Delta: a private copy of what clients were last sent.
		sent = if self._delta then deepCopy(initial) else nil,
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
	if opts.Delta ~= nil and type(opts.Delta) ~= "boolean" then
		error(PREFIX .. "Delta must be a boolean", 2)
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
		_limits = table.freeze({ MaxBytes = maxBytes, MaxDepth = 16, MaxNodes = 4096 }),
		_delta = opts.Delta == true,
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

-- Patches that arrived before the value they build on, per name, at most
-- this many; beyond that the client resyncs instead.
local MAX_HELD_PATCHES = 64

function MirrorClass._requestResync(self: any)
	local resync = self._onResync
	if resync then
		resync()
	end
end

-- Applies `patch` to the entry's current value. Returns false if it can't.
local function applyTo(entry: any, patch: any, version: number): boolean
	local current = entry.value:Get()
	local updated = if type(current) == "table" then applyPatch(current, patch, 1) else nil
	if updated == nil then
		return false
	end
	entry.version = version
	entry.value:Set(updated)
	return true
end

-- Applies held patches that now build on the current version, in order,
-- and drops the ones that are out of date.
function MirrorClass._drain(self: any, entry: any)
	local held = entry.held
	if held == nil then
		return
	end
	while true do
		local found = nil
		for index, item in held do
			if item.base == entry.version then
				found = index
				break
			end
		end
		if found == nil then
			break
		end
		local item = table.remove(held, found)
		if not applyTo(entry, item.patch, item.version) then
			entry.held = nil
			self:_requestResync()
			return
		end
	end
	for index = #held, 1, -1 do
		if held[index].version <= entry.version then
			table.remove(held, index)
		end
	end
	if #held == 0 then
		entry.held = nil
	end
end

--- Applies an update unless a newer version was already applied. With
--- `base`, `value` is a patch from version `base` to `version`.
function MirrorClass.Apply(self: any, name: any, value: any, version: any, _removed: any?, base: any?)
	if type(name) ~= "string" or type(version) ~= "number" then
		return
	end
	local entry = self:_entry(name)
	if version <= entry.version then
		return
	end
	if base == nil then
		entry.version = version
		entry.value:Set(value)
	elseif type(base) ~= "number" then
		return
	elseif base == entry.version then
		if not applyTo(entry, value, version) then
			self:_requestResync()
			return
		end
	elseif base > entry.version then
		-- Arrived before the value it builds on (for example before the
		-- initial snapshot). Keep it until that value arrives.
		local held = entry.held or {}
		entry.held = held
		if #held >= MAX_HELD_PATCHES then
			entry.held = nil
			self:_requestResync()
			return
		end
		table.insert(held, { patch = value, version = version, base = base })
		return
	else
		-- Builds on a value this client never had.
		self:_requestResync()
		return
	end
	self:_drain(entry)
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
	self._mirror._onResync = nil
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
	net:Event("Update"):Connect(function(name, value, version, removed, base)
		mirror:Apply(name, value, version, removed, base)
	end)

	local timeout = if options and options.Timeout then options.Timeout else 10
	local fetch = net:Function("Fetch", { Timeout = timeout })
	local function applySnapshot(snapshot: any)
		if type(snapshot) == "table" then
			for name, entry in snapshot do
				if type(entry) == "table" then
					mirror:Apply(name, entry[1], entry[2])
				end
			end
		end
	end

	-- A delta patch that can't be applied triggers one snapshot fetch at a
	-- time. (The server rate-limits fetches; if one is refused, the next
	-- patch that can't be applied tries again.)
	local resyncing = false
	mirror._onResync = function()
		if resyncing then
			return
		end
		resyncing = true
		task.spawn(function()
			local fetched, latest = fetch:Invoke()
			resyncing = false
			if fetched then
				applySnapshot(latest)
			end
		end)
	end

	local ok, snapshot = fetch:Invoke()
	if not ok then
		error(PREFIX .. ("Initial sync for '%s' failed: %s"):format(namespace, tostring(snapshot)), 2)
	end
	applySnapshot(snapshot)
	return (self :: any) :: ReplicationClient
end

return table.freeze({
	Server = table.freeze(Server),
	Client = table.freeze(Client),
	_newMirror = newMirror,
	_diff = function(old: any, new: any, depth: number): any
		return (diffCopy(old, new, depth))
	end,
	_applyPatch = applyPatch,
})
