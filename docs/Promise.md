# Promise

```lua
local Promise = require(Packages.Constella.Promise)

Promise.retry(fetchLeaderboard, { Attempts = 3, Delay = 0.5 })
	:Timeout(5)
	:Then(function(rows) render(rows) end)
	:Catch(function(err) warn(err) end)
```

## Guarantees

- The executor `function(resolve, reject, onCancel)` runs immediately on its own thread and may yield.
- Handlers run on their own threads, in the order they were attached. Attaching a handler to a promise that has already settled runs it straight away.
- An error thrown in an executor or handler rejects with a `PromiseError` (`Kind = "ExecutionError"`, plus `Message` and `Trace`). Tables passed to `error()` are passed through unchanged.
- Resolving with another promise adopts that promise's outcome.
- **No silent failures.** A rejection that nothing handles (no `Then`/`Catch`/`Finally`/`Await`) by the next resumption point is reported as an error in the output.
- **Cancellation.** `Cancel()` settles a pending promise as `"Cancelled"`, runs its `onCancel` hooks and cancels everything chained from it. A chained promise that's cancelled also cancels its parent once the parent has no other consumers, so cancelling the end of a chain stops the work behind it.
- `all` and `race` cancel the losing promises *before* they settle. Anyone who resumes from `Await` therefore sees the losers already stopped.

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
