# Benchmarks

Measurements, including where Constella loses: library benchmarks on a Roblox server (below), [real clients](#real-clients) with engine-measured traffic, a [soak harness](#soak) for multi-hour runs, and a [like-for-like Signal comparison](#signal-against-sleitnicksignal). [Independent verification](#independent-verification) says who produced these and how to reproduce them. The server tables are historical measurements for the commit named below. They predate the 0.3.1 lifecycle fixes and the 0.3.2 and 0.3.3 speedups; see the [changelog](../CHANGELOG.md) for those A/B results. Every pull request reruns the whole suite on a Roblox server against the code it changes, and fails if anything got measurably slower (see [How to run](#how-to-run)), so these numbers are checked continuously rather than once.

## Setup

| | |
| --- | --- |
| Date | 2026-11-14 |
| Where | **A live Roblox game server**, through Open Cloud Luau execution, in the CI experience used for the test suite. Nothing else ran on it. |
| Engine | Roblox 0.747.0.7471481 |
| Code | **This build:** pull request #4 at commit `f0ac681`. **Baseline:** `main` at `2be9052`, the v0.3.0 release. Both were loaded into the same server and measured in the same session. |
| Tests | 268 of 268 pass on a Roblox server for this build, including the live DataStore and cross-server tests. |
| Speed method | The whole suite ran **7 times**. In each run, every case runs once to warm up, then 5 timed trials with a yield between them; the run's result is the median of those trials. The two builds of each case run back to back, and every other run swaps which goes first. Tables show the **median across the 7 runs**, plus the best and worst run. |
| Comparison method | For each case, the ratio of the two builds' medians, with a **95% bootstrap confidence interval** (both builds' 7 results resampled 2,000 times). A change is called faster or slower only if the interval excludes ±3%. Even so, code that didn't change has come out up to 6% apart between the two builds (`lootTable:Roll` in a later run), so single-digit differences are indicative only. CI fails a pull request when a case is more than 10% slower with the interval above +5%, comfortably beyond that. |
| Memory method | Heap growth (`collectgarbage("count")`, which has sub-KB precision) while building objects, repeated many times; the 80th percentile is reported, because garbage collection during a build can only make a sample smaller. Signal and Cleanup: 21 builds of 5,000 objects; promises: 61 builds of 500. |
| Leak method | Objects go into a weak-keyed table and are released while their owner stays alive; the check waits up to 15 seconds for the garbage collector to free them. |
| Compared with | Pinned by commit and SHA-256 in CI: [sleitnick/signal](https://github.com/Sleitnick/RbxUtil/tree/main/modules/signal) 2.0.3 and [sleitnick/trove](https://github.com/Sleitnick/RbxUtil/tree/main/modules/trove) 1.8.0 (RbxUtil `31f9120`), [LemonSignal](https://github.com/Data-Oriented-House/LemonSignal) 2.0.0, [Janitor](https://github.com/howmanysmall/Janitor) 1.17.0 and [evaera/roblox-lua-promise](https://github.com/evaera/roblox-lua-promise) 4.0.0, plus hand-written baselines for Random and Pool. |

**Absolute times depend on the server.** This run's server was about twice as slow as the one used for the v0.3.0 numbers (Signal `Fire` with one listener: 0.63 µs here, 0.25 µs there). Ratios between implementations in the same run are what carry over; compare rows within one run only.

### Comparing like with like

Constella.Signal catches every listener's errors (`xpcall`, reported through `OnError`), so one failing listener can't break the others. sleitnick/signal and LemonSignal don't. To compare the same guarantee, the suite also runs both with each listener wrapped in `xpcall`; those are the fair rows.

`Random.choose` validates every entry on every call, and the hand-written Random baselines skip validation entirely, so they compare the selection algorithm itself.

## This build against v0.3.0

Median µs per operation. Only the rows with a clear change are listed here; the full table follows.

| Case | This build | v0.3.0 | Change (95% CI) |
| --- | ---: | ---: | --- |
| Promise: `resolve` + `Then` + `Await` | **3.113** | 5.923 | **−47%** [−63, −31] |
| Promise: chain 10 `Then`s, then resolve | 50.724 | 66.047 | −23% [−32, +2] (likely, not certain) |
| Replication: publish one change to a 40-item inventory (full value) | **25.596** | 38.098 | **−33%** [−36, −28] |
| Zone: step, 100 tracked Parts (built-in getters) | **36.418** | 41.733 | **−13%** [−20, −6] |
| Zone: step, 100 tracked points (custom getters) | **28.362** | 30.983 | **−8%** [−16, −5] |
| Scenario: synthetic tick with 50 simulated players | **357.603** | 401.799 | **−11%** [−17, −4] |
| Network: accept a valid request | 2.514 | 2.668 | −6% [−9, 0] |
| Data: load + release a profile | 56.676 | 61.861 | −8% [−26, −1] |

Everything else (Signal, Cleanup, Pool, Random, State, Component) is unchanged within noise, and the regression check found **no case slower**.

| Memory per object | This build | v0.3.0 |
| --- | ---: | ---: |
| Resolved promise | **322 bytes** | 416 bytes |
| Pending promise from `Then` | **242 bytes** | 549 bytes |

| Bytes sent per update (one field of a 40-item inventory changes) | Bytes |
| --- | ---: |
| Full value (both builds) | 1,929 |
| **`Delta = true`** (new) | **90** |

## Full results

Median µs per operation, with the best and worst of the 7 runs.

| Group | Case | Implementation | Median | Best run | Worst run |
| --- | --- | --- | ---: | ---: | ---: |
| Signal | Connect + Disconnect | **Constella.Signal** | 0.642 | 0.460 | 0.761 |
| Signal | Connect + Disconnect | sleitnick/signal + xpcall (same guarantee) | 0.511 | 0.358 | 0.612 |
| Signal | Connect + Disconnect | LemonSignal + xpcall (same guarantee) | 0.665 | 0.368 | 1.043 |
| Signal | Connect + Disconnect | sleitnick/signal (no error isolation) | 0.570 | 0.368 | 0.706 |
| Signal | Connect + Disconnect | LemonSignal (no error isolation) | 0.560 | 0.364 | 0.973 |
| Signal | Fire, 1 listener | **Constella.Signal** | 0.633 | 0.544 | 0.692 |
| Signal | Fire, 1 listener | sleitnick/signal + xpcall | 0.568 | 0.493 | 0.649 |
| Signal | Fire, 1 listener | LemonSignal + xpcall | 0.682 | 0.622 | 0.722 |
| Signal | Fire, 1 listener | sleitnick/signal (no error isolation) | 0.506 | 0.428 | 0.573 |
| Signal | Fire, 1 listener | LemonSignal (no error isolation) | 0.570 | 0.507 | 0.605 |
| Signal | Fire, 10 listeners | **Constella.Signal** | 5.688 | 5.373 | 6.776 |
| Signal | Fire, 10 listeners | sleitnick/signal + xpcall | 5.240 | 4.676 | 5.580 |
| Signal | Fire, 10 listeners | LemonSignal + xpcall | 5.797 | 5.368 | 6.280 |
| Signal | Fire, 100 listeners | **Constella.Signal** | 53.432 | 49.434 | 56.077 |
| Signal | Fire, 100 listeners | sleitnick/signal + xpcall | 51.635 | 47.322 | 54.414 |
| Signal | Fire, 100 listeners | LemonSignal + xpcall | 56.949 | 52.479 | 76.988 |
| Signal | Fire, 1,000 listeners | **Constella.Signal** | 542.665 | 491.791 | 594.948 |
| Signal | Fire, 1,000 listeners | sleitnick/signal + xpcall | 513.111 | 494.876 | 586.066 |
| Signal | Fire, 1,000 listeners | LemonSignal + xpcall | 585.526 | 538.910 | 665.425 |
| Cleanup | Add + Clean 100 functions | **Constella.Cleanup** | 36.804 | 35.454 | 50.520 |
| Cleanup | Add + Clean 100 functions | Janitor | 38.802 | 34.230 | 46.861 |
| Cleanup | Add + Clean 100 functions | sleitnick/trove | 242.550 | 152.697 | 277.910 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | **Constella.Cleanup** | 200.895 | 173.889 | 237.520 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | sleitnick/trove | 216.777 | 181.727 | 270.898 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | Janitor | 239.699 | 193.534 | 299.168 |
| Pool | Spawn + despawn a Part | **Constella.Pool** | 9.791 | 8.115 | 11.212 |
| Pool | Spawn + despawn a Part | Clone + Destroy (no pool) | 27.544 | 25.600 | 31.100 |
| Network | Accept a valid request (all checks) | **Constella.Network** | 2.514 | 2.412 | 2.595 |
| Network | Reject a forged request | **Constella.Network** | 2.048 | 1.932 | 2.277 |
| Random | Weighted roll, 100 entries | **`lootTable:Roll`** (precomputed) | 0.427 | 0.407 | 0.460 |
| Random | Weighted roll, 100 entries | Hand-written: precomputed totals, linear scan | 0.843 | 0.826 | 0.876 |
| Random | Weighted roll, 100 entries | Hand-written: sum, then linear scan (each call) | 2.495 | 1.991 | 2.777 |
| Random | Weighted roll, 100 entries | **`Random.choose`** (validates every call) | 8.000 | 7.652 | 8.350 |
| State | Set with 1 subscriber | **Constella.State** | 1.140 | 1.104 | 1.333 |
| State | Set a source of a computed with 1 subscriber | **Constella.State** | 2.374 | 2.231 | 2.618 |
| Promise | `resolve` + `Then` + `Await` | **Constella.Promise** | 3.113 | 2.559 | 4.718 |
| Promise | `resolve` + `Then` + `Await` | evaera/roblox-lua-promise | 20.420 | 17.868 | 21.600 |
| Promise | Chain 10 `Then`s, then resolve | **Constella.Promise** | 50.724 | 46.315 | 57.537 |
| Promise | Chain 10 `Then`s, then resolve | evaera/roblox-lua-promise | 146.370 | 114.152 | 163.743 |
| Zone | Step, 100 tracked points (custom getters) | **Constella.Zone** | 28.362 | 28.241 | 31.451 |
| Zone | Step, 100 tracked Parts (built-in getters) | **Constella.Zone** | 36.418 | 32.845 | 38.672 |
| Replication | Publish one change to a 40-item inventory | **Constella.Replication**, full value | 25.596 | 24.850 | 31.983 |
| Replication | Publish one change to a 40-item inventory | **Constella.Replication**, `Delta = true` | 39.523 | 35.216 | 43.238 |
| Data | Load + release a profile (MemoryAdapter) | **Constella.Data** | 56.676 | 43.472 | 61.785 |
| Component | Run + Destroy with 200 tagged parts | **Constella.Component** | 2068.070 | 1813.504 | 2360.904 |
| Scenario | Synthetic tick, 50 simulated players | **Constella** | 357.603 | 333.664 | 368.405 |

The scenario is a synthetic workload with 50 stand-in player tables. It calls the server request path directly, changes coins and a 50-entry Delta leaderboard, steps a zone, fires a signal and resolves promises. Replication sends are replaced with a no-op. The recorded 0.36 ms measures server-side library work only; it does not measure connected clients, transport cost, serialization or complete game frame time. [Real clients](#real-clients) measures those with up to 8 real clients.

## Memory

| Per object | Constella | Compared with |
| --- | ---: | --- |
| Connected Signal listener | **160 bytes** | 176 (sleitnick/signal), 304 (LemonSignal) |
| Function tracked by Cleanup | **53 bytes** | 52 (Janitor), 106 (sleitnick/trove) |
| Resolved promise | **322 bytes** | 5,024 (evaera/roblox-lua-promise) |
| Pending promise from `Then` | **242 bytes** | 2,896 (evaera/roblox-lua-promise) |

The promise rows include the 16-byte array slot that keeps each promise. evaera's promises record a stack trace when they're created, which is most of their size.

The byte figures above are estimates from `Network.Payload.measure`, the same estimate Network uses for its limits. [Real clients](#real-clients) has the engine-measured traffic: 130 bytes for Delta and 1,184 for the full value. [Soak](#soak) explains how to measure memory over hours.

## Leaks

Each check releases 2,000 objects while their owner stays alive, then waits for the garbage collector. Both builds freed everything, in every check:

| Check | Still alive afterwards |
| --- | ---: |
| Signal: disconnected listeners (signal kept alive) | 0 of 2,000 |
| Signal: listeners of disconnected connections that are still referenced | 0 of 2,000 |
| Cleanup: cleaned resources (manager kept alive) | 0 of 2,000 |
| State: unsubscribed callbacks (state kept alive) | 0 of 2,000 |
| Pool: objects destroyed past MaxIdle (pool kept alive) | 0 of 2,000 |
| Promise: values of the promises a kept chain came from | 0 of 2,000 |

The unit tests include the same kind of checks (plus Data: a player released during loading; Zone: an untracked item), so a regression fails the test suite and not just this report.

## What the numbers say

- **Promise is the biggest change.** Executors and handlers now run on recycled threads instead of a new coroutine each, its state sits in a compact array, and `Then`, `Finally` and `Await` queue data instead of closures. `resolve` + `Then` + `Await` takes about half the time it did, a pending promise uses 56% less memory, and Constella's Promise is about 6.6× faster than evaera/roblox-lua-promise for a single step (2.9× for a 10-step chain) at a small fraction of the memory.
- **Signal is slower than sleitnick/signal.** With per-listener error catching on all sides, `Fire` took 3–11% longer on this server (within 1% on the faster one used for v0.3.0) and was faster than LemonSignal. `Connect`+`Disconnect` is about 1.25× sleitnick/signal's cost here: Constella also checks its arguments, keeps listeners in connection order, disconnects in `O(1)` and releases the listener on `Disconnect`. It uses the least memory per connection of the three. See [Signal against sleitnick/signal](#signal-against-sleitnicksignal) for a newer local run and why.
- **Cleanup is level with Janitor and about 6.6× faster than Trove** for functions, with half of Trove's memory. For RBXScriptConnections all three are close, because the engine's own `Disconnect` dominates.
- **Pool is about 2.8× faster** than cloning and destroying a Part each time.
- **Replication full sends got a third faster** by checking and measuring a value in one walk instead of two. **Delta** cuts the bytes for a small change to a 40-item inventory by 95% (1,929 → 90) for about 54% more server time per update than a full send. That's the usual trade: bandwidth is the scarcer resource on Roblox servers, which is why Delta exists, and why it's opt-in. With real clients and real sends, Delta measured 89% fewer bytes on the wire and *less* total server time than a full send ([Real clients](#real-clients)).
- **Zone** costs about 0.3 µs per tracked item per step, 8–13% less than before: it no longer allocates per step, and built-in position getters skip the protected call.
- **Random:** `lootTable:Roll` is 19× faster than `Random.choose` and 2× faster than a hand-written precomputed scan, so use a loot table for anything rolled often.
- **The synthetic workload with 50 simulated players** took 0.36 ms in the recorded run, 11% less than the baseline. Actual replication sends were disabled.

## Real clients

Everything above runs on one server with stand-in players. This section runs Constella with **real Roblox clients**: one server and N separate Studio client processes, connected through Roblox's own network replicator, started by [`StudioTestService:ExecuteMultiplayerTestAsync`](https://create.roblox.com/docs/reference/engine/classes/StudioTestService). Every update crosses the real transport and is serialized by the engine. The code is [`tests/load/`](https://github.com/Layfate/Constella/tree/main/tests/load).

| | |
| --- | --- |
| Date | 2026-11-17 |
| Where | A local Roblox Studio (0.747.0.7471481) on an AMD Ryzen 7 5700X (8 cores) with 32 GB, Windows 11. Server and clients on the same machine. |
| Code | 0.3.7 (the changes on top of 0.3.6). |
| Clients | 1, 2, 4 and 8. Each Studio client is its own process of about 1.7 GB, so 8 is what this machine can run at once; **50 real clients have not been measured** (see [extrapolation](#what-50-players-would-cost)). |
| Workload | 10 updates per second. Each phase lasts 20 s; the first 6 s are warm-up and not measured. Characters are off, so player physics doesn't add traffic. |
| Traffic method | **The engine's own counter, not an estimate:** the server's `Stats.DataSendKbps`, the average per connected client in KB/s, as the calibration rows confirm (a 1,000-byte string costs about 1,040 bytes at every client count). Shown per update and per client, above the idle baseline. Client-to-server traffic is each client's own `DataSendKbps`. The receive counters read 0 in Studio test sessions, so they aren't used. |
| Checks | Every run must pass: each client's replica must equal the server's final value exactly (full and Delta), and the server must accept and reject exactly the requests the clients sent (every tenth one is deliberately invalid). |

**Server to each client, bytes per update** (engine-measured):

| What is sent | 1 client | 2 clients | 4 clients | 8 clients |
| --- | ---: | ---: | ---: | ---: |
| Calibration: 1,000-byte random string | 1,042 | 1,036 | 1,022 | 1,033 |
| Calibration: 4,000-byte random string | 4,152 | 4,038 | 4,129 | 4,082 |
| Plain RemoteEvent, whole 40-item inventory (hand-written baseline) | 1,162 | 1,172 | 1,165 | 1,158 |
| Replication, full value | 1,184 | 1,188 | 1,189 | 1,174 |
| **Replication, `Delta = true`** | **130** | **129** | **130** | **130** |
| Game tick (private coins + a public 50-entry Delta leaderboard) | 128 | 127 | 130 | 128 |

**Server time per tick, with real sends** (median / 95th percentile, ms). Each tick updates every player's inventory once:

| Phase | 1 client | 2 clients | 4 clients | 8 clients |
| --- | ---: | ---: | ---: | ---: |
| Plain RemoteEvent, whole inventory (hand-written baseline) | 0.065 / 0.088 | 0.116 / 0.181 | 0.220 / 0.293 | 0.398 / 0.520 |
| Replication, full value | 0.099 / 0.120 | 0.168 / 0.226 | 0.305 / 0.373 | 0.526 / 0.666 |
| Replication, `Delta = true` | 0.086 / 0.100 | 0.145 / 0.178 | 0.246 / 0.289 | 0.425 / 0.510 |
| Game tick (requests, coins, leaderboard, zone, signal, promises) | 0.124 / 0.143 | 0.136 / 0.149 | 0.166 / 0.197 | 0.199 / 0.305 |

**Requests and frames:**

| | 1 client | 2 clients | 4 clients | 8 clients |
| --- | ---: | ---: | ---: | ---: |
| Client to server, bytes per `Network` request (engine-measured) | 37 | 37 | 37 | 38 |
| Requests accepted / rejected (exactly what the clients sent) | 720 / 80 | 1,440 / 160 | 2,880 / 320 | 5,760 / 640 |
| `Ping` function round trip, median (ms) | 33.1 | 33.1 | 33.1 | 33.1 |
| Server frame time in the Game phase, median / 99th percentile (ms) | 16.9 / 18.8 | 16.9 / 18.9 | 16.9 / 18.9 | 16.9 / 18.9 |
| Replication checks passed | 2 of 2 | 4 of 4 | 8 of 8 | 16 of 16 |

What this shows:

- **Delta's saving is real, and a little smaller than estimated.** On the wire, a one-field change to the 40-item inventory costs 130 bytes with Delta against 1,184 for the full value: **89% less**, the same at every client count. The estimate in [Memory](#memory) said 95% (90 against 1,929 bytes): Roblox's encoding of the full table is more compact than the estimate, and each message carries about 40 bytes of overhead.
- **With real sends, Delta also costs less server time than a full send** (0.43 against 0.53 ms per tick at 8 clients), because the engine has much less to serialize. The library-only benchmark above, where sends are a no-op, shows Delta at 54% more CPU; that part is real, but the send dominates.
- **Replication's checks cost something over a plain RemoteEvent:** a full send takes about 30% more server time than firing the same table yourself (0.53 against 0.40 ms at 8 clients), for 1–2% more bytes (the name and version that let clients ignore stale updates). Delta sends 89% fewer bytes than the plain RemoteEvent for about 7% more server time at 8 clients (0.43 against 0.40 ms).
- **A `Network` request is about 37 bytes on the wire** (three arguments), and invalid requests were rejected exactly, with 8 clients sending 20 per second each.
- **Frame time didn't move:** 16.9 ms median at every client count, the 60 Hz frame. The 33 ms `Ping` round trip is two frames: Studio's replicator sends at frame boundaries.

### What 50 players would cost

Not measured: this is a straight-line fit through the 1–8 client results, so treat it as an estimate. Per extra client, an inventory update every tick added about 0.048 ms with Delta, 0.061 ms full and 0.048 ms with a plain RemoteEvent; the game tick added about 0.011 ms. At 50 players and 10 updates per second that is roughly 2.5 ms (Delta), 3.1 ms (full) or 2.4 ms (RemoteEvent) per tick for a per-player inventory change every tick, and about 0.7 ms for the game tick: well inside a 16.7 ms frame. At 130 bytes per update, Delta at 10 updates per second sends each player about 1.3 KB/s; the full value would be about 11.8 KB/s.

## Soak

No multi-hour soak result is published yet. The harness ships in 0.3.7: it runs the full game tick plus constant creation and teardown of signals, cleanups, promises, the pool, zone items, components and private shares, and records the heap's low point for each interval. A control run with clients connected but no Constella work tells library growth apart from Studio's own. Short smoke runs with 1–2 clients passed, but they are too short to say anything about leaks.

To run it yourself: `.github/scripts/studio_load.ps1 -Mode Soak -Clients 4 -Minutes 120`, then the same with `-Minutes 60 -NoWorkload` for the control run, and `python .github/scripts/load_report.py --soak <result.json>` for the table. Results are welcome through the "Benchmark result" issue template.

## Signal against sleitnick/signal

sleitnick/signal is faster. Measured A/B in one local Studio session (same machine as above), 15 runs, against the pinned comparison libraries; median µs per operation:

| Case | Constella.Signal (this build) | Constella.Signal 0.3.6 | sleitnick/signal + xpcall | LemonSignal + xpcall | sleitnick/signal (errors not isolated) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Connect + Disconnect | 0.266 | 0.286 | **0.223** | 0.273 | 0.225 |
| Fire, 1 listener | 0.474 | 0.454 | **0.382** | 0.430 | 0.330 |
| Fire, 10 listeners | 3.727 | 3.695 | **3.430** | 3.849 | 2.974 |
| Fire, 100 listeners | 36.14 | 35.93 | **33.83** | 38.08 | 29.43 |
| Fire, 1,000 listeners | 361.9 | 361.4 | **340.7** | 386.1 | 295.3 |
| Memory per connection | **144 B** | 160 B | 176 B | 304 B | 176 B |

- **Like for like** (every listener's errors caught), Constella's `Fire` takes 24% longer with one listener and 6–9% longer with 10 or more; `Connect`+`Disconnect` about 1.2× as long. It beats LemonSignal from 10 listeners up.
- **Where the time goes.** About 0.04 µs of every `Fire`, most of the one-listener gap, is one check: is the idle runner thread still alive? Without it, `Fire` with one listener measured 0.430 µs. The check is what keeps a signal working when user code cancels a thread it got from `coroutine.running()` inside a listener (for example by adding it to a cleanup). The benchmark report checks this for each library:

  | After user code cancels an idle runner thread | Result |
  | --- | --- |
  | Constella.Signal | keeps working |
  | sleitnick/signal 2.0.3 | every later `Fire` raises "cannot spawn non-suspended coroutine with arguments"; no listener runs |
  | LemonSignal 2.0.0 | the same |

  The rest of the gap per listener comes from connection-order dispatch with snapshot semantics (an id check per listener) and reporting errors to `OnError`.
- **This build's change:** connections are a circular list with the signal as its sentinel, so a connection no longer stores its signal. It saves 16 bytes per connection and makes `Connect`+`Disconnect` 7% faster [95% CI −16, −2], and costs 4% [+3, +6] on `Fire` with one listener (0.02 µs); 10 or more listeners are unchanged. Also tried and measured in the same way, and rejected: stopping the walk on reaching the signal (3–4% slower per listener), checking the callback slot instead of `Connected` (no change), testing the newest id first (no change), and stopping after the last connection seen at the start (no change to the one-listener cost).
- Local Studio and the Roblox servers in [Full results](#full-results) differ in absolute speed and slightly in ratios (there, `Fire` was within 3–11% of sleitnick/signal + xpcall). Pull requests are still measured on a Roblox server in CI.

## Independent verification

**All results on this page were produced by Constella's author.** None has been reproduced by anyone else yet. To make that easy:

- **One command** reproduces the benchmarks, the real-client load test and optionally a soak: `powershell -ExecutionPolicy Bypass -File .github/scripts/reproduce.ps1` (add `-Clients 8 -SoakMinutes 120` for the full set). It writes `build/reproduction/<date>/REPORT.md` with your environment, the Markdown tables and the raw JSON.
- **The comparison libraries are third-party code, downloaded unmodified** at pinned commits and checked by SHA-256 ([`.github/bench-libs.json`](https://github.com/Layfate/Constella/blob/main/.github/bench-libs.json)). The only wrapping is the `xpcall` used for the like-for-like rows, shown in the report's labels.
- **Submit a result** with the "Benchmark result" issue template. Results are listed here whether they agree or not, with the submitter's affiliation as given.

| Submitted by | Date | Machine | Agrees? | Link |
| --- | --- | --- | --- | --- |
| (none yet) | | | | |

## History

Reviews of earlier benchmark runs found real problems. They were fixed like this (the first three Signal versions were measured with the same method in one session on 2026-11-13):

| Signal version | Memory per connection | Connect + Disconnect | Fire, 1 listener |
| --- | ---: | ---: | ---: |
| v0.1.0: array, new thread per listener call | 202 B | 0.279 µs | 1.583 µs |
| Interim: thread reuse, 7-field linked-list node | 304 B | 0.352 µs | 0.435 µs |
| Compact node (2026-11-13 run) | 160 B | 0.296 µs | 0.430 µs |
| Dispatch inlined (0.3.0 to 0.3.6) | 160 B | see below | see below |
| **Now: circular list, signal as sentinel** | **144 B** | see [Signal against sleitnick/signal](#signal-against-sleitnicksignal) | |

The latest change was measured as an A/B test in one session on 2026-11-14: each version ran 9 rounds, alternating with the others, and the table shows the median round with its range.

| Signal version | Connect + Disconnect | Fire, 1 listener | Fire, 10 listeners |
| --- | ---: | ---: | ---: |
| Compact node (before) | 0.280 µs (0.257–0.347) | 0.427 µs (0.418–0.456) | 3.781 µs (3.718–3.931) |
| **Now: dispatch inlined** | **0.276 µs (0.214–0.311)** | **0.407 µs (0.400–0.418)** | **3.657 µs (3.552–3.823)** |
| Rejected: also passing the connection to the runner | 0.263 µs (0.244–0.300) | 0.400 µs (0.396–0.410) | 3.586 µs (3.531–3.713) |
| sleitnick/signal + xpcall, same session | 0.206 µs (0.147–0.219) | 0.378 µs (0.370–0.517) | 3.413 µs (3.355–3.616) |

- **v0.1.0 → interim.** Fire became 3.7× faster by reusing runner threads instead of creating a coroutine per listener call. But each connection became a 7-field table, which Luau stores in 8 hash slots, so memory grew by 50% and Connect got slower.
- **Interim → compact node.** Connection fields moved into the table's array part, leaving only the public `Connected` field in the hash part, and "connect once" became the sign of the order number. Memory fell to 21% below v0.1.0, Connect returned to v0.1.0's speed, and Fire stayed fast.
- **A retention bug fixed on the way.** Building the leak check exposed a bug in the thread-reuse pattern, which is also present in GoodSignal-style signals. A runner thread entered its loop with its first call's arguments and kept them on its stack for as long as it existed, so it held that listener and its `Fire` arguments alive. Runners now start by yielding. A unit test reproduces the bug: it fails on the interim version and passes now.
- **Compact node → now.** `Fire` used to call a `dispatch` helper per listener. Dispatch is now written out in `Fire`, and `Connect` no longer goes through a shared helper either. `Fire` became 3–5% faster. `Connect`+`Disconnect` didn't change beyond noise, and nor did memory. Ordering, snapshot `Fire`, error isolation and the runner-retention fix are unchanged, and the full test suite passes.
- **Tried and rejected: passing the connection to the runner.** Handing the runner thread `(connection, ...)` instead of `(onError, callback, ...)` saved one argument per listener and another 1–2% on `Fire`. But the most recent `Fire` argument then often stayed reachable after the call: in a stress test it was still alive in 21 of 29 trials, against 0 of 29 with the layout kept here. Further testing showed this is bounded: an idle runner's or the caller's unused stack slots hold one call's values until they're reused, and every thread-reusing signal has some version of it. With the layout kept here, the value held is the listener, which is usually alive anyway, instead of a payload that might be large.
- **Memory tests made deterministic.** That bounded hold had made the two Signal memory tests flaky, depending on which tests ran before them. They now run their work on a thread that finishes and then run one more listener before checking. Each still fails against a deliberately leaking Signal: one whose `Disconnect` keeps the node, and one whose runner pins its first call's arguments (the original GoodSignal-style bug).
- **Tried and rejected: `Connected` in the array part.** Moving `Connected` into slot 6 saves 16 bytes per connection (144 B), but the public `Connected` field then needs an `__index` function. Every method call on a connection goes through it, so `Connect`+`Disconnect` got slightly slower, and `Fire` was no faster than the version adopted above.
- **Cleanup** moved from a table per resource to two parallel arrays, giving about 4× less memory.

### 0.3.0

Measured A/B on a Roblox server against `main` before the change, in the run published with v0.3.0 (a faster server than the one above).

- **Random.choose** formatted an error label (`"entry #%d Weight"`) for every entry on every call and built two arrays plus the cumulative sums. It now validates with a plain check and formats only on failure, and without modifiers it scans running sums instead of allocating. 4.3× faster. A test checks that it picks exactly what `lootTable:Roll` picks for 3,000 rolls.
- **State** allocated a table per `Set` (the old value) and two per flush round. It now uses reused arrays: 16–20% faster.
- **Network** created a closure with six upvalues to measure every request's payload. The measuring function now passes its totals along instead: 12–16% faster per request.
- **Promise** created three empty lists per promise up front and kept them after settling. They're now created on demand and dropped on settle: 32% less memory per resolved promise, 15% per pending one, and a kept chain no longer keeps its ancestors' values.
- **Signal** `Disconnect` now clears the listener slot, so a kept connection no longer keeps its listener alive. A first version also cleared the signal and previous-node slots on every `Disconnect`; that cost 6–16% on `Connect`+`Disconnect` in two runs (before the run-order swap below) and rarely freed the signal (later connected nodes still reference it), so only `DisconnectAll` and `Destroy` clear those now. The cost that remains is within noise.
- **Method:** within each run, the build that went first was always the current one, and the first case after the allocation-heavy Promise cases ran slower. Every other run now swaps the order. Promise memory first used 5,000-object builds, which overlapped garbage collection steps and gave impossible numbers (59 bytes for a 4-table object); it now uses 500-object builds.

### After v0.3.0: recycled Promise threads, Delta, broader benchmarks

Measured A/B against the v0.3.0 release on a Roblox server (the tables above).

- **Promise** created a coroutine for every executor and every handler, three closures per `Then`, and kept its state in a hash table. Executors and handlers now run on recycled runner threads (like Signal's listeners), `Then`/`Finally`/`Await` queue data instead of closures, and the state lives in the array part. `resolve` + `Then` + `Await` is 47% faster and a pending promise 56% smaller. Two memory tests needed one extra job before checking, because an idle runner can hold its last job's values in unused stack slots (bounded, as with Signal).
- **Replication** walked each value twice (a type check, then the size estimate). One walk now does both: full sends are 33% faster. The new opt-in **Delta** mode first deep-copied every value and then diffed it, which made an update 63% slower than v0.3.0's full send; building the private copy during the diff, reusing every unchanged part, brought it level with v0.3.0's full send (39.5 vs 38.1 µs) while sending 95% fewer bytes.
- **Zone** cloned its item list and allocated a table on every step, and wrapped every position getter in a protected call. It now reuses a buffer and calls the built-in getters directly: 8–13% faster.
- **Signal** kept a per-signal id counter and connection count up to date on every `Connect` and `Disconnect`. It now uses one counter shared by all signals and counts on demand in `GetConnectionCount`. The change is within noise on these servers.
- **Network** wrapped payload measurement in its own protected call; the whole check already runs in one. Small gain (about 6%).
- **Benchmark method:** added LemonSignal, Janitor and evaera/roblox-lua-promise; Zone, Replication (time and bytes), Data, Component and a 50-player tick; 7 runs; a bootstrap confidence interval for every A/B ratio; and a CI gate for regressions. The first run with Janitor made it look free (0 bytes, 2× faster than Constella), because every case added the same function and Janitor keys entries by object, so it kept one entry; every library now gets distinct functions. The Delta case first compared Delta against v0.3.0's full sends under the same label and tripped the new gate (+63%); cases for features a build doesn't have are now skipped for that build.

## How to run

**On a Roblox server (CI).** Every pull request runs the suite (7 runs) on a Roblox server through Open Cloud, comparing the pull request with its base commit in the same session, with the comparison libraries downloaded at pinned commits and checked by SHA-256. The report goes into the job summary of the "Test suite on a Roblox server" job. **A regression fails the run:** any case more than 10% slower than the base commit, with its 95% confidence interval above +5%. Problems reaching Roblox or GitHub only produce a warning, so an outage can't block a pull request. The scripts are [`.github/scripts/roblox_bench.py`](https://github.com/Layfate/Constella/blob/main/.github/scripts/roblox_bench.py) and the "Build the benchmark place" step in [`ci.yml`](https://github.com/Layfate/Constella/blob/main/.github/workflows/ci.yml).

**In a local Studio, headless (Windows).** The comparison libraries are downloaded at their pinned commits and checked by SHA-256; then Studio's RunScript CLI runs the suite in Edit mode and writes the Markdown report:

```powershell
python .github/scripts/fetch_bench_libs.py          # --baseline <path to a Constella folder> adds an A/B build
.github/scripts/studio_bench.ps1 -Runs 7            # -Groups Signal,Promise runs only those groups
```

**Real clients and soak.** `.github/scripts/studio_load.ps1 -Clients 4` runs the load test, `-Mode Soak -Minutes 120` the soak (add `-NoWorkload` for its control run), and `.github/scripts/load_report.py` turns the JSON into the tables above. Only one multiplayer test session can run at a time. `.github/scripts/reproduce.ps1` runs all of it in one go (see [Independent verification](#independent-verification)).

**In Studio.**

1. Open the dev place (`rojo serve dev.project.json`).
2. Optionally, to compare with other libraries, add ModuleScripts named `Signal` (sleitnick/signal), `LemonSignal`, `Trove` (sleitnick/trove), `Janitor` (with its `Promise` child module) and `Promise` (evaera/roblox-lua-promise) to a Folder named `BenchmarkLibs` in `ServerStorage`. Missing libraries are skipped.
3. In the Studio command bar (Edit mode, nothing else running), run:

```lua
print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)({ Runs = 7 }))
```

To compare two builds of the package, put the second one next to the first (for example as `ReplicatedStorage.Packages.ConstellaBaseline`) and pass both:

```lua
local Packages = game.ReplicatedStorage.Packages
print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)({
	Runs = 7,
	Packages = {
		{ Name = "this build", Module = Packages.Constella },
		{ Name = "baseline", Module = Packages.ConstellaBaseline },
	},
}))
```

It takes about a minute per build and prints Markdown tables like the ones above: every run's result, the A/B comparison with confidence intervals, and any regressions. The code is in [`benchmarks/`](https://github.com/Layfate/Constella/tree/main/benchmarks).
