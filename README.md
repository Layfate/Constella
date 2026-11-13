# Constella

**Made by Zense.**

A modular Luau toolkit for Roblox. Use one utility on its own, or combine them into an explicit app with dependency-ordered services.

```lua
local Constella = require(game.ReplicatedStorage.Packages.Constella)

local cleanup = Constella.Cleanup.new()
local state = Constella.State.new(0)
cleanup:Add(state:Subscribe(function(newValue) print(newValue) end))
state:Set(10) --> 10

local rarity = Constella.Random.choose({
	{ Value = "Common", Weight = 75 },
	{ Value = "Rare", Weight = 20 },
	{ Value = "Legendary", Weight = 5 },
}, Random.new(1234))
print(rarity)
```

- **Nothing runs unless you ask.** Modules load lazily on first access, and `require(Constella.Signal)` loads only Signal.
- **No hidden globals or singletons.** Apps are explicit objects you create and start.
- **Clear boundaries.** Server-only definitions can't be added to a client app, and client-only ones can't be added to a server app.
- **Strict Luau** with exported types on every public API.

## Status (v0.1.0)

| Module | Status | What it does |
| --- | --- | --- |
| [Core / App](docs/Core.md) | ✅ Implemented | Services/controllers, dependency order, Init/Start/Stop, injection |
| [Signal](docs/Signal.md) | ✅ Implemented | Custom events with deterministic dispatch |
| [Cleanup](docs/Cleanup.md) | ✅ Implemented | Resource ownership and disposal |
| [State](docs/State.md) | ✅ Implemented | Reactive values, computed state, batching |
| [Random](docs/Random.md) | ✅ Implemented | Weighted rolls, loot tables, luck |
| [Network](docs/Network.md) | ✅ Implemented | Server-owned remotes with validation, rate limits and payload caps |
| [Component](docs/Component.md) | ✅ Implemented | Tag-based behaviours with ancestry safety |
| [Pool](docs/Pool.md) | ✅ Implemented | Bounded object reuse |
| [Zone](docs/Zone.md) | ✅ Implemented | Enter/exit detection in boxes and spheres |
| [Debug](docs/Debug.md) | ✅ Implemented | Structured logging and metrics |
| [Promise](docs/Promise.md) | ✅ Implemented | Async chaining, cancellation, timeouts, retries |
| [Data](docs/Data.md) | 🧪 Beta (server only) | Player profiles on ProfileStore: migrations, reconciliation, session loss, shutdown budget |
| [Replication](docs/Replication.md) | ✅ Implemented | Explicit server→client State replication |
| [State UI bindings](docs/State.md#ui-bindings) | ✅ Implemented | `State.bind(instance, property, state)` |

All 12 planned modules exist. See the [roadmap](docs/Roadmap.md) for what's left before 1.0.

> **Data safety:** `Constella.Data` doesn't implement its own DataStore session locking. Use it with `ProfileStoreAdapter`, which needs you to install ProfileStore. Constella's layer is tested against a simulated backend, and the adapter against a stand-in for ProfileStore's API. Before using it with real players, test it with real ProfileStore in a separate experience: simulate disconnects, shutdowns, rejoins and high player counts.

## Install

**Wally:** add the following to `wally.toml`, then run `wally install`:
```toml
[dependencies]
Constella = "zense/constella@0.1.0"
```

**pesde:** `pesde add zense/constella`

**Rojo (from source):** copy `src/shared/Constella` into your project, or build a model:
```sh
rojo build default.project.json -o Constella.rbxm
```
Then insert `Constella.rbxm` into `ReplicatedStorage.Packages`.

**Manual:** in Studio, create a ModuleScript named `Constella` in `ReplicatedStorage.Packages`. Paste `init.luau` into it, then add every other file in `src/shared/Constella` as a child ModuleScript with the same name. `Network` is itself a ModuleScript (its `init.luau`) with its own children.

> The `zense/` scope must match the Wally and pesde accounts the package is published from.

## An app in 20 lines

```lua
-- ServerScriptService/Services/GreetingService.luau
local GreetingService = {
	Name = "GreetingService",
	Environment = "Server",
	Dependencies = { "PlayerDataService" },
}

function GreetingService:Init(context)
	local data = context:Get("PlayerDataService") -- only declared dependencies are reachable
	context.Cleanup:Connect(data.Store.Loaded, function(player)
		print("Welcome", player.Name)
	end)
end

return GreetingService
```

```lua
-- ServerScriptService/Main.server.luau
local app = Constella.App.new()
app:AddModules(script.Parent.Services) -- explicit: only this folder
app:Start()
game:BindToClose(function() app:Stop() end)
```

The full demo is in [src/server](src/server) and [src/client](src/client).

## Repository layout

```
src/shared/Constella/   the package (ReplicatedStorage.Packages.Constella)
src/server/             demo server app (player data, rewards, a networked shop)
src/client/             demo client app (replicated coins label, shop client)
examples/               one zero-setup script per module
tests/server/           Studio test suite (TestKit + *.spec modules) + integration tests (server halves)
tests/client/           Network and Replication integration tests (client halves)
docs/                   reference docs
default.project.json    package build (Wally / pesde / .rbxm)
dev.project.json        full dev place: package + demo + examples + tests
```

## Develop and test

```sh
rokit install                      # rojo, wally, selene, stylua
rojo serve dev.project.json        # then connect from the Rojo Studio plugin
# or: rojo build dev.project.json -o ConstellaDev.rbxl
```

Press **Play** in Studio. The test suite runs automatically and prints `[Constella tests] N passed, M failed`. Failures appear as warnings with tracebacks. Two integration tests also run:

- **Network:** a client sends valid, malformed, forged and excessive requests through real remotes.
- **Replication:** a client checks that it sees its own private values and never another player's, and that public updates reach a UI label through `State.bind`.

Each prints `[Constella integration] ... PASS`. To run the suite without playing, use the command bar:

```lua
require(game.ServerScriptService.ConstellaTests.RunTests)()
```

Lint and format with `selene src tests examples` and `stylua src tests examples`.

## Known limitations (v0.1.0)

- The tests run inside Roblox Studio only. There is no headless/CI runner yet.
- State uses explicit dependency lists (`State.computed({ a, b }, fn)`), not automatic tracking. Compute functions and batches must not yield.
- Each Signal listener runs on a new thread through `task.spawn`. There's no thread reuse yet, and no benchmarks exist.
- Network payload sizes are conservative estimates, not Roblox's exact wire sizes. Validation checks shape, so your handlers still decide what's allowed in game.
- Zone tests points, not volumes, and each zone has its own Heartbeat connection.
- Tests that need several real players (rejoins, many clients) are covered with stand-in players in unit tests, not with real clients.
- `Data` is beta. There's no custom DataStore backend; production use relies on ProfileStore, and the ProfileStore adapter hasn't been run against real ProfileStore here. `MemoryAdapter` isn't persistent.
- The unhandled-rejection reporter in Promise is set for the whole process (`Promise.setUnhandledRejectionHandler`).
- No performance claims are made against Knit, Trove, GoodSignal, Fusion or similar libraries, because no benchmarks have been run.

## License

MIT © 2026 Zense. See [LICENSE](LICENSE).
