# Core / App

`Constella.App` (also available as `Constella.Core.App`) manages a set of *definitions*. On the server these are called services, and on a client they're called controllers. The App runs their lifecycle in dependency order.

```lua
local app = Constella.App.new({ Name = "Server" })
app:Add(require(script.Services.DataService))
app:AddModules(script.Services) -- or add a whole folder explicitly
app:Start()
game:BindToClose(function() app:Stop() end)
```

## Definitions

```lua
local InventoryService = {
	Name = "InventoryService",                 -- required, unique per app
	Dependencies = { "PlayerDataService" },    -- optional
	Environment = "Server",                    -- optional: "Server" | "Client" | "Shared"
}

function InventoryService:Init(context) end  -- optional, may yield
function InventoryService:Start(context) end -- optional, runs on its own thread
function InventoryService:Stop(context) end  -- optional

return InventoryService
```

`self` is the definition table. `context` contains:

| Field | Description |
| --- | --- |
| `context.App` | The owning app |
| `context.Name` | The definition's name |
| `context.Cleanup` | A [Cleanup](Cleanup.md), destroyed after `Stop` |
| `context:Get(name)` | Returns a dependency. Raises if `name` isn't in `Dependencies` |

## Lifecycle

1. **`Add`** checks the shape of the definition. It rejects duplicate names, self-dependencies and wrong `Environment` values (a client app refuses `Environment = "Server"`). It only works before `Start`.
2. **`Start`** first resolves the graph. Missing dependencies (all of them listed at once) and cycles (shown as `A -> B -> C -> A`) fail before any user code runs.
3. **Init** runs sequentially in dependency order, and each Init can yield. Connect to other services' signals here. They begin emitting in their own `Start`, which runs only after every `Init` has finished.
4. **Start** also runs in dependency order, each one on its own thread. An error thrown before the first yield fails startup. An error thrown after a yield goes to `OnError` (by default it's raised on a new thread) and the app keeps running.
5. **Failed startup**: `Stop` runs in reverse order for every definition whose `Init` was called, and each one's `context.Cleanup` is destroyed. Then `Start` raises. The app's state becomes `"Failed"` and it can't be restarted. Write `Stop` so it copes with `Start` never having run.
6. **`Stop`** runs `Stop` in reverse dependency order, then destroys each Cleanup. Errors are collected and raised together after everything has stopped. Calling it again does nothing.

The order is deterministic. Definitions are visited in registration order and dependencies in the order they're declared.

## API

| Member | Description |
| --- | --- |
| `App.new(options?)` | `options.Name`, `options.Environment` (`"Server"`/`"Client"`, auto-detected), `options.OnError` |
| `app:Add(definition)` | Registers a definition and returns it |
| `app:AddModules(container, { Recursive?, Filter? }?)` | Requires and adds the ModuleScripts in `container`, sorted by full name |
| `app:Start()` | Runs Init then Start. Can only be called once |
| `app:AwaitStart()` | Yields until the app is running. Raises if startup failed |
| `app:Stop()` | Stops the app. Idempotent |
| `app:Get(name)` / `app:Has(name)` | Looks up a definition |
| `app:GetOrder()` | The resolved startup order (names) |
| `app:GetState()` | `Idle`, `Starting`, `Running`, `Stopping`, `Stopped` or `Failed` |
| `app.Started` / `app.Stopped` | [Signals](Signal.md) |
| `App.is(value)` | Type check |

## Client vs server

Create one app per environment. A server app can't contain `Environment = "Client"` definitions, and a client app can't contain `Environment = "Server"` ones. Use `"Shared"` (or leave the field out) for code that runs on both. Keep server-only modules in `ServerScriptService` or `ServerStorage` so they never replicate to clients. The environment check catches mistakes; it doesn't replace putting code in the right place.
