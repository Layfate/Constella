--!strict
--[=[
	Constella.Signal

	Synchronous, deterministic custom events.

	Semantics
	- Listeners run in the order they were connected.
	- `Fire` iterates over a snapshot: a listener connected during dispatch is
	  not called until the next `Fire`; a listener disconnected during dispatch
	  (before its turn) is skipped.
	- Each listener runs on its own thread via `task.spawn`, so it starts
	  immediately, and a listener that yields does not block the others.
	- A listener error never stops other listeners and never propagates out of
	  `Fire`. It is passed to `Options.OnError`, or re-raised on a separate
	  thread (so it still shows in the output) when no handler is given.
	- `Fire` on a destroyed signal does nothing. `Connect`/`Wait` on a
	  destroyed signal raise an error.
]=]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: any) -> (),
	Destroy: (self: any) -> (),
}

export type Signal<T...> = {
	Connect: (self: any, callback: (T...) -> ()) -> Connection,
	Once: (self: any, callback: (T...) -> ()) -> Connection,
	Wait: (self: any) -> T...,
	Fire: (self: any, T...) -> (),
	DisconnectAll: (self: any) -> (),
	Destroy: (self: any) -> (),
	GetConnectionCount: (self: any) -> number,
	IsDestroyed: (self: any) -> boolean,
}

export type Options = {
	--- Receives the error message (with traceback) of a failing listener.
	OnError: ((message: string) -> ())?,
}

local function defaultErrorHandler(message: string)
	-- Raise on a fresh thread: it appears in the output as an error but does
	-- not interrupt the remaining listeners or the code that called Fire.
	task.spawn(error, "[Constella.Signal] Listener error: " .. message, 0)
end

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

local function runListener(onError: (string) -> (), callback: (...any) -> (), ...: any)
	local ok, message = xpcall(callback, traceback, ...)
	if not ok then
		onError(message)
	end
end

local ConnectionClass = {}
ConnectionClass.__index = ConnectionClass

function ConnectionClass.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false
	local list = self._signal._connections
	local index = table.find(list, self)
	if index then
		table.remove(list, index)
	end
end
ConnectionClass.Destroy = ConnectionClass.Disconnect

local SignalClass = {}
SignalClass.__index = SignalClass

local function connect(self: any, callback: any, once: boolean, method: string): Connection
	if self._destroyed then
		error(("[Constella.Signal] Cannot %s a destroyed Signal"):format(method), 3)
	end
	if type(callback) ~= "function" then
		error(("[Constella.Signal] %s expects a function, got %s"):format(method, typeof(callback)), 3)
	end
	local connection = setmetatable({
		Connected = true,
		_signal = self,
		_callback = callback,
		_once = once,
	}, ConnectionClass)
	table.insert(self._connections, connection)
	return connection :: any
end

function SignalClass.Connect(self: any, callback: (...any) -> ()): Connection
	return connect(self, callback, false, "Connect")
end

function SignalClass.Once(self: any, callback: (...any) -> ()): Connection
	return connect(self, callback, true, "Once")
end

function SignalClass.Wait(self: any): ...any
	local thread = coroutine.running()
	connect(self, function(...)
		task.spawn(thread, ...)
	end, true, "Wait on")
	return coroutine.yield()
end

function SignalClass.Fire(self: any, ...: any)
	if self._destroyed then
		return
	end
	local connections = self._connections
	if #connections == 0 then
		return
	end
	local snapshot = table.clone(connections)
	local onError = self._onError
	for _, connection in snapshot do
		if connection.Connected then
			if connection._once then
				connection:Disconnect()
			end
			task.spawn(runListener, onError, connection._callback, ...)
		end
	end
end

function SignalClass.DisconnectAll(self: any)
	for _, connection in self._connections do
		connection.Connected = false
	end
	table.clear(self._connections)
end

function SignalClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	SignalClass.DisconnectAll(self)
end

function SignalClass.GetConnectionCount(self: any): number
	return #self._connections
end

function SignalClass.IsDestroyed(self: any): boolean
	return self._destroyed
end

local Signal = {}

--- Creates a new signal. `T...` is the argument list passed to listeners.
function Signal.new<T...>(options: Options?): Signal<T...>
	local onError = defaultErrorHandler
	if options ~= nil then
		if type(options) ~= "table" then
			error("[Constella.Signal] Options must be a table", 2)
		end
		if options.OnError ~= nil then
			if type(options.OnError) ~= "function" then
				error("[Constella.Signal] Options.OnError must be a function", 2)
			end
			onError = options.OnError
		end
	end
	local self = setmetatable({
		_connections = {},
		_destroyed = false,
		_onError = onError,
	}, SignalClass)
	return (self :: any) :: Signal<T...>
end

--- Returns true if `value` is a Constella signal.
function Signal.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == SignalClass
end

return table.freeze(Signal)
