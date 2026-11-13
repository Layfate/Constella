# Architecture

## Principles

1. **Opt-in loading.** The root module is a read-only proxy that `require`s a submodule the first time it's accessed. `require(Constella.Signal)` loads Signal and nothing else.
2. **No hidden state.** There are no globals and no singleton services. Apps are values you create. The only module-level state is State's batch queue, which is empty outside a flush, and Random's default RNG.
3. **Thin modules.** Each module is one file with a small public surface and exported types. Internal fields start with `_` and aren't part of the API.
4. **Fail loudly.** Invalid input raises an error naming what's wrong. Errors that can't be raised to a caller (listener errors, Start errors after a yield) are re-raised on a separate thread or passed to an `OnError` hook. They're never swallowed.
5. **Environment boundaries.** The package is shared (ReplicatedStorage), so it must never contain secrets. `Network.Server` replicates like any shared code, but it only enforces rules: your handlers, prices and rewards live in server-only scripts. `Network.Server` refuses to run on a client, `Network.Client` refuses to run on the server, and Apps reject definitions from the wrong environment. `Data` refuses to run on a client. It holds no secrets, and your DataStore access goes through ProfileStore on the server.

## Module dependencies

```
Signal   Cleanup   Random   Pool   Debug      (no dependencies)
State     -> Signal
Core      -> Signal, Cleanup
Zone      -> Signal, Cleanup
Component -> Signal, Cleanup
Network   -> Signal  (Server, Client, Check, Payload, RateLimiter; each loaded on demand)
Promise              (no dependencies)
Data      -> Signal, Promise  (Store, ProfileStoreAdapter, MemoryAdapter; each loaded on demand)
Replication -> State, Network
```

## Naming conventions

- Constructors are `X.new(...)`. Module-level functions are lowerCamelCase (`State.computed`, `Random.choose`).
- Methods and option keys are PascalCase, matching the Roblox API (`:Connect`, `{ OnError = ... }`).
- Every class offers `X.is(value)`.
- Every disposable object has an idempotent `:Destroy()`, so it can be added to a Cleanup.

## Testing

`tests/server/TestKit.luau` is a small runner with no dependencies. Each `*.spec.luau` returns `function(t, Constella)`. The suite runs in Studio, either automatically on Play (`tests/server/Runner.server.luau`) or on demand with `require(ServerScriptService.ConstellaTests.RunTests)()`.

Two integration tests run across both sides on Play:

- **Network:** the client half acts as a hostile client, and the server half checks that the server accepted and rejected exactly what it should have.
- **Replication:** checks private and public visibility, updates, read-only replicas and `State.bind` against a real UI label.
