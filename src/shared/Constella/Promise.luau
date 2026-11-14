--!strict
--[=[
	Constella.Promise

	Asynchronous values with chaining, cancellation and timeouts.

	Semantics
	- The executor runs immediately on a thread of its own (a recycled one,
	  like Signal's listeners) and may yield.
	- Handlers run the same way, in the order they were attached; one that
	  yields never delays the others. Attaching to an already-settled
	  promise runs the handler right away.
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

-- A promise keeps its state in the table's array part, which Luau stores
-- compactly (16 bytes a slot); methods come from the metatable.
--   STATUS     "Pending" | "Resolved" | "Rejected" | "Cancelled"
--   VALUES     table.pack of the outcome, once settled
--   QUEUE      what to notify on settle: one entry, or a plain list of them
--   HOOKS      onCancel hooks (a list)
--   UPSTREAM   the promise(s) this one was chained from: one, or a list
--   CONSUMERS  how many promises are chained from this one
--   HANDLED    true once something handles a rejection
--   MODE, ON_RESOLVED, ON_REJECTED
--              for a promise made by Then or Finally: how to react when its
--              parent settles, and the handlers (cleared once used)
-- QUEUE, HOOKS and UPSTREAM are dropped on settle: Cancel does nothing
-- afterwards, so a settled promise doesn't keep the promises it was chained
-- from, or its cancel hooks, alive.
local STATUS, VALUES, QUEUE, HOOKS, UPSTREAM, CONSUMERS, HANDLED = 1, 2, 3, 4, 5, 6, 7
local MODE, ON_RESOLVED, ON_REJECTED = 8, 9, 10
local THEN, FINALLY = 1, 2

local function isPromise(value: any): boolean
	return type(value) == "table" and getmetatable(value) == PromiseClass
end

-- A plain list (as opposed to a single entry, which is a function, a
-- thread or a promise).
local function isList(value: any): boolean
	return type(value) == "table" and getmetatable(value) == nil
end

local function create(): any
	return setmetatable({ "Pending", nil, nil, nil, nil, 0, false, nil, nil, nil } :: { any }, PromiseClass)
end

-- Runner threads -------------------------------------------------------------
-- Executors and handlers run on recycled "runner" threads instead of a new
-- coroutine each, the same way Signal runs listeners. A runner marks itself
-- busy while its job runs; if the job yields, the next job gets a fresh
-- runner, so a yielding handler never blocks the others. Jobs catch user
-- errors themselves, so a runner never dies from one.
--
-- Like any thread reuse, the values of the most recent job can stay
-- reachable in an idle runner's unused stack slots until it runs the next
-- job. That is bounded to one job, not a leak. The job comes first in the
-- argument list, then the user's function, then the promise and values.
local freeRunner: thread? = nil

local function runJob(job: (...any) -> (), ...: any)
	local runner = freeRunner
	freeRunner = nil
	job(...)
	freeRunner = runner
end

-- Starts by yielding, so a runner never keeps its first job's arguments
-- alive on its stack frame.
local function runnerLoop()
	while true do
		runJob(coroutine.yield())
	end
end

local function spawnJob(job: (...any) -> (), ...: any)
	local runner = freeRunner
	-- A runner is only reused while it's parked. (User code could have
	-- cancelled it, for example by adding coroutine.running() to a Cleanup.)
	if runner == nil or coroutine.status(runner :: thread) ~= "suspended" then
		local fresh = coroutine.create(runnerLoop)
		coroutine.resume(fresh) -- run to the first yield
		freeRunner = fresh
		runner = fresh
	end
	task.spawn(runner :: thread, job, ...)
end

-- Settling ---------------------------------------------------------------------

local settle: (self: any, status: Status, values: any) -> ()
local resolveWith: (self: any, ...any) -> ()
local cancel: (self: any) -> ()

local function finishHandler(child: any, ok: boolean, ...: any)
	if ok then
		resolveWith(child, ...)
	else
		settle(child, "Rejected", table.pack((...)))
	end
end

local function handlerJob(handler: (...any) -> ...any, child: any, values: any)
	finishHandler(child, xpcall(handler, captureError, table.unpack(values, 1, values.n)))
end

local function finallyJob(callback: (Status) -> (), child: any, status: Status, values: any)
	local ok, err = xpcall(callback :: any, captureError, status)
	if not ok then
		settle(child, "Rejected", table.pack(err))
	elseif status == "Cancelled" then
		cancel(child)
	else
		settle(child, status, values)
	end
end

local function executorJob(executor: any, self: any, resolve: any, reject: any, onCancel: any)
	local ok, err = xpcall(executor, captureError, resolve, reject, onCancel)
	if not ok then
		settle(self, "Rejected", table.pack(err))
	end
end

-- Resumes a thread that is waiting on a promise. A waiting thread that was
-- cancelled in the meantime (task.cancel, for example by a Cleanup) is dead
-- and is skipped: resuming it would raise and stop the other callbacks.
local function resumeWaiter(thread: thread)
	if coroutine.status(thread) == "suspended" then
		task.spawn(thread)
	end
end

-- Tells one queue entry that `promise` has settled. An entry is a thread
-- (Await), a function (adoption and the combinators) or a promise made by
-- Then/Finally on `promise`.
local function notify(promise: any, entry: any)
	local kind = type(entry)
	if kind == "thread" then
		resumeWaiter(entry)
	elseif kind == "function" then
		entry()
	elseif entry[MODE] == FINALLY then
		local callback = entry[ON_RESOLVED]
		entry[ON_RESOLVED] = nil
		spawnJob(finallyJob, callback, entry, promise[STATUS], promise[VALUES])
	else
		local status = promise[STATUS]
		local handler = if status == "Resolved"
			then entry[ON_RESOLVED]
			elseif status == "Rejected" then entry[ON_REJECTED]
			else nil
		entry[ON_RESOLVED] = nil
		entry[ON_REJECTED] = nil
		if status == "Cancelled" then
			cancel(entry)
		elseif handler then
			spawnJob(handlerJob, handler, entry, promise[VALUES])
		else
			settle(entry, status, promise[VALUES])
		end
	end
end

local function notifyAll(promise: any, queue: any)
	if queue == nil then
		return
	end
	if isList(queue) then
		for _, entry in queue do
			notify(promise, entry)
		end
	else
		notify(promise, queue)
	end
end

local function subscribe(promise: any, entry: any)
	if promise[STATUS] ~= "Pending" then
		notify(promise, entry)
		return
	end
	local queue = promise[QUEUE]
	if queue == nil then
		promise[QUEUE] = entry
	elseif isList(queue) then
		table.insert(queue, entry)
	else
		promise[QUEUE] = { queue, entry }
	end
end

local function reportIfUnhandled(self: any)
	if not self[HANDLED] then
		unhandledHandler(self[VALUES][1])
	end
end

function settle(self: any, status: Status, values: any)
	if self[STATUS] ~= "Pending" then
		return
	end
	self[STATUS] = status
	self[VALUES] = values
	local queue = self[QUEUE]
	self[QUEUE] = nil
	self[HOOKS] = nil
	self[UPSTREAM] = nil
	notifyAll(self, queue)
	if status == "Rejected" then
		task.defer(reportIfUnhandled, self)
	end
end

local function addUpstream(self: any, upstream: any)
	upstream[CONSUMERS] += 1
	upstream[HANDLED] = true
	local current = self[UPSTREAM]
	if current == nil then
		self[UPSTREAM] = upstream
	elseif isList(current) then
		table.insert(current, upstream)
	else
		self[UPSTREAM] = { current, upstream }
	end
end

function resolveWith(self: any, ...: any)
	if self[STATUS] ~= "Pending" then
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
			local status = first[STATUS]
			if status == "Cancelled" then
				cancel(self)
			else
				settle(self, status, first[VALUES])
			end
		end)
		return
	end
	settle(self, "Resolved", table.pack(...))
end

local function releaseUpstream(upstream: any)
	upstream[CONSUMERS] -= 1
	if upstream[CONSUMERS] <= 0 then
		cancel(upstream)
	end
end

function cancel(self: any)
	if self[STATUS] ~= "Pending" then
		return
	end
	self[STATUS] = "Cancelled"
	self[VALUES] = table.pack(newError("Cancelled", "The promise was cancelled"))
	local hooks, queue, upstream = self[HOOKS], self[QUEUE], self[UPSTREAM]
	self[HOOKS] = nil
	self[QUEUE] = nil
	self[UPSTREAM] = nil
	if hooks then
		for _, hook in hooks do
			local ok, err = pcall(hook)
			if not ok then
				task.spawn(error, PREFIX .. "onCancel hook failed: " .. tostring(err), 0)
			end
		end
	end
	notifyAll(self, queue)
	if upstream ~= nil then
		if isList(upstream) then
			for _, item in upstream do
				releaseUpstream(item)
			end
		else
			releaseUpstream(upstream)
		end
	end
end

-- Methods ------------------------------------------------------------------------

local function checkHandler(handler: any, name: string)
	if handler ~= nil and type(handler) ~= "function" then
		error(PREFIX .. ("%s must be a function, got %s"):format(name, typeof(handler)), 3)
	end
end

function PromiseClass.Then(self: any, onResolved: ((...any) -> ...any)?, onRejected: ((...any) -> ...any)?): any
	checkHandler(onResolved, "onResolved")
	checkHandler(onRejected, "onRejected")
	local child = create()
	child[MODE] = THEN
	child[ON_RESOLVED] = onResolved
	child[ON_REJECTED] = onRejected
	addUpstream(child, self)
	subscribe(self, child)
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
	child[MODE] = FINALLY
	child[ON_RESOLVED] = callback
	addUpstream(child, self)
	subscribe(self, child)
	return child
end

--- Yields until settled. Returns (true, ...values) when resolved, otherwise
--- (false, rejection) - a PromiseError of Kind "Cancelled" if cancelled.
function PromiseClass.Await(self: any): (boolean, ...any)
	self[HANDLED] = true
	if self[STATUS] == "Pending" then
		subscribe(self, coroutine.running())
		coroutine.yield()
	end
	local values = self[VALUES]
	if self[STATUS] == "Resolved" then
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

PromiseClass.Cancel = cancel

function PromiseClass.GetStatus(self: any): Status
	return self[STATUS]
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
			return self[STATUS] == "Cancelled"
		end
		if type(hook) ~= "function" then
			error(PREFIX .. "onCancel expects a function", 2)
		end
		local status = self[STATUS]
		if status == "Cancelled" then
			hook()
			return true
		end
		if status ~= "Pending" then
			-- Settled: the hook can never run, so don't keep it.
			return false
		end
		local hooks = self[HOOKS]
		if hooks then
			table.insert(hooks, hook)
		else
			self[HOOKS] = { hook }
		end
		return false
	end
	spawnJob(executorJob, executor, self, resolve, reject, onCancel)
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
			(promise :: any)[HANDLED] = true
			subscribe(promise, function()
				if finished then
					return
				end
				local p = promise :: any
				if p[STATUS] == "Resolved" then
					results[index] = p[VALUES][1]
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
					reject(table.unpack(p[VALUES], 1, p[VALUES].n))
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
			(promise :: any)[HANDLED] = true
			subscribe(promise, function()
				local p = promise :: any
				results[index] = { Status = p[STATUS], Value = p[VALUES][1] }
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
			(promise :: any)[HANDLED] = true
			subscribe(promise, function()
				if finished then
					return
				end
				local p = promise :: any
				if p[STATUS] == "Cancelled" then
					cancelled += 1
					if cancelled == #list then
						finished = true
						reject(table.unpack(p[VALUES], 1, p[VALUES].n))
					end
					return
				end
				finished = true
				cancelRest()
				if p[STATUS] == "Resolved" then
					resolve(table.unpack(p[VALUES], 1, p[VALUES].n))
				else
					reject(table.unpack(p[VALUES], 1, p[VALUES].n))
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
