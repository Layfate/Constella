# Constella documentation

Reference pages for every module in Constella v0.4.0.

## Architecture

| Page | Covers |
| --- | --- |
| [Core / App](Core.md) | Services and controllers, dependency order, Init/Start/Stop, injection, client/server boundaries |
| [Architecture](Architecture.md) | Design principles, module dependencies, naming conventions, testing approach |
| [Game layout](GameLayout.md) | Where a game's services, controllers, shared code and server-only config go, with a starter template |

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
| [Data](Data.md) | Player profiles on ProfileStore |

## Project

- [Benchmarks](Benchmarks.md): measured results against sleitnick/signal, sleitnick/trove and plain Roblox approaches.
- [Roadmap](Roadmap.md): what's done and what comes next.
- [Implementation roadmap](ImplementationRoadmap.md): the plan for 0.3.8 to 0.6.0, with the tests and benchmarks each change needs.
- [Changelog](https://github.com/Layfate/Constella/blob/main/CHANGELOG.md)
- [Contributing](https://github.com/Layfate/Constella/blob/main/CONTRIBUTING.md): setup, tests and conventions.

## Known limitations

- **Data needs ProfileStore in production.** Every CI run tests it on real DataStores on real Roblox servers, including a player moving to a second server, but it hasn't yet run in a live game under heavy load. `MemoryAdapter` isn't persistent.
- **The Play-mode integration tests run in Studio only.** They need a real client. The rest of the suite runs on a Roblox server in CI on every push.
- **State dependencies are explicit.** Use `State.computed({ a, b }, fn)`; there's no automatic tracking. Compute functions and batches must not yield.
- **Network payload sizes are estimates,** not Roblox's exact wire sizes. Validation checks the shape of a request; your handlers still decide what's allowed in the game.
- **Zone checks points, not volumes.** Each zone has its own Heartbeat connection.
- **Real clients are tested up to 8 at once,** in Studio on one machine: load phases with engine-measured traffic ([Benchmarks](Benchmarks.md#real-clients)). A soak harness for multi-hour runs is included, but no multi-hour result is published yet. 50 real clients, rejoins and live-game network conditions (latency, packet loss) have not been measured; larger player counts are tested with stand-in players.
- **The Promise unhandled-rejection reporter applies to every promise** (`Promise.setUnhandledRejectionHandler`).
- **Performance is measured, not assumed.** [Benchmarks](Benchmarks.md) cover every module plus a 50-player server tick, against sleitnick/signal, LemonSignal, Trove, Janitor, evaera's Promise and hand-written baselines. Every pull request reruns them on a Roblox server against the code it changes and fails if a case gets measurably slower. Where Constella loses (Signal against sleitnick/signal, Replication's extra CPU over a plain RemoteEvent), the numbers say so. All results so far come from Constella's author; [reproducing them](Benchmarks.md#independent-verification) takes one command. No comparisons have been made with Knit, Fusion or other frameworks.
