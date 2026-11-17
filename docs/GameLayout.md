# Game layout

How to lay out a game built on Constella. A working starter game with this layout lives in [`template/`](https://github.com/Layfate/Constella/tree/main/template).

## The folders

```
ReplicatedStorage
├── Packages
│   └── Constella             the library
└── Shared                    seen by the server AND every client
    ├── Types                 every Constella type the game uses, imported once
    ├── Items                 public data both sides read (catalog, prices)
    └── Net                   remote and replication names

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

function ShopService.Init(self: typeof(ShopService), context: Types.Context)
	local coins: CoinsService = context:Get("CoinsService")
end
```

`typeof(require(...))` in a type annotation is evaluated by the type checker only, so it costs nothing at runtime. Getting the instance from `context:Get` keeps the App in charge of the startup order and catches missing dependencies and cycles before any code runs.

## Types

Exported types can only be read from a module that is `require`d directly, so the template imports them in one place, `Shared/Types`, and every other module uses `Types.Context`, `Types.Store<T>` and so on. If the way Constella is installed changes, only that file changes.

`Shared/Types` requires Constella's submodules by path (`Packages.Constella.Core`). That works with the [release download](https://github.com/Layfate/Constella#installation) and the source build. Wally and pesde install a link file at `Packages.Constella` with no children, so with those `Shared/Types` needs to point at the real package folder instead.

Keep listener types by connecting through the signal: `context.Cleanup:Add(store.Loaded:Connect(function(player, profile) ... end))`. `Cleanup:Connect(signal, fn)` accepts any signal, so its callback is untyped.

## Security rules of thumb

1. **The server decides.** The client sends *what it wants* ("buy Sword"), never *what happened* ("I now have 90 coins").
2. **Validate every remote.** Give each [Network](Network.md) endpoint a `Schema` and a `RateLimit`. A schema of `Check.literal(table.unpack(Items.Ids))` rejects unknown items before your handler runs.
3. **Share names, not rules.** `Shared/Net` holds remote names. Schemas, rate limits, prices you charge and rewards you grant are applied on the server.
4. **Secrets live in `ServerStorage` or `ServerScriptService`.** Anything in `ReplicatedStorage` is public.
5. **Replicate deliberately.** [Replication](Replication.md) only sends what a service shares, and `ShareWith(player, ...)` keeps per-player values private.
