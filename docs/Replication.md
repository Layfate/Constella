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
- **Ordering.** Each share has a version number, so a snapshot that arrives late can never overwrite a newer update.
- On the client, values are **read-only** states. The server stays the source of truth.

## API

| Server | Description |
| --- | --- |
| `Replication.Server.new(namespace, { Parent?, Logger?, OnError?, MaxValueBytes? }?)` | Creates its own [Network](Network.md) namespace |
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
