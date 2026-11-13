# Roadmap

## v0.1.0 — first release · implemented

v0.1.0 was built and tested in three stages. Each stage had to pass its tests in Studio before the next one began.

| Stage | Modules | Verified by |
| --- | --- | --- |
| 1. Foundation | Core/App, Signal, Cleanup, State, Random | Unit tests, demo place, examples |
| 2. Secure infrastructure | Network, Component, Pool, Zone, Debug | Unit tests, plus a Play-mode test with a hostile client against real remotes |
| 3. Advanced, optional | Promise, Data (beta), Replication, State UI bindings | Data failure simulations (throttling, takeover by another server, migration failures, newer data, leaving mid-load, save failures, shutdown budget), plus a Play-mode Replication test |

Scope notes:

- **Data** uses adapters, with ProfileStore first. A custom DataStore backend would only be added after its session-locking, throttling, shutdown-budget and migration-failure simulations pass. Data must never overwrite stored data after a failed load.
- **Replication** only sends what the server explicitly shares, and only from server to client.

## v0.2.0 — verification and optimization · released 2026-11-14

This stage proved that what exists works well. No new modules were added.

- **Data:** ✅ tested against real ProfileStore 1.0.3 in its mock mode, including save completion and shutdown.
- **Pool:** ✅ instance reuse benchmarked (1.7–2× faster than clone and destroy).
- **Benchmarks:** ✅ see [Benchmarks](Benchmarks.md). They led to a 3–4× faster Signal, a further 5–6% on `Fire` from inlined dispatch, and 4× less Cleanup memory.
- **Strict type check:** ✅ clean under luau-lsp with Roblox types, and enforced in CI along with StyLua and selene.
- **Reviews:** ✅ two code reviews; every fix has a regression test (see the [changelog](../CHANGELOG.md)).

## Next (toward 0.3.0)

Still verification work. No new modules are planned.

- **Data:** run it against live DataStores in a separate published experience (disconnects, shutdowns, rejoining a second server, high player counts). Data stays beta until then.
- **Pool:** measure memory over long sessions.
- **Random:** add statistical distribution tests (chi-squared) on top of the existing tolerance tests. Document a pattern for server-authoritative reward flows.

## Toward 1.0

- A headless test runner, so CI also runs the test suite (Lune or run-in-roblox).
- API freeze, then semantic versioning for every breaking change.
