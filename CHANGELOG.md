# Changelog

All notable changes follow [Semantic Versioning](https://semver.org). Until 1.0.0, minor versions (0.x) may contain breaking changes.

## Unreleased

### Added
- **CI:** the whole test suite runs on a real Roblox server on every push, through Open Cloud: the CI place is built from `ci.project.json` with a pinned ProfileStore, published to a dedicated CI experience, and run with the Luau execution API. 242 tests pass there, including the live DataStore tests.

### Changed
- **Tests:** the Network integration test counts accepted and rejected requests per player, so it also passes with several clients (Studio Server & Clients mode), where each player has its own rate limit.

### Verified
- **Multiplayer:** in Studio Server & Clients mode with 5 players, Network passed for every player, Replication passed on every client, and Data on real DataStores saved every value when two players left at once and when one left during shutdown.
- **Data:** the live DataStore tests pass on real DataStores through ProfileStore 1.0.3, in Studio Play mode and on a Roblox server in CI. Testing with players moving between live servers is still open, so Data stays beta.

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
