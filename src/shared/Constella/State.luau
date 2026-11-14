--!strict
--[=[
	Constella.State

	Small reactive values with derived (computed) state and batching.

	Semantics
	- `Set` with a value equal to the current one does nothing. Equality is
	  `==` by default, NaN is treated as equal to NaN, and tables compare by
	  reference (pass `Options.Equals` for custom comparison).
	- Subscribers receive `(newValue, oldValue)` and run like Signal
	  listeners: in subscription order, error-isolated.
	- Every `Set` runs as a batch. Notifications are delivered after the
	  values have been written, so a computed state that depends on several
	  sources notifies its subscribers once per change, not once per source.
	- `State.batch(fn)` groups several writes into one notification per
	  state. A state that changes and changes back inside a batch does not
	  notify at all.
	- Computed callbacks must be pure and must not yield.
	- `Destroy` disconnects every subscriber and (for computed states) stops
	  listening to the sources.
]=]

local Signal = require(script.Parent.Signal)

export type Connection = Signal.Connection

export type Value<T> = {
	Get: (self: Value<T>) -> T,
	Set: (self: Value<T>, value: T) -> (),
	Update: (self: Value<T>, updater: (current: T) -> T) -> (),
	Subscribe: (self: Value<T>, callback: (newValue: T, oldValue: T) -> ()) -> Connection,
	Observe: (self: Value<T>, callback: (value: T) -> ()) -> Connection,
	Destroy: (self: Value<T>) -> (),
	IsDestroyed: (self: Value<T>) -> boolean,
}

export type Computed<T> = {
	Get: (self: Computed<T>) -> T,
	Subscribe: (self: Computed<T>, callback: (newValue: T, oldValue: T) -> ()) -> Connection,
	Observe: (self: Computed<T>, callback: (value: T) -> ()) -> Connection,
	Destroy: (self: Computed<T>) -> (),
	IsDestroyed: (self: Computed<T>) -> boolean,
}

export type Options<T> = {
	Equals: ((a: T, b: T) -> boolean)?,
}

-- Safety net against subscribers that keep writing to each other forever.
local MAX_FLUSH_ROUNDS = 100

local function defaultEquals(a: any, b: any): boolean
	return a == b or (a ~= a and b ~= b)
end

-- Batch bookkeeping. This is private scheduling state, not a service: it
-- never holds user data beyond the duration of a single flush.
local batchDepth = 0
local pendingOrder: { any } = {}
local pendingOld: { [any]: { value: any } } = {}

local function schedule(state: any, oldValue: any)
	if pendingOld[state] == nil then
		pendingOld[state] = { value = oldValue }
		table.insert(pendingOrder, state)
	end
end

local function flushRounds()
	local rounds = 0
	while #pendingOrder > 0 do
		rounds += 1
		if rounds > MAX_FLUSH_ROUNDS then
			error(
				("[Constella.State] Update loop detected: states kept changing after %d rounds"):format(
					MAX_FLUSH_ROUNDS
				),
				0
			)
		end
		local order, olds = pendingOrder, pendingOld
		pendingOrder, pendingOld = {}, {}
		for _, state in order do
			local oldValue = olds[state].value
			if not state._destroyed and not state._equals(state._value, oldValue) then
				state._changed:Fire(state._value, oldValue)
			end
		end
	end
end

local function flush()
	batchDepth += 1
	local ok, err = pcall(flushRounds :: any)
	batchDepth -= 1
	if not ok then
		pendingOrder, pendingOld = {}, {}
		error(err, 0)
	end
end

local function write(state: any, newValue: any)
	local oldValue = state._value
	if state._equals(newValue, oldValue) then
		return
	end
	state._value = newValue
	schedule(state, oldValue)
	if batchDepth == 0 then
		flush()
	end
end

local function resolveEquals(options: any): (any, any) -> boolean
	if options == nil then
		return defaultEquals
	end
	if type(options) ~= "table" then
		error("[Constella.State] Options must be a table", 3)
	end
	if options.Equals == nil then
		return defaultEquals
	end
	if type(options.Equals) ~= "function" then
		error("[Constella.State] Options.Equals must be a function", 3)
	end
	return options.Equals
end

-- Methods shared by Value and Computed.
local function get(self: any): any
	return self._value
end

local function subscribe(self: any, callback: (any, any) -> ()): Connection
	if self._destroyed then
		error("[Constella.State] Cannot subscribe to a destroyed state", 2)
	end
	if type(callback) ~= "function" then
		error(("[Constella.State] Subscribe expects a function, got %s"):format(typeof(callback)), 2)
	end
	return self._changed:Connect(callback)
end

local function observe(self: any, callback: (any) -> ()): Connection
	if self._destroyed then
		error("[Constella.State] Cannot observe a destroyed state", 2)
	end
	if type(callback) ~= "function" then
		error(("[Constella.State] Observe expects a function, got %s"):format(typeof(callback)), 2)
	end
	local connection = self._changed:Connect(function(newValue)
		callback(newValue)
	end)
	callback(self._value)
	return connection
end

local function isDestroyed(self: any): boolean
	return self._destroyed
end

local ValueClass = {}
ValueClass.__index = ValueClass
ValueClass.Get = get
ValueClass.Subscribe = subscribe
ValueClass.Observe = observe
ValueClass.IsDestroyed = isDestroyed

function ValueClass.Set(self: any, value: any)
	if self._destroyed then
		error("[Constella.State] Cannot set a destroyed state", 2)
	end
	write(self, value)
end

function ValueClass.Update(self: any, updater: (any) -> any)
	if self._destroyed then
		error("[Constella.State] Cannot update a destroyed state", 2)
	end
	if type(updater) ~= "function" then
		error(("[Constella.State] Update expects a function, got %s"):format(typeof(updater)), 2)
	end
	write(self, updater(self._value))
end

function ValueClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._changed:Destroy()
end

local ComputedClass = {}
ComputedClass.__index = ComputedClass
ComputedClass.Get = get
ComputedClass.Subscribe = subscribe
ComputedClass.Observe = observe
ComputedClass.IsDestroyed = isDestroyed

function ComputedClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, connection in self._sourceConnections do
		connection:Disconnect()
	end
	table.clear(self._sourceConnections)
	self._changed:Destroy()
end

local function isState(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local meta = getmetatable(value)
	return meta == ValueClass or meta == ComputedClass
end

local function evaluate(self: any): any
	local sources = self._sources
	local count = #sources
	local values = table.create(count)
	for index, source in sources do
		values[index] = source._value
	end
	return self._compute(table.unpack(values, 1, count))
end

local State = {}

--- Creates a writable reactive value.
function State.new<T>(initialValue: T, options: Options<T>?): Value<T>
	local self = setmetatable({
		_value = initialValue,
		_equals = resolveEquals(options),
		_changed = Signal.new(),
		_destroyed = false,
	}, ValueClass)
	return (self :: any) :: Value<T>
end

--- Creates a read-only state derived from `sources`. `compute` receives the
--- current value of each source, in order.
---
--- ```lua
--- local total = State.computed({ price, quantity }, function(p, q) return p * q end)
--- ```
function State.computed<T>(sources: { any }, compute: (...any) -> T, options: Options<T>?): Computed<T>
	if type(sources) ~= "table" or #sources == 0 then
		error("[Constella.State] computed expects a non-empty array of source states", 2)
	end
	for index, source in sources do
		if not isState(source) then
			error(("[Constella.State] computed source #%d is not a Constella state"):format(index), 2)
		end
		if source._destroyed then
			error(("[Constella.State] computed source #%d is destroyed"):format(index), 2)
		end
	end
	if type(compute) ~= "function" then
		error(("[Constella.State] computed expects a function, got %s"):format(typeof(compute)), 2)
	end

	local self = setmetatable({
		_value = nil,
		_equals = resolveEquals(options),
		_changed = Signal.new(),
		_destroyed = false,
		_sources = table.clone(sources),
		_compute = compute,
		_sourceConnections = {},
	}, ComputedClass)

	self._value = evaluate(self)

	local function recompute()
		if self._destroyed then
			return
		end
		write(self, evaluate(self))
	end
	for _, source in self._sources do
		table.insert(self._sourceConnections, source._changed:Connect(recompute))
	end

	return (self :: any) :: Computed<T>
end

--- Shorthand for a computed state with a single source.
function State.select<T, U>(source: any, selector: (T) -> U, options: Options<U>?): Computed<U>
	return State.computed({ source }, selector, options)
end

--- Runs `fn` and delivers all resulting notifications once it returns.
--- Errors raised by `fn` are re-raised after notifications are delivered.
function State.batch(fn: () -> ())
	if type(fn) ~= "function" then
		error(("[Constella.State] batch expects a function, got %s"):format(typeof(fn)), 2)
	end
	batchDepth += 1
	local ok, err = pcall(fn :: any)
	batchDepth -= 1
	if batchDepth == 0 then
		flush()
	end
	if not ok then
		error(err, 0)
	end
end

--- Returns true if `value` is a Constella state (writable or computed).
State.is = isState

local BindingClass = {}
BindingClass.__index = BindingClass

function BindingClass.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false
	self._change:Disconnect()
	self._destroying:Disconnect()
end
BindingClass.Destroy = BindingClass.Disconnect

--- Keeps `instance[property]` equal to `source` (optionally passed through
--- `transform`). The binding ends when it is disconnected or when the
--- instance is destroyed. Errors while applying a later value are reported
--- like any subscriber error; an invalid property fails immediately.
---
--- ```lua
--- State.bind(coinsLabel, "Text", coins, function(value) return `Coins: {value}` end)
--- ```
function State.bind(instance: Instance, property: string, source: any, transform: ((any) -> any)?): Connection
	if typeof(instance) ~= "Instance" then
		error(("[Constella.State] bind expects an Instance, got %s"):format(typeof(instance)), 2)
	end
	if type(property) ~= "string" then
		error("[Constella.State] bind expects a property name", 2)
	end
	if not isState(source) then
		error("[Constella.State] bind expects a Constella state as the source", 2)
	end
	if source._destroyed then
		error("[Constella.State] Cannot bind a destroyed state", 2)
	end
	if transform ~= nil and type(transform) ~= "function" then
		error("[Constella.State] bind transform must be a function", 2)
	end

	local target: any = instance
	local function apply(value: any)
		target[property] = if transform then transform(value) else value
	end

	local ok, err = pcall(apply :: any, source._value)
	if not ok then
		error(("[Constella.State] Cannot bind %s.%s: %s"):format(instance:GetFullName(), property, tostring(err)), 2)
	end

	local binding = setmetatable({ Connected = true }, BindingClass) :: any
	binding._change = source._changed:Connect(function(newValue)
		apply(newValue)
	end)
	binding._destroying = instance.Destroying:Connect(function()
		binding:Disconnect()
	end)
	return binding
end

return table.freeze(State)
