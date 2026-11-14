# Signal

```lua
local Signal = require(Packages.Constella.Signal)

local damaged = Signal.new()
local connection = damaged:Connect(function(target, amount) print(target, amount) end)
damaged:Fire("Dummy", 10)
connection:Disconnect()
```

## Guarantees

- Listeners run in the order they were connected.
- `Fire` iterates over a snapshot. A listener connected during dispatch runs from the next `Fire` on. A listener disconnected during dispatch, before its turn, is skipped.
- Each listener starts immediately on its own thread (`task.spawn`), so one that yields doesn't block the others.
- A listener error never stops the other listeners and never propagates out of `Fire`. It goes to `OnError`, or if none is set, it's raised on a separate thread so it still appears in the output with a traceback.
- `Once` disconnects before it runs, so firing the signal again from inside the listener doesn't re-enter it.
- A thread blocked in `Wait` that is cancelled in the meantime is skipped, without an error.
- **Memory.** A disconnected `Connection` no longer references its listener, so keeping one around (in a field, say) doesn't keep the listener or anything it captures alive. After `DisconnectAll` or `Destroy`, kept connections don't keep the signal alive either.

## API

| Member | Description |
| --- | --- |
| `Signal.new(options?)` | `options.OnError: (message: string) -> ()` |
| `signal:Connect(fn)` | Returns a `Connection` |
| `signal:Once(fn)` | Disconnects after the first call |
| `signal:Wait()` | Yields until the next `Fire` and returns its arguments |
| `signal:Fire(...)` | Does nothing once the signal is destroyed |
| `signal:DisconnectAll()` | |
| `signal:Destroy()` | Disconnects everything. Idempotent. `Connect`/`Wait` raise afterwards |
| `signal:GetConnectionCount()` | |
| `signal:IsDestroyed()` | |
| `connection.Connected` | `boolean` |
| `connection:Disconnect()` / `:Destroy()` | Idempotent |
| `Signal.is(value)` | Type check |

Types: `Signal.Signal<T...>` and `Signal.Connection`.

## Limitations

- A thread suspended in `Wait()` stays suspended if the signal is destroyed, and is eventually garbage collected.
- Listener threads are recycled when a listener doesn't yield. As with any signal that reuses threads, the values of the most recent listener call can stay reachable until that thread runs its next listener. This is bounded to one call and isn't a leak.
- See [Benchmarks](Benchmarks.md) for how Signal compares with sleitnick/signal: on a Roblox server, `Fire` costs the same like for like (within 1%, about 0.22 µs per listener), `Connect`+`Disconnect` is about 1.45× slower (0.18 vs 0.12 µs), and it uses less memory per connection (160 vs 176 bytes), with per-listener error isolation and ordering guarantees.
