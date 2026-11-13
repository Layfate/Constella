# Changelog

All notable changes follow [Semantic Versioning](https://semver.org). Until 1.0.0, minor versions (0.x) may contain breaking changes.

## 0.1.0 — unreleased

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
