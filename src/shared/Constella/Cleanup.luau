--!strict
--[=[
	Constella.Cleanup

	Owns resources and disposes them together.

	Supported resources (detected automatically)
	- function             -> called
	- thread               -> cancelled (task.cancel)
	- Instance             -> :Destroy()
	- RBXScriptConnection  -> :Disconnect()
	- table with Destroy, Disconnect or Cancel (e.g. Signal, Connection,
	  nested Cleanup, Promise)
	Any other value can be added with an explicit method name:
	`cleanup:Add(tween, "Cancel")`.

	Semantics
	- Resources are disposed in reverse order of addition (LIFO).
	- Clean/Destroy are idempotent: a resource is disposed at most once.
	- If a disposal fails, the remaining resources are still disposed; one
	  aggregated error is raised afterwards (nothing is silently swallowed).
	- After Destroy, anything added is disposed immediately. This makes
	  "async work finished after its owner died" races safe by default.
	- Clean leaves the manager usable; Destroy does not.
]=]

export type Cleanup = {
	Add: <T>(self: Cleanup, resource: T, method: string?) -> T,
	Set: <T>(self: Cleanup, key: any, resource: T, method: string?) -> T,
	Get: (self: Cleanup, key: any) -> any,
	Remove: (self: Cleanup, keyOrResource: any) -> boolean,
	Detach: (self: Cleanup, keyOrResource: any) -> any,
	Connect: (self: Cleanup, signal: any, callback: (...any) -> ()) -> any,
	Extend: (self: Cleanup) -> Cleanup,
	AttachToInstance: (self: Cleanup, instance: Instance) -> any,
	Clean: (self: Cleanup) -> (),
	Destroy: (self: Cleanup) -> (),
	Count: (self: Cleanup) -> number,
	IsDestroyed: (self: Cleanup) -> boolean,
}

-- Storage: two parallel arrays, so tracking a plain resource costs two
-- array slots instead of a table per resource. The method column holds a
-- method name (string) or one of these markers. Keyed resources (Set) are
-- stored as a small record { resource, method, key } marked KEYED.
local CALL = table.freeze({}) -- function: call it
local CANCEL = table.freeze({}) -- thread: cancel it
local KEYED = table.freeze({}) -- keyed record

local function getMember(value: any, name: string): any
	return value[name]
end

-- Indexing can raise (a missing Instance member, a strict __index), so it
-- runs under pcall; `getMember` is shared so no closure is created per check.
local function hasMethod(value: any, name: string): boolean
	local ok, member = pcall(getMember, value, name)
	return ok and type(member) == "function"
end

local function resolve(resource: any, method: string?, level: number): any
	if method ~= nil then
		if type(method) ~= "string" then
			error(("[Constella.Cleanup] Method name must be a string, got %s"):format(typeof(method)), level)
		end
		if not hasMethod(resource, method) then
			error(
				("[Constella.Cleanup] Resource of type %s has no method '%s'"):format(typeof(resource), method),
				level
			)
		end
		return method
	end

	local valueType = typeof(resource)
	if valueType == "function" then
		return CALL
	elseif valueType == "thread" then
		return CANCEL
	elseif valueType == "Instance" then
		return "Destroy"
	elseif valueType == "RBXScriptConnection" then
		return "Disconnect"
	elseif valueType == "table" then
		if hasMethod(resource, "Destroy") then
			return "Destroy"
		elseif hasMethod(resource, "Disconnect") then
			return "Disconnect"
		elseif hasMethod(resource, "Cancel") then
			return "Cancel"
		end
	end

	error(
		("[Constella.Cleanup] Don't know how to clean a value of type %s; pass a method name as the second argument"):format(
			valueType
		),
		level
	)
end

local function cancelThread(thread: thread)
	local status = coroutine.status(thread)
	if status == "suspended" then
		task.cancel(thread)
	elseif status ~= "dead" then
		-- The thread is currently running (e.g. it is cleaning up its own
		-- owner). It cannot be cancelled right now, so cancel it as soon as
		-- it yields.
		task.defer(function()
			if coroutine.status(thread) == "suspended" then
				task.cancel(thread)
			end
		end)
	end
end

local function dispose(resource: any, method: any)
	if method == CALL then
		resource()
	elseif method == CANCEL then
		cancelThread(resource)
	elseif method == KEYED then
		dispose(resource.resource, resource.method)
	else
		resource[method](resource)
	end
end

local function formatErrors(errors: { string }): string
	return ("[Constella.Cleanup] %d resource(s) failed to clean up (all others were cleaned):\n%s"):format(
		#errors,
		table.concat(errors, "\n")
	)
end

local Cleanup = {}

local CleanupClass = {}
CleanupClass.__index = CleanupClass

-- Position of a resource, looked up by key first, then by value.
local function indexOf(self: any, keyOrResource: any): number?
	local record = self._keys[keyOrResource]
	if record then
		return table.find(self._resources, record)
	end
	local methods = self._methods
	for index, resource in self._resources do
		if methods[index] == KEYED then
			if rawequal(resource.resource, keyOrResource) then
				return index
			end
		elseif rawequal(resource, keyOrResource) then
			return index
		end
	end
	return nil
end

-- Removes the entry at `index` and returns its stored resource and method.
local function removeAt(self: any, index: number): (any, any)
	local resource = table.remove(self._resources, index)
	local method = table.remove(self._methods, index)
	if method == KEYED and self._keys[resource.key] == resource then
		self._keys[resource.key] = nil
	end
	return resource, method
end

local function addEntry(self: any, resource: any, method: string?, key: any, level: number): any
	if resource == nil then
		error("[Constella.Cleanup] Cannot add nil", level)
	end
	local resolved = resolve(resource, method, level + 1)

	if self._destroyed then
		local ok, err = pcall(dispose :: any, resource, resolved)
		if not ok then
			error(
				("[Constella.Cleanup] A resource added after Destroy failed to clean up: %s"):format(tostring(err)),
				level
			)
		end
		return resource
	end

	if key ~= nil then
		local record = { resource = resource, method = resolved, key = key }
		table.insert(self._resources, record)
		table.insert(self._methods, KEYED)
		self._keys[key] = record
	else
		table.insert(self._resources, resource)
		table.insert(self._methods, resolved)
	end
	return resource
end

--- Adds a resource and returns it, so calls can be inlined:
--- `local part = cleanup:Add(Instance.new("Part"))`
function CleanupClass.Add(self: any, resource: any, method: string?): any
	return addEntry(self, resource, method, nil, 3)
end

--- Stores a resource under `key`. The previous resource under the same key
--- is cleaned. `Set(key, nil)` cleans and clears the key.
function CleanupClass.Set(self: any, key: any, resource: any, method: string?): any
	if key == nil then
		error("[Constella.Cleanup] Key must not be nil", 2)
	end
	local previous = self._keys[key]
	if previous and rawequal(previous.resource, resource) then
		return resource
	end
	if previous then
		local index = table.find(self._resources, previous)
		if index then
			removeAt(self, index)
		end
		self._keys[key] = nil
	end
	if resource ~= nil then
		addEntry(self, resource, method, key, 3)
	end
	if previous then
		local ok, err = pcall(dispose :: any, previous.resource, previous.method)
		if not ok then
			error(
				("[Constella.Cleanup] Previous resource under key %s failed to clean up: %s"):format(
					tostring(key),
					tostring(err)
				),
				2
			)
		end
	end
	return resource
end

--- Returns the resource stored under `key`, or nil.
function CleanupClass.Get(self: any, key: any): any
	local record = self._keys[key]
	return if record then record.resource else nil
end

--- Cleans a single resource now (looked up by key first, then by value).
--- Returns false if it was not found.
function CleanupClass.Remove(self: any, keyOrResource: any): boolean
	local index = indexOf(self, keyOrResource)
	if not index then
		return false
	end
	local resource, method = removeAt(self, index)
	local ok, err = pcall(dispose :: any, resource, method)
	if not ok then
		error(("[Constella.Cleanup] Remove failed to clean up resource: %s"):format(tostring(err)), 2)
	end
	return true
end

--- Stops tracking a resource WITHOUT cleaning it, and returns it.
function CleanupClass.Detach(self: any, keyOrResource: any): any
	local index = indexOf(self, keyOrResource)
	if not index then
		return nil
	end
	local resource, method = removeAt(self, index)
	return if method == KEYED then resource.resource else resource
end

--- Connects to an RBXScriptSignal or Constella Signal and tracks the connection.
function CleanupClass.Connect(self: any, signal: any, callback: (...any) -> ()): any
	return addEntry(self, signal:Connect(callback), nil, nil, 3)
end

--- Creates a child Cleanup that is destroyed together with this one.
function CleanupClass.Extend(self: any): any
	local child = Cleanup.new()
	return addEntry(self, child, "Destroy", nil, 3)
end

--- Destroys this Cleanup when `instance` is destroyed.
function CleanupClass.AttachToInstance(self: any, instance: Instance): any
	if typeof(instance) ~= "Instance" then
		error(("[Constella.Cleanup] AttachToInstance expects an Instance, got %s"):format(typeof(instance)), 2)
	end
	return addEntry(
		self,
		instance.Destroying:Connect(function()
			self:Destroy()
		end),
		nil,
		nil,
		3
	)
end

local function clean(self: any, level: number)
	if self._cleaning then
		-- Re-entrant call from inside a disposer: the outer loop finishes the job.
		return
	end
	self._cleaning = true
	local errors: { string }? = nil
	local resources, methods = self._resources, self._methods
	while true do
		local count = #resources
		if count == 0 then
			break
		end
		-- Last in, first out. Read and clear before disposing, because a
		-- disposer may add or remove resources on this same manager.
		local resource, method = resources[count], methods[count]
		resources[count] = nil
		methods[count] = nil
		if method == KEYED and self._keys[resource.key] == resource then
			self._keys[resource.key] = nil
		end
		local ok, err = pcall(dispose :: any, resource, method)
		if not ok then
			errors = errors or {}
			table.insert(errors :: { string }, tostring(err))
		end
	end
	self._cleaning = false
	if errors then
		error(formatErrors(errors), level)
	end
end

--- Cleans every resource. The manager stays usable afterwards.
function CleanupClass.Clean(self: any)
	clean(self, 3)
end

--- Cleans every resource and marks the manager destroyed. Idempotent.
function CleanupClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	clean(self, 3)
end

function CleanupClass.Count(self: any): number
	return #self._resources
end

function CleanupClass.IsDestroyed(self: any): boolean
	return self._destroyed
end

function Cleanup.new(): Cleanup
	local self = setmetatable({
		_resources = {},
		_methods = {},
		_keys = {},
		_destroyed = false,
		_cleaning = false,
	}, CleanupClass)
	return (self :: any) :: Cleanup
end

--- Returns true if `value` is a Constella Cleanup.
function Cleanup.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == CleanupClass
end

return table.freeze(Cleanup)
