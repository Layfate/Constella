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
- A recycled listener thread cancelled by user cleanup is replaced before the next `Fire`, for both `Connect` and `Once`.
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
| `signal:GetConnectionCount()` | Counts the connected listeners (it walks the list, so `Connect` and `Disconnect` don't have to keep a count) |
| `signal:IsDestroyed()` | |
| `connection.Connected` | `boolean` |
| `connection:Disconnect()` / `:Destroy()` | Idempotent |
| `Signal.is(value)` | Type check |

Types: `Signal.Signal<T...>` and `Signal.Connection`.

## Limitations

- A thread suspended in `Wait()` stays suspended if the signal is destroyed, and is eventually garbage collected.
- Listener threads are recycled when a listener doesn't yield. As with any signal that reuses threads, the values of the most recent listener call can stay reachable until that thread runs its next listener. This is bounded to one call and isn't a leak.
- **sleitnick/signal is faster.** See [Benchmarks](Benchmarks.md#signal-against-sleitnicksignal). Like for like (every listener's errors caught), `Fire` takes 6–24% longer than sleitnick/signal's (24% with a single listener, 6–9% with 10 or more), and `Connect`+`Disconnect` about 1.2× as long. Against LemonSignal, `Fire` is faster with 10 or more listeners and slower with one. In return, Signal calls listeners in connection order, disconnects in `O(1)`, keeps working if your code cancels one of its idle threads (sleitnick/signal and LemonSignal then fail on every later `Fire`), and uses the least memory per connection: 144 bytes, against 176 and 304.
