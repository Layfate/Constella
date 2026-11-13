--!strict
--[=[
	Constella.Network.Client

	Looks up remotes that the server created. A client can never create
	remotes, and it only sees namespaces the server chose to expose.

	Functions never hang: Invoke returns (false, "Timeout") after the
	configured timeout, and (false, code) when the server rejected the call.
	Treat everything coming back from the server as display data; the server
	is the source of truth.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type ClientOptions = {
	--- Where to look for the namespace. Defaults to ReplicatedStorage.ConstellaRemotes.
	Parent: Instance?,
	--- Seconds to wait for remotes to replicate. Defaults to 10.
	Timeout: number?,
}

export type ClientEvent = {
	Name: string,
	Fire: (self: any, ...any) -> (),
	Connect: (self: any, handler: (...any) -> ()) -> RBXScriptConnection,
	Destroy: (self: any) -> (),
}

export type ClientFunction = {
	Name: string,
	--- Returns (true, ...results) or (false, code). Codes: "Timeout",
	--- "RateLimited", "Rejected", "Unavailable", "ServerError", "NetworkError".
	Invoke: (self: any, ...any) -> (boolean, ...any),
}

export type Client = {
	Namespace: string,
	Event: (self: any, name: string) -> ClientEvent,
	Function: (self: any, name: string, options: { Timeout: number? }?) -> ClientFunction,
	Destroy: (self: any) -> (),
}

local PREFIX = "[Constella.Network] "
local ROOT_FOLDER_NAME = "ConstellaRemotes"
local DEFAULT_TIMEOUT = 10

local function checkTimeout(value: any, level: number): number
	if value == nil then
		return DEFAULT_TIMEOUT
	end
	if type(value) ~= "number" or not (value > 0) or value == math.huge then
		error(PREFIX .. "Timeout must be a positive number of seconds", level)
	end
	return value
end

local function waitFor(parent: Instance, name: string, timeout: number, what: string): Instance
	local child = parent:WaitForChild(name, timeout)
	if child == nil then
		error(
			PREFIX .. ("%s '%s' was not found in %s after %ss"):format(what, name, parent:GetFullName(), tostring(timeout)),
			3
		)
	end
	return child :: Instance
end

local ClientEventClass = {}
ClientEventClass.__index = ClientEventClass

function ClientEventClass.Fire(self: any, ...: any)
	self._remote:FireServer(...)
end

function ClientEventClass.Connect(self: any, handler: (...any) -> ()): RBXScriptConnection
	if type(handler) ~= "function" then
		error(PREFIX .. ("Connect expects a function, got %s"):format(typeof(handler)), 2)
	end
	local connection = self._remote.OnClientEvent:Connect(handler)
	table.insert(self._connections, connection)
	return connection
end

function ClientEventClass.Destroy(self: any)
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
end

local ClientFunctionClass = {}
ClientFunctionClass.__index = ClientFunctionClass

function ClientFunctionClass.Invoke(self: any, ...: any): (boolean, ...any)
	local thread = coroutine.running()
	local finished = false
	local remote = self._remote
	local args = table.pack(...)

	-- Deferred so both callbacks can only resume this thread after it yields.
	task.defer(function()
		local results = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n)))
		if finished then
			return
		end
		finished = true
		task.spawn(thread, results)
	end)
	local timer = task.delay(self._timeout, function()
		if finished then
			return
		end
		finished = true
		task.spawn(thread, nil)
	end)

	local results = coroutine.yield()
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

local ClientClass = {}
ClientClass.__index = ClientClass

function ClientClass.Event(self: any, name: string): ClientEvent
	local remote = waitFor(self._folder, name, self._timeout, "Remote")
	if not (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then
		error(PREFIX .. ("'%s' is a %s, not an event"):format(name, remote.ClassName), 2)
	end
	local event = setmetatable({ Name = name, _remote = remote, _connections = {} }, ClientEventClass)
	table.insert(self._events, event)
	return (event :: any) :: ClientEvent
end

function ClientClass.Function(self: any, name: string, options: { Timeout: number? }?): ClientFunction
	local timeout = checkTimeout(if options then options.Timeout else nil, 3)
	local remote = waitFor(self._folder, name, self._timeout, "Remote")
	if not remote:IsA("RemoteFunction") then
		error(PREFIX .. ("'%s' is a %s, not a function"):format(name, remote.ClassName), 2)
	end
	local fn = setmetatable({ Name = name, _remote = remote, _timeout = timeout }, ClientFunctionClass)
	return (fn :: any) :: ClientFunction
end

--- Disconnects every handler connected through this client.
function ClientClass.Destroy(self: any)
	for _, event in self._events do
		event:Destroy()
	end
	table.clear(self._events)
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
	local parent = (options and options.Parent) or waitFor(ReplicatedStorage, ROOT_FOLDER_NAME, timeout, "Folder")
	local folder = waitFor(parent, namespace, timeout, "Namespace")
	local self = setmetatable({
		Namespace = namespace,
		_folder = folder,
		_timeout = timeout,
		_events = {},
	}, ClientClass)
	return (self :: any) :: Client
end

return table.freeze(Client)
