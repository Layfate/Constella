# Benchmarks

Measured results, including where Constella loses. They come from one machine, so run the suite yourself before relying on them; see [How to run](#how-to-run).

## Setup

| | |
| --- | --- |
| Date | 2026-11-13 |
| Engine | Roblox Studio 0.747 (Edit mode, Windows) |
| Speed method | The whole suite ran **5 times**. In each run, a case runs once to warm up, then 5 timed trials with a yield between them; the run's result is the median of those trials. The table shows the **median across the 5 runs**, plus the best and worst run. |
| Memory method | Heap growth (`gcinfo`) while building 5,000 objects, repeated 21 times. Garbage collection during a build can only make a sample *smaller*, so the 80th percentile is reported; the upper samples are the uninterrupted ones. Repeated rounds gave identical results. |
| Leak method | Objects go into a weak-keyed table and are released while their owner stays alive. The check then waits (creating throwaway garbage to keep the collector running) until the garbage collector has freed them. |
| Compared with | [sleitnick/signal](https://github.com/Sleitnick/RbxUtil/tree/main/modules/signal) 2.0.3 (GoodSignal-style) and [sleitnick/trove](https://github.com/Sleitnick/RbxUtil/tree/main/modules/trove) 1.8.0, both from RbxUtil commit `31f9120fca02` |

### Comparing like with like

Constella.Signal catches every listener's errors (`xpcall`, reported through `OnError`), so one failing listener can't break the others. sleitnick/signal doesn't catch them. To compare the same guarantee, the suite also runs sleitnick/signal with each listener wrapped in `xpcall`. That's the fair comparison, and it's listed first below.

## Speed

| Group | Case | Implementation | Median µs/op | Best run | Worst run |
| --- | --- | --- | ---: | ---: | ---: |
| Signal | Connect + Disconnect | Constella.Signal | 0.307 | 0.293 | 0.444 |
| Signal | Connect + Disconnect | sleitnick/signal + xpcall (same guarantee) | 0.201 | 0.157 | 0.227 |
| Signal | Connect + Disconnect | sleitnick/signal (no error isolation) | 0.183 | 0.152 | 0.228 |
| Signal | Fire, 1 listener | Constella.Signal | 0.458 | 0.412 | 0.614 |
| Signal | Fire, 1 listener | sleitnick/signal + xpcall (same guarantee) | 0.370 | 0.360 | 0.374 |
| Signal | Fire, 1 listener | sleitnick/signal (no error isolation) | 0.324 | 0.319 | 0.327 |
| Signal | Fire, 10 listeners | Constella.Signal | 3.793 | 3.675 | 4.790 |
| Signal | Fire, 10 listeners | sleitnick/signal + xpcall (same guarantee) | 3.497 | 3.300 | 3.896 |
| Signal | Fire, 10 listeners | sleitnick/signal (no error isolation) | 2.885 | 2.853 | 2.986 |
| Cleanup | Add + Clean 100 functions | Constella.Cleanup | 19.215 | 16.283 | 19.930 |
| Cleanup | Add + Clean 100 functions | sleitnick/trove | 151.731 | 145.501 | 153.704 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | Constella.Cleanup | 144.129 | 132.348 | 162.849 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | sleitnick/trove | 145.321 | 131.264 | 200.733 |
| Pool | Spawn + despawn a Part | Constella.Pool | 19.932 | 19.351 | 21.828 |
| Pool | Spawn + despawn a Part | Clone + Destroy (no pool) | 38.895 | 37.557 | 40.742 |
| Network | Accept a valid request (all checks) | Constella.Network | 2.013 | 1.949 | 2.150 |
| Network | Reject a forged request | Constella.Network | 1.562 | 1.523 | 1.677 |
| Random | Weighted roll, 100 entries | `lootTable:Roll` (precomputed) | 0.261 | 0.257 | 0.276 |
| Random | Weighted roll, 100 entries | `Random.choose` (validates every call) | 26.535 | 24.431 | 28.692 |
| State | Set with 1 subscriber | Constella.State | 1.103 | 1.015 | 1.128 |

## Memory

| Per object | Constella | Compared with |
| --- | ---: | ---: |
| Connected Signal listener | **160 bytes** | 176 bytes (sleitnick/signal) |
| Function tracked by Cleanup | **53 bytes** | 106 bytes (sleitnick/trove) |

## Leaks

Each check releases 2,000 objects while their owner stays alive, then waits for the garbage collector.

| Check | Still alive afterwards |
| --- | ---: |
| Signal: disconnected listeners (signal kept alive) | 0 of 2,000 |
| Cleanup: cleaned resources (manager kept alive) | 0 of 2,000 |
| State: unsubscribed callbacks (state kept alive) | 0 of 2,000 |
| Pool: objects destroyed past MaxIdle (pool kept alive) | 0 of 2,000 |

The unit tests include the same kind of check, so a leak fails the test suite and not just this report.

## What the numbers say

- **Signal, like for like, is a little slower than sleitnick/signal.**
  - `Fire` is about 8–24% slower across runs, and `Connect`+`Disconnect` about 1.5× slower (0.31 vs 0.20 µs). That's a few tenths of a microsecond per call.
  - It uses **less memory** per connection (160 vs 176 bytes).
  - Without error isolation, sleitnick/signal is faster still. That's the cost of catching errors, and Constella always pays it.
- **Cleanup is about 8× faster than Trove for functions, and uses half the memory.** For RBXScriptConnections the two are even, because the engine's own Disconnect dominates.
- **Pool roughly halves** the cost of spawning a Part compared with cloning and destroying one each time.
- **Network's full set of checks costs about 2 µs per request.** That's rate limiting, payload measurement, schema validation and dispatch, so 1,000 requests take about 2 ms of server time.
- **Use `Random.lootTable`** for anything rolled often. It's about 100× faster than `Random.choose` on 100 entries.

## History

Reviews of earlier benchmark runs found real problems. They were fixed like this (all Signal versions measured with the same method, same session):

| Signal version | Memory per connection | Connect + Disconnect | Fire, 1 listener |
| --- | ---: | ---: | ---: |
| v0.1.0: array, new thread per listener call | 202 B | 0.279 µs | 1.583 µs |
| Interim: thread reuse, 7-field linked-list node | 304 B | 0.352 µs | 0.435 µs |
| **Now: thread reuse, compact node** | **160 B** | **0.296 µs** | **0.430 µs** |

- **v0.1.0 → interim.** Fire became 3.7× faster by reusing runner threads instead of creating a coroutine per listener call. But each connection became a 7-field table, which Luau stores in 8 hash slots, so memory grew by 50% and Connect got slower.
- **Interim → now.** Connection fields moved into the table's array part, leaving only the public `Connected` field in the hash part, and "connect once" became the sign of the order number. Memory fell to 21% below v0.1.0, Connect returned to v0.1.0's speed, and Fire stayed fast.
- **A retention bug fixed on the way.** Building the leak check exposed a bug in the thread-reuse pattern, which is also present in GoodSignal-style signals. A runner thread entered its loop with its first call's arguments and kept them on its stack for as long as it existed, so it held that listener and its `Fire` arguments alive. Runners now start by yielding. A unit test reproduces the bug: it fails on the interim version and passes now.
- **Cleanup** moved from a table per resource to two parallel arrays, giving about 4× less memory.

## How to run

1. Open the dev place (`rojo serve dev.project.json`).
2. Optionally, to compare with other libraries, add ModuleScripts named `Signal` (sleitnick/signal) and `Trove` (sleitnick/trove) to a Folder named `BenchmarkLibs` in `ServerStorage`. Missing libraries are skipped.
3. In the Studio command bar (Edit mode, nothing else running), run:

```lua
print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)({ Runs = 5 }))
```

It takes about 30 seconds and prints Markdown tables like the ones above. The code is in [`benchmarks/`](../benchmarks).
