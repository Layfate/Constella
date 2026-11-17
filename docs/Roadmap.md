# Roadmap

## v0.1.0 — first release · implemented

v0.1.0 was built and tested in three stages. Each stage had to pass its tests in Studio before the next one began.

| Stage | Modules | Verified by |
| --- | --- | --- |
| 1. Foundation | Core/App, Signal, Cleanup, State, Random | Unit tests, demo place, examples |
| 2. Secure infrastructure | Network, Component, Pool, Zone, Debug | Unit tests, plus a Play-mode test with a hostile client against real remotes |
| 3. Advanced, optional | Promise, Data (beta in 0.1.0 and 0.2.0), Replication, State UI bindings | Data failure simulations (throttling, takeover by another server, migration failures, newer data, leaving mid-load, save failures, shutdown budget), plus a Play-mode Replication test |

Scope notes:

- **Data** uses adapters, with ProfileStore first. A custom DataStore backend would only be added after its session-locking, throttling, shutdown-budget and migration-failure simulations pass. Data must never overwrite stored data after a failed load.
- **Replication** only sends what the server explicitly shares, and only from server to client.

## v0.2.0 — verification and optimization · released 2026-11-14

This stage proved that what exists works well. No new modules were added.

- **Data:** ✅ tested against real ProfileStore 1.0.3 in its mock mode, including save completion and shutdown.
- **Pool:** ✅ instance reuse benchmarked (1.7–2× faster than clone and destroy).
- **Benchmarks:** ✅ see [Benchmarks](Benchmarks.md). They led to a 3–4× faster Signal, a further 3–5% on `Fire` from inlined dispatch, and 4× less Cleanup memory.
- **Strict type check:** ✅ clean under luau-lsp with Roblox types, and enforced in CI along with StyLua and selene.
- **Random:** ✅ chi-squared tests for the weights, the Luck formula and shuffle; a [server-authoritative reward pattern](Random.md#server-authoritative-rewards) is documented.
- **Reviews:** ✅ three rounds of review fixes, including a Data shutdown race and runaway `Start` threads; every fix has a regression test (see the [changelog](https://github.com/Layfate/Constella/blob/main/CHANGELOG.md)).

## v0.3.0 — types, Data out of beta, hardening · released 2026-11-14

Still verification work. No new modules.

- **Data:** ✅ out of beta. Every CI run tests it on real DataStores on real Roblox servers: a player moving to a second server (two servers at once), many sessions at once, and the live DataStore tests. Studio Server & Clients with 5 players covered players leaving together and during shutdown. Still to observe: a live game under heavy load over time.
- **Types:** ✅ typed public API (`Promise<T>`, `Store<T>`/`Profile<T>`, real `self` types).
- **Hardening:** ✅ cancelled waiting threads are skipped everywhere, and settled promises, disconnected connections and players who left mid-load no longer stay referenced. Each fix has a regression test.
- **Performance:** ✅ fewer allocations in Random, Promise, State, Cleanup, Network, Replication and Zone, measured A/B against 0.2.0 on a Roblox server (see [Benchmarks](Benchmarks.md)).
- **Packaging:** ✅ Wally and pesde packages checked in CI; 0.3.0 is published as `layfate/constella` on Wally and `zense/constella` on pesde. Fresh installs from both registries match every library module.

## v0.3.1 — lifecycle, concurrency and Delta replication · released 2026-11-14

- **Lifecycle:** ✅ cancelled Data loads, Component `Start` threads, Signal runners and Pool prewarm failures clean up fully.
- **Network:** ✅ per-player and overall in-flight request limits (16 and 256 by default).
- **Promise:** ✅ executors and handlers on recycled threads: about 2× faster and up to 56% less memory per promise.
- **Replication:** ✅ one validation walk (full sends a third faster) and the opt-in **Delta** mode (95% fewer bytes for small changes to big tables).
- **Zone, Network, Signal:** ✅ fewer allocations and checks per step, request and connection.
- **Benchmarks:** ✅ every module, a 50-player tick, LemonSignal/Janitor/evaera Promise as competitors, confidence intervals, and a CI gate that fails a pull request with a regression.

## v0.3.2 — departed players and faster hot paths · released 2026-11-14

- **Network, Replication:** ✅ requests and shares for players who already left keep nothing alive; refused Replication resyncs are retried with backoff.
- **Data:** ✅ `profile:Update` fires `Changed` for in-place edits.
- **Performance:** ✅ nested Signal `Fire` and promise chains reuse parked runner threads (25–34% faster, no garbage per nesting level); State `Set` 32% faster; Network requests allocate nothing.

## v0.3.3 — faster payload checks · released 2026-11-16

- **Replication:** ✅ payload checks add plain keys and values inline: full sends 32% faster and Delta sends 28% faster on a Roblox server, with identical sizes and rejection reasons.
- **Packaging:** ✅ wally.run links to the documentation; the README covers exported types with Wally.

## v0.3.5 — starter template and typed demo · released 2026-11-17

- **Template:** ✅ a starter game with the recommended layout across ReplicatedStorage, ServerScriptService, ServerStorage and StarterPlayerScripts, checked in CI and in a Studio playtest with a hostile client. See [Game layout](GameLayout.md).
- **Demo:** ✅ typed with Constella's exported types instead of `any`.

## v0.3.6 — every public type from the root module · released 2026-11-17

- **Types:** ✅ all 71 public types are exported from the root module (`Constella.Context`, `Constella.Store<T>`, ...), so Wally and pesde users can use them. Lazy loading is unchanged and tested.

## v0.3.7 — real clients and measured traffic · released 2026-11-17

- **Real clients:** ✅ load tests with 1–8 real Studio clients over the network replicator; every replica matched the server.
- **Bandwidth:** ✅ measured from the engine's counters: Delta sends 130 bytes against 1,184 for the full value (89% less).
- **Signal:** ✅ 144 bytes per connection instead of 160, compared like-for-like with sleitnick/signal (which is still faster).
- **Soak:** harness shipped; a multi-hour result is not published yet.

## Next

- **Soak:** publish a multi-hour soak result with its control run.
- **Pool:** measure memory over long sessions.
- **Replication Delta:** run the Play-mode test (`tests/client/ReplicationIntegration.client.luau`) in Studio with real clients.
- **Typed listeners and profile keys:** `Cleanup:Connect` types its callback as `(...any)`, and `profile:Set` accepts any key and value.

## Toward 1.0

- API freeze, then semantic versioning for every breaking change.
