<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-512.png">
    <img src="assets/logo-512-panel.png" alt="Constella logo" width="160">
  </picture>
</p>

<h1 align="center">Constella</h1>

<p align="center">
  <b>A modular, strictly typed Luau toolkit for Roblox.</b><br>
  Use one utility on its own, or build your whole game on it.
</p>

<p align="center">
  <a href="https://github.com/Layfate/Constella/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Layfate/Constella/actions/workflows/ci.yml/badge.svg?branch=main"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-7c6cf0"></a>
  <a href="CHANGELOG.md"><img alt="Version 0.3.2" src="https://img.shields.io/badge/version-0.3.2-4fb4f0"></a>
  <img alt="Luau: strict" src="https://img.shields.io/badge/luau-strict-5b7cfa">
  <img alt="Platform: Roblox" src="https://img.shields.io/badge/platform-Roblox-3b3f63">
</p>

<p align="center">Made by <b>Zense</b></p>

📖 **[Documentation → docs/](docs/README.md)**<br>
🧪 **[Examples → one script per module](examples/)**<br>
🗺️ **[Roadmap](docs/Roadmap.md)**

```toml
# wally.toml
[dependencies]
Constella = "layfate/constella@0.3.2"
```

Also available as a ready-to-insert model file (**[download `Constella.rbxm`](https://github.com/Layfate/Constella/releases/latest)**) or with pesde (`pesde add zense/constella`). See [Installation](#installation).

- **Use only what you need.** Every module loads on first use. `require(Constella.Signal)` loads Signal and nothing else, and no system starts unless you start it.
- **Safe networking by default.** Every client request passes rate limiting, payload caps, schema validation and your authorization check before your code runs. Clients only ever see generic error codes; the details stay on the server.
- **An explicit architecture.** Apps start services in dependency order, catch duplicates, missing dependencies and cycles before any code runs, keep client and server code apart, and roll back cleanly if startup fails. No globals, no singletons, no auto-discovery.
- **Player data that fails closed.** Migrations, template reconciliation and session-loss handling sit on top of ProfileStore's session locking. A failed load never overwrites saved data.
- **Tested and measured.** Unit tests, Data failure simulations, tests against real ProfileStore, Play-mode integration tests with a hostile client against real remotes, and published [benchmarks](docs/Benchmarks.md) against other libraries and hand-written baselines, including where Constella is slower.

> [!NOTE]
> `Constella.Data` runs on [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore), which you install separately. Every CI run tests it on real DataStores on real Roblox servers, including a player moving to a second server. See [Data](docs/Data.md) for exactly what's verified.

## Modules

| | Module | What it does |
| --- | --- | --- |
| **Architecture** | [Core / App](docs/Core.md) | Services and controllers with dependency-ordered Init/Start/Stop and injection |
| **Utilities** | [Signal](docs/Signal.md) | Custom events with deterministic dispatch and error isolation |
| | [Cleanup](docs/Cleanup.md) | Owns connections, instances, threads and promises, and disposes them together |
| | [State](docs/State.md) | Reactive values, computed state, batching and UI bindings |
| | [Promise](docs/Promise.md) | Async chaining, cancellation, timeouts and retries |
| | [Random](docs/Random.md) | Weighted rolls, loot tables and luck, with the math documented |
| | [Debug](docs/Debug.md) | Structured logging and metrics, with almost no cost when switched off |
| **Game systems** | [Network](docs/Network.md) | Server-owned remotes with validation, rate limits and payload caps |
| | [Replication](docs/Replication.md) | Server→client State, only when the server explicitly shares it |
| | [Component](docs/Component.md) | Behaviour attached to CollectionService tags |
| | [Pool](docs/Pool.md) | Bounded object reuse for projectiles and effects |
| | [Zone](docs/Zone.md) | Enter/exit detection for players and parts |
| | [Data](docs/Data.md) | Player profiles on ProfileStore *(server only)* |

## Compared with other libraries

Each module has a well-known alternative. Constella's case is that all 13 share one set of rules (strict types, explicit lifetimes, loud errors, no globals) and are tested together on real Roblox servers. If you only need one piece, the specialist library is often the right pick.

| Job | Common choice | Constella | Main difference |
| --- | --- | --- | --- |
| **Secure remotes** | Plain RemoteEvents; Zap, ByteNet or Blink | [Network](docs/Network.md) | **Security first:** every client request is rate limited, size capped, schema checked and authorized before your handler runs, and clients only see generic error codes. Zap, ByteNet and Blink focus on compact serialization and bandwidth instead. The two approaches can be combined |
| Player data | ProfileStore directly | [Data](docs/Data.md) | Built **on** ProfileStore: adds migrations, template reconciliation, `Changed` signals, kick-on-session-loss and a shutdown budget that waits for every save |
| App structure | Knit | [Core](docs/Core.md) | Explicit apps instead of global singletons: dependency order, cycle and environment checks before any code runs, and rollback when startup fails |
| Cleanup | Trove, Janitor, Maid | [Cleanup](docs/Cleanup.md) | Level with Janitor and about 6× faster than Trove for functions on a Roblox server, with half of Trove's memory ([benchmarks](docs/Benchmarks.md)) |
| Signals | GoodSignal, sleitnick/signal | [Signal](docs/Signal.md) | Catches each listener's errors and calls listeners in order. With the same error catching, `Fire` is within 1–11% of sleitnick/signal (depending on the server) and faster than LemonSignal; `Connect`+`Disconnect` is slower; and it uses the least memory per connection of the three |
| Promises | evaera/promise | [Promise](docs/Promise.md) | A smaller, strictly typed core: cancellation, timeouts, `all`/`race`/`allSettled`, retry with backoff. About 6× faster than evaera/promise for a `resolve`+`Then`+`Await` and a tenth of the memory per promise; evaera/promise has a larger API and a long track record |
| Reactive state | Fusion | [State](docs/State.md) | Small reactive values with property bindings, not a UI framework. For building whole interfaces declaratively, Fusion does far more |
| Zones | ZonePlus | [Zone](docs/Zone.md) | Simple point tests against boxes and spheres, with hysteresis at the edges, at about 0.3 µs per tracked item per step. ZonePlus supports more shapes and features |
| Tagged components | sleitnick/component | [Component](docs/Component.md) | Each component gets its own Cleanup and an ancestor filter |
| Object reuse | PartCache | [Pool](docs/Pool.md) | Pools any object, not only Parts, with limits on idle and active counts |

## Quick start

Utilities work on their own, with no setup:

```lua
-- Any Script or LocalScript
local Constella = require(game:GetService("ReplicatedStorage").Packages.Constella)

local cleanup = Constella.Cleanup.new()
local health = Constella.State.new(100)
cleanup:Add(health:Subscribe(function(new, old)
	print("Health", old, "->", new)
end))
health:Set(80)

local rarity = Constella.Random.choose({
	{ Value = "Common", Weight = 75 },
	{ Value = "Rare", Weight = 20 },
	{ Value = "Legendary", Weight = 5 },
}, Random.new(1234)) -- seeded: the same roll every time

cleanup:Destroy() -- disconnects everything it owns
```

For a whole game, write services and start them with an app. This service keeps each player's coins on the server, shows them to that player only, and sells items through a validated, rate-limited remote:

```lua
-- ServerScriptService/Services/CoinService.luau
local Players = game:GetService("Players")
local Constella = require(game:GetService("ReplicatedStorage").Packages.Constella)
local Check = Constella.Network.Check

local PRICES = { Sword = 10, Shield = 50 }

local CoinService = { Name = "CoinService", Environment = "Server" }

function CoinService:Init(context)
	local replicator = context.Cleanup:Add(Constella.Replication.Server.new("Coins"))
	local network = context.Cleanup:Add(Constella.Network.Server.new("Shop"))
	local coins = {}

	context.Cleanup:Connect(Players.PlayerAdded, function(player)
		coins[player] = Constella.State.new(100)
		replicator:ShareWith(player, "Coins", coins[player]) -- visible to this player only
	end)
	context.Cleanup:Connect(Players.PlayerRemoving, function(player)
		local balance = coins[player]
		coins[player] = nil
		if balance then
			balance:Destroy()
		end
	end)

	-- Clients may only send "Sword" or "Shield", at most twice per second.
	network:Function("Buy", {
		Schema = { Check.literal("Sword", "Shield") },
		RateLimit = { Count = 2, Per = 1 },
	}):SetHandler(function(player, item)
		local balance, price = coins[player], PRICES[item]
		if not balance or balance:Get() < price then
			return false
		end
		balance:Update(function(current)
			return current - price
		end)
		return true
	end)
end

return CoinService
```

```lua
-- ServerScriptService/Main.server.luau
local Constella = require(game:GetService("ReplicatedStorage").Packages.Constella)

local app = Constella.App.new()
app:AddModules(script.Parent.Services) -- only this folder, never auto-discovered
app:Start()
game:BindToClose(function()
	app:Stop()
end)
```

```lua
-- StarterPlayer/StarterPlayerScripts/Shop.client.luau
local Constella = require(game:GetService("ReplicatedStorage").Packages.Constella)

local coins = Constella.Replication.Client.new("Coins"):Get("Coins") -- read-only
coins:Observe(function(value)
	print("Coins:", value)
end)

local buy = Constella.Network.Client.new("Shop"):Function("Buy", { Timeout = 5 })
local ok, bought = buy:Invoke("Sword") -- ok is false on a rejection, rate limit or timeout
print("Bought a sword:", ok and bought)
```

A complete demo game, with saved data, a coins UI and a shop, lives in [`src/server`](src/server) and [`src/client`](src/client). Each module also has a short example in [`examples/`](examples/).

## Installation

**Download (easiest).** Get `Constella.rbxm` from the [latest release](https://github.com/Layfate/Constella/releases/latest). In Studio, right-click `ReplicatedStorage` → **Insert from File…** and choose the file. Then move the inserted `Constella` module into a Folder named `Packages`, so the path is `ReplicatedStorage.Packages.Constella`.

> [!TIP]
> The package is named `layfate/constella` on Wally and `zense/constella` on pesde. The release download, the Wally package and the pesde package are built from the same tagged source.

**Wally.** Add Constella to `wally.toml`, then run `wally install`:

```toml
[dependencies]
Constella = "layfate/constella@0.3.2"
```

**pesde.**

```bash
pesde add zense/constella
```

**Build from source.** Build the model file with Rojo, then insert `Constella.rbxm` into `ReplicatedStorage.Packages`:

```bash
rojo build default.project.json -o Constella.rbxm
```

<details>
<summary><b>Manual install (no tools)</b></summary>

1. In Studio, create a Folder named `Packages` in `ReplicatedStorage`.
2. Inside it, create a ModuleScript named `Constella` and paste in [`src/shared/Constella/init.luau`](src/shared/Constella/init.luau).
3. For every other file in [`src/shared/Constella`](src/shared/Constella), add a child ModuleScript with the same name (without `.luau`).
4. `Network` and `Data` are folders: give each one a ModuleScript holding its `init.luau`, with the rest of its files as children.

</details>

## Development

```bash
rokit install                  # rojo, wally, selene, stylua
rojo serve dev.project.json    # dev place: package, demo, examples and tests
selene src tests examples benchmarks     # lint
stylua src tests examples benchmarks     # format
```

Press **Play** in the dev place to run the full test suite and both integration tests. On every push and pull request, GitHub Actions checks formatting (StyLua), lint (selene) and strict Roblox types (luau-lsp), then runs the whole test suite on a real Roblox server through Open Cloud, including the live DataStore tests. See [CONTRIBUTING.md](CONTRIBUTING.md) for how tests are structured and what a pull request needs.

## License

MIT © 2026 Zense. See [LICENSE](LICENSE).
