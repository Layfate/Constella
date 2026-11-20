# Architecture

## Principles

1. **Opt-in loading.** The root module is a read-only proxy that `require`s a submodule the first time it's accessed. `require(Constella.Signal)` loads Signal and nothing else.
2. **No hidden state.** There are no globals and no singleton services. Apps, servers, stores and zones are values you create. The module-level state that does exist holds no game data and isn't shared between your objects:
   - State's batch queue, which is empty outside a flush;
   - Random's default RNG, used when you don't pass your own;
   - Signal's and Promise's pools of idle runner threads (a few threads reused to run listeners and handlers), plus Signal's connection counter;
   - Promise's unhandled-rejection handler (`Promise.setUnhandledRejectionHandler`);
   - Network.Contract's registry of the endpoints it created (weak keys), so a hand-made table can't pass as one.
3. **Thin modules.** Each module has a small public surface and exported types. Most are one file. Network and Data are folders whose parts load on demand (`Network.Server`, `Data.Store`, ...), so a client never loads server code and a store never loads an adapter it doesn't use. Internal fields start with `_` and aren't part of the API.
4. **Fail loudly.** Invalid input raises an error naming what's wrong. Errors that can't be raised to a caller (listener errors, Start errors after a yield) are re-raised on a separate thread or passed to an `OnError` hook. They're never swallowed.
5. **Environment boundaries.** The package is shared (ReplicatedStorage), so it must never contain secrets. `Network.Server` replicates like any shared code, but it only enforces rules: your handlers, prices and rewards live in server-only scripts. `Network.Server` refuses to run on a client, `Network.Client` refuses to run on the server, and Apps reject definitions from the wrong environment. `Data` refuses to run on a client. It holds no secrets, and your DataStore access goes through ProfileStore on the server.

## Module dependencies

```
Signal   Cleanup   Random   Pool   Debug      (no dependencies)
State     -> Signal
Core      -> Signal, Cleanup
Zone      -> Signal, Cleanup
Component -> Signal, Cleanup
Network   -> Signal  (parts, each loaded on demand:
                      Check, Contract, Payload, RateLimiter  no dependencies
                      Client  -> Contract
                      Server  -> Check, Contract, Payload, RateLimiter)
Promise              (no dependencies)
Data      -> Signal, Promise  (parts, each loaded on demand:
                      MemoryAdapter, ProfileStoreAdapter -> Util
                      Store -> Util, Signal, Promise)
Replication -> State, Network
```

Type-only imports (`type Logger = typeof(require(...Debug).Logger.new(""))`) aren't run, so Network, Replication and Data never load Debug. `tests/server/Lazy.spec.luau` enforces this table: it requires every module and part from a copy of the package that contains only its listed dependencies, so an undeclared `require` fails the suite.

## Naming conventions

- Constructors are `X.new(...)`. Module-level functions are lowerCamelCase (`State.computed`, `Random.choose`).
- Methods and option keys are PascalCase, matching the Roblox API (`:Connect`, `{ OnError = ... }`).
- Every class offers `X.is(value)`.
- Every disposable object has an idempotent `:Destroy()`, so it can be added to a Cleanup.

## Testing

`tests/server/TestKit.luau` is a small runner with no dependencies. Each `*.spec.luau` returns `function(t, Constella)`. The suite runs in Studio, either automatically on Play (`tests/server/Runner.server.luau`) or on demand with `require(ServerScriptService.ConstellaTests.RunTests)()`, and in CI on a live Roblox server. Leak tests use `t.collected(weak)` or `t.leaked(build)` (objects still alive after release; 0 means no leak), and `t.fakePlayer()` gives a stand-in player with `Kick` and `Leave`.

Types are tested in both directions. `tests/types/pass` must type-check cleanly. Each file in `tests/types/fail` misuses a typed API and must produce exactly the error it declares on its `-- expect:` line (`.github/scripts/check_types.py`), so a type that silently became `any` fails CI.

Two integration tests run across both sides on Play:

- **Network:** the client half acts as a hostile client, through plain and contract endpoints, and the server half checks that the server accepted and rejected exactly what it should have.
- **Replication:** checks private and public visibility, updates, read-only replicas and `State.bind` against a real UI label.
