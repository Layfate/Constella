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

## Next: verification and optimization (toward 0.2.0)

This stage proves that what exists works well. No new modules are planned.

- **Data:** run it with real ProfileStore in a separate test experience. Cover disconnects, shutdowns, rejoining a second server and high player counts. Data stays beta until this passes.
- **Pool:** benchmark instance reuse against creating and destroying instances, and measure memory over long sessions.
- **Random:** add statistical distribution tests (chi-squared) on top of the existing tolerance tests. Document a pattern for server-authoritative reward flows.
- **Benchmarks** for Signal, Cleanup, Pool and Network validation against well-known standalone libraries. No performance claims will be made until they exist.
- **Script Analysis pass**, to fix strict-mode type warnings.

## Toward 1.0

- A headless test runner for CI (Lune or run-in-roblox).
- API freeze, then semantic versioning for every breaking change.
