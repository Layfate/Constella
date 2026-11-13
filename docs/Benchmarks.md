# Benchmarks

Measured results, including where Constella loses. These numbers come from one machine. Run the suite yourself before relying on them; see [How to run](#how-to-run).

## Setup

| | |
| --- | --- |
| Date | 2026-11-13 |
| Engine | Roblox Studio 0.747 (Edit mode, Windows) |
| Method | Each case runs once to warm up, then 7 timed trials with a yield between them. The table shows the **median** time per operation, plus the fastest and slowest trials. |
| Compared with | [sleitnick/signal](https://github.com/Sleitnick/RbxUtil/tree/main/modules/signal) 2.0.3 (GoodSignal-style) and [sleitnick/trove](https://github.com/Sleitnick/RbxUtil/tree/main/modules/trove) 1.8.0, both from RbxUtil commit `31f9120fca02` |

Results vary by about 10–30% between runs on the same machine. Treat small differences as a tie.

## Results

| Group | Case | Implementation | Median µs/op | Fastest | Slowest |
| --- | --- | --- | ---: | ---: | ---: |
| Signal | Connect + Disconnect | Constella.Signal | 0.403 | 0.324 | 0.478 |
| Signal | Connect + Disconnect | sleitnick/signal | 0.140 | 0.125 | 0.239 |
| Signal | Fire, 1 listener | Constella.Signal | 0.420 | 0.411 | 0.439 |
| Signal | Fire, 1 listener | sleitnick/signal | 0.319 | 0.314 | 0.591 |
| Signal | Fire, 10 listeners | Constella.Signal | 3.540 | 3.466 | 5.473 |
| Signal | Fire, 10 listeners | sleitnick/signal | 2.897 | 2.813 | 3.244 |
| Cleanup | Add + Clean 100 functions | Constella.Cleanup | 18.745 | 17.776 | 21.754 |
| Cleanup | Add + Clean 100 functions | sleitnick/trove | 143.028 | 133.850 | 180.908 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | Constella.Cleanup | 135.827 | 129.541 | 187.639 |
| Cleanup | Connect + Clean 100 RBXScriptConnections | sleitnick/trove | 190.119 | 130.058 | 223.879 |
| Pool | Spawn + despawn a Part | Clone + Destroy (no pool) | 37.754 | 36.307 | 42.163 |
| Pool | Spawn + despawn a Part | Constella.Pool | 19.790 | 19.301 | 21.301 |
| Network | Accept a valid request (all checks) | Constella.Network | 1.946 | 1.840 | 2.492 |
| Network | Reject a forged request | Constella.Network | 1.862 | 1.477 | 2.439 |
| Random | Weighted roll, 100 entries | `Random.choose` (validates every call) | 28.230 | 24.898 | 29.201 |
| Random | Weighted roll, 100 entries | `lootTable:Roll` (precomputed) | 0.259 | 0.254 | 0.310 |
| State | Set with 1 subscriber | Constella.State | 1.065 | 0.953 | 1.152 |

### Memory (approximate)

These figures are measured as Luau heap growth (`gcinfo`). Garbage collection can run at any moment, so they're rough.

| Case | Implementation | Heap growth |
| --- | --- | ---: |
| 10,000 connected listeners | Constella.Signal | about 2.1–3.0 MB (varies between runs) |
| 10,000 connected listeners | sleitnick/signal | about 1.7 MB |
| 10,000 tracked functions | Constella.Cleanup | about 0.5 MB |
| 10,000 tracked functions | sleitnick/trove | about 1.0 MB |

## What the numbers say

- **Signal is slightly slower than sleitnick/signal.**
  - `Fire` is about 20–30% slower and `Connect`+`Disconnect` about 2–3× slower.
  - Each connection uses more memory.
  - Constella pays this for per-listener error isolation and its documented guarantees: errors are caught and passed to `OnError`, listeners run in connection order, and a listener connected during a `Fire` waits until the next one.
  - Both libraries recycle listener threads.
- **Cleanup is faster than Trove and uses about half the memory** for plain functions. For RBXScriptConnections the two are roughly even, since the engine's own Disconnect cost dominates.
- **Pool roughly halves** the cost of spawning and despawning a Part compared with cloning and destroying one each time.
- **Network's full set of checks costs about 2 µs per request.** That covers rate limiting, payload measurement, schema validation and dispatch, so 1,000 requests take about 2 ms of server time.
- **Use `Random.lootTable`** for anything rolled often. It validates once and rolls in O(log n), about 100× faster than `Random.choose` on 100 entries.

## Performance work these benchmarks caused

The first benchmark run (same day) showed two clear weaknesses, which were then fixed:

| | Before | After |
| --- | ---: | ---: |
| Signal `Fire`, 1 listener | 1.470 µs | 0.420 µs |
| Signal `Fire`, 10 listeners | 13.616 µs | 3.540 µs |
| Cleanup memory, 10,000 functions | about 2.0 MB | about 0.5 MB |

- **Signal** used to create a new coroutine for every listener call and copy the listener list on every `Fire`. It now reuses runner threads and keeps listeners in a linked list, with an id cutoff that gives snapshot semantics without copying.
- **Cleanup** used to allocate a small table per resource. It now stores plain resources in two parallel arrays.
- All existing tests still pass for both modules.

## How to run

1. Open the dev place (`rojo serve dev.project.json`).
2. Optionally, to compare with other libraries, add ModuleScripts named `Signal` (sleitnick/signal) and `Trove` (sleitnick/trove) to a Folder named `BenchmarkLibs` in `ServerStorage`. Missing libraries are skipped.
3. In the Studio command bar (Edit mode), run:

```lua
print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)())
```

The output is a Markdown table like the one above. The code is in [`benchmarks/`](../benchmarks).
