# Constella documentation

Reference pages for every module in Constella v0.1.0.

## Architecture

| Page | Covers |
| --- | --- |
| [Core / App](Core.md) | Services and controllers, dependency order, Init/Start/Stop, injection, client/server boundaries |
| [Architecture](Architecture.md) | Design principles, module dependencies, naming conventions, testing approach |

## Utilities

| Page | Covers |
| --- | --- |
| [Signal](Signal.md) | Custom events with deterministic dispatch and error isolation |
| [Cleanup](Cleanup.md) | Owning and disposing connections, instances, threads and objects |
| [State](State.md) | Reactive values, computed state, batching and UI bindings |
| [Promise](Promise.md) | Async chaining, cancellation, timeouts and retries |
| [Random](Random.md) | Weighted rolls, loot tables and luck, with the math written out |
| [Debug](Debug.md) | Structured logging and metrics |

## Game systems

| Page | Covers |
| --- | --- |
| [Network](Network.md) | Server-owned remotes: validation, rate limits, payload caps and authorization. Includes client vs server API differences |
| [Replication](Replication.md) | Sending State from server to client, with explicit authorization |
| [Component](Component.md) | Behaviour attached to CollectionService tags |
| [Pool](Pool.md) | Bounded object reuse |
| [Zone](Zone.md) | Enter/exit detection for players and parts |
| [Data](Data.md) | Player profiles on ProfileStore (beta) |

## Project

- [Benchmarks](Benchmarks.md): measured results against sleitnick/signal, sleitnick/trove and plain Roblox approaches.
- [Roadmap](Roadmap.md): what's done and what comes next.
- [Changelog](../CHANGELOG.md)
- [Contributing](../CONTRIBUTING.md): setup, tests and conventions.

## Known limitations

- **Data is beta.** Production use relies on ProfileStore. The adapter is tested against real ProfileStore 1.0.3 in its mock mode, but not yet against live DataStores in a published experience. `MemoryAdapter` isn't persistent.
- **Tests run in Studio only.** CI checks formatting, lint and strict types on every push, but there's no headless test runner yet.
- **State dependencies are explicit.** Use `State.computed({ a, b }, fn)`; there's no automatic tracking. Compute functions and batches must not yield.
- **Network payload sizes are estimates,** not Roblox's exact wire sizes. Validation checks the shape of a request; your handlers still decide what's allowed in the game.
- **Zone checks points, not volumes.** Each zone has its own Heartbeat connection.
- **Multi-player scenarios** (rejoins, many clients) are tested with stand-in players in unit tests, not with real clients.
- **The Promise unhandled-rejection reporter applies to every promise** (`Promise.setUnhandledRejectionHandler`).
- **Performance is measured, not assumed.** [Benchmarks](Benchmarks.md) cover Signal, Cleanup, Pool, Network, Random and State. Signal is slightly slower than sleitnick/signal; Cleanup is faster than Trove. No comparisons have been made with Knit, Fusion or other frameworks.
