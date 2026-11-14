# Changelog

All notable changes follow [Semantic Versioning](https://semver.org). Until 1.0.0, minor versions (0.x) may contain breaking changes.

## Unreleased (0.3.0)

Typed public API, Data out of beta, fixes for cancelled waiting threads and for references kept longer than needed, and fewer allocations on hot paths. No modules or public functions were removed, and no behaviour changed except as listed under Fixed.

### Fixed
- **Promise, Signal, Core, Network, Data:** a waiting thread that was cancelled in the meantime (with `task.cancel`, for example by a `Cleanup`) was still resumed, which raises. Resolving a promise could then throw and skip the remaining `Await` callers. `App:Start()` could raise after `Started` had fired and leave other `AwaitStart` callers waiting forever. `Signal:Wait` reported an error, and the Network client and the ProfileStore save waiter logged one. Cancelled waiters are now skipped.
- **Data:** the store kept a reference to every player who was released while their profile was still loading (a player who left mid-load), for the life of the server.
- **Promise:** a settled promise kept the promises it was chained from, and their values, alive for as long as it was referenced, and kept its cancel hooks too. Both are released when it settles. A cancel hook registered after the promise settled is no longer stored (it could never run).
- **Signal:** a `Connection` kept after `Disconnect` (for example in a field) kept its listener, and everything the listener captured, alive. It now lets go of the listener. After `DisconnectAll` or `Destroy`, kept connections no longer keep the signal alive either.
- **Packaging:** the Wally package would have contained the whole repository, including build output and a downloaded copy of ProfileStore, because Wally 0.3.2 ignores `include`. `wally.toml` now excludes everything but the library, and pesde no longer ships a hand-written `default.project.json` (pesde generates it on install).

### Changed
- **Performance:** fewer allocations on hot paths, with identical results. Measured A/B on a Roblox server ([Benchmarks](docs/Benchmarks.md)): `Random.choose` 4.3× faster, `State` `Set` about 20% faster, each Network request about 15% faster, and a resolved promise 32% smaller. Everything else is unchanged within noise.
  - `Random.choose` and `Random.chooseIndex` no longer build an error label for every entry on every call, and allocate nothing without modifiers. They pick exactly the entry `lootTable:Roll` picks for the same roll (a new test checks 3,000 rolls).
  - `Promise` creates its internal lists only when needed, instead of three tables per promise.
  - `State` `Set` allocates nothing (internal buffers are reused). Computed states with 1–3 sources no longer build an array on every recompute.
  - `Cleanup` no longer creates a closure for every table resource it adds, `Network` no longer creates one to measure every request's payload, `Replication` builds its size limits once instead of on every update, and `Zone` no longer allocates on steps where nothing entered or left.
- **Types:** the public API is properly typed.
  - `Promise<T>` is generic in its value type; `Promise.resolve`, `Promise.delay`, `:Finally`, `:Timeout` and `:Expect` keep the type. `:Then`/`:Catch` return the new `AnyPromise` type.
  - `Data.Store.new` takes `T` from `Template`: `Store<T>`, `Profile<T>` with a typed `Data`, and `LoadAsync` returns `Promise<Profile<T>>`.
  - `Config.Adapter` is the new `Data` `Adapter` type and `Config.Logger` is a Debug logger, instead of `any`.
  - Every exported class type gives its methods a real `self` type (122 signatures) instead of `self: any`.
  - Existing annotations keep working: `Promise`, `Store` and `Profile` without type arguments mean the old untyped versions.
- **Data is no longer beta.** Everything that can be checked before a live game has now been verified on real DataStores on real Roblox servers (see [docs/Data.md](docs/Data.md#status-and-verification)). The API is unchanged.
- **Tests:** the Network integration test counts accepted and rejected requests per player, so it also passes with several clients (Studio Server & Clients mode), where each player has its own rate limit.

### Added
- **Tests:** a regression test for each fix above. TestKit gains `t.collected(weakTable)`, which waits for the garbage collector to free objects.
- **Benchmarks:** Promise and computed-State cases, memory per promise, and leak checks for kept connections and kept promise chains. The suite can measure several builds of the package in one session, alternating case by case. On pull requests, CI runs it on a Roblox server against the base commit and adds the report to the job summary.
- **Packaging:** every push builds the Wally and pesde packages and checks that each contains exactly the library. Releases publish to both registries when their tokens are set, and fail if `init.luau`, `wally.toml` and `pesde.toml` disagree with the tag.
- **Docs site:** https://layfate.github.io/Constella/ (GitHub Pages from `docs/`).
- **CI:** two live Data scenarios run on real Roblox servers on every push ([`tests/server/Live.luau`](tests/server/Live.luau)). A player moves to a second server: server B sees server A's data, A gives up the session and kicks the player, and B's save is the one stored. And 15 sessions load and save at once on one server.
- **Docs:** [Data](docs/Data.md) explains ProfileStore's MessagingService subscription limit for servers that keep many profiles open with few players.
- **CI:** the whole test suite runs on a real Roblox server on every push, through Open Cloud: the CI place is built from `ci.project.json` with a pinned ProfileStore, published to a dedicated CI experience, and run with the Luau execution API, including the live DataStore tests.

### Verified
- **Multiplayer:** in Studio Server & Clients mode with 5 players, Network passed for every player, Replication passed on every client, and Data on real DataStores saved every value when two players left at once and when one left during shutdown.
- **Data:** the live DataStore tests pass on real DataStores through ProfileStore 1.0.3, in Studio Play mode and on a Roblox server in CI, and so do players moving between live servers (see the CI entry above).

## 0.2.0 — 2026-11-14

Verification and performance release: fixes from two code reviews (each with a regression test), Data verified against real ProfileStore, a faster Signal, a benchmark suite, and CI. No modules or public functions were removed.

### Upgrading from 0.1.0
- **Data:** with ProfileStore, `profile:Save()`, `store:Release()` and `store:Shutdown()` now yield until ProfileStore has finished writing, for up to `SaveTimeout` (30 seconds by default). Code that called them expecting an immediate return now waits for the real save.
- **Network:** a client function allows at most 8 outstanding `Invoke` calls by default. Further calls fail fast with `"TooManyRequests"` instead of piling up threads. Raise `MaxInFlight` if you need more.
- **Core:** a `Start` that is still running when its definition stops (for example a `while true do ... task.wait() end` loop) is now cancelled just before that definition's `Stop`, on `app:Stop()` and on a failed startup. Move work that must outlive `Stop` out of `Start`.

### Fixed
- **Data:** `store:Shutdown()` only waited for the sessions it released itself. A release that was already saving (a player who left just before the server closed) wasn't counted, so `Shutdown` could return `true` before that final save finished. It now waits for every session that is still ending.
- **Core:** a `Start` that yielded and never returned kept running after `app:Stop()` and after a failed startup had rolled back. It's now cancelled before its definition's `Stop`.
- **Replication:** a share that was stopped and recreated under the same name restarted its version at 1, so clients could discard its updates as stale. Versions now come from one counter per replicator that only ever increases.
- **Replication:** snapshots read the live state, so a value rejected as an update (unsupported or oversized) could still be served by a later snapshot. Shares now cache the last value that passed validation, and the initial value gets the full size check at `Share` time.
- **Network:** an error inside a Schema validator (for example a `Check.refine` predicate) wasn't caught. For a RemoteFunction, that could send the server's error text to the client. Validation and payload measurement now run in protected calls: errors go to `OnError` and the request is rejected as `InvalidArguments`. Both entry points also guard the whole check sequence.
- **Data:** with ProfileStore, `profile:Save()`, `store:Release()` and `store:Shutdown()` returned before anything was written, because ProfileStore saves on a separate thread and fires `OnSessionEnd` before its final write. The adapter now waits for ProfileStore's `OnAfterSave`, capped by a new `SaveTimeout` option (30 seconds by default).

### Changed
- **Signal:** listener threads are recycled and connections live in a linked list, instead of creating a new coroutine per listener and copying the list on every `Fire`. `Fire` is 3–4× faster; ordering, snapshot and error-isolation behaviour are unchanged.
- **Cleanup:** plain resources are stored in two parallel arrays instead of a table each, using about 4× less memory.
- **Signal:** `Fire` dispatches listeners inline instead of through a helper call, so it is about 3–5% faster. Memory per connection (160 bytes), ordering, snapshot and error-isolation behaviour are unchanged.
- **Tests:** the Signal memory tests no longer depend on which tests ran before them, and still fail against deliberately leaking Signals.

### Added
- **Data:** `ProfileStoreAdapter.new(ProfileStore, { Mock = true })` uses ProfileStore's in-memory mock store, so tests never touch real data.
- **Tests:** `tests/server/ProfileStore.spec.luau` runs Data against real ProfileStore (verified with 1.0.3) when it's installed, and is skipped otherwise. TestKit gains `t.skip`.
- **Benchmarks:** `benchmarks/` suite and [docs/Benchmarks.md](docs/Benchmarks.md), comparing with sleitnick/signal, sleitnick/trove and plain Roblox approaches.
- **Network:** `MaxInFlight` on client functions (default 8) bounds outstanding `InvokeServer` calls, counting timed-out ones that haven't returned. Beyond it, `Invoke` fails fast with `"TooManyRequests"`. Also adds `fn:GetInFlight()`.
- **Core:** `WaitForStart` and `StartTimeout` let critical services act as a readiness gate. `App:Start` waits for their `Start` to finish, and any error or timeout fails startup with a rollback.
- **CI:** a GitHub Actions workflow checks formatting (StyLua), lint (selene) and Roblox types (luau-lsp, strict) on every push and pull request.
- **Benchmarks:** the report also lists every run's result, not just the median, best and worst. New cases: Signal `Fire` with 100 and 1,000 listeners, and hand-written weighted-pick baselines without validation for Random.
- **Docs:** a server-authoritative reward pattern in [docs/Random.md](docs/Random.md#server-authoritative-rewards).
- **Releases:** publishing a GitHub release builds `Constella.rbxm` from the tagged source with the pinned Rojo and attaches it. The build fails if the tag doesn't match `Constella.Version`.
- **Repository:** [SECURITY.md](SECURITY.md) with private vulnerability reporting, issue and pull request templates, and Dependabot for the workflow actions.

## 0.1.0 — 2026-11-13

First release, made by Zense. Every module listed in the roadmap is included. `Data` is marked beta.

### Core architecture
- `Constella` root module: lazy loading (requiring one module never loads the others) and a read-only public table.
- `Core` / `App`:
  - explicit apps with dependency-ordered Init/Start/Stop;
  - checks for duplicates, missing dependencies, cycles (with the cycle path) and the wrong environment (client/server);
  - rollback when startup fails;
  - dependency injection limited to the dependencies a definition declares.

### Utilities
- `Signal`: Connect/Once/Wait/Fire/DisconnectAll/Destroy, with snapshot dispatch and error isolation.
- `Cleanup`: Add/Set/Get/Remove/Detach/Connect/Extend/AttachToInstance/Clean/Destroy. Idempotent and LIFO, keeps cleaning when one disposal fails, and cancels Promises.
- `State`:
  - values, `computed`/`select`, `batch`, `Observe`, custom equality;
  - glitch-free updates (no in-between notifications), so a value with several sources notifies once per change;
  - `State.bind` for UI bindings.
- `Random`: `choose`, `chooseIndex`, `lootTable`, `chance`, `shuffle`, plus `Luck` and `Multipliers` modifiers with documented math. Supports seeded RNGs.
- `Promise`:
  - chaining, adopting returned promises, and cancellation (downstream, and upstream once a promise has no other consumers);
  - `all`, `allSettled`, `race`, `delay`, `retry` with backoff, `fromEvent` and `Timeout`;
  - typed `PromiseError`s and reporting of unhandled rejections.
- `Debug`: structured loggers with levels, lazy messages and sinks; metrics with counters, observations and timers.

### Game systems
- `Network`:
  - only the server creates remotes, each inside a namespace it owns;
  - schema validation (`Network.Check`), per-player rate limits, and caps on payload size, depth and value count;
  - `Authorize` hooks;
  - clients get generic error codes, and client calls time out instead of hanging;
  - rejections are visible on the server through `OnReject`, `GetStats` and the logger;
  - the server never invokes clients.
- `Replication`: explicit server→client State replication, with public and per-player shares, versioned updates, value checks and read-only client copies.
- `Component`: CollectionService tag components with ancestry safety, `Filter`, Start/Stop, a Cleanup per object, and Added/Removed signals.
- `Pool`: bounded pools (`MaxIdle`/`MaxActive`), Reset/OnAcquire hooks, deterministic release and `Pool.instances`.
- `Zone`: box, sphere and moving-part zones; Entered/Exited; tracking of players, parts and models; `ExitPadding` hysteresis; manual or Heartbeat updates.
- `Data` (beta, server only):
  - `Store` with versioned migrations run on a copy, template reconciliation and load retries;
  - when a load fails, the player is kicked and stored data is never overwritten;
  - handling for lost sessions, `BindPlayers`, a shutdown time budget, and stats;
  - `ProfileStoreAdapter` for production, and `MemoryAdapter` for tests (session locking, several servers and failure injection).

### Tooling
- A Studio test suite (unit tests, Data failure simulations) plus Play-mode Network and Replication integration tests.
- A demo place (persisted and replicated coins, a networked shop) and one example per module.
- Rojo, Wally and pesde configuration.
