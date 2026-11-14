--!strict
--[=[
	Constella.Debug

	Structured logging and lightweight runtime metrics.

	- Loggers are values you create; there is no global log configuration.
	- A disabled level costs one comparison. Pass a function instead of a
	  string to avoid building expensive messages that will be discarded:
	  `logger:Debug(function() return dumpState() end)`.
	- Metrics are opt-in per instance and become no-ops when disabled.
]=]

export type Level = "Trace" | "Debug" | "Info" | "Warn" | "Error" | "None"

export type LogRecord = {
	Level: Level,
	Logger: string,
	Message: string,
	Fields: { [string]: any }?,
	Time: number,
}

export type LoggerOptions = {
	--- Minimum level that is emitted. Defaults to "Info".
	Level: Level?,
	--- Receives every emitted record. Defaults to printing to the output.
	Sink: ((record: LogRecord) -> ())?,
}

export type Logger = {
	Name: string,
	Trace: (self: Logger, message: string | () -> string, fields: { [string]: any }?) -> (),
	Debug: (self: Logger, message: string | () -> string, fields: { [string]: any }?) -> (),
	Info: (self: Logger, message: string | () -> string, fields: { [string]: any }?) -> (),
	Warn: (self: Logger, message: string | () -> string, fields: { [string]: any }?) -> (),
	Error: (self: Logger, message: string | () -> string, fields: { [string]: any }?) -> (),
	SetLevel: (self: Logger, level: Level) -> (),
	GetLevel: (self: Logger) -> Level,
	IsEnabled: (self: Logger, level: Level) -> boolean,
	Child: (self: Logger, name: string) -> Logger,
}

export type Observation = {
	Count: number,
	Sum: number,
	Min: number,
	Max: number,
	Mean: number,
}

export type MetricsSnapshot = {
	Counters: { [string]: number },
	Observations: { [string]: Observation },
}

export type Metrics = {
	Increment: (self: Metrics, name: string, amount: number?) -> (),
	Observe: (self: Metrics, name: string, value: number) -> (),
	Time: (self: Metrics, name: string, fn: (...any) -> ...any, ...any) -> ...any,
	Snapshot: (self: Metrics) -> MetricsSnapshot,
	Reset: (self: Metrics) -> (),
	SetEnabled: (self: Metrics, enabled: boolean) -> (),
	IsEnabled: (self: Metrics) -> boolean,
}

local PREFIX = "[Constella.Debug] "

local LEVELS: { [string]: number } = {
	Trace = 1,
	Debug = 2,
	Info = 3,
	Warn = 4,
	Error = 5,
	None = 6,
}

local function checkLevel(level: any, level_: number): number
	local rank = LEVELS[level]
	if rank == nil then
		error(
			PREFIX .. ("Unknown log level %s (use Trace, Debug, Info, Warn, Error or None)"):format(tostring(level)),
			level_
		)
	end
	return rank
end

local function formatValue(value: any): string
	if type(value) == "string" then
		if string.find(value, '[%s="]') then
			return ("%q"):format(value)
		end
		return value
	end
	return tostring(value)
end

local function formatRecord(record: LogRecord): string
	local line = ("[%s] %s %s"):format(record.Logger, string.upper(record.Level), record.Message)
	local fields = record.Fields
	if fields then
		local keys = {}
		for key in fields do
			table.insert(keys, tostring(key))
		end
		table.sort(keys)
		local parts = table.create(#keys)
		for index, key in keys do
			parts[index] = key .. "=" .. formatValue(fields[key])
		end
		if #parts > 0 then
			line ..= " " .. table.concat(parts, " ")
		end
	end
	return line
end

local function defaultSink(record: LogRecord)
	local line = formatRecord(record)
	if record.Level == "Error" then
		-- Shown in red without interrupting the caller.
		task.spawn(error, line, 0)
	elseif record.Level == "Warn" then
		warn(line)
	else
		print(line)
	end
end

local LoggerClass = {}
LoggerClass.__index = LoggerClass

local function emit(self: any, level: Level, message: any, fields: { [string]: any }?)
	if LEVELS[level] < self._rank then
		return
	end
	local text: string
	if type(message) == "function" then
		local ok, result = pcall(message)
		text = if ok then tostring(result) else ("<message function failed: %s>"):format(tostring(result))
	else
		text = tostring(message)
	end
	self._sink({
		Level = level,
		Logger = self.Name,
		Message = text,
		Fields = fields,
		Time = os.clock(),
	})
end

function LoggerClass.Trace(self: any, message: any, fields: { [string]: any }?)
	emit(self, "Trace", message, fields)
end
function LoggerClass.Debug(self: any, message: any, fields: { [string]: any }?)
	emit(self, "Debug", message, fields)
end
function LoggerClass.Info(self: any, message: any, fields: { [string]: any }?)
	emit(self, "Info", message, fields)
end
function LoggerClass.Warn(self: any, message: any, fields: { [string]: any }?)
	emit(self, "Warn", message, fields)
end
function LoggerClass.Error(self: any, message: any, fields: { [string]: any }?)
	emit(self, "Error", message, fields)
end

function LoggerClass.SetLevel(self: any, level: Level)
	self._rank = checkLevel(level, 3)
	self._level = level
end

function LoggerClass.GetLevel(self: any): Level
	return self._level
end

function LoggerClass.IsEnabled(self: any, level: Level): boolean
	return checkLevel(level, 3) >= self._rank
end

local Logger = {}

function Logger.new(name: string, options: LoggerOptions?): Logger
	if type(name) ~= "string" or name == "" then
		error(PREFIX .. "Logger name must be a non-empty string", 2)
	end
	local level: Level = "Info"
	local sink = defaultSink
	if options ~= nil then
		if type(options) ~= "table" then
			error(PREFIX .. "Logger options must be a table", 2)
		end
		if options.Level ~= nil then
			checkLevel(options.Level, 3)
			level = options.Level
		end
		if options.Sink ~= nil then
			if type(options.Sink) ~= "function" then
				error(PREFIX .. "Logger Sink must be a function", 2)
			end
			sink = options.Sink
		end
	end
	local self = setmetatable({
		Name = name,
		_level = level,
		_rank = LEVELS[level],
		_sink = sink,
	}, LoggerClass)
	return (self :: any) :: Logger
end

--- Creates a logger named "Parent/child" with the same level and sink.
function LoggerClass.Child(self: any, name: string): Logger
	return Logger.new(self.Name .. "/" .. tostring(name), { Level = self._level, Sink = self._sink })
end

local MetricsClass = {}
MetricsClass.__index = MetricsClass

function MetricsClass.Increment(self: any, name: string, amount: number?)
	if not self._enabled then
		return
	end
	self._counters[name] = (self._counters[name] or 0) + (amount or 1)
end

function MetricsClass.Observe(self: any, name: string, value: number)
	if not self._enabled then
		return
	end
	if type(value) ~= "number" or value ~= value then
		error(PREFIX .. ("Observe expects a number, got %s"):format(tostring(value)), 2)
	end
	local observation = self._observations[name]
	if observation == nil then
		self._observations[name] = { Count = 1, Sum = value, Min = value, Max = value }
	else
		observation.Count += 1
		observation.Sum += value
		observation.Min = math.min(observation.Min, value)
		observation.Max = math.max(observation.Max, value)
	end
end

--- Runs `fn(...)`, records its duration in milliseconds under `name`, and
--- returns its results. Errors propagate after the duration is recorded.
function MetricsClass.Time(self: any, name: string, fn: (...any) -> ...any, ...: any): ...any
	if not self._enabled then
		return fn(...)
	end
	debug.profilebegin(name)
	local started = os.clock()
	local results = table.pack(pcall(fn, ...))
	local elapsed = (os.clock() - started) * 1000
	debug.profileend()
	MetricsClass.Observe(self, name, elapsed)
	if not results[1] then
		error(results[2], 0)
	end
	return table.unpack(results, 2, results.n)
end

function MetricsClass.Snapshot(self: any): MetricsSnapshot
	local observations = {}
	for name, observation in self._observations do
		observations[name] = {
			Count = observation.Count,
			Sum = observation.Sum,
			Min = observation.Min,
			Max = observation.Max,
			Mean = observation.Sum / observation.Count,
		}
	end
	return { Counters = table.clone(self._counters), Observations = observations }
end

function MetricsClass.Reset(self: any)
	table.clear(self._counters)
	table.clear(self._observations)
end

function MetricsClass.SetEnabled(self: any, enabled: boolean)
	self._enabled = enabled == true
end

function MetricsClass.IsEnabled(self: any): boolean
	return self._enabled
end

local Metrics = {}

function Metrics.new(options: { Enabled: boolean? }?): Metrics
	local enabled = true
	if options ~= nil and options.Enabled ~= nil then
		enabled = options.Enabled == true
	end
	local self = setmetatable({
		_enabled = enabled,
		_counters = {},
		_observations = {},
	}, MetricsClass)
	return (self :: any) :: Metrics
end

local Debug = {
	Logger = table.freeze(Logger),
	Metrics = table.freeze(Metrics),
	format = formatRecord,
}

--- Current Luau heap size in kilobytes.
function Debug.getMemoryKB(): number
	return gcinfo()
end

return table.freeze(Debug)
