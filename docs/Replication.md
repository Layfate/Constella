# Replication

Sends State values from the server to clients. Nothing replicates unless the server explicitly shares it.

```lua
-- Server
local replicator = Constella.Replication.Server.new("Game")
replicator:Share("RoundTime", roundTime)              -- every player
replicator:ShareWith(player, "Coins", coinsState)     -- this player only
```

```lua
-- Client
local replica = Constella.Replication.Client.new("Game")
Constella.State.bind(coinsLabel, "Text", replica:Get("Coins"), function(value)
	return if value then `Coins: {value}` else "Coins: ..."
end)
```

## Security

- **Explicit authorization.** A value is only sent if the server called `Share` (for everyone) or `ShareWith(player, ...)` (for that player). A private share is never sent to, and never included in snapshots for, anyone else.
- **One direction only.** The update channel is a Network event with no Schema, so anything a client fires at it is rejected. The only request a client can make is a snapshot fetch, which takes no arguments and is rate-limited.
- **Value checks.** Functions, threads, userdata and tables with metatables are refused, and values over `MaxValueBytes` (16 KB by default) are refused too. These are reported on the server and never sent.
- **Ordering.** Versions come from one counter per replicator that only ever goes up. A snapshot that arrives late can never overwrite a newer update. A share that's stopped and recreated under the same name always continues above every version a client has already seen.
- **Snapshots only contain validated values.** If an update is rejected (unsupported or too large), it's reported on the server, and both live updates and snapshots keep serving the last value that passed validation.
- On the client, values are **read-only** states. The server stays the source of truth.

## API

| Server | Description |
| --- | --- |
| `Replication.Server.new(namespace, { Parent?, Logger?, OnError?, MaxValueBytes?, Delta? }?)` | Creates its own [Network](Network.md) namespace. `Delta = true` sends table changes as patches (see below) |
| `replicator:Share(name, state)` | Public. Returns a share with `:Stop()` |
| `replicator:ShareWith(player, name, state)` | Private. Removed automatically when the player leaves |
| `replicator:Destroy()` | |

| Client | Description |
| --- | --- |
| `Replication.Client.new(namespace, { Timeout? }?)` | Yields until the initial snapshot arrives |
| `replica:Get(name)` | A read-only state (nil until the value is known) |
| `replica:Observe(name, fn)` | |
| `replica:Destroy()` | |

A name can be public or private, not both. Private names can be reused across players, so each player can have their own `"Coins"`.

Tables are compared by reference (State semantics). Set a **new** table to replicate a change; changing a table in place won't trigger an update.

## Delta updates

By default every change sends the whole value. With `Delta = true`, a change from one table to another is sent as a **patch** that lists only what changed (recursively), whenever that's smaller than the whole value:

```lua
local replicator = Constella.Replication.Server.new("Game", { Delta = true })
replicator:ShareWith(player, "Inventory", inventory)

local nextValue = table.clone(inventory:Get())
nextValue.Coins += 10
inventory:Set(nextValue) -- sends about 90 bytes instead of the whole 40-item inventory (~1.9 KB)
```

- **What clients see is the same.** The client applies the patch to its copy and sets the result as a new table, so subscribers run exactly as they would for a full value. Unchanged nested tables are shared between the old and new value.
- **Safe with in-place edits.** The server diffs against its own private copy of what clients were last sent, not against the table you passed before. Editing the current table in place and then setting a copy still replicates every change.
- **Ordering and recovery.** Each patch names the version it builds on. A patch that arrives before that version (during the initial sync) is kept until the value arrives, up to 64 per name. A patch that can't be applied makes the client fetch a fresh snapshot, one fetch at a time; the server's rate limit on fetches still applies.
- **The trade-off is CPU for bandwidth.** Diffing walks the value once more, so a Delta update costs about 50% more server time than a full send (about 14 µs more for a 40-item inventory on a Roblox server), and saves about 95% of the bytes. See [Benchmarks](Benchmarks.md).
- **Use it for arrays and string-keyed dictionaries**, which is what RemoteEvents carry faithfully anyway. Patches are built only from arrays and string-keyed fields, so they survive serialization.
- It's off by default. The full-value path has been verified with real clients in Studio Play mode; Delta is covered by unit tests on the server (including 300 random updates kept in sync, with in-place edits) and by a Play-mode test in `tests/client/ReplicationIntegration.client.luau`.
