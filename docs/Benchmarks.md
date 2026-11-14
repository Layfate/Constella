# Benchmarks

Measured results, including where Constella loses. They come from one machine, so run the suite yourself before relying on them; see [How to run](#how-to-run).

## Setup

| | |
| --- | --- |
| Date | 2026-11-14 |
| Place | **A different Studio place from the previous run.** This run used a published test place with only Constella's scripts and the comparison libraries in it. The previous run (2026-11-13) used the unpublished dev place. |
| Engine | Roblox Studio 0.747.0.7471481 (Edit mode, Windows), nothing else running |
| Code | Constella 0.2.0, loaded from the release `Constella.rbxm`, with the Signal dispatch change described under [History](#history). The previous run measured the version before it. |
| Tests | 238 of 238 unit tests passed in the same place, on the same package, before the benchmark run. |
| Speed method | The whole suite ran **5 times**. In each run, a case runs once to warm up, then 5 timed trials with a yield between them; the run's result is the median of those trials. The table shows the **median across the 5 runs**, plus the best and worst run. Every run's result is listed under [All 5 runs](#all-5-runs). |
| Memory method | Heap growth (`gcinfo`) while building 5,000 objects, repeated 21 times. Garbage collection during a build can only make a sample *smaller*, so the 80th percentile is reported; the upper samples are the uninterrupted ones. Repeated rounds gave identical results. |
| Leak method | Objects go into a weak-keyed table and are released while their owner stays alive. The check then waits (creating throwaway garbage to keep the collector running) until the garbage collector has freed them. |
| Compared with | [sleitnick/signal](https://github.com/Sleitnick/RbxUtil/tree/main/modules/signal) 2.0.3 (GoodSignal-style) and [sleitnick/trove](https://github.com/Sleitnick/RbxUtil/tree/main/modules/trove) 1.8.0, both from RbxUtil commit `31f9120fca02`, plus hand-written baselines for Random |

Compare implementations **within one run**, not across runs. Absolute times change with the machine and the place (see [Why the two runs differ](#why-the-two-runs-differ)).

### Comparing like with like

Constella.Signal catches every listener's errors (`xpcall`, reported through `OnError`), so one failing listener can't break the others. sleitnick/signal doesn't catch them. To compare the same guarantee, the suite also runs sleitnick/signal with each listener wrapped in `xpcall`. That's the fair comparison, and it's listed first below.

For Random, `Random.choose` checks every entry on every call, so comparing it with a precomputed table mostly measures that validation. The two hand-written baselines skip validation entirely, so they compare the selection algorithm itself.

## Speed

Median µs per operation. The last column is the previous run's median, from the other place, for comparison (— means the case is new).

| Group | Case | Implementation | Median | Best run | Worst run | Previous (2026-11-13) |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Signal | Connect + Disconnect | Constella.Signal | 0.304 | 0.242 | 0.425 | 0.307 |
| Signal | Connect + Disconnect | sleitnick/signal + xpcall (same guarantee) | 0.188 | 0.181 | 0.265 | 0.201 |
| Signal | Connect + Disconnect | sleitnick/signal (no error isolation) | 0.195 | 0.124 | 0.317 | 0.183 |
| Signal | Fire, 1 listener | Constella.Signal | 0.409 | 0.405 | 0.518 | 0.458 |
| Signal | Fire, 1 listener | sleitnick/signal + xpcall (same guarantee) | 0.375 | 0.372 | 0.403 | 0.370 |
| Signal | Fire, 1 listener | sleitnick/signal (no error isolation) | 0.328 | 0.319 | 0.394 | 0.324 |
| Signal | Fire, 10 listeners | Constella.Signal | 3.644 | 3.605 | 4.199 | 3.793 |
| Signal | Fire, 10 listeners | sleitnick/signal + xpcall (same guarantee) | 3.401 | 3.378 | 3.627 | 3.497 |
| Signal | Fire, 10 listeners | sleitnick/signal (no error isolation) | 2.933 | 2.864 | 3.433 | 2.885 |
| Signal | Fire, 100 listeners | Constella.Signal | 36.343 | 35.311 | 41.783 | — |
| Signal | Fire, 100 listeners | sleitnick/signal + xpcall (same guarantee) | 34.544 | 33.676 | 40.828 | — |
| Signal | Fire, 100 listeners | sleitnick/signal (no error isolation) | 28.756 | 28.175 | 30.090 | — |
| Signal | Fire, 1,000 listeners | Constella.Signal | 360.032 | 355.666 | 385.890 | — |
| Signal | Fire, 1,000 listeners | sleitnick/signal + xpcall (same guarantee) | 341.828 | 338.894 | 387.826 | — |
| Signal | Fire, 1,000 listeners | sleitnick/signal (no error isolation) | 284.360 | 280.564 | 325.056 | — |
| Cleanup | Add + Clean 100 functions | Constella.Cleanup | 18.044 | 17.632 | 20.446 | 19.215 |
| Cleanup | Add + Clean 100 functions | sleitnick/trove | 157.699 | 157.069 | 188.677 | 151.731 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | Constella.Cleanup | 134.004 | 129.228 | 160.907 | 144.129 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | sleitnick/trove | 144.062 | 141.297 | 176.172 | 145.321 |
| Pool | Spawn + despawn a Part | Constella.Pool | 31.001 | 30.312 | 36.372 | 19.932 |
| Pool | Spawn + despawn a Part | Clone + Destroy (no pool) | 52.516 | 51.683 | 65.677 | 38.895 |
| Network | Accept a valid request (all checks) | Constella.Network | 2.034 | 1.782 | 2.063 | 2.013 |
| Network | Reject a forged request | Constella.Network | 1.569 | 1.515 | 2.136 | 1.562 |
| Random | Weighted roll, 100 entries | `lootTable:Roll` (precomputed, binary search) | 0.252 | 0.251 | 0.263 | 0.261 |
| Random | Weighted roll, 100 entries | Hand-written: precomputed totals, linear scan | 0.522 | 0.502 | 0.582 | — |
| Random | Weighted roll, 100 entries | Hand-written: sum, then linear scan (each call) | 1.358 | 1.341 | 1.611 | — |
| Random | Weighted roll, 100 entries | `Random.choose` (validates every call) | 25.173 | 24.949 | 28.195 | 26.535 |
| State | Set with 1 subscriber | Constella.State | 1.020 | 0.948 | 1.272 | 1.103 |

### All 5 runs

Each value is that run's median of 5 timed trials, in µs per operation, in the order the runs happened. Run 4 was slower for almost every case, which points to the machine rather than the code; the medians aren't affected by one slow run.

| Case | Implementation | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Signal: Connect + Disconnect | Constella.Signal | 0.242 | 0.304 | 0.367 | 0.425 | 0.295 |
| Signal: Connect + Disconnect | sleitnick/signal + xpcall | 0.188 | 0.183 | 0.181 | 0.265 | 0.252 |
| Signal: Connect + Disconnect | sleitnick/signal | 0.254 | 0.124 | 0.182 | 0.317 | 0.195 |
| Signal: Fire, 1 listener | Constella.Signal | 0.409 | 0.405 | 0.410 | 0.518 | 0.406 |
| Signal: Fire, 1 listener | sleitnick/signal + xpcall | 0.372 | 0.372 | 0.375 | 0.403 | 0.375 |
| Signal: Fire, 1 listener | sleitnick/signal | 0.328 | 0.319 | 0.336 | 0.394 | 0.324 |
| Signal: Fire, 10 listeners | Constella.Signal | 3.605 | 3.609 | 3.776 | 4.199 | 3.644 |
| Signal: Fire, 10 listeners | sleitnick/signal + xpcall | 3.378 | 3.391 | 3.435 | 3.627 | 3.401 |
| Signal: Fire, 10 listeners | sleitnick/signal | 2.864 | 2.869 | 3.433 | 3.207 | 2.933 |
| Signal: Fire, 100 listeners | Constella.Signal | 35.438 | 35.311 | 36.343 | 41.783 | 37.013 |
| Signal: Fire, 100 listeners | sleitnick/signal + xpcall | 33.676 | 33.875 | 34.544 | 37.189 | 40.828 |
| Signal: Fire, 100 listeners | sleitnick/signal | 28.175 | 28.526 | 29.272 | 30.090 | 28.756 |
| Signal: Fire, 1,000 listeners | Constella.Signal | 356.426 | 355.666 | 366.128 | 385.890 | 360.032 |
| Signal: Fire, 1,000 listeners | sleitnick/signal + xpcall | 340.932 | 341.828 | 362.366 | 387.826 | 338.894 |
| Signal: Fire, 1,000 listeners | sleitnick/signal | 283.108 | 280.564 | 292.506 | 325.056 | 284.360 |
| Cleanup: Add + Clean 100 functions | Constella.Cleanup | 17.911 | 18.044 | 17.632 | 20.446 | 20.315 |
| Cleanup: Add + Clean 100 functions | sleitnick/trove | 157.699 | 157.069 | 174.574 | 188.677 | 157.406 |
| Cleanup: Connect + Clean 100 RBXScriptConnections | Constella.Cleanup | 129.228 | 130.797 | 160.907 | 142.816 | 134.004 |
| Cleanup: Connect + Clean 100 RBXScriptConnections | sleitnick/trove | 162.752 | 144.062 | 176.172 | 143.904 | 141.297 |
| Pool: Spawn + despawn a Part | Constella.Pool | 30.633 | 30.312 | 36.372 | 32.842 | 31.001 |
| Pool: Spawn + despawn a Part | Clone + Destroy (no pool) | 52.516 | 51.683 | 65.677 | 63.006 | 52.341 |
| Network: Accept a valid request (all checks) | Constella.Network | 2.034 | 1.813 | 2.063 | 2.040 | 1.782 |
| Network: Reject a forged request | Constella.Network | 1.569 | 1.539 | 2.136 | 1.583 | 1.515 |
| Random: Weighted roll, 100 entries | `lootTable:Roll` | 0.252 | 0.251 | 0.258 | 0.263 | 0.251 |
| Random: Weighted roll, 100 entries | Hand-written: precomputed totals, linear scan | 0.502 | 0.522 | 0.582 | 0.522 | 0.515 |
| Random: Weighted roll, 100 entries | Hand-written: sum, then linear scan | 1.358 | 1.341 | 1.611 | 1.406 | 1.350 |
| Random: Weighted roll, 100 entries | `Random.choose` | 25.142 | 24.949 | 28.195 | 26.088 | 25.173 |
| State: Set with 1 subscriber | Constella.State | 1.020 | 0.948 | 1.272 | 1.066 | 1.007 |

## Memory

Identical in both runs.

| Per object | Constella | Compared with |
| --- | ---: | ---: |
| Connected Signal listener | **160 bytes** | 176 bytes (sleitnick/signal) |
| Function tracked by Cleanup | **53 bytes** | 106 bytes (sleitnick/trove) |

## Leaks

Each check releases 2,000 objects while their owner stays alive, then waits for the garbage collector. Both runs found no leaks.

| Check | Still alive afterwards |
| --- | ---: |
| Signal: disconnected listeners (signal kept alive) | 0 of 2,000 |
| Cleanup: cleaned resources (manager kept alive) | 0 of 2,000 |
| State: unsubscribed callbacks (state kept alive) | 0 of 2,000 |
| Pool: objects destroyed past MaxIdle (pool kept alive) | 0 of 2,000 |

The unit tests include the same kind of check, so a leak fails the test suite and not just this report.

## What the numbers say

- **Signal, like for like, is a little slower than sleitnick/signal, and the gap stays small as listeners grow.**
  - `Fire` costs about 0.36 µs per listener against 0.34 µs: 9% slower with 1 listener, 7% with 10, and 5% with 100 or 1,000. The cost per listener is constant, so firing to 1,000 listeners takes about 0.36 ms.
  - `Connect`+`Disconnect` is about 1.6× slower (0.30 vs 0.19 µs). That's the cost of guarantees sleitnick/signal doesn't make: checks for a destroyed signal and a non-function callback, listeners called in connection order, `O(1)` `Disconnect` (sleitnick/signal walks its list to find the previous node), a connection count, and snapshot `Fire`. These are the noisiest rows in the report.
  - It uses **less memory** per connection (160 vs 176 bytes).
  - Without error isolation, sleitnick/signal is faster still. That's the cost of catching errors, and Constella always pays it.
- **Cleanup is about 9× faster than Trove for functions, and uses half the memory.** For RBXScriptConnections they're close (134 vs 144 µs), because the engine's own Disconnect dominates.
- **Pool is about 1.7× faster** than cloning and destroying a Part each time.
- **Network's full set of checks costs about 2 µs per request.** That's rate limiting, payload measurement, schema validation and dispatch on the server, not a client-server round trip. 1,000 requests take about 2 ms of server time.
- **`Random.lootTable` is the one to use for anything rolled often.** Against hand-written code with no validation at all, it's 2.1× faster than a precomputed linear scan (its binary search wins at 100 entries) and 5.4× faster than summing and scanning on every call. `Random.choose` is about 100× slower than `lootTable:Roll` because it validates every entry on every call, which is fine for occasional rolls.

## Why the two runs differ

- **Pool and Clone + Destroy are about 50% slower in this place** (31.0 vs 19.9 µs, and 52.5 vs 38.9 µs). Both cases create Instances and parent them into `workspace`, so their cost depends on the place and the engine, not just on Luau. Pool's lead over Clone + Destroy is similar in both places: 1.7× now, 1.95× before.
- **Luau-only cases agree within about 10%** between the two places (Cleanup functions, Network, Random, State), which is normal for runs on different days.
- **Constella.Signal `Fire` is faster because the code changed** (see [History](#history)). sleitnick/signal + xpcall's `Fire` barely moved (0.375 vs 0.370 µs), so the improvement isn't noise from the new place.
- **Sub-0.3 µs cases are noisy.** `Connect`+`Disconnect` ranged from 0.12 to 0.43 µs across this run's 5 runs, for every implementation. Treat differences under about 20% in those rows as noise.

## History

Reviews of earlier benchmark runs found real problems. They were fixed like this (the first three Signal versions were measured with the same method in one session on 2026-11-13):

| Signal version | Memory per connection | Connect + Disconnect | Fire, 1 listener |
| --- | ---: | ---: | ---: |
| v0.1.0: array, new thread per listener call | 202 B | 0.279 µs | 1.583 µs |
| Interim: thread reuse, 7-field linked-list node | 304 B | 0.352 µs | 0.435 µs |
| Compact node (2026-11-13 run) | 160 B | 0.296 µs | 0.430 µs |
| **Now: dispatch inlined** | **160 B** | see below | see below |

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

## How to run

1. Open the dev place (`rojo serve dev.project.json`).
2. Optionally, to compare with other libraries, add ModuleScripts named `Signal` (sleitnick/signal) and `Trove` (sleitnick/trove) to a Folder named `BenchmarkLibs` in `ServerStorage`. Missing libraries are skipped.
3. In the Studio command bar (Edit mode, nothing else running), run:

```lua
print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)({ Runs = 5 }))
```

It takes about 30 seconds and prints Markdown tables like the ones above, including every run's result. The code is in [`benchmarks/`](../benchmarks).
