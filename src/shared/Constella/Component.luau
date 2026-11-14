--!strict
--[=[
	Constella.Component

	Attaches behaviour to every Instance with a CollectionService tag.

	```lua
	local Spinner = { Tag = "Spinner" }

	function Spinner:Start()
		self.Cleanup:Connect(RunService.Heartbeat, function(dt)
			self.Instance.CFrame *= CFrame.Angles(0, dt, 0)
		end)
	end

	local spinners = Component.new(Spinner)
	spinners:Run()
	```

	Semantics
	- An object is created for a tagged instance only while the instance is
	  inside one of `Ancestors` (default: { workspace }) and passes `Filter`.
	  Moving it out (or streaming it out on a client) detaches it; moving it
	  back attaches a fresh object.
	- Each object has `self.Instance`, `self.Cleanup` (destroyed on detach)
	  and `self.Component` (the manager). Methods are looked up on the
	  definition table, so `function Spinner:Foo()` is available as `self:Foo()`.
	- Start runs on its own thread. If it errors before yielding, the object
	  is detached and the error reported; Added does not fire.
	- On detach: Stop runs, then the object's Cleanup is destroyed, then
	  Removed fires. Errors are reported, never swallowed.
]=]

local CollectionService = game:GetService("CollectionService")

local Signal = require(script.Parent.Signal)
local Cleanup = require(script.Parent.Cleanup)

export type Definition = {
	Tag: string,
	Ancestors: { Instance }?,
	Filter: ((instance: Instance) -> boolean)?,
	Start: ((self: Definition) -> ())?,
	Stop: ((self: Definition) -> ())?,
	[string]: any,
}

export type Options = {
	OnError: ((message: string) -> ())?,
}

export type Object = {
	Instance: Instance,
	Cleanup: Cleanup.Cleanup,
	Component: any,
	[string]: any,
}

export type Component = {
	Tag: string,
	Added: Signal.Signal<any>,
	Removed: Signal.Signal<any>,
	Run: (self: Component) -> (),
	Get: (self: Component, instance: Instance) -> any,
	GetAll: (self: Component) -> { any },
	Destroy: (self: Component) -> (),
}

local PREFIX = "[Constella.Component] "

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

local ComponentClass = {}
ComponentClass.__index = ComponentClass

local function qualifies(self: any, instance: Instance): boolean
	if not CollectionService:HasTag(instance, self.Tag) then
		return false
	end
	local inside = false
	for _, ancestor in self._ancestors do
		if instance:IsDescendantOf(ancestor) then
			inside = true
			break
		end
	end
	if not inside then
		return false
	end
	local filter = self._definition.Filter
	if filter then
		local ok, result = pcall(filter, instance)
		if not ok then
			self._onError(PREFIX .. ("Filter for '%s' failed: %s"):format(self.Tag, tostring(result)))
			return false
		end
		return result == true
	end
	return true
end

local function detach(self: any, instance: Instance)
	local object = self._objects[instance]
	if object == nil then
		return
	end
	self._objects[instance] = nil
	local definition = self._definition
	if definition.Stop and object._started then
		local ok, err = xpcall(definition.Stop, traceback, object)
		if not ok then
			self._onError(PREFIX .. ("Stop failed for %s: %s"):format(instance:GetFullName(), tostring(err)))
		end
	end
	local ok, err = pcall(function()
		object.Cleanup:Destroy()
	end)
	if not ok then
		self._onError(PREFIX .. ("Cleanup failed for %s: %s"):format(instance:GetFullName(), tostring(err)))
	end
	if object._announced then
		self.Removed:Fire(object)
	end
end

local function attach(self: any, instance: Instance)
	if self._objects[instance] then
		return
	end
	local object = setmetatable({
		Instance = instance,
		Cleanup = Cleanup.new(),
		Component = self,
		_started = false,
		_announced = false,
	}, self._objectMeta)
	self._objects[instance] = object

	local definition = self._definition
	if definition.Start then
		local synchronous = true
		local failed = false
		object._started = true
		task.spawn(function()
			local ok, err = xpcall(definition.Start, traceback, object)
			if not ok then
				self._onError(PREFIX .. ("Start failed for %s: %s"):format(instance:GetFullName(), tostring(err)))
				if synchronous then
					failed = true
				end
			end
		end)
		synchronous = false
		if failed then
			object._started = false -- Stop is for objects whose Start succeeded or is running
			detach(self, instance)
			return
		end
	end
	-- Start may have detached the object (e.g. by removing the tag).
	if self._objects[instance] == object then
		object._announced = true
		self.Added:Fire(object)
	end
end

local function evaluate(self: any, instance: Instance)
	if self._destroyed then
		return
	end
	if qualifies(self, instance) then
		attach(self, instance)
	else
		detach(self, instance)
	end
end

local function watch(self: any, instance: Instance)
	if self._watched[instance] then
		return
	end
	self._watched[instance] = instance.AncestryChanged:Connect(function()
		evaluate(self, instance)
	end)
	evaluate(self, instance)
end

local function unwatch(self: any, instance: Instance)
	local connection = self._watched[instance]
	if connection then
		connection:Disconnect()
		self._watched[instance] = nil
	end
	detach(self, instance)
end

--- Starts observing the tag. Connect to Added/Removed first if you need
--- events for instances that already exist.
function ComponentClass.Run(self: any)
	if self._destroyed then
		error(PREFIX .. "Cannot run a destroyed Component", 2)
	end
	if self._running then
		error(PREFIX .. ("Component '%s' is already running"):format(self.Tag), 2)
	end
	self._running = true
	self._cleanup:Connect(CollectionService:GetInstanceAddedSignal(self.Tag), function(instance: Instance)
		watch(self, instance)
	end)
	self._cleanup:Connect(CollectionService:GetInstanceRemovedSignal(self.Tag), function(instance: Instance)
		unwatch(self, instance)
	end)
	for _, instance in CollectionService:GetTagged(self.Tag) do
		watch(self, instance)
	end
end

--- Returns the object attached to `instance`, or nil.
function ComponentClass.Get(self: any, instance: Instance): any
	return self._objects[instance]
end

function ComponentClass.GetAll(self: any): { any }
	local objects = {}
	for _, object in self._objects do
		table.insert(objects, object)
	end
	return objects
end

--- Detaches every object (Stop, Cleanup, Removed) and stops observing.
function ComponentClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._cleanup:Destroy()
	local instances = {}
	for instance in self._watched do
		table.insert(instances, instance)
	end
	for _, instance in instances do
		unwatch(self, instance)
	end
	self._destroyed = true
	self.Added:Destroy()
	self.Removed:Destroy()
end

local Component = {}

function Component.new(definition: Definition, options: Options?): Component
	if type(definition) ~= "table" then
		error(PREFIX .. "Component.new expects a definition table", 2)
	end
	if type(definition.Tag) ~= "string" or definition.Tag == "" then
		error(PREFIX .. "Definition needs a non-empty string Tag", 2)
	end
	for _, field in { "Start", "Stop", "Filter" } do
		local value = definition[field]
		if value ~= nil and type(value) ~= "function" then
			error(PREFIX .. ("Definition %s must be a function"):format(field), 2)
		end
	end
	local ancestors: { any } = definition.Ancestors or { workspace }
	if type(ancestors) ~= "table" or #ancestors == 0 then
		error(PREFIX .. "Ancestors must be a non-empty array of Instances", 2)
	end
	for _, ancestor in ancestors do
		if typeof(ancestor) ~= "Instance" then
			error(PREFIX .. "Ancestors must be a non-empty array of Instances", 2)
		end
	end
	if options ~= nil and options.OnError ~= nil and type(options.OnError) ~= "function" then
		error(PREFIX .. "OnError must be a function", 2)
	end

	local self = setmetatable({
		Tag = definition.Tag,
		Added = Signal.new(),
		Removed = Signal.new(),
		_definition = definition,
		_objectMeta = { __index = definition },
		_ancestors = table.clone(ancestors),
		_objects = {},
		_watched = {},
		_cleanup = Cleanup.new(),
		_running = false,
		_destroyed = false,
		_onError = (options and options.OnError) or function(message: string)
			task.spawn(error, message, 0)
		end,
	}, ComponentClass)
	return (self :: any) :: Component
end

return table.freeze(Component)
