--!strict
--[=[
	Constella.Network.Server

	Server-owned remotes. Only the server creates remotes; each Server owns
	one namespace folder (ReplicatedStorage.ConstellaRemotes.<Namespace>),
	and a second Server for the same namespace is refused.

	Every request from a client passes these gates, in order, before your
	handler runs:
	  1. NotAccepted      - the endpoint has no Schema (server-to-client only)
	  2. RateLimited      - per-player token bucket, per endpoint
	  3. PayloadTooLarge  - size / depth / value-count limits
	  4. InvalidArguments - Schema validators (extra arguments are rejected)
	  5. Unauthorized     - your Authorize(player, ...) hook
	Rejected requests are dropped (events) or answered with a generic code
	(functions). The detailed reason stays on the server: it is counted in
	GetStats(), passed to OnReject and logged when a Logger is given.

	The server never calls InvokeClient: a client could hang it forever.
	Send data to clients with events.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Signal)
local Check = require(script.Parent.Check)
local Payload = require(script.Parent.Payload)
local RateLimiter = require(script.Parent.RateLimiter)

export type RejectReason =
	"NotAccepted"
	| "RateLimited"
	| "PayloadTooLarge"
	| "InvalidArguments"
	| "Unauthorized"
	| "NoHandler"
	| "HandlerError"

export type EndpointConfig = {
	--- Validators for each argument the client may send. Without a Schema,
	--- an Event only goes from server to client and client fires are rejected.
	Schema: { Check.Validator }?,
	--- Per player, per endpoint. `false` disables rate limiting.
	RateLimit: (RateLimiter.Config | boolean)?,
	--- Defaults to 4096.
	MaxPayloadBytes: number?,
	--- Return true to allow. Errors count as a rejection and are reported.
	Authorize: ((player: Player, ...any) -> boolean)?,
	--- Events only: use an UnreliableRemoteEvent.
	Unreliable: boolean?,
}

export type ServerOptions = {
	--- Where the namespace folder is created. Defaults to
	--- ReplicatedStorage.ConstellaRemotes.
	Parent: Instance?,
	OnReject: ((player: Player, endpoint: string, reason: RejectReason, detail: string?) -> ())?,
	--- Receives handler and Authorize errors. Defaults to re-raising on a new thread.
	OnError: ((message: string) -> ())?,
	--- A Constella.Debug logger; rejections are logged at Warn.
	Logger: any?,
	--- Time source for rate limiting (tests). Defaults to os.clock.
	Clock: (() -> number)?,
}

export type EndpointStats = {
	Accepted: number,
	Rejected: { [string]: number },
}

export type ServerEvent = {
	Name: string,
	Connect: (self: ServerEvent, handler: (player: Player, ...any) -> ()) -> Signal.Connection,
	Fire: (self: ServerEvent, player: Player, ...any) -> (),
	FireAll: (self: ServerEvent, ...any) -> (),
	FireList: (self: ServerEvent, players: { Player }, ...any) -> (),
	FireExcept: (self: ServerEvent, except: Player, ...any) -> (),
	Destroy: (self: ServerEvent) -> (),
}

export type ServerFunction = {
	Name: string,
	SetHandler: (self: ServerFunction, handler: (player: Player, ...any) -> ...any) -> (),
	Destroy: (self: ServerFunction) -> (),
}

export type Server = {
	Namespace: string,
	Folder: Folder,
	Event: (self: Server, name: string, config: EndpointConfig?) -> ServerEvent,
	Function: (self: Server, name: string, config: EndpointConfig) -> ServerFunction,
	GetStats: (self: Server) -> { [string]: EndpointStats },
	Destroy: (self: Server) -> (),
}

local PREFIX = "[Constella.Network] "
local ROOT_FOLDER_NAME = "ConstellaRemotes"
local DEFAULT_RATE_LIMIT: RateLimiter.Config = { Count = 30, Per = 1 }
local DEFAULT_MAX_PAYLOAD_BYTES = 4096
local NAME_PATTERN = "^[%w_]+$"

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

local function checkName(kind: string, name: any, level: number)
	if type(name) ~= "string" or #name == 0 or #name > 50 or not string.match(name, NAME_PATTERN) then
		error(
			PREFIX .. ("%s name must be 1-50 letters, digits or underscores, got %s"):format(kind, tostring(name)),
			level
		)
	end
end

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

-- Shared endpoint logic --------------------------------------------------

local function reject(endpoint: any, player: any, reason: RejectReason, detail: string?)
	local server = endpoint._server
	local stats = endpoint._stats
	stats.Rejected[reason] = (stats.Rejected[reason] or 0) + 1
	if server._onReject then
		local ok, err = pcall(server._onReject, player, endpoint.Name, reason, detail)
		if not ok then
			server._onError(PREFIX .. "OnReject hook failed: " .. tostring(err))
		end
	end
	if server._logger then
		server._logger:Warn("Rejected request", {
			Namespace = server.Namespace,
			Endpoint = endpoint.Name,
			Player = if typeof(player) == "Instance" then player.Name else tostring(player),
			Reason = reason,
			Detail = detail,
		})
	end
end

-- Runs the security gates. Returns true when the request may proceed,
-- otherwise false and the rejection reason.
local function admit(endpoint: any, player: any, ...: any): (boolean, RejectReason?)
	local config = endpoint._config
	local schema = config.Schema
	if schema == nil then
		reject(endpoint, player, "NotAccepted", "endpoint does not accept client requests")
		return false, "NotAccepted"
	end
	if endpoint._limiter and not endpoint._limiter:Consume(player) then
		reject(endpoint, player, "RateLimited", nil)
		return false, "RateLimited"
	end
	-- Measuring only reads the values a client sent, which can't carry
	-- metatables, so it can't raise. (The whole check also runs inside a
	-- protected call in _receive/_invoke.)
	local size, sizeReason = Payload.measure(endpoint._payloadLimits, ...)
	if size == nil then
		reject(endpoint, player, "PayloadTooLarge", sizeReason)
		return false, "PayloadTooLarge"
	end
	-- Validators are user code (custom functions, Check.refine predicates).
	-- An error in one is a server bug: report it and reject the request.
	local checked, valid, invalidReason = xpcall(Check.arguments, traceback, schema, ...)
	if not checked then
		endpoint._server._onError(
			PREFIX .. ("A Schema validator for '%s' raised an error: %s"):format(endpoint.Name, tostring(valid))
		)
		reject(endpoint, player, "InvalidArguments", "a validator raised an error")
		return false, "InvalidArguments"
	end
	if not valid then
		reject(endpoint, player, "InvalidArguments", invalidReason)
		return false, "InvalidArguments"
	end
	local authorize = config.Authorize
	if authorize then
		local ok, allowed = xpcall(authorize, traceback, player, ...)
		if not ok then
			endpoint._server._onError(
				PREFIX .. ("Authorize for '%s' failed: %s"):format(endpoint.Name, tostring(allowed))
			)
			reject(endpoint, player, "Unauthorized", "Authorize raised an error")
			return false, "Unauthorized"
		end
		if allowed ~= true then
			reject(endpoint, player, "Unauthorized", nil)
			return false, "Unauthorized"
		end
	end
	endpoint._stats.Accepted += 1
	return true
end

local function validateConfig(kind: string, name: string, config: any, level: number)
	if config == nil then
		return
	end
	if type(config) ~= "table" then
		error(PREFIX .. ("%s '%s' config must be a table"):format(kind, name), level)
	end
	local schema = config.Schema
	if schema ~= nil then
		if type(schema) ~= "table" then
			error(PREFIX .. ("%s '%s' Schema must be an array of validators"):format(kind, name), level)
		end
		for index, validator in schema do
			if type(index) ~= "number" or type(validator) ~= "function" then
				error(PREFIX .. ("%s '%s' Schema must be an array of validators"):format(kind, name), level)
			end
		end
	end
	local rate = config.RateLimit
	if rate ~= nil and rate ~= false and type(rate) ~= "table" then
		error(PREFIX .. ("%s '%s' RateLimit must be { Count, Per } or false"):format(kind, name), level)
	end
	local maxBytes = config.MaxPayloadBytes
	if maxBytes ~= nil and (type(maxBytes) ~= "number" or not (maxBytes > 0) or maxBytes == math.huge) then
		error(PREFIX .. ("%s '%s' MaxPayloadBytes must be a positive number"):format(kind, name), level)
	end
	if config.Authorize ~= nil and type(config.Authorize) ~= "function" then
		error(PREFIX .. ("%s '%s' Authorize must be a function"):format(kind, name), level)
	end
end

local function createEndpoint(
	server: any,
	class: any,
	kind: string,
	name: string,
	config: any,
	className: string,
	level: number
): any
	if server._destroyed then
		error(PREFIX .. "This Server has been destroyed", level)
	end
	checkName(kind, name, level + 1)
	if server._endpoints[name] then
		error(PREFIX .. ("'%s' already exists in namespace '%s'"):format(name, server.Namespace), level)
	end
	validateConfig(kind, name, config, level + 1)
	local resolved = config or {}

	local limiter = nil
	if resolved.RateLimit ~= false then
		local rate = if type(resolved.RateLimit) == "table" then resolved.RateLimit else DEFAULT_RATE_LIMIT
		local ok, result = pcall(RateLimiter.new, rate, server._clock)
		if not ok then
			error(PREFIX .. ("%s '%s': %s"):format(kind, name, tostring(result)), level)
		end
		limiter = result
	end

	local remote = Instance.new(className)
	remote.Name = name

	local endpoint = setmetatable({
		Name = name,
		_server = server,
		_config = resolved,
		_limiter = limiter,
		_payloadLimits = { MaxBytes = resolved.MaxPayloadBytes or DEFAULT_MAX_PAYLOAD_BYTES },
		_remote = remote,
		_destroyed = false,
	}, class)

	local stats = { Accepted = 0, Rejected = {} }
	endpoint._stats = stats
	server._endpoints[name] = endpoint
	server._stats[name] = stats
	return endpoint
end

-- Events -----------------------------------------------------------------

local ServerEventClass = {}
ServerEventClass.__index = ServerEventClass

--- Internal: processes one client request. Called by OnServerEvent, and by
--- tests with stand-in players.
function ServerEventClass._receive(self: any, player: any, ...: any)
	if self._destroyed then
		return
	end
	-- Nothing a client sends may raise an error out of here.
	local ok, admitted = pcall(admit :: any, self, player, ...)
	if not ok then
		self._server._onError(
			PREFIX .. ("Checking a request for '%s' failed: %s"):format(self.Name, tostring(admitted))
		)
		return
	end
	if admitted then
		self._signal:Fire(player, ...)
	end
end

--- Connects a handler for validated client requests.
function ServerEventClass.Connect(self: any, handler: (Player, ...any) -> ()): Signal.Connection
	return self._signal:Connect(handler)
end

function ServerEventClass.Fire(self: any, player: Player, ...: any)
	if not isPlayer(player) then
		error(PREFIX .. ("Fire expects a Player, got %s"):format(typeof(player)), 2)
	end
	self._remote:FireClient(player, ...)
end

function ServerEventClass.FireAll(self: any, ...: any)
	self._remote:FireAllClients(...)
end

function ServerEventClass.FireList(self: any, players: { Player }, ...: any)
	for _, player in players do
		if isPlayer(player) then
			self._remote:FireClient(player, ...)
		end
	end
end

function ServerEventClass.FireExcept(self: any, except: Player, ...: any)
	for _, player in Players:GetPlayers() do
		if player ~= except then
			self._remote:FireClient(player, ...)
		end
	end
end

function ServerEventClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._signal:Destroy()
	self._connection:Disconnect()
	self._remote:Destroy()
	self._server._endpoints[self.Name] = nil
end

-- Functions --------------------------------------------------------------

local ServerFunctionClass = {}
ServerFunctionClass.__index = ServerFunctionClass

--- Internal: processes one client invocation. Returns (true, ...results) or
--- (false, code) where code is "RateLimited", "Rejected", "Unavailable" or
--- "ServerError". Called by OnServerInvoke, and by tests.
function ServerFunctionClass._invoke(self: any, player: any, ...: any): ...any
	if self._destroyed then
		return false, "Unavailable"
	end
	-- Nothing a client sends may raise an error back to the client.
	local ok, admitted, reason = pcall(admit, self, player, ...)
	if not ok then
		self._server._onError(
			PREFIX .. ("Checking a request for '%s' failed: %s"):format(self.Name, tostring(admitted))
		)
		return false, "Rejected"
	end
	if not admitted then
		return false, if reason == "RateLimited" then "RateLimited" else "Rejected"
	end
	local handler = self._handler
	if handler == nil then
		reject(self, player, "NoHandler", nil)
		return false, "Unavailable"
	end
	local results = table.pack(xpcall(handler, traceback, player, ...))
	if not results[1] then
		self._server._onError(PREFIX .. ("Handler for '%s' failed: %s"):format(self.Name, tostring(results[2])))
		reject(self, player, "HandlerError", nil)
		return false, "ServerError"
	end
	return true, table.unpack(results, 2, results.n)
end

--- Sets the function that answers validated client invocations. It may
--- yield. Its return values are sent back to the client.
function ServerFunctionClass.SetHandler(self: any, handler: (Player, ...any) -> ...any)
	if type(handler) ~= "function" then
		error(PREFIX .. ("SetHandler expects a function, got %s"):format(typeof(handler)), 2)
	end
	if self._handler ~= nil then
		error(PREFIX .. ("'%s' already has a handler"):format(self.Name), 2)
	end
	self._handler = handler
end

function ServerFunctionClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._remote.OnServerInvoke = nil
	self._remote:Destroy()
	self._server._endpoints[self.Name] = nil
end

-- Server -----------------------------------------------------------------

local ServerClass = {}
ServerClass.__index = ServerClass

--- Creates a RemoteEvent. Pass a Schema to accept client fires.
function ServerClass.Event(self: any, name: string, config: EndpointConfig?): ServerEvent
	local className = if config and config.Unreliable then "UnreliableRemoteEvent" else "RemoteEvent"
	local endpoint = createEndpoint(self, ServerEventClass, "Event", name, config, className, 3)
	endpoint._signal = Signal.new({
		OnError = function(message: string)
			self._onError(PREFIX .. ("Handler for '%s' failed: %s"):format(name, message))
		end,
	})
	endpoint._connection = endpoint._remote.OnServerEvent:Connect(function(player: Player, ...: any)
		endpoint:_receive(player, ...)
	end)
	endpoint._remote.Parent = self.Folder
	return endpoint
end

--- Creates a RemoteFunction answered by SetHandler. A Schema is required.
function ServerClass.Function(self: any, name: string, config: EndpointConfig): ServerFunction
	if type(config) ~= "table" or config.Schema == nil then
		error(PREFIX .. ("Function '%s' needs a Schema (use {} for no arguments)"):format(tostring(name)), 2)
	end
	local endpoint = createEndpoint(self, ServerFunctionClass, "Function", name, config, "RemoteFunction", 3)
	endpoint._remote.OnServerInvoke = function(player: Player, ...: any)
		return endpoint:_invoke(player, ...)
	end
	endpoint._remote.Parent = self.Folder
	return endpoint
end

--- Accepted / rejected counts per endpoint (a copy).
function ServerClass.GetStats(self: any): { [string]: EndpointStats }
	local copy = {}
	for name, stats in self._stats do
		copy[name] = { Accepted = stats.Accepted, Rejected = table.clone(stats.Rejected) }
	end
	return copy
end

--- Internal: drops per-player state. Called on PlayerRemoving.
function ServerClass._forgetPlayer(self: any, player: any)
	for _, endpoint in self._endpoints do
		if endpoint._limiter then
			endpoint._limiter:Forget(player)
		end
	end
end

function ServerClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	local endpoints = {}
	for _, endpoint in self._endpoints do
		table.insert(endpoints, endpoint)
	end
	for _, endpoint in endpoints do
		endpoint:Destroy()
	end
	self._destroyed = true
	self._playerRemoving:Disconnect()
	self.Folder:Destroy()
end

local Server = {}

--- Creates the server side of a namespace. Call once per namespace.
function Server.new(namespace: string, options: ServerOptions?): Server
	if RunService:IsRunning() and not RunService:IsServer() then
		error(PREFIX .. "Network.Server can only be used on the server", 2)
	end
	checkName("Namespace", namespace, 3)
	if options ~= nil and type(options) ~= "table" then
		error(PREFIX .. "Options must be a table", 2)
	end
	local opts: ServerOptions = options or {}

	local parent = opts.Parent
	if parent == nil then
		local root = ReplicatedStorage:FindFirstChild(ROOT_FOLDER_NAME)
		if root == nil then
			root = Instance.new("Folder")
			root.Name = ROOT_FOLDER_NAME
			root.Parent = ReplicatedStorage
		end
		parent = root
	end
	if (parent :: Instance):FindFirstChild(namespace) then
		error(PREFIX .. ("Namespace '%s' is already owned by another Server"):format(namespace), 2)
	end

	local folder = Instance.new("Folder")
	folder.Name = namespace

	local self = setmetatable({
		Namespace = namespace,
		Folder = folder,
		_endpoints = {},
		_stats = {},
		_destroyed = false,
		_clock = opts.Clock,
		_logger = opts.Logger,
		_onReject = opts.OnReject,
		_onError = opts.OnError or function(message: string)
			task.spawn(error, message, 0)
		end,
	}, ServerClass)

	self._playerRemoving = Players.PlayerRemoving:Connect(function(player: Player)
		self:_forgetPlayer(player)
	end)

	folder.Parent = parent
	return (self :: any) :: Server
end

return table.freeze(Server)
