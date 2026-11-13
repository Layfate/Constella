--!strict
--[=[
	Constella.Data.MemoryAdapter

	An in-memory backend for Studio testing and failure simulation. It is
	NOT persistent: everything is lost when the server stops.

	It models what Constella.Data relies on from a real backend:
	- session locking: one active session per key. A second server asking
	  for the same key takes it over; the first session saves, ends and is
	  told so (the same behaviour as ProfileStore's session stealing);
	- new keys start as a deep copy of the template;
	- failures: SimulateFailures makes the next N loads or saves fail.

	Several adapters can share one database to simulate several servers:
	```lua
	local database = MemoryAdapter.newDatabase()
	local serverA = MemoryAdapter.new({ Database = database })
	local serverB = MemoryAdapter.new({ Database = database })
	```
]=]

local Util = require(script.Parent.Util)

export type Options = {
	--- Share one database between adapters to simulate several servers.
	Database: any?,
	--- Seconds each load/save waits, to simulate network latency.
	Latency: number?,
}

local MAX_SAVE_ATTEMPTS = 3

local SessionClass = {}
SessionClass.__index = SessionClass

local function writeRecord(self: any): (boolean, string?)
	local adapter = self._backend._adapter
	if adapter._latency > 0 then
		task.wait(adapter._latency)
	end
	if adapter._failSaves > 0 then
		adapter._failSaves -= 1
		return false, "SaveFailed"
	end
	self._record.data = Util.deepCopy(self.Data)
	self._record.saves += 1
	return true
end

function SessionClass.IsActive(self: any): boolean
	return self._active
end

function SessionClass.OnSessionEnd(self: any, callback: () -> ())
	table.insert(self._endCallbacks, callback)
end

--- Saves now. Returns false and a reason if the save failed.
function SessionClass.Save(self: any): (boolean, string?)
	if not self._active then
		return false, "SessionEnded"
	end
	return writeRecord(self)
end

-- Saves (retrying), releases the lock and notifies listeners.
-- Returns false if the final save failed; the lock is still released so the
-- player can rejoin, and the stored data stays at the last good save.
local function finish(self: any): (boolean, string?)
	if not self._active then
		return true
	end
	self._active = false
	local saved, reason = false, nil
	for _ = 1, MAX_SAVE_ATTEMPTS do
		saved, reason = writeRecord(self)
		if saved then
			break
		end
	end
	if self._record.owner == self then
		self._record.owner = nil
	end
	for _, callback in self._endCallbacks do
		task.spawn(callback)
	end
	return saved, reason
end

function SessionClass.End(self: any): (boolean, string?)
	return finish(self)
end

local BackendClass = {}
BackendClass.__index = BackendClass

--- Starts a session for `key`. Yields. Returns nil and a reason on failure.
function BackendClass.StartSession(self: any, key: string, options: any): (any, string?)
	local adapter = self._adapter
	if adapter._latency > 0 then
		task.wait(adapter._latency)
	end
	local shouldCancel = options and options.ShouldCancel
	if shouldCancel and shouldCancel() then
		return nil, "Cancelled"
	end
	if adapter._failLoads > 0 then
		adapter._failLoads -= 1
		return nil, "Throttled"
	end

	local records = self._records
	local record = records[key]
	if record == nil then
		record = { data = Util.deepCopy(self._template), owner = nil, saves = 0 }
		records[key] = record
	end
	-- Session locking: take the key over from its current owner, which
	-- saves its latest data first.
	local owner = record.owner
	if owner ~= nil then
		finish(owner)
	end

	local session = setmetatable({
		Data = Util.deepCopy(record.data),
		_active = true,
		_record = record,
		_backend = self,
		_endCallbacks = {},
	}, SessionClass)
	record.owner = session
	return session
end

local AdapterClass = {}
AdapterClass.__index = AdapterClass

function AdapterClass.Open(self: any, name: string, template: { [any]: any }): any
	local database = self._database
	database[name] = database[name] or {}
	return setmetatable({
		_adapter = self,
		_records = database[name],
		_template = Util.deepCopy(template),
	}, BackendClass)
end

--- Makes the next `Loads` session starts and `Saves` saves fail.
function AdapterClass.SimulateFailures(self: any, failures: { Loads: number?, Saves: number? })
	self._failLoads = failures.Loads or 0
	self._failSaves = failures.Saves or 0
end

--- Test helper: a copy of the stored data for a key (nil if none).
function AdapterClass.Peek(self: any, name: string, key: string): any
	local records = self._database[name]
	local record = records and records[key]
	return if record then Util.deepCopy(record.data) else nil
end

--- Test helper: stores data for a key directly, as if saved by an older game version.
function AdapterClass.Write(self: any, name: string, key: string, data: any)
	local database = self._database
	database[name] = database[name] or {}
	database[name][key] = { data = Util.deepCopy(data), owner = nil, saves = 0 }
end

--- Test helper: whether a live session currently owns the key.
function AdapterClass.IsLocked(self: any, name: string, key: string): boolean
	local records = self._database[name]
	local record = records and records[key]
	return record ~= nil and record.owner ~= nil
end

local MemoryAdapter = {}

function MemoryAdapter.newDatabase(): any
	return {}
end

function MemoryAdapter.new(options: Options?): any
	local opts: Options = options or {}
	return setmetatable({
		_database = opts.Database or MemoryAdapter.newDatabase(),
		_latency = opts.Latency or 0,
		_failLoads = 0,
		_failSaves = 0,
	}, AdapterClass)
end

return table.freeze(MemoryAdapter)
