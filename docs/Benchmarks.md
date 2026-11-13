# Benchmarks

Measured results, including where Constella loses. They come from one machine, so run the suite yourself before relying on them; see [How to run](#how-to-run).

## Setup

| | |
| --- | --- |
| Date | 2026-11-14 |
| Place | **A different Studio place from the previous run.** This run used a published test place with only Constella's scripts and the comparison libraries in it. The previous run (2026-11-13) used the unpublished dev place. |
| Engine | Roblox Studio 0.747.0.7471481 (Edit mode, Windows), nothing else running |
| Code | Constella 0.2.0, with the Signal dispatch change described under [History](#history). The previous run measured the version before it. |
| Tests | 234 of 234 unit tests passed in the same place, on the same code, before the benchmark run. |
| Speed method | The whole suite ran **5 times**. In each run, a case runs once to warm up, then 5 timed trials with a yield between them; the run's result is the median of those trials. The table shows the **median across the 5 runs**, plus the best and worst run. Every run's result is listed under [All 5 runs](#all-5-runs). |
| Memory method | Heap growth (`gcinfo`) while building 5,000 objects, repeated 21 times. Garbage collection during a build can only make a sample *smaller*, so the 80th percentile is reported; the upper samples are the uninterrupted ones. Repeated rounds gave identical results. |
| Leak method | Objects go into a weak-keyed table and are released while their owner stays alive. The check then waits (creating throwaway garbage to keep the collector running) until the garbage collector has freed them. |
| Compared with | [sleitnick/signal](https://github.com/Sleitnick/RbxUtil/tree/main/modules/signal) 2.0.3 (GoodSignal-style) and [sleitnick/trove](https://github.com/Sleitnick/RbxUtil/tree/main/modules/trove) 1.8.0, both from RbxUtil commit `31f9120fca02` |

Compare implementations **within one run**, not across runs. Absolute times change with the machine and the place (see [Why the two runs differ](#why-the-two-runs-differ)).

### Comparing like with like

Constella.Signal catches every listener's errors (`xpcall`, reported through `OnError`), so one failing listener can't break the others. sleitnick/signal doesn't catch them. To compare the same guarantee, the suite also runs sleitnick/signal with each listener wrapped in `xpcall`. That's the fair comparison, and it's listed first below.

## Speed

Median µs per operation. The last column is the previous run's median, from the other place, for comparison.

| Group | Case | Implementation | Median | Best run | Worst run | Previous (2026-11-13) |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Signal | Connect + Disconnect | Constella.Signal | 0.295 | 0.290 | 0.304 | 0.307 |
| Signal | Connect + Disconnect | sleitnick/signal + xpcall (same guarantee) | 0.221 | 0.186 | 0.232 | 0.201 |
| Signal | Connect + Disconnect | sleitnick/signal (no error isolation) | 0.209 | 0.181 | 0.235 | 0.183 |
| Signal | Fire, 1 listener | Constella.Signal | 0.407 | 0.399 | 0.426 | 0.458 |
| Signal | Fire, 1 listener | sleitnick/signal + xpcall (same guarantee) | 0.370 | 0.366 | 0.374 | 0.370 |
| Signal | Fire, 1 listener | sleitnick/signal (no error isolation) | 0.328 | 0.319 | 0.334 | 0.324 |
| Signal | Fire, 10 listeners | Constella.Signal | 3.594 | 3.567 | 3.611 | 3.793 |
| Signal | Fire, 10 listeners | sleitnick/signal + xpcall (same guarantee) | 3.369 | 3.348 | 3.381 | 3.497 |
| Signal | Fire, 10 listeners | sleitnick/signal (no error isolation) | 2.871 | 2.845 | 2.908 | 2.885 |
| Cleanup | Add + Clean 100 functions | Constella.Cleanup | 16.402 | 16.163 | 20.020 | 19.215 |
| Cleanup | Add + Clean 100 functions | sleitnick/trove | 160.057 | 148.964 | 176.374 | 151.731 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | Constella.Cleanup | 126.094 | 122.616 | 159.272 | 144.129 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | sleitnick/trove | 127.903 | 121.900 | 165.118 | 145.321 |
| Pool | Spawn + despawn a Part | Constella.Pool | 30.714 | 30.356 | 31.092 | 19.932 |
| Pool | Spawn + despawn a Part | Clone + Destroy (no pool) | 51.948 | 51.085 | 63.240 | 38.895 |
| Network | Accept a valid request (all checks) | Constella.Network | 1.925 | 1.770 | 1.944 | 2.013 |
| Network | Reject a forged request | Constella.Network | 1.476 | 1.466 | 1.516 | 1.562 |
| Random | Weighted roll, 100 entries | `lootTable:Roll` (precomputed) | 0.247 | 0.246 | 0.254 | 0.261 |
| Random | Weighted roll, 100 entries | `Random.choose` (validates every call) | 24.817 | 24.466 | 26.666 | 26.535 |
| State | Set with 1 subscriber | Constella.State | 1.023 | 0.976 | 1.033 | 1.103 |

### All 5 runs

Each value is that run's median of 5 timed trials, in µs per operation, in the order the runs happened.

| Case | Implementation | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Signal: Connect + Disconnect | Constella.Signal | 0.304 | 0.295 | 0.290 | 0.296 | 0.295 |
| Signal: Connect + Disconnect | sleitnick/signal + xpcall | 0.186 | 0.228 | 0.221 | 0.232 | 0.221 |
| Signal: Connect + Disconnect | sleitnick/signal | 0.235 | 0.202 | 0.209 | 0.181 | 0.229 |
| Signal: Fire, 1 listener | Constella.Signal | 0.426 | 0.415 | 0.407 | 0.399 | 0.404 |
| Signal: Fire, 1 listener | sleitnick/signal + xpcall | 0.370 | 0.374 | 0.371 | 0.368 | 0.366 |
| Signal: Fire, 1 listener | sleitnick/signal | 0.331 | 0.334 | 0.319 | 0.328 | 0.322 |
| Signal: Fire, 10 listeners | Constella.Signal | 3.573 | 3.594 | 3.611 | 3.567 | 3.598 |
| Signal: Fire, 10 listeners | sleitnick/signal + xpcall | 3.355 | 3.373 | 3.369 | 3.348 | 3.381 |
| Signal: Fire, 10 listeners | sleitnick/signal | 2.908 | 2.893 | 2.871 | 2.845 | 2.866 |
| Cleanup: Add + Clean 100 functions | Constella.Cleanup | 16.316 | 20.020 | 16.402 | 16.163 | 19.053 |
| Cleanup: Add + Clean 100 functions | sleitnick/trove | 160.057 | 162.027 | 153.551 | 148.964 | 176.374 |
| Cleanup: Connect + Clean 100 RBXScriptConnections | Constella.Cleanup | 126.094 | 124.941 | 122.616 | 159.272 | 144.576 |
| Cleanup: Connect + Clean 100 RBXScriptConnections | sleitnick/trove | 165.118 | 164.333 | 121.900 | 127.903 | 126.367 |
| Pool: Spawn + despawn a Part | Constella.Pool | 30.795 | 31.092 | 30.714 | 30.356 | 30.476 |
| Pool: Spawn + despawn a Part | Clone + Destroy (no pool) | 52.554 | 63.240 | 51.085 | 51.899 | 51.948 |
| Network: Accept a valid request (all checks) | Constella.Network | 1.770 | 1.944 | 1.873 | 1.925 | 1.940 |
| Network: Reject a forged request | Constella.Network | 1.476 | 1.477 | 1.466 | 1.516 | 1.468 |
| Random: Weighted roll, 100 entries | `lootTable:Roll` | 0.246 | 0.247 | 0.247 | 0.254 | 0.250 |
| Random: Weighted roll, 100 entries | `Random.choose` | 24.960 | 24.466 | 24.584 | 26.666 | 24.817 |
| State: Set with 1 subscriber | Constella.State | 1.023 | 1.033 | 0.976 | 1.001 | 1.031 |

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

- **Signal, like for like, is a little slower than sleitnick/signal.**
  - `Fire` is about 7–10% slower (0.407 vs 0.370 µs with 1 listener, 3.59 vs 3.37 µs with 10). In the previous run, before the dispatch change, it was 8–24% slower.
  - `Connect`+`Disconnect` is about 1.3× slower (0.30 vs 0.22 µs). That's the cost of guarantees sleitnick/signal doesn't make: checks for a destroyed signal and a non-function callback, listeners called in connection order, `O(1)` `Disconnect` (sleitnick/signal walks its list to find the previous node), a connection count, and snapshot `Fire`.
  - It uses **less memory** per connection (160 vs 176 bytes).
  - Without error isolation, sleitnick/signal is faster still. That's the cost of catching errors, and Constella always pays it.
- **Cleanup is about 10× faster than Trove for functions, and uses half the memory.** For RBXScriptConnections the two are even (126 vs 128 µs), because the engine's own Disconnect dominates.
- **Pool is about 1.7× faster** than cloning and destroying a Part each time.
- **Network's full set of checks costs about 2 µs per request.** That's rate limiting, payload measurement, schema validation and dispatch, so 1,000 requests take about 2 ms of server time.
- **Use `Random.lootTable`** for anything rolled often. It's about 100× faster than `Random.choose` on 100 entries.

## Why the two runs differ

- **Pool and Clone + Destroy are about 50% slower in this place** (30.7 vs 19.9 µs, and 51.9 vs 38.9 µs). Both cases create Instances and parent them into `workspace`, so their cost depends on the place and the engine, not just on Luau. Pool's lead over Clone + Destroy is similar in both places: 1.7× now, 1.95× before.
- **Luau-only cases agree within about 10–15%** between the two places (Cleanup functions, Network, Random, State), which is normal for runs on different days.
- **Constella.Signal `Fire` is faster because the code changed** (see [History](#history)). sleitnick/signal's `Fire` times didn't move (0.370 µs in both runs), so the improvement isn't noise from the new place.
- **Some cases had one or two slow runs.** RBXScriptConnection cleanup ranged from 122 to 165 µs for both libraries, and Cleanup functions from 16 to 20 µs. The median absorbs these; compare the best runs too before reading much into a single difference.
- **Sub-0.3 µs cases are noisy.** sleitnick/signal's `Connect`+`Disconnect` ranged from 0.18 to 0.24 µs across this run's 5 runs. Treat differences under about 20% in those rows as noise.

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
- **Tried and rejected: passing the connection to the runner.** Handing the runner thread `(connection, ...)` instead of `(onError, callback, ...)` saved one argument per listener and another 1–2% on `Fire`. But an idle runner then often kept the first `Fire` argument alive: in a stress test it stayed alive in 21 of 29 trials, against 0 of 29 with the layout kept here. The runner-retention unit test caught it, and it now repeats its scenario 5 times so intermittent retention like this fails reliably.
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
