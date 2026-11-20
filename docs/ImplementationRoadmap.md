# Implementation roadmap: 0.4 to 0.6

A plan for the next releases after v0.3.7, based on a review of every module in `src/shared/Constella`. It focuses on type safety, scalability, reliability and measured performance. The five headline features are:

1. typed Network contracts;
2. strongly typed Data accessors;
3. a shared Zone scheduler;
4. interest-based Replication;
5. optional diagnostics.

Each one is built from the existing 13 modules. None adds a module, a dependency or a runtime layer that the existing code already provides.

[Roadmap](Roadmap.md) records what shipped. This page is the plan, and each item moves there once it is released.

## Status

**0.4.0 ships Phases 0, 1 and 2.** Phase 0 was folded into 0.4.0 instead of a separate 0.3.8 release. Two Phase 0 items need multi-hour runs on a dedicated machine, so they moved to 0.5.0, where Phase 3 needs them first: the published soak result (0.4) and the characters-on load phase (0.4). Where the implementation differs from the plan below, the plan was updated, and the reason is here:

| Planned | Shipped | Why |
| --- | --- | --- |
| A minimal structural `Logger` type (anything with `Warn`) | `Logger` is exactly Debug's logger type, as Data's already was | Luau rejected the real `Debug.Logger` against the smaller type (it refuses the extra fields inside an optional), which would have broken every existing caller passing a logger |
| Contract phantom field `_types: ((T...) -> ())?` | `_types: (T...) -> ()`, required in the type and never set at runtime | Luau infers `T...` through a required field, not an optional one: with `?`, every contract type silently became `any`. The `tests/types/fail` cases caught it |
| `CheckWrites` on by default in Studio | Off by default; recommended as `CheckWrites = RunService:IsStudio()` | An on-by-default check would make existing Studio code raise where it didn't before |
| `Validate` runs on the prepared data | It runs without Constella's `_ConstellaVersion` key, which is added afterwards | Otherwise every `Check.record` validator, the obvious way to use it, rejects every profile |
| Typed `Migrations` | Unchanged (`(data: any) -> any`) | Narrower types risk breaking existing migrations for little gain; revisit with the new solver |
| Template and demo on contracts | Template on contracts; the `src/` demo stays on the plain API | The demo also shows that untyped code keeps working unchanged |
| Spikes: typed validators, typed client results | Not done; `Invoke` keeps returning `(boolean, ...any)` | No design found that types results without a per-call allocation; the limit is documented in Network.md |

## Ground rules

Every item below has to meet all of these. A change that can't is cut, not weakened.

| Rule | What it means in practice |
| --- | --- |
| **Backwards compatible** | Only additive API. Every existing call, default, error message prefix, gate order and event order stays the same. New behaviour is opt-in through a new method or option. Each phase re-runs the whole current suite unchanged as its compatibility test. |
| **Lazy loading** | Requiring the root loads nothing. Requiring a module loads only the dependencies listed in [Architecture](Architecture.md#module-dependencies). A new cross-module link is either a type-only import (`type X = typeof(require(...))`, never run) or an object the caller passes in (duck-typed). Phase 0 adds a test that enforces this for each module. |
| **Strict Luau** | `--!strict` everywhere. CI stays clean under luau-lsp 1.70.1 with Roblox definitions (the version pinned in `ci.yml`). Public types must work under the solver CI uses. Features that need the new solver (`keyof`, `index`, user type functions) wait until CI runs it (see [Decisions](#decisions-to-make)). |
| **Security unchanged** | Nothing a client sends reaches user code without the five gates in `Network/Server.luau:9-15`, in that order. The server never calls `InvokeClient`. Replication stays server-to-client only, and a value is never sent to, or included in a snapshot for, a player who may not see it. Server-only modules still refuse to run on a client. Every security property gets a hostile-client test with real Studio clients. |
| **No new dependencies or abstractions** | No new packages and no new top-level modules. A new type or method must replace hand-written code that users write today, or it doesn't ship. |
| **Measured, not assumed** | Every optimization has a benchmark case. It is accepted only with an A/B result showing a 95% CI that excludes ±3% in its favour and no other case regressing past the CI gate (>10% slower with the CI above +5%). Results go in CHANGELOG with the CI. A change that misses the bar is reverted and listed with its numbers in a new "Rejected after measurement" section of [Benchmarks](Benchmarks.md), so it isn't tried again blind. Features that aren't optimizations must also prove **no regression** on existing cases. |
| **Every change ships with** | (1) regression tests in `tests/server/*.spec.luau`; (2) a leak test for anything that holds players, instances, threads or callbacks; (3) a benchmark case in `benchmarks/RunBenchmarks.luau`; (4) a real-client phase in `tests/load/` when the change affects traffic or per-frame cost; (5) updates to the module page, Architecture, README limitations, CHANGELOG and Roadmap. |

## What the review found

These are the starting points for each phase, with the code they come from.

### Type safety

- **Network is untyped end to end.** Handlers are `(player: Player, ...any)`, `Fire` takes `...any`, and client `Invoke` returns `(boolean, ...any)` (`Network/Server.luau:82-96`, `Network/Client.luau:31-46`). The template keeps endpoint names in a shared table (`template/src/shared/Net.luau`), but nothing links a name to its argument types, so the server handler, the client call and the Schema can drift apart unnoticed.
- **`Validator` is `(any) -> (boolean, string?)`** (`Network/Check.luau:14`). A Schema carries no type information, so types can't be inferred from validators. Contracts have to declare the type and the Schema separately (see Phase 1).
- **Data keys are untyped.** `profile.Data: T` is typed, but `Get`, `Set` and `Update` take any string key and any value (`Data/Store.luau:97-99`). The current Roadmap's "Next" list already notes this.
- **Data backend types are `any`.** `Adapter.Open` returns `any` (`Data/Store.luau:44-46`), `ProfileStoreAdapter.new` returns `any` (`Data/ProfileStoreAdapter.luau:189`), and the session contract (`StartSession`, `Data`, `Save`, `End`, `IsActive`, `OnSessionEnd`) exists only in prose in `docs/Data.md:160`.
- **`Logger: any?`** in `Network/Server.luau:71` and `Replication.luau:54`. Data already types its logger with a type-only import (`Data/Store.luau:40`); the other two should do the same.
- **Zone items are `any`:** `Entered: Signal<any>` (`Zone.luau:49-50`). **Replication** takes `state: any` and returns `Computed<any>` (`Replication.luau:72-82`). **`Cleanup:Connect`** passes `(...any)` to its callback (`Cleanup.luau:33`).

### Scalability

- **Every Zone has its own Heartbeat connection** (`Zone.luau:370-379`) and reads every tracked item's position itself. With Z zones and P players, a step makes Z×P position reads, and each read for a player calls `FindFirstChild("HumanoidRootPart")` (`Zone.luau:75`). Nothing is shared between zones that track the same players.
- **`Zone:Untrack` is O(n)** (`table.find` + `table.remove`, `Zone.luau:194-196`), so untracking everything is O(n²).
- **Zone intervals drift:** `elapsed = 0` instead of `elapsed -= interval` (`Zone.luau:375`), so the real period is `Interval` plus up to one frame.
- **Replication audiences are all-or-one.** A share is public (everyone) or private (one player) (`Replication.luau:247-252`). A value for a team, a round or the players near something has to be sent to everyone or shared once per player.
- **Public shares serialize once per player.** `_audience` allocates `Players:GetPlayers()` and `FireList` calls `FireClient` per player (`Replication.luau:247-252`, `Network/Server.luau:391-397`), where `FireAllClients` would make one call. This is an optimization candidate, not a conclusion (see [Candidates](#optimization-candidates)).
- **Snapshots deep-copy every value** (`Replication.luau:426,431`), although the copies the server keeps are never mutated after they are made.

### Reliability

- **`Network.Client:Event(name)` keeps every event object it ever returned** (`Network/Client.luau:198-199`), and `ClientEvent:Destroy` doesn't remove itself from the list. Calling `Event` in a loop (for example once per respawn) grows that list without bound.
- **`RateLimiter:GetTokens(key)` creates a bucket for an unknown key** (`Network/RateLimiter.luau:58-60`). It's harmless through Network, which only calls `Consume` for admitted players, but standalone users who query arbitrary keys leak buckets.
- **`profile:Set` accepts values DataStores can't store** (Instances, functions, mixed tables, NaN keys). The error only appears when ProfileStore saves, away from the code that caused it.
- **Loaded data is never checked against the template's types.** Only the version and table shape are checked (`Data/Store.luau:232-284`), so a corrupt field (a string where the template has a number) reaches game code.
- **Docs are out of date.** Architecture principle 2 says module-level state is limited to State's batch queue and Random's RNG, but Signal and Promise keep runner pools (`Signal.luau:106-108`, `Promise.luau:170-172`), and Signal keeps a connection counter. Principle 3 says "each module is one file", but Network and Data are folders.

### Diagnostics

- Network and Data already have `GetStats()`. Debug already has `Logger` and `Metrics`. **Replication and Zone report nothing.** No module records timings or bytes into `Debug.Metrics`, so a game can't see from its own telemetry what Constella costs it.

## Phase 0: foundations (shipped in 0.4.0, except 0.4)

Infrastructure that every later phase uses, plus the small fixes found in the review. There is no new feature API in this phase.

### 0.1 Type tests that can fail

`Types.spec.luau` shows that correct code type-checks. Nothing shows that **wrong** code fails to. Add `tests/types/`:

- `tests/types/pass/*.luau`: must analyze clean.
- `tests/types/fail/*.luau`: each file contains one deliberate misuse plus a `-- expect: <substring of the luau-lsp error>` header.
- `.github/scripts/check_types.py` runs `luau-lsp analyze` on each `fail` file separately. It fails if a file analyzes clean or if the expected message is missing. It runs in the existing `checks` job.

Every typed API in Phases 1–4 adds at least one `fail` case, for example a wrong argument type to a contract `Fire`, or a misspelt key to `profile:Mutate`. Exclude `tests/types/fail` from the normal analyze step.

### 0.2 Lazy-loading graph test

Extend `Types.spec`'s "requiring the root loads no submodule" test into a per-module dependency check. For each module, clone the package keeping only that module and its documented dependencies, then require it. A require of anything else fails the test. The test encodes the dependency table from Architecture.md, so the doc and the code can't drift apart. Every phase below must keep it green, for example "Replication doesn't load Zone", "Data doesn't load Network" and "Zone doesn't load Debug".

### 0.3 Leak and benchmark helpers

- Promote `t.collected(weak, timeout)` (TestKit) as the one leak primitive and add `t.leakCheck(build, release)`, matching `Bench.leakCheck`, so specs stop re-implementing it (`Cleanup.spec`, `Signal.spec` and `Promise.spec` each have their own copy).
- Add a **player-churn helper** for specs: stand-in players that join, act and leave, with the departed player put in a weak table. Network, Replication, Data and Zone leak tests all need "a player left; nothing still holds them".
- Benchmarks: add a `Scale` group whose cases take a size parameter (zones × players, members × shares), so cost curves can be reported instead of one point.

### 0.4 Baselines before anything changes

- Run and publish the **multi-hour soak with its control run** (already in Roadmap "Next"). Later phases compare heap and frame-time drift against it.
- Add a Studio load phase with **characters on and server-scripted movement** (the current phases run with characters off, `docs/Benchmarks.md#real-clients`). Zone and interest Replication can't be measured realistically without moving characters.

### 0.5 Fixes from the review

| Fix | Compatibility | Tests |
| --- | --- | --- |
| Type `Logger` in Network.Server and Replication options with Data's type-only import | Type-level only; `any` callers keep working | `fail` case: passing a non-logger |
| Export `DataBackend`, `DataSession` types; type `Adapter.Open`, `ProfileStoreAdapter.new`, `MemoryAdapter.new` | Type-level only | `pass` case: a custom adapter implementing the types; `fail` case: a session missing `End` |
| `Cleanup:Connect` generic over `RBXScriptSignal<T...>` and `Signal<T...>` | Type-level only | `pass` / `fail` cases |
| `ClientEvent:Destroy` removes itself from the client's list | Same behaviour; the list no longer grows | Leak test: 2,000 `Event` + `Destroy` calls leave the list empty and the objects collectable |
| `RateLimiter:GetTokens` returns capacity for unknown keys without storing a bucket | Same return value | Regression test: `GetTokens` on 1,000 new keys stores nothing |
| Correct Architecture principles 2 and 3 | Docs only | — |

## Phase 1: typed Network contracts (shipped in 0.4.0)

### Design

A contract is a shared, frozen description of one namespace's endpoints: names, direction and the argument Schema. Its Luau type carries the argument and result types. **The endpoint objects it produces at runtime are the same `ServerEvent` / `ServerFunction` / `ClientEvent` / `ClientFunction` objects that exist today, cast to a typed interface.** Contracts therefore add no runtime cost per request: the gates, remotes and folders are unchanged.

```lua
-- ReplicatedStorage/Shared/ShopContract.luau
local Constella = require(Packages.Constella)
local Check = Constella.Network.Check
local Contract = Constella.Network.Contract -- a new part, loaded on first access like Server/Client

return Contract.define({
	Namespace = "Shop",
	-- client -> server, validated by Schema; returns (result, balance)
	Purchase = Contract.fn({ Check.literal("Sword", "Shield") })
		:: Constella.ContractFunction<(string), (string, number)>,
	-- server -> client only (no Schema)
	CoinsChanged = Contract.event() :: Constella.ContractEvent<(number)>,
})
```

```lua
-- server
local shop = Network.Server.new(ShopContract.Namespace)
local purchase = shop:FunctionOf(ShopContract.Purchase, { RateLimit = { Count = 2, Per = 1 }, Authorize = ... })
purchase:SetHandler(function(player, itemId) -- itemId: string
	return "Purchased", 90 -- checked against (string, number)
end)
shop:EventOf(ShopContract.CoinsChanged):Fire(player, 90) -- Fire(player, "90") is a type error

-- client
local shop = Network.Client.new(ShopContract.Namespace)
local ok, result, balance = shop:FunctionOf(ShopContract.Purchase):Invoke("Sword") -- Invoke(5) is a type error
```

Types (a phantom signature on a field that is never set at runtime; it must be declared required, see [Status](#status)):

```lua
export type Event<T...> = { Name: string, Schema: { Validator }?, _types: (T...) -> () }
export type Function<A..., R...> = { Name: string, Schema: { Validator }, _types: (A...) -> R... }
export type TypedServerEvent<T...> = {
	Connect: (self: TypedServerEvent<T...>, handler: (player: Player, T...) -> ()) -> Signal.Connection,
	Fire: (self: TypedServerEvent<T...>, player: Player, T...) -> (),
	FireAll: (self: TypedServerEvent<T...>, T...) -> (),
	-- FireList, FireExcept, Destroy as today
}
```

Rules:

- `Server:EventOf` / `FunctionOf` and `Client:EventOf` / `FunctionOf` are **new methods**. `Event(name, config)` and `Function(name, config)` are unchanged.
- The Schema comes from the contract. Passing `Schema` in the server config as well is an error, because two Schemas could disagree. `RateLimit`, `MaxPayloadBytes`, `Authorize` and `Unreliable` stay in the **server's** config and never go in the shared contract.
- `Contract.define` checks names with the same pattern as `checkName`, refuses duplicates and freezes the result.
- `Contract.fn` without a Schema is an error, as `Server:Function` is today.

**Security note.** A Schema in a shared contract replicates to clients, so exploiters can read the validation rules. Validation rules aren't secrets, and the gates never relied on hiding them. Still, **any check that depends on server-only knowledge (ownership, prices, cooldowns) belongs in `Authorize` or the handler, never in a contract `Check.refine`**. Add this rule to Network.md and GameLayout.md, and change the template's "only names live here" comment to explain it.

**Known limit.** Luau can't tell whether the Schema actually matches the declared types: `Contract.fn({ Check.number() }) :: Constella.ContractFunction<(string), ()>` type-checks. Contracts stop the server, the client and the declaration from drifting apart, but **not** the declaration and its validators. A spike (below) checks whether typed validators can close this gap without a runtime wrapper. If they can't, the limit is documented.

### Steps

1. **Spike (time-boxed):** prove the phantom-type pattern under luau-lsp 1.70.1. Check inference of `T...` through `EventOf`, multiple-return `R...`, zero-argument events and hover output quality. Exit criterion: the `pass` / `fail` type tests from 0.1 behave. If generic packs don't infer through the method, fall back to `Contract.serverEvent(contract)` helper functions with the same types.
2. `Network/Contract.luau` (new **part** of Network, lazily loaded like `Check`; not a new module).
3. `EventOf` / `FunctionOf` on Server and Client. Both delegate to the existing `createEndpoint` / `waitFor` and return the same object.
4. Template and demo migrate to contracts (`template/src/shared/Net.luau` becomes the contract).
5. **Spike: typed validators.** Can `Check.string(): Validator<string>` carry its type into `Contract.fn` without changing what a `Validator` is at runtime? It must still be a plain function, because `validateConfig` checks `type(validator) == "function"` and users write their own. Accept only if a `fail` test catches a Schema/type mismatch and no runtime wrapper is added.
6. **Spike: typed client results.** `Invoke` returns `(true, R...)` or `(false, code)`, which Luau can't express as one type. Options: keep `(boolean, ...any)` on `Invoke` (default), or add a typed `InvokeOrNil` returning `R...` and the code separately. Decide by type-test ergonomics. Any option that allocates per call is rejected.

### Tests

- **Regression:** the whole Network suite unchanged. A contract endpoint goes through all five gates in order: re-run the hostile cases from `Network.spec` through `FunctionOf`/`EventOf`. Schema-in-both-places errors. Duplicate names error. A contract event without a Schema rejects client fires (`NotAccepted`).
- **Type:** `fail` cases for a wrong `Fire` argument type, wrong handler parameter type, wrong `Invoke` argument count and wrong return type.
- **Leak:** creating and destroying 500 contract endpoints leaves nothing referenced (the existing `_endpoints` / `_stats` cleanup applies).
- **Real clients:** `tests/client/NetworkIntegration` gets a contract-based endpoint in its hostile client, with the same accepted/rejected counts.

### Benchmarks

- `Network: Accept a valid request` and `Reject a forged request` through a contract endpoint against a plain endpoint. **Required result: no difference** (CI includes 0). If any overhead appears, the design is wrong and the endpoint isn't really the same object.
- Real clients: the `Requests` phase run through a contract with bytes per request unchanged (37 bytes today).

## Phase 2: strongly typed Data accessors (shipped in 0.4.0)

### Design

`profile.Data: T` is already typed. What's missing is a **write path checked against `T`** that still fires `Changed`. Under the current solver, a method can't map a string key to the type of that field (`keyof` / `index` need the new solver), so the typed path goes through `T` itself:

```lua
profile:Mutate(function(data) -- data: PlayerData
	data.Coins += price        -- type-checked
	data.Owned[itemId] = true  -- type-checked
end)
```

Semantics:

- `Mutate` takes a shallow copy of the top-level keys (one `table.clone`), calls `fn(self.Data)` and then fires `Changed(key, new, old)` for every top-level key whose value changed.
- For a **table-valued key that still holds the same table**, `Changed` fires with the same table as new and old. That is exactly what `Update` already does for in-place edits (`Data/Store.luau:172-189`), so listeners never miss a nested edit. The cost is one `Changed` per table-valued key. Option `{ Keys = { "Owned" } }` limits which keys are considered.
- `Mutate` runs `checkActive` before and after the call, like `Update` (`Data/Store.luau:181-183`): if the session was lost while the callback yielded, it raises and fires nothing. Detecting a yield inside the callback would cost a coroutine per call, so it isn't done. Callbacks shouldn't yield, and the docs say so, as `State.batch` does.
- `Get`, `Set` and `Update` are unchanged.

Alongside it, reusing existing modules:

- **`Validate: Check.Validator?`** in the Store config. The caller passes a `Network.Check` validator (for example `Check.record{...}`), and it runs on the prepared copy in `_prepare`. A failure is `CorruptData` and follows the existing **never-overwrite** path: the session ends unchanged and the player is kicked. Data does **not** require Check; the caller passes the function, so lazy loading is unchanged.
- **`CheckWrites: boolean?`** (off by default; see [Status](#status)). `Set` / `Update` / `Mutate` check that the new value is DataStore-storable: no Instances, functions, threads or metatables, no mixed or sparse tables, no non-string/non-integer keys, no NaN and valid UTF-8. The walker lives in `Data/Util` with DataStore rules. It doesn't reuse `Payload` because the rules differ (remotes carry Vector3 and Instances, DataStores don't), and loading Network from Data would break the dependency graph.
- **Typed `Migrations`:** `{ [number]: (data: { [string]: any }) -> { [string]: any }? }`.

The new-solver path (`Get: <K>(self, key: K) -> index<T, K>`) is a later, separate decision (see [Decisions](#decisions-to-make)).

### Tests

- **Regression:** `Mutate` fires `Changed` once per changed key, in key-iteration order. A same-value assignment fires nothing for primitives. It errors on an inactive profile, and also when the session is lost while the callback yields (simulated through MemoryAdapter), in which case it fires no `Changed`. `Validate` failure → `CorruptData`, the stored data is byte-identical afterwards (MemoryAdapter record check), and the player is kicked. `CheckWrites` rejects each forbidden kind with a message naming the key path.
- **ProfileStore:** `Mutate` and `Validate` in `ProfileStore.spec` (mock mode) and in the live CI DataStore scenarios.
- **Type:** `fail` cases for a misspelt field in `Mutate`, a wrong value type, and a `Validate` that isn't a validator.
- **Leak:** a released profile and its `Changed` listeners are collectable after 500 `Mutate` calls. `Mutate` keeps no reference to its snapshot.

### Benchmarks

- New cases: `Data: Set one key`, `Update one key`, `Mutate one key` and `Mutate one key (Keys option)` on a 20-key profile, plus `Set with CheckWrites` on a 40-entry table. **Accept** `Mutate` only if it is within 2× of `Set` for one key. Otherwise ship it with the `Keys` option as the documented fast path, with the numbers on the Data page.
- `Load + release a profile` with and without `Validate`, to report what validation costs per load.

## Phase 3: shared Zone scheduler (0.5.0)

### Design

A **scheduler is a value the game creates**, not hidden module state (Architecture principle 2):

```lua
local scheduler = Zone.Scheduler.new({ Budget = 0.5 }) -- ms per frame for all its zones
local shop = Zone.new(shopPart, { Scheduler = scheduler, Interval = 0.1 })
local arena = Zone.new(arenaPart, { Scheduler = scheduler, Interval = 0.25 })
```

- Without `Scheduler`, a zone behaves exactly as today: its own Heartbeat, the same interval behaviour and the same event order.
- **One Heartbeat connection** per scheduler. Zones are stepped in round-robin order of due time. Each zone keeps its own `Interval`, with drift-free timing (`due += interval`, re-based if it falls behind by more than one interval).
- **Budget:** once `Budget` ms are spent in a frame, the remaining due zones wait for the next frame, oldest first. A zone is never skipped twice in a row. Missed steps are counted (diagnostics) and never run in a burst.
- **Per-frame position cache:** within one scheduler frame, an item tracked by several zones is read once, **only for built-in getters** (Player, BasePart, Model, Attachment). Custom getters may be stateful and are always called. The cache is cleared at the end of the frame, so it holds no references between frames.
- **Player root caching:** the built-in Player getter caches the `HumanoidRootPart` per character and drops it on `CharacterRemoving` / `AncestryChanged`, instead of calling `FindFirstChild` every step. This must be measured first (it adds connections per player). See the acceptance criteria.
- Events still fire **after each zone's evaluation, per zone**. Today zones step in Heartbeat connection order and fire as they go, and the scheduler keeps that model.
- `Zone.Scheduler` lives in `Zone.luau` (`Zone.Scheduler.new`), not a new module or file.

Also in this phase:

- `Zone<T = any>` generic type: `Entered: Signal<T>`, `Track: (self, item: T, ...)`. Type-level only.
- **O(1) `Untrack`** using an index map and tombstones, compacted after each step. Tracking order, and therefore event order, stays the same.

**Spatial index: only if the numbers ask for it.** A uniform grid that lets each item test only nearby zones is the "possible future addition" in Zone.md. It is a stage-2 item and ships only if the stage-1 scheduler still spends more than 1 ms per frame on the 50 players × 500 zones case **and** the grid cuts that by at least 30% without regressing the 8 players × 10 zones case. Moving (part-based) zones would need re-binning, which is the main cost to measure.

### Tests

- **Regression:** the whole `Zone.spec` passes with every zone placed in a scheduler. Add tests for budget deferral order and no double skips, drift-free intervals (simulated clock), a zone destroyed mid-frame, a zone added during another zone's handler, and a scheduler destroyed while zones remain (they stop, without error). The cache serves built-in getters only: a custom getter called once per zone per step is asserted.
- **Order:** for items tracked in two zones of one scheduler, the Entered/Exited sequence matches the same zones without a scheduler.
- **Leak:** untracked items, destroyed zones, departed players and destroyed characters are collectable while the scheduler stays alive. The position cache is empty after each frame.

### Benchmarks

- `Zone: frame cost, Z zones × P players` for (10×8), (50×50) and (500×50), with per-zone Heartbeat against one scheduler. The scheduler is stepped directly so the cost is measured without frame noise.
- `Zone: Untrack all, 1,000 items` against the current O(n) path.
- Real clients: the characters-on phase from 0.4 with 50 zones, reporting server Heartbeat time (`Stats.HeartbeatTimeMs`, as `LoadServer` already does) and Entered/Exited counts matching the server's own ground truth.
- **Accept** the scheduler as recommended (in docs) only if (50×50) improves past the CI bar and (10×8) shows no regression. Accept root caching only if it improves the Player-getter case past the bar.

## Phase 4: interest-based Replication (0.6.0)

### Design

A **group share** has a member set that the game changes:

```lua
local share = replicator:ShareWithPlayers("ArenaScore", arenaScore, {}) -- start empty
arena.Entered:Connect(function(player) share:Add(player) end)
arena.Exited:Connect(function(player) share:Remove(player) end)
```

- New method `ShareWithPlayers(name, state, players?)` returns a `GroupShare` (`Share` plus `Add`, `Remove`, `Has` and `GetMembers`). `Share` and `ShareWith` are unchanged.
- **Zone integration is two lines of user code.** Replication does not require Zone, so lazy loading is preserved and Zone is optional.
- **A non-member never receives the value**, in updates or in snapshots (`_snapshotFor` filters by membership). This rule is the same as for private shares and is tested the same way.
- **Add** sends the current value to that player only. **Remove** sends that player a removal, so their replica becomes `nil`. Departed players are removed on `PlayerRemoving`, and a player who has already left is refused (the same rule as `ShareWith`, `Replication.luau:339-345`).
- Name kinds: `public`, `private` and `group` can't share a name (same rule as today).

**The hard part: versions on re-entry.** A client drops anything at or below the version it has (`Replication.luau:668`). If a player leaves and re-enters an audience, the server must not resend a version the client already saw as a removal, and Delta patches must not be sent to a member whose base differs. The design:

1. Every `Add` takes a fresh version from the replicator's clock and sends the full value to that member only.
2. The server keeps `memberVersion[player]` per group share.
3. On a change, members whose `memberVersion` equals the share's base get the patch (one `FireList`). Members at a different version get the full value. Both groups move to the new version.
4. The client protocol stays as it is: a removal is the existing `removed = true` message, and every re-add arrives with a higher version.

This has to be proven by tests before any optimization work starts on it.

Also in this phase:

- **Typed replication keys**, reusing Phase 1's phantom pattern: `Replication.key() :: Replication.Key<number>` in a shared contract, `replicator:ShareKey(key, state: State.Value<number>)`, and `replica:GetKey(key): Computed<number?>`. Type-level only, sitting on top of `Share` / `Get`.
- **Optional coalescing:** `Coalesce = true` on the server options sends each changed share at most once per frame (on Heartbeat), with the last value. It is off by default because it adds up to one frame of latency. Coalescing reuses the dirty-set idea from `State.batch` but doesn't change State.

### Tests

- **Security (unit and real clients):** a non-member's replica stays `nil` throughout, and their snapshot fetch doesn't contain the name. With 4 real clients, observers who are never members receive zero updates for the name (checked in the client's own log), and the server's share bytes match only members' traffic.
- **Versions:** add → remove → add within one frame. Re-entry while a Delta patch is in flight. Re-entry when the initial snapshot arrives after a live update (the existing stale-snapshot case in `studio_tests.ps1`, repeated for group shares). Fifty random add/remove/change sequences per run with a fixed seed, checking that every member's replica equals the server value and every non-member's is `nil`.
- **Leak:** departed members, removed members, stopped group shares and destroyed replicators keep no player, state or value alive (player-churn helper from 0.3).
- **Coalescing:** k changes in one frame produce one send with the last value. Ordering across shares within a frame is preserved. Destroying the replicator with dirty shares sends nothing afterwards.

### Benchmarks

- `Replication: change a group share with M members` for M = 1, 8 and 50, against M private shares of the same value (today's workaround) and against one public share.
- Real clients: an `Interest` phase where 8 clients move between 4 zones, measuring per-client bytes (engine `DataSendKbps`) for members and non-members and the server tick time. **Expected and required:** non-members' bytes for the share equal the idle baseline.
- Coalescing: k = 1, 2 and 10 changes per frame, bytes and server time. Accept the default-off option regardless (it is a behaviour choice), but publish the numbers.

## Phase 5: optional diagnostics (0.5.0, built alongside Phase 3)

### Design

No new module: diagnostics go through **`Debug.Metrics`**, which already exists and becomes a no-op when disabled.

- New option `Metrics: Debug.Metrics?` on `Network.Server`, `Replication.Server`, `Data.Store` and `Zone.Scheduler`. It is typed with a type-only import, so passing nothing loads nothing.
- When `Metrics` is nil, the cost is **one nil check** on the paths that record. Phase gate: an A/B on every existing case with `Metrics` absent must show **no regression** (CI includes 0).
- What gets recorded (counter names are documented on the Debug page):
  - Network: accepted, rejected by reason, and in-flight peak per endpoint.
  - Replication: sends, full sends against patches, estimated bytes (sizes are already computed in `_publish`), resync fetches and held patches.
  - Data: load time, save time, failures by `Kind` and session losses.
  - Zone scheduler: step time, zones stepped, zones deferred and cache hits.
- `debug.profilebegin` labels (MicroProfiler) are added only when `Metrics` is set and enabled.
- **`Replication.Server:GetStats()`** and **`ReplicationClient:GetStats()`** (counters always kept, cheap integers), matching Network's and Data's `GetStats`.
- A Studio-only **`Mutate` audit** (Data, opt-in): deep-compares nested tables after `Mutate` and warns when an edit wasn't covered by `Keys`. It exists to catch misuse of the fast path, and is never on in live games.

### Tests

- Every counter is checked against a known workload, for example 10 accepted and 3 rejected requests give exactly those counts.
- With `Metrics` disabled through `SetEnabled(false)`, nothing is recorded and the hot paths take the no-op branch.
- Leak: a destroyed Server, Store or Scheduler leaves no reference in the `Metrics` object apart from its counters (strings and numbers).

### Benchmarks

- Every existing case with `Metrics` absent (must not regress), and the main cases with `Metrics` enabled (cost published on the Debug page so games can decide).

## Optimization candidates

Each of these is a hypothesis. It ships only if its benchmark clears the bar in [Ground rules](#ground-rules), and otherwise goes in the rejected list with its numbers.

| Candidate | Where | Benchmark that decides | Risk to check |
| --- | --- | --- | --- |
| `FireAllClients` for public shares instead of `FireList(GetPlayers())` | `Replication.luau:247-252,272-274` | Real clients, 8: server time per tick and bytes per client | Must reach exactly the same players; a player in `Players` before their client is ready must behave the same (integration test) |
| Skip snapshot `deepCopy` (kept copies are never mutated) | `Replication.luau:423-435` | `Replication: snapshot of 20 shares` and the `Fetch` round trip | Prove the invariant first: a test freezes every kept copy and runs the whole Replication suite |
| `Check.cframe` without the component table | `Network/Check.luau:247` | New case `Check.cframe` on valid input | None beyond equal results on NaN/inf fuzz |
| `Check.arguments` without O(n²) `select` | `Network/Check.luau:282-293` | `Accept a valid request` with 3 and 8 arguments | Probably within noise for 3; keep only if 8 improves past the bar |
| Avoid per-publish `_audience` table for private shares | `Replication.luau:247-252` | `Publish one change` (private) | — |
| Zone root caching, position cache | Phase 3 | Phase 3 cases | Connection count per player |

## Not planned

Considered and left out to avoid abstraction or overhead:

- **A middleware or plugin layer for Network.** The five gates and `Authorize` cover the same ground without a per-request call chain.
- **A global default Zone scheduler.** That would be hidden state. Users opt in with a value.
- **Client-side pre-validation of contract Schemas.** It saves bandwidth only for buggy clients, adds client CPU, and an exploit client skips it anyway.
- **A Diagnostics module.** `Debug.Metrics` already does this.
- **Requiring the new type solver now.** It would break users on the current one.
- **Bidirectional Replication.** Clients send requests through Network, where the gates apply.

## Release plan

| Version | Contents | Done when |
| --- | --- | --- |
| **0.4.0** (released) | Phase 0 (type tests, lazy-graph test, leak/bench helpers, review fixes) + Phase 1 (contracts) + Phase 2 (`Mutate`, `Validate`, `CheckWrites`, typed backends) | CI green including the `fail` type tests; no regression on any existing case; template migrated; hostile-client test passes through contracts |
| **0.5.0** | Phase 0 leftovers (soak result, characters-on load phase) + Phase 3 (Zone scheduler, generic `Zone<T>`, O(1) `Untrack`) + Phase 5 (Metrics option, Replication `GetStats`) | Soak result in Benchmarks.md; scheduler scale curve published; `Metrics`-absent A/B shows no regression |
| **0.6.0** | Phase 4 (group shares, typed keys, coalescing) | Randomized version test and real-client interest phase pass; non-member bytes equal idle |
| **Toward 1.0** | API freeze (unchanged from [Roadmap](Roadmap.md#toward-10)) | — |

Each release updates the version everywhere CONTRIBUTING's release steps list it, the public type count in `Types.spec` and the Roadmap, and the "Known limitations" list in `docs/README.md` (the Zone line goes away with Phase 3).

## Decisions to make

1. **Shared Schemas.** Contracts put argument validators in ReplicatedStorage (readable by clients). The alternative, names and types shared with Schemas server-only, keeps today's template rule but lets the Schema and the declared type drift apart. Recommended: shared Schemas, with the `Authorize` rule documented.
2. **New type solver.** When luau-lsp's new solver is stable in CI and default in Studio, add `profile:Get(key)` / `Set(key, value)` overloads typed with `keyof<T>` / `index<T, K>`. Until then, `Mutate` is the typed path.
3. **`Mutate` and nested tables.** Firing `Changed` for every table-valued key is safe but noisy. The alternative (only changed references) is cheaper but misses in-place edits. Recommended: safe by default, `Keys` as the fast path, decided finally by the Phase 2 benchmark.
4. **Zone interval drift fix outside the scheduler.** The legacy path keeps `elapsed = 0` for compatibility. Fixing it there too is a small, observable behaviour change, so if wanted it should go in a minor release with an upgrade note.
