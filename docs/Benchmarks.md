# Benchmarks

Measured results, including where Constella loses. Every pull request reruns them on a Roblox server (see [How to run](#how-to-run)), so the numbers below can be checked against a fresh run at any time.

## Setup

| | |
| --- | --- |
| Date | 2026-11-14 |
| Where | **A live Roblox game server**, through Open Cloud Luau execution, in the CI experience used for the test suite. Nothing else ran on it. Earlier runs (see [History](#history)) were in Studio Edit mode, which is slower in absolute terms, so compare rows within this run only. |
| Engine | Roblox 0.747.0.7471481 |
| Code | **This build:** Constella 0.3.0 (pull request #3). **Baseline:** `main` just before it (commit `4f55b06`: 0.2.0 plus the typing work listed in the changelog, which doesn't change any code path measured here). Both were loaded into the same server and measured in the same session. |
| Tests | 253 of 253 pass on a Roblox server for this build, including the live DataStore and cross-server tests. |
| Speed method | The whole suite ran **5 times**. In each run, every case runs once to warm up, then 5 timed trials with a yield between them; the run's result is the median of those trials. The two builds of each case run back to back, and every other run swaps which goes first. The table shows the **median across the 5 runs**, plus the best and worst run. |
| Memory method | Heap growth (`gcinfo`) while building objects, repeated many times. Garbage collection during a build can only make a sample *smaller*, so the 80th percentile is reported. Signal and Cleanup: 21 builds of 5,000 objects. Promises allocate more per object, so they use 61 builds of 500 (larger builds overlapped collection steps and gave samples that were far too small). |
| Leak method | Objects go into a weak-keyed table and are released while their owner stays alive. The check then waits up to 15 seconds (creating throwaway garbage to keep the collector running) until the garbage collector has freed them. |
| Compared with | [sleitnick/signal](https://github.com/Sleitnick/RbxUtil/tree/main/modules/signal) 2.0.3 (GoodSignal-style) and [sleitnick/trove](https://github.com/Sleitnick/RbxUtil/tree/main/modules/trove) 1.8.0, both from RbxUtil commit `31f9120fca02` (pinned by hash in CI), plus hand-written baselines for Random |

### Comparing like with like

Constella.Signal catches every listener's errors (`xpcall`, reported through `OnError`), so one failing listener can't break the others. sleitnick/signal doesn't catch them. To compare the same guarantee, the suite also runs sleitnick/signal with each listener wrapped in `xpcall`. That's the fair comparison.

For Random, `Random.choose` checks every entry on every call, so comparing it with a precomputed table mostly measures that validation. The two hand-written baselines skip validation entirely, so they compare the selection algorithm itself.

## Speed

Median µs per operation across 5 runs, with the best and worst run. "Change" compares this build with the baseline; differences under about 10% that fall inside both builds' run ranges are noise.

| Group | Case | Implementation | Median | Best run | Worst run | Change |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Signal | Connect + Disconnect | Constella.Signal | 0.180 | 0.163 | 0.198 | +6% (noise) |
| Signal | Connect + Disconnect | Constella.Signal, baseline | 0.170 | 0.156 | 0.188 | |
| Signal | Connect + Disconnect | sleitnick/signal + xpcall (same guarantee) | 0.124 | 0.118 | 0.131 | |
| Signal | Connect + Disconnect | sleitnick/signal (no error isolation) | 0.118 | 0.115 | 0.137 | |
| Signal | Fire, 1 listener | Constella.Signal | 0.246 | 0.244 | 0.250 | −4% (noise) |
| Signal | Fire, 1 listener | Constella.Signal, baseline | 0.255 | 0.251 | 0.267 | |
| Signal | Fire, 1 listener | sleitnick/signal + xpcall (same guarantee) | 0.246 | 0.237 | 0.252 | |
| Signal | Fire, 1 listener | sleitnick/signal (no error isolation) | 0.208 | 0.205 | 0.219 | |
| Signal | Fire, 10 listeners | Constella.Signal | 2.203 | 2.189 | 2.528 | same |
| Signal | Fire, 10 listeners | Constella.Signal, baseline | 2.209 | 2.205 | 2.410 | |
| Signal | Fire, 10 listeners | sleitnick/signal + xpcall (same guarantee) | 2.210 | 2.186 | 2.219 | |
| Signal | Fire, 10 listeners | sleitnick/signal (no error isolation) | 1.922 | 1.910 | 2.080 | |
| Signal | Fire, 100 listeners | Constella.Signal | 21.763 | 21.191 | 22.867 | same |
| Signal | Fire, 100 listeners | Constella.Signal, baseline | 21.880 | 21.547 | 22.459 | |
| Signal | Fire, 100 listeners | sleitnick/signal + xpcall (same guarantee) | 21.803 | 21.628 | 21.988 | |
| Signal | Fire, 100 listeners | sleitnick/signal (no error isolation) | 18.921 | 18.528 | 19.066 | |
| Signal | Fire, 1,000 listeners | Constella.Signal | 220.695 | 217.997 | 222.603 | same |
| Signal | Fire, 1,000 listeners | Constella.Signal, baseline | 218.362 | 216.043 | 226.684 | |
| Signal | Fire, 1,000 listeners | sleitnick/signal + xpcall (same guarantee) | 219.014 | 217.689 | 227.288 | |
| Signal | Fire, 1,000 listeners | sleitnick/signal (no error isolation) | 190.499 | 186.354 | 195.855 | |
| Cleanup | Add + Clean 100 functions | Constella.Cleanup | 14.375 | 13.925 | 14.485 | same |
| Cleanup | Add + Clean 100 functions | Constella.Cleanup, baseline | 14.197 | 14.046 | 14.422 | |
| Cleanup | Add + Clean 100 functions | sleitnick/trove | 86.630 | 83.638 | 90.737 | |
| Cleanup | Connect + Clean 100 RBXScriptConnections | Constella.Cleanup | 94.260 | 91.086 | 103.120 | same |
| Cleanup | Connect + Clean 100 RBXScriptConnections | Constella.Cleanup, baseline | 94.841 | 89.946 | 95.591 | |
| Cleanup | Connect + Clean 100 RBXScriptConnections | sleitnick/trove | 94.230 | 92.236 | 109.894 | |
| Pool | Spawn + despawn a Part | Constella.Pool | 4.568 | 4.279 | 4.614 | same |
| Pool | Spawn + despawn a Part | Constella.Pool, baseline | 4.639 | 4.541 | 6.194 | |
| Pool | Spawn + despawn a Part | Clone + Destroy (no pool) | 9.087 | 8.885 | 9.365 | |
| Network | Accept a valid request (all checks) | Constella.Network | **1.029** | 0.999 | 1.060 | **−15%** |
| Network | Accept a valid request (all checks) | Constella.Network, baseline | 1.207 | 1.155 | 1.223 | |
| Network | Reject a forged request | Constella.Network | **0.839** | 0.829 | 0.901 | **−13%** |
| Network | Reject a forged request | Constella.Network, baseline | 0.968 | 0.950 | 1.006 | |
| Random | Weighted roll, 100 entries | `Random.choose` (validates every call) | **3.560** | 3.532 | 3.592 | **4.3× faster** |
| Random | Weighted roll, 100 entries | `Random.choose`, baseline | 15.179 | 14.806 | 15.393 | |
| Random | Weighted roll, 100 entries | `lootTable:Roll` (precomputed, binary search) | 0.249 | 0.245 | 0.254 | same |
| Random | Weighted roll, 100 entries | `lootTable:Roll`, baseline | 0.250 | 0.247 | 0.255 | |
| Random | Weighted roll, 100 entries | Hand-written: sum, then linear scan (each call) | 1.143 | 1.059 | 1.594 | |
| Random | Weighted roll, 100 entries | Hand-written: precomputed totals, linear scan | 0.385 | 0.380 | 0.395 | |
| State | Set with 1 subscriber | Constella.State | **0.479** | 0.459 | 0.483 | **−20%** |
| State | Set with 1 subscriber | Constella.State, baseline | 0.600 | 0.579 | 0.605 | |
| State | Set a source of a computed with 1 subscriber | Constella.State | **1.023** | 0.999 | 1.041 | **−19%** |
| State | Set a source of a computed with 1 subscriber | Constella.State, baseline | 1.265 | 1.245 | 1.296 | |
| Promise | `resolve` + `Then` + `Await` | Constella.Promise | 1.690 | 1.586 | 2.161 | −11% (noisy) |
| Promise | `resolve` + `Then` + `Await` | Constella.Promise, baseline | 1.894 | 1.740 | 2.452 | |
| Promise | Chain 10 `Then`s, then resolve | Constella.Promise | 19.656 | 19.098 | 23.972 | same |
| Promise | Chain 10 `Then`s, then resolve | Constella.Promise, baseline | 19.657 | 18.426 | 21.591 | |

The three earlier CI runs of this pull request (before the run-order swap was added) agreed on every row marked as a change: Network −12 to −16%, `Random.choose` 4.3×, State −16 to −20%.

## Memory

| Per object | Constella | Baseline | Compared with |
| --- | ---: | ---: | ---: |
| Connected Signal listener | **160 bytes** | 160 bytes | 176 bytes (sleitnick/signal) |
| Function tracked by Cleanup | **53 bytes** | 53 bytes | 106 bytes (sleitnick/trove) |
| Resolved promise (`Promise.resolve`) | **416 bytes** | 608 bytes | |
| Pending promise from `Then` (the promise, its link to the parent, the parent's queue entry) | **549 bytes** | 645 bytes | |

The promise rows include the 16-byte array slot that keeps each promise. A resolved promise uses 32% less memory because the three bookkeeping lists every promise used to create up front are now created only when needed. `Promise.new` isn't listed: its executor thread is garbage as soon as it finishes, and heap growth would count it.

## Leaks

Each check releases 2,000 objects while their owner stays alive, then waits for the garbage collector. Two new checks (marked) cover references that the baseline kept:

| Check | Still alive afterwards | Baseline |
| --- | ---: | ---: |
| Signal: disconnected listeners (signal kept alive) | 0 of 2,000 | 0 |
| **Signal: listeners of disconnected connections that are still referenced** (new) | **0 of 2,000** | **2,000** |
| Cleanup: cleaned resources (manager kept alive) | 0 of 2,000 | 0 |
| State: unsubscribed callbacks (state kept alive) | 0 of 2,000 | 0 |
| Pool: objects destroyed past MaxIdle (pool kept alive) | 0 of 2,000 | 0 |
| **Promise: values of the promises a kept chain came from** (new) | **0 of 2,000** | **2,000** |

The unit tests include the same kind of checks (plus one for a player released during loading in Data), so a regression fails the test suite and not just this report.

## What the numbers say

- **Signal matches sleitnick/signal like for like on a Roblox server.** With the same guarantee (each listener wrapped in `xpcall`), `Fire` costs the same, within 1%, from 1 to 1,000 listeners: about 0.22 µs per listener. Without error isolation, sleitnick/signal is about 13% faster; that's the cost of catching errors, and Constella always pays it.
  - `Connect`+`Disconnect` is about 1.45× slower (0.18 vs 0.12 µs). That's the cost of guarantees sleitnick/signal doesn't make: checks for a destroyed signal and a non-function callback, listeners called in connection order, `O(1)` `Disconnect`, a connection count, snapshot `Fire`, and now releasing the listener on `Disconnect`. These are the noisiest rows in the report.
  - It uses **less memory** per connection (160 vs 176 bytes).
- **Cleanup is about 6× faster than Trove for functions, and uses half the memory.** For RBXScriptConnections they're the same, because the engine's own Disconnect dominates.
- **Pool is about 2× faster** than cloning and destroying a Part each time.
- **Network's full set of checks costs about 1 µs per request** on a server: rate limiting, payload measurement, schema validation and dispatch. 1,000 requests take about 1 ms of server time. Measuring the payload no longer allocates a closure per request, which saved 13–15%.
- **`Random.choose` is now 4.3× faster.** It used to build an error label for every entry on every call, even when nothing was wrong. It still validates every entry, so for anything rolled often `Random.lootTable` remains the one to use: `lootTable:Roll` is 14× faster than `choose`, 1.5× faster than a hand-written precomputed linear scan and 4.6× faster than summing and scanning on every call.
- **State `Set` is about 20% faster**, because it no longer allocates: notifications are queued in reused buffers instead of a new table per `Set` and two per flush.
- **Promise** speed barely changes; the gain is memory (above) and, more importantly, that a kept promise no longer keeps the values of the promises it came from alive.

## Studio and server numbers

The earlier runs in [History](#history) were in Studio Edit mode. The same code runs faster on a Roblox server: Signal `Fire` with one listener took 0.41 µs in Studio and 0.25 µs here, Network 2.0 µs and 1.0 µs. Ratios between implementations were similar in both. Only compare numbers from the same run.

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

### 0.3.0

Measured A/B on a Roblox server against `main` before the change (the tables above).

- **Random.choose** formatted an error label (`"entry #%d Weight"`) for every entry on every call and built two arrays plus the cumulative sums. It now validates with a plain check and formats only on failure, and without modifiers it scans running sums instead of allocating. 4.3× faster. A test checks that it picks exactly what `lootTable:Roll` picks for 3,000 rolls.
- **State** allocated a table per `Set` (the old value) and two per flush round. It now uses reused arrays: 16–20% faster.
- **Network** created a closure with six upvalues to measure every request's payload. The measuring function now passes its totals along instead: 12–16% faster per request.
- **Promise** created three empty lists per promise up front and kept them after settling. They're now created on demand and dropped on settle: 32% less memory per resolved promise, 15% per pending one, and a kept chain no longer keeps its ancestors' values.
- **Signal** `Disconnect` now clears the listener slot, so a kept connection no longer keeps its listener alive. A first version also cleared the signal and previous-node slots on every `Disconnect`; that cost 6–16% on `Connect`+`Disconnect` in two runs (before the run-order swap below) and rarely freed the signal (later connected nodes still reference it), so only `DisconnectAll` and `Destroy` clear those now. The cost that remains is within noise.
- **Method:** within each run, the build that went first was always the current one, and the first case after the allocation-heavy Promise cases ran slower. Every other run now swaps the order. Promise memory first used 5,000-object builds, which overlapped garbage collection steps and gave impossible numbers (59 bytes for a 4-table object); it now uses 500-object builds.

## How to run

**On a Roblox server (CI).** Every pull request runs the suite on a Roblox server through Open Cloud, comparing the pull request with its base commit in the same session, and adds the report to the job summary of the "Test suite on a Roblox server" job. It's informational and never fails the run. The scripts are [`.github/scripts/roblox_bench.py`](https://github.com/Layfate/Constella/blob/main/.github/scripts/roblox_bench.py) and the "Build the benchmark place" step in [`ci.yml`](https://github.com/Layfate/Constella/blob/main/.github/workflows/ci.yml).

**In Studio.**

1. Open the dev place (`rojo serve dev.project.json`).
2. Optionally, to compare with other libraries, add ModuleScripts named `Signal` (sleitnick/signal) and `Trove` (sleitnick/trove) to a Folder named `BenchmarkLibs` in `ServerStorage`. Missing libraries are skipped.
3. In the Studio command bar (Edit mode, nothing else running), run:

```lua
print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)({ Runs = 5 }))
```

To compare two builds of the package, put the second one next to the first (for example as `ReplicatedStorage.Packages.ConstellaBaseline`) and pass both:

```lua
local Packages = game.ReplicatedStorage.Packages
print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)({
	Runs = 5,
	Packages = {
		{ Name = "this build", Module = Packages.Constella },
		{ Name = "baseline", Module = Packages.ConstellaBaseline },
	},
}))
```

It takes about 30 seconds per build and prints Markdown tables like the ones above, including every run's result. The code is in [`benchmarks/`](https://github.com/Layfate/Constella/tree/main/benchmarks).
