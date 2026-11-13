--!strict
--[=[
	Constella.Signal

	Synchronous, deterministic custom events.

	Semantics
	- Listeners run in the order they were connected.
	- `Fire` iterates over a snapshot: a listener connected during dispatch is
	  not called until the next `Fire`; a listener disconnected during dispatch
	  (before its turn) is skipped.
	- Each listener starts immediately on a runner thread (recycled when the
	  previous listener did not yield), so a listener that yields does not
	  block the others.
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

-- Connections form a doubly linked list in connection order.
--
-- Layout: internal fields live in the table's array part, which Luau stores
-- compactly; only the public `Connected` field uses the hash part.
--   [1] callback   [2] signal   [3] previous (or false)   [4] next (or false)
--   [5] id: increases with every Connect; negative for Once connections
--
-- Fire only visits ids that existed when it started, which gives snapshot
-- semantics without copying the list. A disconnected node keeps its next
-- pointer, so a Fire that is walking past it carries on.
local CALLBACK, SIGNAL, PREVIOUS, NEXT, ID = 1, 2, 3, 4, 5

-- Listeners run on recycled "runner" threads instead of a new coroutine
-- per call. A runner marks itself busy while a listener runs; if that
-- listener yields, the next listener gets a fresh runner, so a yielding
-- listener never blocks the others. Errors are caught per listener, so a
-- failing listener never kills its runner. A runner receives the connection
-- itself, so Fire passes one argument fewer and the error handler is only
-- looked up when a listener fails.
local freeRunner: thread? = nil

local function runOnRunner(connection: any, ...: any)
	local runner = freeRunner
	freeRunner = nil
	local ok, message = xpcall(connection[CALLBACK], traceback, ...)
	if not ok then
		connection[SIGNAL]._onError(message)
	end
	freeRunner = runner
end

-- The loop takes no arguments and starts by yielding, so a runner never
-- keeps a call's callback or arguments alive between calls. (Entering the
-- loop with the first call's arguments would pin them on its stack frame
-- for as long as the runner exists.)
local function runnerLoop()
	while true do
		runOnRunner(coroutine.yield())
	end
end

local function newRunner(): thread
	local runner = coroutine.create(runnerLoop)
	coroutine.resume(runner) -- run to the first yield
	return runner
end

local ConnectionClass = {}
ConnectionClass.__index = ConnectionClass

function ConnectionClass.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false
	local signal = self[SIGNAL]
	local previous, following = self[PREVIOUS], self[NEXT]
	if previous then
		previous[NEXT] = following
	else
		signal._head = following or nil
	end
	if following then
		following[PREVIOUS] = previous
	else
		signal._tail = previous or nil
	end
	signal._count -= 1
end
ConnectionClass.Destroy = ConnectionClass.Disconnect

local SignalClass = {}
SignalClass.__index = SignalClass

local function connectError(self: any, callback: any, method: string)
	if self._destroyed then
		error(("[Constella.Signal] Cannot %s a destroyed Signal"):format(method), 3)
	end
	error(("[Constella.Signal] %s expects a function, got %s"):format(method, typeof(callback)), 3)
end

-- Connect is a hot path, so the checks and list append are written out
-- here instead of calling a shared helper (one call fewer per Connect).
local function append(self: any, callback: any, once: boolean, method: string): any
	if self._destroyed or type(callback) ~= "function" then
		connectError(self, callback, method)
	end
	local id = self._nextId
	self._nextId = id + 1
	local tail = self._tail
	-- Array slots keep connections compact; Connected is the public field.
	-- selene: allow(mixed_table)
	local connection = setmetatable({
		callback,
		self,
		tail or false,
		false,
		if once then -id else id,
		Connected = true,
	}, ConnectionClass)
	if tail then
		tail[NEXT] = connection
	else
		self._head = connection
	end
	self._tail = connection
	self._count += 1
	return connection
end

function SignalClass.Connect(self: any, callback: (...any) -> ()): Connection
	if self._destroyed or type(callback) ~= "function" then
		connectError(self, callback, "Connect")
	end
	local id = self._nextId
	self._nextId = id + 1
	local tail = self._tail
	-- Array slots per the layout above; Connected is the public field.
	-- selene: allow(mixed_table)
	local connection: any =
		setmetatable({ callback :: any, self, tail or false, false, id, Connected = true }, ConnectionClass)
	if tail then
		tail[NEXT] = connection
	else
		self._head = connection
	end
	self._tail = connection
	self._count += 1
	return connection
end

function SignalClass.Once(self: any, callback: (...any) -> ()): Connection
	return append(self, callback, true, "Once")
end

function SignalClass.Wait(self: any): ...any
	local thread = coroutine.running()
	append(self, function(...)
		task.spawn(thread, ...)
	end, true, "Wait on")
	return coroutine.yield()
end

function SignalClass.Fire(self: any, ...: any)
	if self._destroyed then
		return
	end
	local node = self._head
	if not node then
		return
	end
	local lastId = self._nextId - 1
	-- Dispatch is written out here (one call fewer per listener). A runner
	-- clears freeRunner while its listener runs and restores it when the
	-- listener returns, so a listener that yields makes the next one start
	-- on a new runner.
	while node do
		local id = node[ID]
		if id < 0 then
			if -id > lastId then
				break
			end
			if node.Connected then
				node:Disconnect()
				if freeRunner == nil then
					freeRunner = newRunner()
				end
				task.spawn(freeRunner :: thread, node, ...)
			end
		else
			if id > lastId then
				break
			end
			if node.Connected then
				if freeRunner == nil then
					freeRunner = newRunner()
				end
				task.spawn(freeRunner :: thread, node, ...)
			end
		end
		node = node[NEXT]
	end
end

function SignalClass.DisconnectAll(self: any)
	local node = self._head
	while node do
		node.Connected = false
		node = node[NEXT]
	end
	self._head = nil
	self._tail = nil
	self._count = 0
end

function SignalClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	SignalClass.DisconnectAll(self)
end

function SignalClass.GetConnectionCount(self: any): number
	return self._count
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
		_head = nil,
		_tail = nil,
		_count = 0,
		_nextId = 1,
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
