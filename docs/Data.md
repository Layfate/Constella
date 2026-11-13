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

## Status: beta, not production-verified

- **Constella doesn't implement its own DataStore session locking.** Production data should go through `ProfileStoreAdapter`. [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) then handles the DataStore calls, session locking, autosaving, retries and its own shutdown handling.
- Constella's own layer (migrations, reconciliation, lifecycle, session loss, shutdown budget) is tested against `MemoryAdapter`. That adapter simulates session locking, throttled loads, failed saves, latency and several servers sharing one database.
- `ProfileStoreAdapter` has only been tested against a stand-in that copies ProfileStore's public API. **Before using it with real players,** test it with real ProfileStore in a separate experience. Simulate disconnects, server shutdowns, rejoins (including joining a second server) and high player counts.

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

| Member | Description |
| --- | --- |
| `Data.Store.new(config)` | `Name`, `Template`, `Adapter`, `Version?`, `Migrations?`, `LoadAttempts?` (3), `RetryDelay?` (1s, doubling), `KickOnFailure?`, `Key?(player)`, `Logger?`, `OnError?` |
| `store:LoadAsync(player)` | A Promise of the Profile. While loading it returns the same promise, and once loaded the same profile |
| `store:Get(player)` | The loaded profile, or nil |
| `store:Release(player)` | Ends the session (the adapter does the final save). Cancels a load that's still in progress |
| `store:BindPlayers()` | Loads players on join and releases them on leave |
| `store:Shutdown(budget = 20)` | Stops new loads, releases everyone, and waits at most `budget` seconds. Returns whether everything finished in time |
| `store:GetStats()` | `{ Loaded, Loading, LoadsSucceeded, LoadsFailed, SessionsLost }` |
| `store.Loaded(player, profile)` / `store.Released(player)` | Signals |
| `profile.Data` | The live data table |
| `profile:Get(key)` / `:Set(key, value)` / `:Update(key, fn)` | `Set`/`Update` fire `profile.Changed(key, new, old)` |
| `profile:Save()` | Requests a save. Returns false (and reports the error) if it fails |
| `profile:IsActive()` / `profile:Release()` | |
| `Data.Store.isError(value, kind?)` | |

## Adapters

| Adapter | Use |
| --- | --- |
| `Data.ProfileStoreAdapter.new(ProfileStore)` | Production |
| `Data.MemoryAdapter.new({ Database?, Latency? })` | Studio and tests. **Not persistent.** Has `SimulateFailures({ Loads, Saves })`, `Peek`, `Write` and `IsLocked`. Share a `MemoryAdapter.newDatabase()` between adapters to simulate several servers |

Any other backend can be used if it implements the same three-method contract that `MemoryAdapter` documents: `Open`, `StartSession`, and a session with `Data` / `Save` / `End` / `IsActive` / `OnSessionEnd`.
