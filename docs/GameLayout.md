# Game layout

How to lay out a game built on Constella. A working starter game with this layout lives in [`template/`](https://github.com/Layfate/Constella/tree/main/template).

## The folders

```
ReplicatedStorage
├── Packages
│   └── Constella             the library
└── Shared                    seen by the server AND every client
    ├── Items                 public data both sides read (catalog, prices)
    └── Net                   the Shop Network contract and replication names

ServerScriptService
└── Server
    ├── Main.server           the only server Script
    └── Services/             one ModuleScript per feature

ServerStorage
└── Config/                   server-only data: drop rates, admin lists, keys

StarterPlayer.StarterPlayerScripts
└── Client
    ├── Main.client           the only client Script
    └── Controllers/          one ModuleScript per feature
```

| Folder | Replicates to clients? | Put here |
| --- | --- | --- |
| `ReplicatedStorage.Shared` | **Yes.** Exploiters can read every line | Code and data both sides need: types, names, public catalogs. Never secrets, never decisions |
| `ServerScriptService.Server` | No | Services: everything that decides what happens |
| `ServerStorage.Config` | No | Data the server reads but players must not see |
| `StarterPlayerScripts.Client` | Yes (it runs there) | Controllers: UI, input, effects. They display and ask, and never decide |

## One Script per side

Each side has a single `Main` Script. Everything else is a ModuleScript that the [App](Core.md) loads:

```lua
local app = Constella.App.new({ Name = "Server" })
app:AddModules(script.Parent.Services, {
	Recursive = true,
	Filter = function(module) return string.match(module.Name, "Service$") ~= nil end,
})
app:Start()
game:BindToClose(function() app:Stop() end)
```

- `Recursive` lets you group services in subfolders (`Services/Combat/DamageService`).
- `Filter` lets helper modules sit next to the services that use them without being registered as services.
- The App runs `Init` then `Start` in dependency order, and `Stop` in reverse when the server shuts down. Startup order doesn't depend on folder order.
- Adding a feature means adding one ModuleScript. You never add a Script.

## Services and dependencies

A service names what it needs and gets it from `context:Get`. It never `require`s another service to call it:

```lua
type CoinsService = typeof(require(script.Parent.CoinsService)) -- types only

local ShopService = {
	Name = "ShopService",
	Environment = "Server",
	Dependencies = { "CoinsService" },
}

function ShopService.Init(self: typeof(ShopService), context: Constella.Context)
	local coins: CoinsService = context:Get("CoinsService")
end
```

`typeof(require(...))` in a type annotation is evaluated by the type checker only, so it costs nothing at runtime. Getting the instance from `context:Get` keeps the App in charge of the startup order and catches missing dependencies and cycles before any code runs.

## Types

Every public type is exported from the root module, so the `Constella` you already required is all you need:

```lua
local Constella = require(ReplicatedStorage.Packages.Constella)

local coins: Constella.Value<number> = Constella.State.new(0)
local store: Constella.Store<PlayerData> = Constella.Data.Store.new({ ... })
function MyService.Init(self: MyService, context: Constella.Context) end
```

The names match the modules' own (`Context`, `Store<T>`, `Value<T>`, `Logger`), with a module prefix where two would clash (`NetworkServer` and `ReplicationServer`, `ComponentOptions`, `PoolStats`). The full list is at the end of `init.luau`. The types cost nothing at runtime: requiring Constella still loads only the modules you use.

With Wally, run [wally-package-types](https://github.com/JohnnyMorganz/wally-package-types) after `wally install` so the link file re-exports them (see [Installation](https://github.com/Layfate/Constella#installation)). The release download and the source build need nothing extra.

Listener types are kept either way: `context.Cleanup:Connect(store.Loaded, function(player, profile) ... end)` checks the callback against the signal, as does `context.Cleanup:Add(store.Loaded:Connect(...))`.

Remotes are typed through a [Network contract](Network.md#contracts-typed-endpoints) in `Shared/Net`: the server's handler, the client's call and the declaration are checked against each other, so renaming an argument's type on one side is a type error on the other.

## Security rules of thumb

1. **The server decides.** The client sends *what it wants* ("buy Sword"), never *what happened* ("I now have 90 coins").
2. **Validate every remote.** Give each [Network](Network.md) endpoint a `Schema` and a `RateLimit`. A schema of `Check.literal(table.unpack(Items.Ids))` rejects unknown items before your handler runs.
3. **Share shapes, not rules.** `Shared/Net` holds the Shop contract: endpoint names, argument Schemas and types. A Schema only checks the shape of a request, so clients seeing it is harmless. Rate limits, prices you charge, rewards you grant and anything else that needs server-only knowledge are applied on the server, in the endpoint config, `Authorize` or the handler, never in the shared contract.
4. **Secrets live in `ServerStorage` or `ServerScriptService`.** Anything in `ReplicatedStorage` is public.
5. **Replicate deliberately.** [Replication](Replication.md) only sends what a service shares, and `ShareWith(player, ...)` keeps per-player values private.
