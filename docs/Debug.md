# Debug

Structured logging and lightweight metrics.

```lua
local logger = Debug.Logger.new("Shop", { Level = "Info" })
logger:Info("Purchase", { Player = player.Name, Item = "Sword" })
--> [Shop] INFO Purchase Item=Sword Player=Player1

logger:Debug(function() return expensiveDump() end) -- only built when Debug is enabled
```

## Logger

- **Levels:** `Trace` < `Debug` < `Info` < `Warn` < `Error` < `None`. The default is `Info`.
- **Low overhead when off.** A disabled level costs one number comparison. A function message is only called when its level is enabled.
- **Default sink.** Trace, Debug and Info go to `print` and Warn goes to `warn`. Error is raised on a separate thread, so it shows in red without interrupting your code.
- **Custom sink.** `Sink = function(record) end` receives `{ Level, Logger, Message, Fields, Time }`. Use it to send logs to analytics, store them in a buffer, or capture them in tests.
- **Formatting.** Fields are printed in sorted key order, and values containing spaces are quoted.

| Member | Description |
| --- | --- |
| `Debug.Logger.new(name, { Level?, Sink? }?)` | |
| `logger:Trace/Debug/Info/Warn/Error(message, fields?)` | `message` is a string or a function that returns one |
| `logger:SetLevel(level)` / `logger:GetLevel()` / `logger:IsEnabled(level)` | |
| `logger:Child(name)` | Named `"Parent/name"`, with the same level and sink |
| `Debug.format(record)` | The default line format |

## Metrics

| Member | Description |
| --- | --- |
| `Debug.Metrics.new({ Enabled? }?)` | |
| `metrics:Increment(name, amount?)` | Counter |
| `metrics:Observe(name, value)` | Tracks count, sum, min and max |
| `metrics:Time(name, fn, ...)` | Runs `fn`, records its duration in milliseconds (also shown in the MicroProfiler) and returns its results. Errors are re-raised |
| `metrics:Snapshot()` | `{ Counters, Observations = { [name] = { Count, Sum, Min, Max, Mean } } }` |
| `metrics:Reset()` / `metrics:SetEnabled(bool)` | When disabled, every call is a no-op |
| `Debug.getMemoryKB()` | The current Luau heap size |

There's no global logger or registry. Pass loggers and metrics to the code that needs them, for example through a Core context or a Network `Logger` option.
