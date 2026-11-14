# Promise

```lua
local Promise = require(Packages.Constella.Promise)

Promise.retry(fetchLeaderboard, { Attempts = 3, Delay = 0.5 })
	:Timeout(5)
	:Then(function(rows) render(rows) end)
	:Catch(function(err) warn(err) end)
```

## Guarantees

- The executor `function(resolve, reject, onCancel)` runs immediately on a thread of its own and may yield.
- Handlers run the same way, in the order they were attached, and one that yields never delays the others. Attaching a handler to a promise that has already settled runs it straight away.
- **Threads are recycled,** the way [Signal](Signal.md) runs listeners: an executor or handler that doesn't yield hands its thread to the next one, instead of a new coroutine being created each time. That's most of why Promise is about 2× faster than its earlier thread-per-handler design and 6–7× faster than evaera/roblox-lua-promise (see [Benchmarks](Benchmarks.md)). If user code cancels a recycled thread (for example by adding `coroutine.running()` to a Cleanup), the next job simply gets a new one.
- An error thrown in an executor or handler rejects with a `PromiseError` (`Kind = "ExecutionError"`, plus `Message` and `Trace`). Tables passed to `error()` are passed through unchanged.
- Resolving with another promise adopts that promise's outcome.
- **No silent failures.** A rejection that nothing handles (no `Then`/`Catch`/`Finally`/`Await`) by the next resumption point is reported as an error in the output.
- **Cancellation.** `Cancel()` settles a pending promise as `"Cancelled"`, runs its `onCancel` hooks and cancels everything chained from it. A chained promise that's cancelled also cancels its parent once the parent has no other consumers, so cancelling the end of a chain stops the work behind it.
- `all` and `race` cancel the losing promises *before* they settle. Anyone who resumes from `Await` therefore sees the losers already stopped.
- A thread blocked in `Await` that is cancelled (for example by a `Cleanup` it was added to) is simply skipped when the promise settles. The other waiters still resume.
- **Memory.** Once a promise settles it lets go of the promises it was chained from and of its `onCancel` hooks, so keeping the end of a chain doesn't keep the earlier values alive. A hook registered after the promise settled is never stored, because it can never run.

## Types

`Promise<T>` resolves with a `T`. `Promise.resolve(5)` is a `Promise<number>`, `Promise.delay` a `Promise<number>`, and Data's `store:LoadAsync(player)` a `Promise<Profile<T>>`, so `:Expect()` returns a typed value.

- `:Then` and `:Catch` return an `AnyPromise`, because the handler decides the next value and Luau can't express "a promise of whatever the handler returns". Cast it if you need the type: `local p = (a:Then(f) :: any) :: Promise<number>`.
- `:Await()` returns `(boolean, any)`: the second value is the value on success but the rejection reason on failure, so it can't be typed `T`.
- `Promise.new`, `Promise.all` and `Promise.race` return `Promise<any>`, because their value types can't be inferred.

## API

| Member | Description |
| --- | --- |
| `Promise.new(executor)` | `onCancel(hook)` registers cleanup. `onCancel()` returns whether the promise is cancelled |
| `Promise.resolve(...)` / `Promise.reject(...)` | |
| `Promise.try(fn, ...)` | Wraps a function call, which may return a promise |
| `Promise.delay(seconds)` | Resolves with the elapsed time. Cancelling it stops the timer |
| `Promise.all(list)` | An array of each first value. Rejects on the first failure and cancels the rest |
| `Promise.allSettled(list)` | `{ { Status, Value } }` |
| `Promise.race(list)` | Settles like the first to settle and cancels the others |
| `Promise.retry(fn, { Attempts?, Delay?, Backoff?, ShouldRetry? }?)` | Retries with exponential backoff |
| `Promise.fromEvent(signal, predicate?)` | The next matching event. Works with RBXScriptSignal and Constella Signal |
| `promise:Then(onResolved?, onRejected?)` / `:Catch(fn)` / `:Finally(fn(status))` | |
| `promise:Await()` | `(true, ...)` or `(false, reason)` |
| `promise:Expect()` | The values, or raises the rejection |
| `promise:Timeout(seconds, value?)` | Rejects with a `Timeout` PromiseError (or `value`) and cancels the slow work |
| `promise:Cancel()` / `promise:GetStatus()` | `Pending`, `Resolved`, `Rejected` or `Cancelled` |
| `Promise.is(value)` / `Promise.isError(value, kind?)` | |
| `Promise.setUnhandledRejectionHandler(fn?)` | Replaces the reporter for every promise and returns the previous one. For tests and custom reporting |

`Cleanup:Add(promise)` cancels the promise when the Cleanup is cleaned.

## Limitations

- As with any thread reuse (Signal does the same), an idle recycled thread can keep the values of the last executor or handler it ran reachable, in unused stack slots, until it runs the next one. That's bounded to one call and isn't a leak.
