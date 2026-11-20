--!strict
--[=[
	Constella.Network.Client

	Looks up remotes that the server created. A client can never create
	remotes, and it only sees namespaces the server chose to expose.

	Functions never hang: Invoke returns (false, "Timeout") after the
	configured timeout, and (false, code) when the server rejected the call.

	A timed-out InvokeServer cannot be cancelled from Luau (the engine owns
	that yield), so its thread stays suspended until the server answers or
	the client leaves. To keep that bounded, each function allows at most
	MaxInFlight calls (default 8) to be outstanding, counting timed-out ones
	that have not come back yet. Beyond that, Invoke returns
	(false, "TooManyRequests") immediately without contacting the server.
	Treat everything coming back from the server as display data; the server
	is the source of truth.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Contract = require(script.Parent.Contract)

export type ClientOptions = {
	--- Where to look for the namespace. Defaults to ReplicatedStorage.ConstellaRemotes.
	Parent: Instance?,
	--- Seconds to wait for remotes to replicate. Defaults to 10.
	Timeout: number?,
}

export type ClientEvent = {
	Name: string,
	Fire: (self: ClientEvent, ...any) -> (),
	Connect: (self: ClientEvent, handler: (...any) -> ()) -> RBXScriptConnection,
	Destroy: (self: ClientEvent) -> (),
}

export type ClientFunction = {
	Name: string,
	--- Returns (true, ...results) or (false, code). Codes: "Timeout",
	--- "TooManyRequests", "RateLimited", "Rejected", "Unavailable",
	--- "ServerError", "NetworkError".
	Invoke: (self: ClientFunction, ...any) -> (boolean, ...any),
	--- Calls that have not returned from the server yet (including timed-out ones).
	GetInFlight: (self: ClientFunction) -> number,
}

export type FunctionOptions = {
	--- Seconds before Invoke gives up. Defaults to 10.
	Timeout: number?,
	--- Maximum outstanding calls, including timed-out ones that have not
	--- returned yet. Defaults to 8.
	MaxInFlight: number?,
}

--- A contract event on the client: `ClientEvent` with typed arguments.
export type TypedClientEvent<T...> = {
	Name: string,
	Fire: (self: TypedClientEvent<T...>, T...) -> (),
	Connect: (self: TypedClientEvent<T...>, handler: (T...) -> ()) -> RBXScriptConnection,
	Destroy: (self: TypedClientEvent<T...>) -> (),
}

--- A contract function on the client: `ClientFunction` with typed
--- arguments. Results stay `...any`: on failure the second value is an
--- error code, not the first result.
export type TypedClientFunction<A..., R...> = {
	Name: string,
	Invoke: (self: TypedClientFunction<A..., R...>, A...) -> (boolean, ...any),
	GetInFlight: (self: TypedClientFunction<A..., R...>) -> number,
}

export type Client = {
	Namespace: string,
	Event: (self: Client, name: string) -> ClientEvent,
	Function: (self: Client, name: string, options: FunctionOptions?) -> ClientFunction,
	--- The event a contract describes, typed.
	EventOf: <T...>(self: Client, endpoint: Contract.Event<T...>) -> TypedClientEvent<T...>,
	--- The function a contract describes, typed.
	FunctionOf: <A..., R...>(
		self: Client,
		endpoint: Contract.Function<A..., R...>,
		options: FunctionOptions?
	) -> TypedClientFunction<A..., R...>,
	Destroy: (self: Client) -> (),
}

local PREFIX = "[Constella.Network] "
local ROOT_FOLDER_NAME = "ConstellaRemotes"
local DEFAULT_TIMEOUT = 10
local DEFAULT_MAX_IN_FLIGHT = 8

local function checkTimeout(value: any, level: number): number
	if value == nil then
		return DEFAULT_TIMEOUT
	end
	if type(value) ~= "number" or not (value > 0) or value == math.huge then
		error(PREFIX .. "Timeout must be a positive number of seconds", level)
	end
	return value
end

-- Resumes the calling thread unless it was cancelled while it waited.
local function resume(thread: thread, ...: any)
	if coroutine.status(thread) == "suspended" then
		task.spawn(thread, ...)
	end
end

-- `level` is the error level, counted from waitFor.
local function waitFor(parent: Instance, name: string, timeout: number, what: string, level: number): Instance
	local child = parent:WaitForChild(name, timeout)
	if child == nil then
		error(
			PREFIX
				.. ("%s '%s' was not found in %s after %ss"):format(what, name, parent:GetFullName(), tostring(timeout)),
			level
		)
	end
	return child :: Instance
end

local ClientEventClass = {}
ClientEventClass.__index = ClientEventClass

function ClientEventClass.Fire(self: any, ...: any)
	self._remote:FireServer(...)
end

-- Drops connections the game already disconnected itself, so an event that
-- is connected and disconnected over and over (once per round, say) doesn't
-- keep every old connection. Runs when the list has doubled since the last
-- pass, so it costs O(1) per Connect on average.
local function pruneConnections(self: any)
	local connections = self._connections
	local kept = 0
	for index = 1, #connections do
		local connection = connections[index]
		if connection.Connected then
			kept += 1
			connections[kept] = connection
		end
	end
	for index = #connections, kept + 1, -1 do
		connections[index] = nil
	end
	self._pruneAt = math.max(16, kept * 2)
end

function ClientEventClass.Connect(self: any, handler: (...any) -> ()): RBXScriptConnection
	if type(handler) ~= "function" then
		error(PREFIX .. ("Connect expects a function, got %s"):format(typeof(handler)), 2)
	end
	local connection = self._remote.OnClientEvent:Connect(handler)
	local connections = self._connections
	table.insert(connections, connection)
	if #connections >= self._pruneAt then
		pruneConnections(self)
	end
	-- Registered with the client while it has connections, so
	-- client:Destroy() disconnects them, even after an earlier Destroy.
	self._client._events[self] = true
	return connection
end

--- Disconnects every handler connected through this event.
function ClientEventClass.Destroy(self: any)
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._pruneAt = 16
	-- Nothing left to disconnect, so the client no longer needs to hold it.
	self._client._events[self] = nil
end

local ClientFunctionClass = {}
ClientFunctionClass.__index = ClientFunctionClass

function ClientFunctionClass.Invoke(self: any, ...: any): (boolean, ...any)
	if self._inFlight >= self._maxInFlight then
		return false, "TooManyRequests"
	end
	self._inFlight += 1

	local thread = coroutine.running()
	local finished = false
	local remote = self._remote
	local args = table.pack(...)

	-- Deferred so both callbacks can only resume this thread after it yields.
	task.defer(function()
		local results = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n)))
		-- The call is no longer outstanding, whether or not the caller timed out.
		self._inFlight -= 1
		if finished then
			return
		end
		finished = true
		resume(thread, results)
	end)
	local timer = task.delay(self._timeout, function()
		if finished then
			return
		end
		finished = true
		resume(thread, nil)
	end)

	local results: any = coroutine.yield()
	if results == nil then
		return false, "Timeout"
	end
	task.cancel(timer)
	if not results[1] then
		return false, "NetworkError"
	end
	if results[2] == true then
		return true, table.unpack(results, 3, results.n)
	end
	if results[2] == false and type(results[3]) == "string" then
		return false, results[3]
	end
	return false, "NetworkError"
end

function ClientFunctionClass.GetInFlight(self: any): number
	return self._inFlight
end

local function newFunction(name: string, remote: any, options: FunctionOptions?, level: number): ClientFunction
	local timeout = checkTimeout(if options then options.Timeout else nil, level + 1)
	local maxInFlight = if options and options.MaxInFlight ~= nil then options.MaxInFlight else DEFAULT_MAX_IN_FLIGHT
	if type(maxInFlight) ~= "number" or maxInFlight < 1 or maxInFlight % 1 ~= 0 or maxInFlight == math.huge then
		error(PREFIX .. "MaxInFlight must be a positive integer", level)
	end
	local fn = setmetatable({
		Name = name,
		_remote = remote,
		_timeout = timeout,
		_maxInFlight = maxInFlight,
		_inFlight = 0,
	}, ClientFunctionClass)
	return (fn :: any) :: ClientFunction
end

local ClientClass = {}
ClientClass.__index = ClientClass

-- `level` is the error level of the public method's caller, counted from
-- the public method (so 2 for a direct call).
local function findEvent(self: any, name: string, level: number): any
	local remote = waitFor(self._folder, name, self._timeout, "Remote", level + 2)
	if not (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then
		error(PREFIX .. ("'%s' is a %s, not an event"):format(name, remote.ClassName), level + 1)
	end
	-- The client only holds an event while it has connections (see Connect),
	-- so events that are looked up and dropped can be collected.
	return setmetatable(
		{ Name = name, _remote = remote, _connections = {}, _pruneAt = 16, _client = self },
		ClientEventClass
	)
end

local function findFunction(self: any, name: string, options: FunctionOptions?, level: number): any
	local remote = waitFor(self._folder, name, self._timeout, "Remote", level + 2)
	if not remote:IsA("RemoteFunction") then
		error(PREFIX .. ("'%s' is a %s, not a function"):format(name, remote.ClassName), level + 1)
	end
	return newFunction(name, remote, options, level + 2)
end

local function checkContract(self: any, endpoint: any, kind: "Event" | "Function", level: number)
	if not Contract.is(endpoint, kind) then
		error(PREFIX .. ("%sOf expects a Contract.%s from Contract.define"):format(kind, string.lower(kind)), level + 1)
	end
	if endpoint.Namespace ~= self.Namespace then
		error(
			PREFIX
				.. ("'%s' belongs to namespace '%s', not '%s'"):format(
					endpoint.Name,
					endpoint.Namespace,
					self.Namespace
				),
			level + 1
		)
	end
end

function ClientClass.Event(self: any, name: string): ClientEvent
	return findEvent(self, name, 2)
end

function ClientClass.Function(self: any, name: string, options: FunctionOptions?): ClientFunction
	return findFunction(self, name, options, 2)
end

--- The event a contract describes (the same object `Event` returns).
function ClientClass.EventOf(self: any, endpoint: any): any
	checkContract(self, endpoint, "Event", 2)
	return findEvent(self, endpoint.Name, 2)
end

--- The function a contract describes (the same object `Function` returns).
function ClientClass.FunctionOf(self: any, endpoint: any, options: FunctionOptions?): any
	checkContract(self, endpoint, "Function", 2)
	return findFunction(self, endpoint.Name, options, 2)
end

--- Disconnects every handler connected through this client.
function ClientClass.Destroy(self: any)
	local events = {}
	for event in self._events do
		table.insert(events, event)
	end
	for _, event in events do
		event:Destroy()
	end
end

local function newClient(namespace: string, folder: Instance, timeout: number): Client
	local self = setmetatable({
		Namespace = namespace,
		_folder = folder,
		_timeout = timeout,
		-- Events that have connections (event -> true).
		_events = {},
	}, ClientClass)
	return (self :: any) :: Client
end

local Client = {}

--- Connects to a namespace the server created. Yields until it replicates.
function Client.new(namespace: string, options: ClientOptions?): Client
	if RunService:IsRunning() and RunService:IsServer() then
		error(PREFIX .. "Network.Client is for LocalScripts; use Network.Server on the server", 2)
	end
	if type(namespace) ~= "string" or namespace == "" then
		error(PREFIX .. "Namespace must be a non-empty string", 2)
	end
	local timeout = checkTimeout(options and options.Timeout, 3)
	local parent = (options and options.Parent) or waitFor(ReplicatedStorage, ROOT_FOLDER_NAME, timeout, "Folder", 3)
	local folder = waitFor(parent, namespace, timeout, "Namespace", 3)
	return newClient(namespace, folder, timeout)
end

--- Internal: a client for `folder` without the environment check, so tests
--- running on a server can look up remotes and exercise Destroy.
function Client._newClient(namespace: string, folder: Instance, timeout: number?): Client
	return newClient(namespace, folder, timeout or DEFAULT_TIMEOUT)
end

--- Internal: an event of `client` over any object with an OnClientEvent
--- signal (a BindableEvent's Event, in tests), since a server can't connect
--- to a real RemoteEvent's OnClientEvent.
function Client._newEvent(client: Client, name: string, remote: any): ClientEvent
	return setmetatable(
		{ Name = name, _remote = remote, _connections = {}, _pruneAt = 16, _client = client },
		ClientEventClass
	) :: any
end

--- Internal: wraps any object with an InvokeServer method. Used by tests to
--- exercise timeouts and the in-flight limit without a running client.
function Client._newFunction(name: string, remote: any, options: FunctionOptions?): ClientFunction
	return newFunction(name, remote, options, 3)
end

return table.freeze(Client)
