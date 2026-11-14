--!strict
--[=[
	Constella.Promise

	Asynchronous values with chaining, cancellation and timeouts.

	Semantics
	- The executor runs immediately on its own thread and may yield.
	- Handlers run on their own threads, in the order they were attached.
	  Attaching to an already-settled promise runs the handler right away.
	- An error thrown in an executor or handler rejects with a PromiseError
	  (Kind "ExecutionError") that carries the message and a traceback.
	  Tables thrown with error() are passed through unchanged.
	- Resolving with another promise adopts its outcome.
	- No silent failures: a rejection nobody handles (no Then/Catch/Finally/
	  Await on it) by the next resumption point is reported, by default as an
	  error in the output.
	- Cancel() settles a pending promise as "Cancelled", runs its onCancel
	  hooks and cancels every promise chained from it. A chained promise
	  that is cancelled also cancels its parent once the parent has no other
	  consumers, so cancelling the end of a chain stops the work behind it.
]=]

export type Status = "Pending" | "Resolved" | "Rejected" | "Cancelled"

export type ErrorKind = "ExecutionError" | "Timeout" | "Cancelled"

export type PromiseError = {
	Kind: ErrorKind,
	Message: string,
	Trace: string?,
}

--- A promise whose value type isn't tracked: what `Then` and `Catch` return,
--- since the handler decides the next value. Luau can't express "a Promise of
--- the handler's return type" here, so annotate it yourself if you need to:
--- `local p = (a:Then(f) :: any) :: Promise<number>`.
export type AnyPromise = {
	Then: (self: AnyPromise, onResolved: ((...any) -> ...any)?, onRejected: ((...any) -> ...any)?) -> AnyPromise,
	Catch: (self: AnyPromise, onRejected: (...any) -> ...any) -> AnyPromise,
	Finally: (self: AnyPromise, callback: (status: Status) -> ()) -> AnyPromise,
	Await: (self: AnyPromise) -> (boolean, ...any),
	Expect: (self: AnyPromise) -> ...any,
	Cancel: (self: AnyPromise) -> (),
	Timeout: (self: AnyPromise, seconds: number, rejectionValue: any?) -> AnyPromise,
	GetStatus: (self: AnyPromise) -> Status,
}

--- A promise that resolves with a `T` (its first value). `Promise` on its own
--- means `Promise<any>`.
export type Promise<T = any> = {
	--- `onResolved` receives the value; what it returns becomes the next
	--- promise's value, so the result is an `AnyPromise`.
	Then: (
		self: Promise<T>,
		onResolved: ((value: T, ...any) -> ...any)?,
		onRejected: ((reason: any, ...any) -> ...any)?
	) -> AnyPromise,
	Catch: (self: Promise<T>, onRejected: (reason: any, ...any) -> ...any) -> AnyPromise,
	Finally: (self: Promise<T>, callback: (status: Status) -> ()) -> Promise<T>,
	--- `(true, value)` or `(false, reason)`. The second value is only a `T`
	--- when the first is true, so it's typed `any`.
	Await: (self: Promise<T>) -> (boolean, any),
	--- The value, or raises the rejection.
	Expect: (self: Promise<T>) -> T,
	Cancel: (self: Promise<T>) -> (),
	Timeout: (self: Promise<T>, seconds: number, rejectionValue: any?) -> Promise<T>,
	GetStatus: (self: Promise<T>) -> Status,
}

export type RetryOptions = {
	--- Total attempts, including the first. Defaults to 3.
	Attempts: number?,
	--- Seconds to wait before the second attempt. Defaults to 0.
	Delay: number?,
	--- Multiplier applied to Delay after each failure. Defaults to 2.
	Backoff: number?,
	--- Return false to stop retrying for this rejection.
	ShouldRetry: ((...any) -> boolean)?,
}

local PREFIX = "[Constella.Promise] "

-- Errors ----------------------------------------------------------------

local ErrorClass = {}
ErrorClass.__index = ErrorClass
ErrorClass.__tostring = function(self: any): string
	return ("%s%s: %s"):format(PREFIX, self.Kind, self.Message)
end

local function newError(kind: ErrorKind, message: string, trace: string?): PromiseError
	return (setmetatable({ Kind = kind, Message = message, Trace = trace }, ErrorClass) :: any) :: PromiseError
end

local function captureError(err: any): any
	if type(err) == "table" then
		return err
	end
	return newError("ExecutionError", tostring(err), debug.traceback(nil, 2))
end

local function defaultUnhandled(value: any)
	local text = tostring(value)
	if type(value) == "table" and getmetatable(value) == ErrorClass and value.Trace then
		text ..= "\n" .. value.Trace
	end
	task.spawn(error, PREFIX .. "Unhandled rejection: " .. text, 0)
end

local unhandledHandler: (any) -> () = defaultUnhandled

-- Core --------------------------------------------------------------------

local PromiseClass = {}
PromiseClass.__index = PromiseClass

local function isPromise(value: any): boolean
	return type(value) == "table" and getmetatable(value) == PromiseClass
end

local function create(): any
	return setmetatable({
		_status = "Pending",
		_values = nil,
		_queue = {},
		_cancelHooks = {},
		_upstream = {},
		_consumers = 0,
		_handled = false,
	}, PromiseClass)
end

local function subscribe(promise: any, callback: () -> ())
	if promise._status == "Pending" then
		table.insert(promise._queue, callback)
	else
		callback()
	end
end

local function settle(self: any, status: Status, values: any)
	if self._status ~= "Pending" then
		return
	end
	self._status = status
	self._values = values
	local queue = self._queue
	self._queue = {}
	for _, callback in queue do
		callback()
	end
	if status == "Rejected" then
		task.defer(function()
			if not self._handled then
				unhandledHandler(self._values[1])
			end
		end)
	end
end

local function addUpstream(self: any, upstream: any)
	upstream._consumers += 1
	upstream._handled = true
	table.insert(self._upstream, upstream)
end

local function resolveWith(self: any, ...: any)
	if self._status ~= "Pending" then
		return
	end
	local first = ...
	if select("#", ...) == 1 and isPromise(first) then
		if first == self then
			settle(self, "Rejected", table.pack(newError("ExecutionError", "A promise cannot resolve with itself")))
			return
		end
		addUpstream(self, first)
		subscribe(first, function()
			local status = first._status
			if status == "Cancelled" then
				self:Cancel()
			else
				settle(self, status, first._values)
			end
		end)
		return
	end
	settle(self, "Resolved", table.pack(...))
end

local function runHandler(child: any, handler: (...any) -> ...any, values: any)
	task.spawn(function()
		local results = table.pack(xpcall(handler, captureError, table.unpack(values, 1, values.n)))
		if results[1] then
			resolveWith(child, table.unpack(results, 2, results.n))
		else
			settle(child, "Rejected", table.pack(results[2]))
		end
	end)
end

local function checkHandler(handler: any, name: string)
	if handler ~= nil and type(handler) ~= "function" then
		error(PREFIX .. ("%s must be a function, got %s"):format(name, typeof(handler)), 3)
	end
end

function PromiseClass.Then(self: any, onResolved: ((...any) -> ...any)?, onRejected: ((...any) -> ...any)?): any
	checkHandler(onResolved, "onResolved")
	checkHandler(onRejected, "onRejected")
	local child = create()
	addUpstream(child, self)
	subscribe(self, function()
		local status = self._status
		local values = self._values
		if status == "Resolved" then
			if onResolved then
				runHandler(child, onResolved, values)
			else
				settle(child, "Resolved", values)
			end
		elseif status == "Rejected" then
			if onRejected then
				runHandler(child, onRejected, values)
			else
				settle(child, "Rejected", values)
			end
		else
			child:Cancel()
		end
	end)
	return child
end

function PromiseClass.Catch(self: any, onRejected: (...any) -> ...any): any
	if type(onRejected) ~= "function" then
		error(PREFIX .. ("Catch expects a function, got %s"):format(typeof(onRejected)), 2)
	end
	return PromiseClass.Then(self, nil, onRejected)
end

--- Runs `callback(status)` however the promise settles (including
--- cancellation) and passes the original outcome through.
function PromiseClass.Finally(self: any, callback: (Status) -> ()): any
	if type(callback) ~= "function" then
		error(PREFIX .. ("Finally expects a function, got %s"):format(typeof(callback)), 2)
	end
	local child = create()
	addUpstream(child, self)
	subscribe(self, function()
		local status, values = self._status, self._values
		task.spawn(function()
			local ok, err = xpcall(callback :: any, captureError, status)
			if not ok then
				settle(child, "Rejected", table.pack(err))
			elseif status == "Cancelled" then
				child:Cancel()
			else
				settle(child, status, values)
			end
		end)
	end)
	return child
end

--- Yields until settled. Returns (true, ...values) when resolved, otherwise
--- (false, rejection) - a PromiseError of Kind "Cancelled" if cancelled.
function PromiseClass.Await(self: any): (boolean, ...any)
	self._handled = true
	if self._status == "Pending" then
		local thread = coroutine.running()
		table.insert(self._queue, function()
			task.spawn(thread)
		end)
		coroutine.yield()
	end
	local values = self._values
	if self._status == "Resolved" then
		return true, table.unpack(values, 1, values.n)
	end
	return false, table.unpack(values, 1, values.n)
end

--- Yields until settled. Returns the values, or raises the rejection.
function PromiseClass.Expect(self: any): ...any
	local results = table.pack(PromiseClass.Await(self))
	if not results[1] then
		local err = results[2]
		error(if type(err) == "table" then err else tostring(err), 2)
	end
	return table.unpack(results, 2, results.n)
end

function PromiseClass.Cancel(self: any)
	if self._status ~= "Pending" then
		return
	end
	self._status = "Cancelled"
	self._values = table.pack(newError("Cancelled", "The promise was cancelled"))
	for _, hook in self._cancelHooks do
		local ok, err = pcall(hook)
		if not ok then
			task.spawn(error, PREFIX .. "onCancel hook failed: " .. tostring(err), 0)
		end
	end
	local queue = self._queue
	self._queue = {}
	for _, callback in queue do
		callback()
	end
	for _, upstream in self._upstream do
		upstream._consumers -= 1
		if upstream._consumers <= 0 then
			upstream:Cancel()
		end
	end
end

function PromiseClass.GetStatus(self: any): Status
	return self._status
end

local Promise = {}

--- Creates a promise. `executor(resolve, reject, onCancel)` runs right away.
--- `onCancel(hook)` registers cleanup for cancellation and returns true if
--- the promise is already cancelled; `onCancel()` just returns that flag.
function Promise.new(executor: (
	resolve: (...any) -> (),
	reject: (...any) -> (),
	onCancel: (hook: (() -> ())?) -> boolean
) -> ()): Promise
	if type(executor) ~= "function" then
		error(PREFIX .. ("Promise.new expects a function, got %s"):format(typeof(executor)), 2)
	end
	local self = create()
	local function resolve(...: any)
		resolveWith(self, ...)
	end
	local function reject(...: any)
		settle(self, "Rejected", table.pack(...))
	end
	local function onCancel(hook: (() -> ())?): boolean
		if hook == nil then
			return self._status == "Cancelled"
		end
		if type(hook) ~= "function" then
			error(PREFIX .. "onCancel expects a function", 2)
		end
		if self._status == "Cancelled" then
			hook()
			return true
		end
		table.insert(self._cancelHooks, hook)
		return false
	end
	task.spawn(function()
		local ok, err = xpcall(executor :: any, captureError, resolve, reject, onCancel)
		if not ok then
			settle(self, "Rejected", table.pack(err))
		end
	end)
	return self
end

-- Passes through every value it's given (including none), so the body takes
-- `...`; the cast below gives callers the typed signature.
local function resolvedPromise(...: any): Promise
	local self = create()
	resolveWith(self, ...)
	return self
end
Promise.resolve = (resolvedPromise :: any) :: <T>(value: T, ...any) -> Promise<T>

function Promise.reject(...: any): Promise
	local self = create()
	settle(self, "Rejected", table.pack(...))
	return self
end

--- Calls `callback(...)` inside a promise; its return value (or error) settles it.
function Promise.try(callback: (...any) -> ...any, ...: any): Promise
	local args = table.pack(...)
	return Promise.new(function(resolve)
		resolve(callback(table.unpack(args, 1, args.n)))
	end)
end

--- Resolves with the elapsed time after `seconds`. Cancelling stops the timer.
function Promise.delay(seconds: number): Promise<number>
	if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 or seconds == math.huge then
		error(PREFIX .. "delay expects a non-negative number of seconds", 2)
	end
	return Promise.new(function(resolve, _, onCancel)
		local started = os.clock()
		local thread = task.delay(seconds, function()
			resolve(os.clock() - started)
		end)
		onCancel(function()
			task.cancel(thread)
		end)
	end)
end

local function checkPromiseList(list: any, name: string)
	if type(list) ~= "table" then
		error(PREFIX .. ("%s expects an array of promises"):format(name), 3)
	end
	for index, value in list do
		if not isPromise(value) then
			error(PREFIX .. ("%s: item %s is not a promise"):format(name, tostring(index)), 3)
		end
	end
end

--- Resolves with an array of each promise's first value once all resolve.
--- Rejects as soon as one rejects (or is cancelled) and cancels the rest.
function Promise.all(promises: { Promise | AnyPromise }): Promise<{ any }>
	checkPromiseList(promises, "all")
	local list: { any } = table.clone(promises)
	return Promise.new(function(resolve, reject, onCancel)
		local count = #list
		if count == 0 then
			resolve({})
			return
		end
		local results = table.create(count)
		local remaining = count
		local finished = false
		local function cancelRest()
			for _, promise in list do
				promise:Cancel()
			end
		end
		onCancel(cancelRest)
		for index, promise in list do
			(promise :: any)._handled = true
			subscribe(promise, function()
				if finished then
					return
				end
				local p = promise :: any
				if p._status == "Resolved" then
					results[index] = p._values[1]
					remaining -= 1
					if remaining == 0 then
						finished = true
						resolve(results)
					end
				else
					finished = true
					-- Cancel the others first so they are stopped by the time
					-- anyone awaiting this promise resumes.
					cancelRest()
					reject(table.unpack(p._values, 1, p._values.n))
				end
			end)
		end
	end)
end

--- Resolves once every promise has settled, with an array of
--- { Status = Status, Value = firstValue }.
function Promise.allSettled(promises: { Promise | AnyPromise }): Promise<{ { Status: Status, Value: any } }>
	checkPromiseList(promises, "allSettled")
	local list: { any } = table.clone(promises)
	return Promise.new(function(resolve)
		local count = #list
		local results = table.create(count)
		local remaining = count
		if count == 0 then
			resolve(results)
			return
		end
		for index, promise in list do
			(promise :: any)._handled = true
			subscribe(promise, function()
				local p = promise :: any
				results[index] = { Status = p._status, Value = p._values[1] }
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
			end)
		end
	end)
end

--- Settles like the first promise to resolve or reject, then cancels the
--- others. Cancelled inputs are ignored unless all of them are cancelled.
function Promise.race(promises: { Promise | AnyPromise }): Promise
	checkPromiseList(promises, "race")
	local list: { any } = table.clone(promises)
	if #list == 0 then
		error(PREFIX .. "race needs at least one promise", 2)
	end
	return Promise.new(function(resolve, reject, onCancel)
		local finished = false
		local cancelled = 0
		local function cancelRest()
			for _, promise in list do
				promise:Cancel()
			end
		end
		onCancel(cancelRest)
		for _, promise in list do
			(promise :: any)._handled = true
			subscribe(promise, function()
				if finished then
					return
				end
				local p = promise :: any
				if p._status == "Cancelled" then
					cancelled += 1
					if cancelled == #list then
						finished = true
						reject(table.unpack(p._values, 1, p._values.n))
					end
					return
				end
				finished = true
				cancelRest()
				if p._status == "Resolved" then
					resolve(table.unpack(p._values, 1, p._values.n))
				else
					reject(table.unpack(p._values, 1, p._values.n))
				end
			end)
		end
	end)
end

--- Rejects with `rejectionValue` (default: a PromiseError of Kind "Timeout")
--- if this promise has not settled after `seconds`, and cancels it.
function PromiseClass.Timeout(self: any, seconds: number, rejectionValue: any?): any
	local timer = Promise.delay(seconds):Then(function()
		return Promise.reject(
			if rejectionValue ~= nil
				then rejectionValue
				else newError("Timeout", ("Timed out after %s seconds"):format(tostring(seconds)))
		)
	end)
	return Promise.race({ self, timer })
end

--- Calls `callback()` (which may return a promise) until it resolves or the
--- attempts run out. Waits Delay, Delay*Backoff, ... between attempts.
function Promise.retry(callback: () -> any, options: RetryOptions?): Promise
	if type(callback) ~= "function" then
		error(PREFIX .. "retry expects a function", 2)
	end
	local opts: RetryOptions = options or {}
	local attempts = opts.Attempts or 3
	if type(attempts) ~= "number" or attempts < 1 or attempts % 1 ~= 0 then
		error(PREFIX .. "Attempts must be a positive integer", 2)
	end
	local delaySeconds = opts.Delay or 0
	local backoff = opts.Backoff or 2
	return Promise.new(function(resolve, reject, onCancel)
		local current: any = nil
		onCancel(function()
			if current then
				current:Cancel()
			end
		end)
		local wait = delaySeconds
		for attempt = 1, attempts do
			current = Promise.try(callback)
			local results = table.pack(current:Await())
			if onCancel() then
				return
			end
			if results[1] then
				resolve(table.unpack(results, 2, results.n))
				return
			end
			local giveUp = attempt == attempts
			if not giveUp and opts.ShouldRetry and not opts.ShouldRetry(table.unpack(results, 2, results.n)) then
				giveUp = true
			end
			if giveUp then
				reject(table.unpack(results, 2, results.n))
				return
			end
			if wait > 0 then
				current = Promise.delay(wait)
				current:Await()
				if onCancel() then
					return
				end
			end
			wait *= backoff
		end
	end)
end

--- Resolves with the arguments of the next event that passes `predicate`.
--- Works with RBXScriptSignals and Constella Signals.
function Promise.fromEvent(event: any, predicate: ((...any) -> boolean)?): Promise
	return Promise.new(function(resolve, reject, onCancel)
		local connection: any
		connection = event:Connect(function(...)
			if predicate then
				local ok, passed = pcall(predicate, ...)
				if not ok then
					connection:Disconnect()
					reject(captureError(passed))
					return
				end
				if not passed then
					return
				end
			end
			connection:Disconnect()
			resolve(...)
		end)
		onCancel(function()
			connection:Disconnect()
		end)
	end)
end

Promise.is = isPromise

--- True if `value` is a PromiseError, optionally of the given Kind.
function Promise.isError(value: any, kind: ErrorKind?): boolean
	if type(value) ~= "table" or getmetatable(value) ~= ErrorClass then
		return false
	end
	return kind == nil or value.Kind == kind
end

--- Replaces the unhandled-rejection reporter for every promise and returns
--- the previous one. Intended for tests and custom error reporting.
function Promise.setUnhandledRejectionHandler(handler: ((value: any) -> ())?): (any) -> ()
	if handler ~= nil and type(handler) ~= "function" then
		error(PREFIX .. "handler must be a function or nil", 2)
	end
	local previous = unhandledHandler
	unhandledHandler = handler or defaultUnhandled
	return previous
end

return table.freeze(Promise)
