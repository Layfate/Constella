--!strict
--[=[
	Constella.Pool

	Bounded object reuse for projectiles, effects and other short-lived
	objects.

	Semantics
	- Acquire returns an idle object, or creates one with `Create`.
	- `MaxActive` caps how many objects can be out at once: `TryAcquire`
	  returns nil and `Acquire` raises when the cap is reached.
	- `MaxIdle` caps how many released objects are kept. Extra objects are
	  destroyed on release, so memory stays bounded.
	- Release is deterministic: releasing an object that is not currently
	  acquired from this pool (twice, or from another pool) raises.
	- `Reset` runs on release. If it fails, the object is destroyed (never
	  reused in an unknown state) and the error is raised.
	- After Destroy, idle objects are destroyed and released ones are
	  destroyed instead of being kept.
]=]

export type Options<T> = {
	--- Creates a new object. Required.
	Create: () -> T,
	--- Prepares a released object for reuse.
	Reset: ((object: T) -> ())?,
	--- Runs every time an object is handed out.
	OnAcquire: ((object: T) -> ())?,
	--- Disposes an object. Defaults to :Destroy() for Instances and tables
	--- with a Destroy method.
	Destroy: ((object: T) -> ())?,
	--- Maximum number of idle objects kept. Defaults to 64.
	MaxIdle: number?,
	--- Maximum number of objects out at once. Defaults to unlimited.
	MaxActive: number?,
	--- Objects to create up front.
	Prewarm: number?,
}

export type Stats = {
	Idle: number,
	Active: number,
	Created: number,
	Destroyed: number,
	Reused: number,
}

export type Pool<T> = {
	Acquire: (self: Pool<T>) -> T,
	TryAcquire: (self: Pool<T>) -> T?,
	Release: (self: Pool<T>, object: T) -> (),
	IsActive: (self: Pool<T>, object: T) -> boolean,
	Prewarm: (self: Pool<T>, count: number) -> (),
	Clear: (self: Pool<T>) -> (),
	GetStats: (self: Pool<T>) -> Stats,
	Destroy: (self: Pool<T>) -> (),
}

type InstancesOptions = { Reset: ((any) -> ())?, MaxIdle: number?, MaxActive: number?, Prewarm: number? }

local PREFIX = "[Constella.Pool] "
local DEFAULT_MAX_IDLE = 64

local function defaultDestroy(object: any)
	local valueType = typeof(object)
	if valueType == "Instance" or (valueType == "table" and type(object.Destroy) == "function") then
		object:Destroy()
	end
end

local function checkCount(value: any, label: string, allowZero: boolean, level: number)
	if
		type(value) ~= "number"
		or value ~= value
		or value % 1 ~= 0
		or value == math.huge
		or value < (if allowZero then 0 else 1)
	then
		error(
			PREFIX
				.. ("%s must be a %s integer, got %s"):format(
					label,
					if allowZero then "non-negative" else "positive",
					tostring(value)
				),
			level
		)
	end
end

local PoolClass = {}
PoolClass.__index = PoolClass

local function dispose(self: any, object: any)
	self._destroyedCount += 1
	self._destroy(object)
end

local function create(self: any): any
	local object = self._create()
	if object == nil then
		error(PREFIX .. "Create returned nil", 0)
	end
	self._created += 1
	return object
end

function PoolClass.TryAcquire(self: any): any
	if self._destroyed then
		error(PREFIX .. "Cannot acquire from a destroyed Pool", 2)
	end
	if self._maxActive and self._activeCount >= self._maxActive then
		return nil
	end
	local object = table.remove(self._idle)
	if object ~= nil then
		self._reused += 1
	else
		object = create(self)
	end
	self._active[object] = true
	self._activeCount += 1
	if self._onAcquire then
		local ok, err = pcall(self._onAcquire, object)
		if not ok then
			self._active[object] = nil
			self._activeCount -= 1
			pcall(dispose :: any, self, object)
			error(PREFIX .. "OnAcquire failed: " .. tostring(err), 2)
		end
	end
	return object
end

function PoolClass.Acquire(self: any): any
	local object = PoolClass.TryAcquire(self)
	if object == nil then
		error(PREFIX .. ("Pool is exhausted (MaxActive = %d)"):format(self._maxActive), 2)
	end
	return object
end

function PoolClass.Release(self: any, object: any)
	if object == nil or not self._active[object] then
		error(PREFIX .. "Released an object that is not currently acquired from this Pool", 2)
	end
	self._active[object] = nil
	self._activeCount -= 1

	if self._destroyed or #self._idle >= self._maxIdle then
		dispose(self, object)
		return
	end
	if self._reset then
		local ok, err = pcall(self._reset, object)
		if not ok then
			pcall(dispose :: any, self, object)
			error(PREFIX .. "Reset failed; the object was destroyed: " .. tostring(err), 2)
		end
	end
	table.insert(self._idle, object)
end

function PoolClass.IsActive(self: any, object: any): boolean
	return self._active[object] == true
end

--- Creates idle objects until there are `count` idle (bounded by MaxIdle).
function PoolClass.Prewarm(self: any, count: number)
	checkCount(count, "Prewarm count", true, 3)
	local target = math.min(count, self._maxIdle)
	while #self._idle < target do
		local object = create(self)
		if self._reset then
			self._reset(object)
		end
		table.insert(self._idle, object)
	end
end

--- Destroys every idle object. Acquired objects are unaffected.
function PoolClass.Clear(self: any)
	local idle = self._idle
	self._idle = {}
	local firstError = nil
	for _, object in idle do
		local ok, err = pcall(dispose :: any, self, object)
		if not ok and firstError == nil then
			firstError = err
		end
	end
	if firstError ~= nil then
		error(PREFIX .. "Failed to destroy an idle object: " .. tostring(firstError), 2)
	end
end

function PoolClass.GetStats(self: any): Stats
	return {
		Idle = #self._idle,
		Active = self._activeCount,
		Created = self._created,
		Destroyed = self._destroyedCount,
		Reused = self._reused,
	}
end

--- Destroys idle objects. Objects still acquired are destroyed when released.
function PoolClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	PoolClass.Clear(self)
end

local Pool = {}

function Pool.new<T>(options: Options<T>): Pool<T>
	if type(options) ~= "table" then
		error(PREFIX .. "Pool.new expects an options table", 2)
	end
	if type(options.Create) ~= "function" then
		error(PREFIX .. "Options.Create must be a function", 2)
	end
	for _, field in { "Reset", "OnAcquire", "Destroy" } do
		local value = (options :: any)[field]
		if value ~= nil and type(value) ~= "function" then
			error(PREFIX .. ("Options.%s must be a function"):format(field), 2)
		end
	end
	local maxIdle = options.MaxIdle or DEFAULT_MAX_IDLE
	checkCount(maxIdle, "MaxIdle", true, 3)
	if options.MaxActive ~= nil then
		checkCount(options.MaxActive, "MaxActive", false, 3)
	end

	local self = setmetatable({
		_create = options.Create,
		_reset = options.Reset,
		_onAcquire = options.OnAcquire,
		_destroy = options.Destroy or defaultDestroy,
		_maxIdle = maxIdle,
		_maxActive = options.MaxActive,
		_idle = {},
		_active = {},
		_activeCount = 0,
		_created = 0,
		_destroyedCount = 0,
		_reused = 0,
		_destroyed = false,
	}, PoolClass)

	if options.Prewarm ~= nil then
		PoolClass.Prewarm(self, options.Prewarm)
	end
	return (self :: any) :: Pool<T>
end

--- A pool of clones of `template`. Released clones are parented to nil
--- (after your Reset runs) so they stop rendering and simulating.
function Pool.instances(template: Instance, options: InstancesOptions?): Pool<any>
	if typeof(template) ~= "Instance" then
		error(PREFIX .. ("Pool.instances expects an Instance template, got %s"):format(typeof(template)), 2)
	end
	local opts: InstancesOptions = options or {}
	local userReset = opts.Reset
	return Pool.new({
		Create = function()
			return (template :: any):Clone()
		end,
		Reset = function(object: any)
			if userReset then
				userReset(object)
			end
			object.Parent = nil
		end,
		MaxIdle = opts.MaxIdle,
		MaxActive = opts.MaxActive,
		Prewarm = opts.Prewarm,
	})
end

return table.freeze(Pool)
