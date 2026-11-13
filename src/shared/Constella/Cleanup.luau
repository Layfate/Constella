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
	Add: <T>(self: any, resource: T, method: string?) -> T,
	Set: <T>(self: any, key: any, resource: T, method: string?) -> T,
	Get: (self: any, key: any) -> any,
	Remove: (self: any, keyOrResource: any) -> boolean,
	Detach: (self: any, keyOrResource: any) -> any,
	Connect: (self: any, signal: any, callback: (...any) -> ()) -> any,
	Extend: (self: any) -> Cleanup,
	AttachToInstance: (self: any, instance: Instance) -> any,
	Clean: (self: any) -> (),
	Destroy: (self: any) -> (),
	Count: (self: any) -> number,
	IsDestroyed: (self: any) -> boolean,
}

type Kind = "function" | "thread" | "method"

type Entry = {
	resource: any,
	kind: Kind,
	method: string?,
	key: any,
}

local function hasMethod(value: any, name: string): boolean
	local ok, member = pcall(function()
		return value[name]
	end)
	return ok and type(member) == "function"
end

local function resolve(resource: any, method: string?, level: number): (Kind, string?)
	if method ~= nil then
		if type(method) ~= "string" then
			error(("[Constella.Cleanup] Method name must be a string, got %s"):format(typeof(method)), level)
		end
		if not hasMethod(resource, method) then
			error(("[Constella.Cleanup] Resource of type %s has no method '%s'"):format(typeof(resource), method), level)
		end
		return "method", method
	end

	local valueType = typeof(resource)
	if valueType == "function" then
		return "function", nil
	elseif valueType == "thread" then
		return "thread", nil
	elseif valueType == "Instance" then
		return "method", "Destroy"
	elseif valueType == "RBXScriptConnection" then
		return "method", "Disconnect"
	elseif valueType == "table" then
		if hasMethod(resource, "Destroy") then
			return "method", "Destroy"
		elseif hasMethod(resource, "Disconnect") then
			return "method", "Disconnect"
		elseif hasMethod(resource, "Cancel") then
			return "method", "Cancel"
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

local function dispose(entry: Entry)
	local resource = entry.resource
	if entry.kind == "function" then
		resource()
	elseif entry.kind == "thread" then
		cancelThread(resource)
	else
		resource[entry.method :: string](resource)
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

local function findEntry(self: any, keyOrResource: any): Entry?
	local keyed = self._keys[keyOrResource]
	if keyed then
		return keyed
	end
	for _, entry in self._entries do
		if rawequal(entry.resource, keyOrResource) then
			return entry
		end
	end
	return nil
end

local function unlink(self: any, entry: Entry)
	local index = table.find(self._entries, entry)
	if index then
		table.remove(self._entries, index)
	end
	if entry.key ~= nil and self._keys[entry.key] == entry then
		self._keys[entry.key] = nil
	end
end

local function addEntry(self: any, resource: any, method: string?, key: any, level: number): any
	if resource == nil then
		error("[Constella.Cleanup] Cannot add nil", level)
	end
	local kind, resolvedMethod = resolve(resource, method, level + 1)
	local entry: Entry = { resource = resource, kind = kind, method = resolvedMethod, key = key }

	if self._destroyed then
		local ok, err = pcall(dispose, entry)
		if not ok then
			error(("[Constella.Cleanup] A resource added after Destroy failed to clean up: %s"):format(tostring(err)), level)
		end
		return resource
	end

	table.insert(self._entries, entry)
	if key ~= nil then
		self._keys[key] = entry
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
	local previous: Entry? = self._keys[key]
	if previous and rawequal(previous.resource, resource) then
		return resource
	end
	if previous then
		unlink(self, previous)
	end
	if resource ~= nil then
		addEntry(self, resource, method, key, 3)
	end
	if previous then
		local ok, err = pcall(dispose, previous)
		if not ok then
			error(("[Constella.Cleanup] Previous resource under key %s failed to clean up: %s"):format(tostring(key), tostring(err)), 2)
		end
	end
	return resource
end

--- Returns the resource stored under `key`, or nil.
function CleanupClass.Get(self: any, key: any): any
	local entry = self._keys[key]
	return if entry then entry.resource else nil
end

--- Cleans a single resource now (looked up by key first, then by value).
--- Returns false if it was not found.
function CleanupClass.Remove(self: any, keyOrResource: any): boolean
	local entry = findEntry(self, keyOrResource)
	if not entry then
		return false
	end
	unlink(self, entry)
	local ok, err = pcall(dispose, entry)
	if not ok then
		error(("[Constella.Cleanup] Remove failed to clean up resource: %s"):format(tostring(err)), 2)
	end
	return true
end

--- Stops tracking a resource WITHOUT cleaning it, and returns it.
function CleanupClass.Detach(self: any, keyOrResource: any): any
	local entry = findEntry(self, keyOrResource)
	if not entry then
		return nil
	end
	unlink(self, entry)
	return entry.resource
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
	return addEntry(self, instance.Destroying:Connect(function()
		self:Destroy()
	end), nil, nil, 3)
end

local function clean(self: any, level: number)
	if self._cleaning then
		-- Re-entrant call from inside a disposer: the outer loop finishes the job.
		return
	end
	self._cleaning = true
	local errors: { string }? = nil
	local entries = self._entries
	while true do
		local entry = table.remove(entries)
		if entry == nil then
			break
		end
		if entry.key ~= nil and self._keys[entry.key] == entry then
			self._keys[entry.key] = nil
		end
		local ok, err = pcall(dispose, entry)
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
	return #self._entries
end

function CleanupClass.IsDestroyed(self: any): boolean
	return self._destroyed
end

function Cleanup.new(): Cleanup
	local self = setmetatable({
		_entries = {} :: { Entry },
		_keys = {} :: { [any]: Entry },
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
