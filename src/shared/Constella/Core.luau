--!strict
--[=[
	Constella.Core

	Explicit application instances that own services (server) or
	controllers (client) and run their lifecycle in dependency order.

	```lua
	local app = Constella.App.new()
	app:Add(require(script.Services.InventoryService))
	app:Start()
	```

	Lifecycle
	1. Add       - definitions are validated (name, duplicates, environment).
	2. Start     - dependencies are resolved: missing dependencies and cycles
	               fail before any user code runs.
	             - Init runs for every definition, sequentially, in
	               dependency order. Init may yield.
	             - Start runs for every definition in dependency order, each
	               on its own thread. An error raised before Start first
	               yields fails startup; an error after a yield is reported
	               through OnError and the app keeps running.
	             - A definition with WaitForStart = true is a readiness
	               gate: Start (yields included) must finish before later
	               definitions start and before the app is Running. An
	               error at any point, or running past StartTimeout
	               (default 30s), fails startup. App:Start then yields.
	             - If startup fails, Stop runs (reverse order) for every
	               definition whose Init completed, their Cleanup is
	               destroyed and Start raises the error. The app is then
	               "Failed" and cannot be restarted.
	3. Stop      - Stop runs in reverse dependency order, then each
	               context's Cleanup is destroyed. Idempotent.

	A Start that is still running when its definition stops (it yielded and
	never returned, like a `while true do ... task.wait() end` loop) is
	cancelled just before that definition's Stop, both on App:Stop and on
	a failed startup. Threads that Start spawns itself are not tracked: add
	them to context.Cleanup.

	An app can only be started once.
]=]

local Signal = require(script.Parent.Signal)
local Cleanup = require(script.Parent.Cleanup)

export type Environment = "Server" | "Client" | "Shared"
export type AppState = "Idle" | "Starting" | "Running" | "Stopping" | "Stopped" | "Failed"

export type Context = {
	--- The app this definition belongs to.
	App: App,
	--- The definition's name.
	Name: string,
	--- Destroyed automatically after Stop (or after a failed startup).
	Cleanup: Cleanup.Cleanup,
	--- Returns a declared dependency. Undeclared names raise an error.
	Get: (self: Context, name: string) -> any,
}

export type Definition = {
	Name: string,
	Dependencies: { string }?,
	Environment: Environment?,
	Init: ((self: Definition, context: Context) -> ())?,
	Start: ((self: Definition, context: Context) -> ())?,
	Stop: ((self: Definition, context: Context) -> ())?,
	--- Make App:Start wait for this definition's Start to finish (even if it
	--- yields). Any Start error then fails startup. Defaults to false.
	WaitForStart: boolean?,
	--- Seconds a WaitForStart definition may take. Defaults to 30.
	StartTimeout: number?,
	[string]: any,
}

export type AppOptions = {
	Name: string?,
	--- Defaults to "Server" on the server and "Client" on a client.
	Environment: ("Server" | "Client")?,
	--- Receives errors that cannot be raised to a caller (errors thrown by
	--- Start after it yielded). Defaults to re-raising on a new thread.
	OnError: ((message: string) -> ())?,
}

export type AddModulesOptions = {
	Recursive: boolean?,
	Filter: ((module: ModuleScript) -> boolean)?,
}

export type App = {
	Name: string,
	Environment: "Server" | "Client",
	Started: Signal.Signal<()>,
	Stopped: Signal.Signal<()>,
	Add: <T>(self: App, definition: T) -> T,
	AddModules: (self: App, container: Instance, options: AddModulesOptions?) -> { any },
	Get: (self: App, name: string) -> any,
	Has: (self: App, name: string) -> boolean,
	GetOrder: (self: App) -> { string },
	GetState: (self: App) -> AppState,
	Start: (self: App) -> (),
	AwaitStart: (self: App) -> (),
	Stop: (self: App) -> (),
}

local PREFIX = "[Constella.App] "
local LIFECYCLE_METHODS = { "Init", "Start", "Stop" }
local DEFAULT_START_TIMEOUT = 30

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

local function detectEnvironment(): "Server" | "Client"
	local RunService = game:GetService("RunService")
	if RunService:IsServer() then
		return "Server"
	end
	return "Client"
end

local function validateDefinition(app: any, definition: any, source: string?, level: number)
	local where = if source then (" (from %s)"):format(source) else ""
	if type(definition) ~= "table" then
		error(PREFIX .. ("Definition must be a table, got %s%s"):format(typeof(definition), where), level)
	end
	local name = definition.Name
	if type(name) ~= "string" or name == "" then
		error(PREFIX .. ("Definition needs a non-empty string Name%s"):format(where), level)
	end
	if app._byName[name] ~= nil then
		error(PREFIX .. ("'%s' was already added to app '%s'%s"):format(name, app.Name, where), level)
	end

	local dependencies = definition.Dependencies
	if dependencies ~= nil then
		if type(dependencies) ~= "table" then
			error(PREFIX .. ("'%s'.Dependencies must be an array of names"):format(name), level)
		end
		local seen = {}
		for index, dependency in dependencies do
			if type(index) ~= "number" or type(dependency) ~= "string" then
				error(PREFIX .. ("'%s'.Dependencies must be an array of names"):format(name), level)
			end
			if dependency == name then
				error(PREFIX .. ("'%s' cannot depend on itself"):format(name), level)
			end
			if seen[dependency] then
				error(PREFIX .. ("'%s' lists dependency '%s' twice"):format(name, dependency), level)
			end
			seen[dependency] = true
		end
	end

	for _, method in LIFECYCLE_METHODS do
		local value = definition[method]
		if value ~= nil and type(value) ~= "function" then
			error(PREFIX .. ("'%s'.%s must be a function, got %s"):format(name, method, typeof(value)), level)
		end
	end

	if definition.WaitForStart ~= nil and type(definition.WaitForStart) ~= "boolean" then
		error(PREFIX .. ("'%s'.WaitForStart must be a boolean"):format(name), level)
	end
	local startTimeout = definition.StartTimeout
	if
		startTimeout ~= nil
		and (type(startTimeout) ~= "number" or not (startTimeout > 0) or startTimeout == math.huge)
	then
		error(PREFIX .. ("'%s'.StartTimeout must be a positive number of seconds"):format(name), level)
	end

	local environment = definition.Environment
	if environment ~= nil and environment ~= "Server" and environment ~= "Client" and environment ~= "Shared" then
		error(PREFIX .. ('\'%s\'.Environment must be "Server", "Client" or "Shared"'):format(name), level)
	end
	if environment ~= nil and environment ~= "Shared" and environment ~= app.Environment then
		error(
			PREFIX
				.. ("'%s' is a %s-only definition and cannot be added to a %s app"):format(
					name,
					environment:lower(),
					app.Environment:lower()
				),
			level
		)
	end
end

local function resolveOrder(app: any): { any }
	-- Report every missing dependency at once.
	local missing = {}
	for _, definition in app._definitions do
		for _, dependency in definition.Dependencies or {} do
			if app._byName[dependency] == nil then
				table.insert(missing, ("'%s' -> '%s'"):format(definition.Name, dependency))
			end
		end
	end
	if #missing > 0 then
		error(PREFIX .. "Missing dependencies (not added to the app): " .. table.concat(missing, ", "), 0)
	end

	-- Depth-first topological sort. Deterministic: definitions are visited in
	-- registration order, dependencies in declared order.
	local order = {}
	local marks: { [string]: "visiting" | "done" } = {}
	local path: { string } = {}

	local function visit(definition: any)
		local name = definition.Name
		local mark = marks[name]
		if mark == "done" then
			return
		end
		if mark == "visiting" then
			local start = table.find(path, name) :: number
			local cycle = table.move(path, start, #path, 1, {})
			table.insert(cycle, name)
			error(PREFIX .. "Circular dependency: " .. table.concat(cycle, " -> "), 0)
		end
		marks[name] = "visiting"
		table.insert(path, name)
		for _, dependency in definition.Dependencies or {} do
			visit(app._byName[dependency])
		end
		table.remove(path)
		marks[name] = "done"
		table.insert(order, definition)
	end

	for _, definition in app._definitions do
		visit(definition)
	end
	return order
end

local function createContext(app: any, definition: any): Context
	local allowed = {}
	for _, dependency in definition.Dependencies or {} do
		allowed[dependency] = true
	end
	local context = {
		App = app,
		Name = definition.Name,
		Cleanup = Cleanup.new(),
	}
	function context.Get(_: any, name: string): any
		if not allowed[name] then
			error(
				PREFIX
					.. ("'%s' accessed '%s' without listing it in Dependencies"):format(definition.Name, tostring(name)),
				2
			)
		end
		return app._byName[name]
	end
	return table.freeze(context) :: any
end

-- Runs Stop (reverse order) and destroys each context's Cleanup.
-- Returns the collected error messages; never throws.
local function teardown(app: any, definitions: { any }): { string }
	local errors = {}
	for index = #definitions, 1, -1 do
		local definition = definitions[index]
		local context = app._contexts[definition.Name]
		-- A Start that is still running (it yielded and never returned) must
		-- not keep working while its definition stops.
		local startThread = app._startThreads[definition.Name]
		if startThread then
			app._startThreads[definition.Name] = nil
			if coroutine.status(startThread) == "suspended" then
				pcall(task.cancel, startThread)
			end
		end
		if definition.Stop then
			local ok, err = xpcall(definition.Stop, traceback, definition, context)
			if not ok then
				table.insert(errors, ("Stop failed for '%s': %s"):format(definition.Name, err))
			end
		end
		local ok, err = pcall(function()
			context.Cleanup:Destroy()
		end)
		if not ok then
			table.insert(errors, ("Cleanup failed for '%s': %s"):format(definition.Name, tostring(err)))
		end
	end
	return errors
end

-- Resumes a waiting thread unless it was cancelled while it waited (then it
-- is dead, and resuming it would raise).
local function resume(thread: thread, ...: any)
	if coroutine.status(thread) == "suspended" then
		task.spawn(thread, ...)
	end
end

local function resumeWaiters(app: any, ok: boolean, message: string?)
	local waiting = app._waiting
	app._waiting = {}
	for _, thread in waiting do
		resume(thread, ok, message)
	end
end

local AppClass = {}
AppClass.__index = AppClass

local function add(self: any, definition: any, source: string?, level: number): any
	if self._state ~= "Idle" then
		local name = if type(definition) == "table" then tostring(definition.Name) else "?"
		error(PREFIX .. ("Cannot add '%s': app '%s' has already been started"):format(name, self.Name), level)
	end
	validateDefinition(self, definition, source, level + 1)
	self._byName[definition.Name] = definition
	table.insert(self._definitions, definition)
	return definition
end

--- Registers a service/controller definition. Returns it unchanged.
function AppClass.Add(self: any, definition: any): any
	return add(self, definition, nil, 3)
end

--- Requires and adds every ModuleScript in `container` (children only,
--- or all descendants with `Recursive = true`), sorted by full name so the
--- result does not depend on instance order. This is explicit: nothing is
--- discovered unless you point it at a container.
function AppClass.AddModules(self: any, container: Instance, options: AddModulesOptions?): { any }
	if typeof(container) ~= "Instance" then
		error(PREFIX .. ("AddModules expects an Instance, got %s"):format(typeof(container)), 2)
	end
	local recursive = options ~= nil and options.Recursive == true
	local filter = if options then options.Filter else nil
	local candidates: { Instance } = if recursive then container:GetDescendants() else container:GetChildren()
	local modules = {}
	for _, instance in candidates do
		if instance:IsA("ModuleScript") and (filter == nil or filter(instance)) then
			table.insert(modules, instance)
		end
	end
	table.sort(modules, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)

	local added = {}
	for _, module in modules do
		local ok, result = pcall(require, module)
		if not ok then
			error(PREFIX .. ("Failed to require %s: %s"):format(module:GetFullName(), tostring(result)), 2)
		end
		table.insert(added, add(self, result, module:GetFullName(), 3))
	end
	return added
end

--- Returns the definition registered under `name`.
function AppClass.Get(self: any, name: string): any
	local definition = self._byName[name]
	if definition == nil then
		error(PREFIX .. ("'%s' was not added to app '%s'"):format(tostring(name), self.Name), 2)
	end
	return definition
end

function AppClass.Has(self: any, name: string): boolean
	return self._byName[name] ~= nil
end

--- Returns the resolved startup order (empty until Start).
function AppClass.GetOrder(self: any): { string }
	local names = {}
	for _, definition in self._order do
		table.insert(names, definition.Name)
	end
	return names
end

function AppClass.GetState(self: any): AppState
	return self._state
end

local function fail(self: any, message: string)
	self._state = "Failed"
	self._failure = message
	resumeWaiters(self, false, message)
	error(message, 0)
end

function AppClass.Start(self: any)
	if self._state ~= "Idle" then
		error(
			PREFIX
				.. ("Cannot start app '%s': it is %s (an app can only be started once)"):format(
					self.Name,
					self._state:lower()
				),
			2
		)
	end
	self._state = "Starting"

	local resolved, orderOrError = pcall(resolveOrder, self)
	if not resolved then
		fail(self, tostring(orderOrError))
	end
	local order = orderOrError :: { any }
	self._order = order

	-- Init: sequential, in dependency order. Fail fast.
	local initialized = {}
	for _, definition in order do
		local context = createContext(self, definition)
		self._contexts[definition.Name] = context
		if definition.Init then
			local ok, err = xpcall(definition.Init, traceback, definition, context)
			if not ok then
				-- The failing definition's own Cleanup is destroyed too.
				table.insert(initialized, definition)
				local stopErrors = teardown(self, initialized)
				local message = PREFIX .. ("Init failed for '%s': %s"):format(definition.Name, err)
				if #stopErrors > 0 then
					message ..= "\nWhile rolling back:\n" .. table.concat(stopErrors, "\n")
				end
				fail(self, message)
			end
		end
		table.insert(initialized, definition)
	end
	self._initialized = initialized

	-- Start: each on its own thread, in dependency order.
	for _, definition in order do
		if definition.Start then
			local context = self._contexts[definition.Name]
			local waits = definition.WaitForStart == true

			-- "Settled" means startup no longer waits on this definition: its
			-- Start returned, failed, timed out, or (without WaitForStart)
			-- yielded. Errors raised after settling go to OnError.
			local settled = false
			local failure: string? = nil
			local waiter: thread? = nil
			local function settle(err: string?): boolean
				if settled then
					return false
				end
				settled = true
				failure = err
				if waiter then
					resume(waiter)
				end
				return true
			end

			local startThread = task.spawn(function()
				local ok, err = xpcall(definition.Start, traceback, definition, context)
				if not settle(if ok then nil else err) and not ok then
					self._onError(PREFIX .. ("Start for '%s' failed after yielding: %s"):format(definition.Name, err))
				end
			end)
			self._startThreads[definition.Name] = startThread

			if not settled then
				if waits then
					local timeout = definition.StartTimeout or DEFAULT_START_TIMEOUT
					local timer = task.delay(timeout, function()
						if settled then
							return
						end
						-- Cancel the stuck Start before rolling back, so it can't
						-- keep running while its Stop and Cleanup execute.
						if coroutine.status(startThread) == "suspended" then
							pcall(task.cancel, startThread)
						end
						settle(("did not finish within %s seconds"):format(tostring(timeout)))
					end)
					waiter = coroutine.running()
					coroutine.yield()
					waiter = nil
					pcall(task.cancel, timer)
				else
					settle(nil)
				end
			end

			if failure then
				local stopErrors = teardown(self, initialized)
				local message = PREFIX .. ("Start failed for '%s': %s"):format(definition.Name, failure)
				if #stopErrors > 0 then
					message ..= "\nWhile rolling back:\n" .. table.concat(stopErrors, "\n")
				end
				fail(self, message)
			end
		end
	end

	self._state = "Running"
	self.Started:Fire()
	resumeWaiters(self, true, nil)
end

--- Yields until the app is running. Raises if startup failed.
function AppClass.AwaitStart(self: any)
	local state = self._state
	if state == "Running" or state == "Stopping" or state == "Stopped" then
		return
	end
	if state == "Failed" then
		error(PREFIX .. ("App '%s' failed to start: %s"):format(self.Name, tostring(self._failure)), 2)
	end
	table.insert(self._waiting, coroutine.running())
	local ok, message = coroutine.yield()
	if not ok then
		error(PREFIX .. ("App '%s' failed to start: %s"):format(self.Name, tostring(message)), 2)
	end
end

--- Stops every definition in reverse dependency order. Idempotent. Errors
--- from individual Stop calls are collected and raised after all have run.
function AppClass.Stop(self: any)
	local state = self._state
	if state == "Stopped" or state == "Stopping" or state == "Failed" then
		return
	end
	if state == "Starting" then
		error(PREFIX .. ("Cannot stop app '%s' while it is starting"):format(self.Name), 2)
	end
	if state == "Idle" then
		self._state = "Stopped"
		return
	end
	self._state = "Stopping"
	local errors = teardown(self, self._initialized)
	self._state = "Stopped"
	self.Stopped:Fire()
	if #errors > 0 then
		error(PREFIX .. ("App '%s' stopped with errors:\n%s"):format(self.Name, table.concat(errors, "\n")), 2)
	end
end

local App = {}

function App.new(options: AppOptions?): App
	if options ~= nil and type(options) ~= "table" then
		error(PREFIX .. "Options must be a table", 2)
	end
	local opts: AppOptions = options or {}
	local environment = opts.Environment
	if environment == nil then
		environment = detectEnvironment()
	elseif environment ~= "Server" and environment ~= "Client" then
		error(PREFIX .. 'Options.Environment must be "Server" or "Client"', 2)
	end
	if opts.OnError ~= nil and type(opts.OnError) ~= "function" then
		error(PREFIX .. "Options.OnError must be a function", 2)
	end
	local name = opts.Name or environment

	local self = setmetatable({
		Name = name,
		Environment = environment,
		Started = Signal.new(),
		Stopped = Signal.new(),
		_state = "Idle",
		_definitions = {},
		_byName = {},
		_contexts = {},
		_order = {},
		_initialized = {},
		_startThreads = {},
		_waiting = {},
		_failure = nil,
		_onError = opts.OnError or function(message: string)
			task.spawn(error, message, 0)
		end,
	}, AppClass)
	return (self :: any) :: App
end

--- Returns true if `value` is a Constella App.
function App.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == AppClass
end

return table.freeze({
	App = table.freeze(App),
})
