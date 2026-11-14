# Data (server only)

Player profiles with migrations, reconciliation, lifecycle handling and failure safety, built on top of a storage *adapter*.

```lua
local ProfileStore = require(ServerScriptService.ProfileStore) -- you install ProfileStore

local store = Constella.Data.Store.new({
	Name = "PlayerData",
	Version = 2,
	Template = { Coins = 0, Inventory = {} },
	Migrations = {
		[1] = function(data) data.Coins = data.Gold or 0; data.Gold = nil end, -- v1 -> v2
	},
	Adapter = Constella.Data.ProfileStoreAdapter.new(ProfileStore),
})

store.Loaded:Connect(function(player, profile)
	profile:Update("Coins", function(coins) return coins + 10 end)
end)
store:BindPlayers()
game:BindToClose(function() store:Shutdown(20) end)
```

## Status and verification

**Constella doesn't implement its own DataStore session locking.** Production data should go through `ProfileStoreAdapter`. [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) then handles the DataStore calls, session locking, autosaving, retries and its own shutdown handling.

| What | Verified how | Status |
| --- | --- | --- |
| Constella's layer: migrations, reconciliation, lifecycle, session loss, shutdown budget | `MemoryAdapter`, which simulates session locking, throttling, failed saves, latency and several servers | ✅ Tested |
| `ProfileStoreAdapter` with **real ProfileStore 1.0.3** | ProfileStore's own mock mode, which runs its real session, save and end-session code on an in-memory store ([`tests/server/ProfileStore.spec.luau`](https://github.com/Layfate/Constella/blob/main/tests/server/ProfileStore.spec.luau)) | ✅ Tested |
| `ProfileStoreAdapter` on **real DataStores**, one server | The `live DataStores` tests (save and reload, release, several players, cleanup of the test keys). They run on a Roblox server in every CI run, and in Play mode in Studio with API access | ✅ Tested |
| Real DataStores with **several real players on one server** | Studio Server & Clients with 5 players: all 5 loaded, two left at the same moment, one left while the server shut down with two still active. Every value was saved and `Shutdown` returned `true` (2026-11-14) | ✅ Tested |
| A player **moving to a second server** (two real Roblox servers at once) | In every CI run: server A loads the player and saves; server B loads the same player, sees A's data, and A gives up the session (kicking the player with ProfileStore's "loaded on another server" message) so it can't overwrite B. B's save is the one stored | ✅ Tested |
| **Many sessions** on one server | In every CI run: 15 profiles load at once on a real server, each saves the right value, and shutdown finishes | ✅ Tested |
| Heavy production load: DataStore throttling with many players over hours | Needs a real game | ⏳ Not yet verified |

**Many profiles on one server.** ProfileStore subscribes to one MessagingService topic per active profile, so another server can ask it to release that profile. Roblox limits subscriptions per server, and the limit grows with the number of players. One profile per player stays well within it. If you keep many extra profiles open (guilds, shared worlds) on a server with few players, you can hit the limit: ProfileStore logs "reached the allowed limit of active subscriptions", and those profiles can't be released gracefully to another server.

**Before you move a live game's data to it,** try it in a separate test experience first, as with any change to how player data is stored.

### Save completion with ProfileStore

ProfileStore's `Profile:Save()` and `Profile:EndSession()` return straight away and write on a separate thread. Its `OnSessionEnd` even fires *before* the final write. The adapter waits for ProfileStore's `OnAfterSave` signal, which fires after a successful write, so in Constella:

- `profile:Save()` returns `true` only once the save has been written. It yields.
- `store:Release(player)` returns once the final save has been written, and `Released` fires after that.
- `store:Shutdown(budget)` measures real save completion.

Each wait is capped by `SaveTimeout` (30 seconds by default). On a timeout, Constella reports a failure while ProfileStore keeps retrying the write in the background. ProfileStore's own `BindToClose` handler keeps a live server alive until its pending saves finish.

### Testing safely

`Data.ProfileStoreAdapter.new(ProfileStore, { Mock = true })` uses ProfileStore's in-memory mock store, so tests never touch real player data, even in a place that has DataStore access. Constella's ProfileStore tests always use it.

One thing to know: ProfileStore's mock `StartSessionAsync` ignores the cancel callback. In mock mode, a player who leaves while loading is handled *after* the load finishes; the session is ended straight away and no profile is handed out.

## Never overwrite on failure

The load pipeline goes:

1. Start a session (retrying with backoff).
2. Validate the data.
3. Migrate it.
4. Reconcile it with the template.
5. Commit it.

If *any* step fails, the session ends without the stored data being touched, the profile isn't handed out, and the player is kicked (`KickOnFailure`, on by default). A player never plays on template data that could later be saved over their real data.

| Failure | Error Kind | Stored data |
| --- | --- | --- |
| The backend can't start a session (throttled, down) after every attempt | `LoadFailed` | Untouched |
| The player leaves while their data is loading | `PlayerLeft` (no kick) | Untouched, and the session is ended |
| The data isn't a table, or has an invalid version | `CorruptData` | Untouched |
| The data was saved by a **newer** game version than this server | `NewerVersion` | Untouched |
| No migration exists for the stored version | `MissingMigration` | Untouched |
| A migration throws or returns a non-table | `MigrationFailed` | Untouched. Migrations run on a copy, so half-applied changes are thrown away |
| The store is shutting down | `ShuttingDown` | — |

## Changing data

**Change data only with `profile:Set` and `profile:Update`.** Reading `profile.Data` directly is fine, but writing to it isn't:

- A direct write skips the `Changed` signal, so anything listening (UI, replication) never hears about it.
- A direct write skips the active-session check. After a session is lost, `Set` and `Update` raise an error, but a direct write just disappears with no error.

`profile.Data` can't be frozen or wrapped, because it's the same table ProfileStore saves.

**`Set` compares by identity.** If you edit a table in place and then `Set` that same table, nothing happens and `Changed` doesn't fire, because the value didn't change from `Set`'s point of view. Build a new table instead, which `Update` makes easy:

```lua
-- Wrong: edits the stored table in place; Set sees the same table and does nothing.
local inventory = profile:Get("Inventory")
table.insert(inventory, "Sword")
profile:Set("Inventory", inventory)

-- Right: Update with a copy; Changed fires with the new and old tables.
profile:Update("Inventory", function(inventory)
	local updated = table.clone(inventory)
	table.insert(updated, "Sword")
	return updated
end)

-- Also fine: Update that edits in place and returns the same table.
-- Changed still fires, with that table as both the new and the old value.
profile:Update("Inventory", function(inventory)
	table.insert(inventory, "Sword")
	return inventory
end)
```

Prefer the copy when a listener needs the old value, for example to diff it. The identity rule for `Set` also applies to [State](State.md), whose `Update` has no in-place exception: give it a new table.

## Versions and migrations

- Data is stamped with `_ConstellaVersion`, a reserved key you can't use in your Template.
- New profiles start at the current `Version`.
- Data with no version counts as version 0. That covers data created before Constella, which needs a `Migrations[0]`.
- `Migrations[n](data)` upgrades version `n` to `n + 1`. It can change `data` in place or return a replacement table.
- After migrating, missing template keys are added (nested dictionaries are filled in recursively). **Existing values are never overwritten.**

## Session loss

When the backend ends a session (for example the player joined another server, which took the session over):

- The profile becomes inactive, and writing to it raises an error.
- `Released` fires.
- The player is kicked if they're still on this server.

`MemoryAdapter` and ProfileStore both save the old session's data before the new server reads it. The session-takeover test checks that no data is lost.

## API

`Data.Store.new` takes its type from `Template`: `profile.Data` is typed, so `profile.Data.Coins` is a `number` and a misspelt key is a type error. `store:LoadAsync(player)` returns a `Promise<Profile<T>>`, and `store.Loaded` passes a typed `Profile<T>`.

| Member | Description |
| --- | --- |
| `Data.Store.new(config)` | `Name`, `Template`, `Adapter`, `Version?`, `Migrations?`, `LoadAttempts?` (3), `RetryDelay?` (1s, doubling), `KickOnFailure?`, `Key?(player)`, `Logger?`, `OnError?` |
| `store:LoadAsync(player)` | A Promise of the Profile. While loading it returns the same promise, and once loaded the same profile. Cancelling the promise clears that load entry and cooperatively stops the worker, which still releases any late session. A later call starts a fresh load |
| `store:Get(player)` | The loaded profile, or nil |
| `store:Release(player)` | Ends the session (the adapter does the final save). Cancels a load that's still in progress |
| `store:BindPlayers()` | Loads players on join and releases them on leave |
| `store:Shutdown(budget = 20)` | Stops new loads, releases everyone, and waits at most `budget` seconds for pending loads, yielding migrations, late session cleanup and releases already saving. Returns whether everything finished in time. Work exceeding the budget continues cleanup in the background |
| `store:GetStats()` | `{ Loaded, Loading, LoadsSucceeded, LoadsFailed, SessionsLost }`. Loading includes cancelled workers until their session cleanup finishes |
| `store.Loaded(player, profile)` / `store.Released(player)` | Signals |
| `profile.Data` | The live data table. Read it freely; change it only with `Set`/`Update` (see [Changing data](#changing-data)) |
| `profile:Get(key)` / `:Set(key, value)` / `:Update(key, fn)` | `Set`/`Update` fire `profile.Changed(key, new, old)` |
| `profile:Save()` | Saves now and yields until the save is written. Returns false (and reports the error) if it fails or times out |
| `profile:IsActive()` / `profile:Release()` | |
| `Data.Store.isError(value, kind?)` | |

## Adapters

| Adapter | Use |
| --- | --- |
| `Data.ProfileStoreAdapter.new(ProfileStore, { Mock?, SaveTimeout? }?)` | Production. `Mock = true` uses ProfileStore's in-memory mock store; `SaveTimeout` (30) caps how long Save and Release wait for the write |
| `Data.MemoryAdapter.new({ Database?, Latency? })` | Studio and tests. **Not persistent.** Has `SimulateFailures({ Loads, Saves })`, `Peek`, `Write` and `IsLocked`. Share a `MemoryAdapter.newDatabase()` between adapters to simulate several servers |

Any other backend can be used if it implements the same three-method contract that `MemoryAdapter` documents: `Open`, `StartSession`, and a session with `Data` / `Save` / `End` / `IsActive` / `OnSessionEnd`.
