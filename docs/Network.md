# Network

Remotes that are owned by the server and safe by default.

```lua
-- Server (inside a service)
local Network = Constella.Network
local Check = Network.Check

local server = context.Cleanup:Add(Network.Server.new("Shop"))
local purchase = server:Function("Purchase", {
	Schema = { Check.literal("Sword", "Shield") },
	RateLimit = { Count = 2, Per = 1 },
})
purchase:SetHandler(function(player, item)
	return trySpend(player, PRICES[item])
end)
```

```lua
-- Client (inside a controller)
local shop = Constella.Network.Client.new("Shop")
local ok, result = shop:Function("Purchase", { Timeout = 5 }):Invoke("Sword")
```

## Security model

The server never trusts the client. Every request from a client passes these checks, in this order, before your handler runs:

| # | Check | Rejection reason |
| --- | --- | --- |
| 1 | The endpoint accepts client requests (it has a `Schema`) | `NotAccepted` |
| 2 | Per-player, per-endpoint token bucket | `RateLimited` |
| 3 | Payload size (default 4096 bytes), nesting depth (8) and value count (512) | `PayloadTooLarge` |
| 4 | `Schema` validators. Extra arguments are rejected | `InvalidArguments` |
| 5 | Your `Authorize(player, ...)` hook. Errors count as a rejection | `Unauthorized` |

When a request is rejected:

- An **event** request is dropped.
- A **function** call gets a generic code back: `"RateLimited"` or `"Rejected"`.
- If a handler fails, the client gets `"ServerError"`. The error text is never sent to the client.
- The detailed reason stays on the server. It's counted in `server:GetStats()`, passed to `OnReject`, and logged when you provide a `Logger`.

Other rules:

- **Only the server creates remotes.** Each `Server` owns one namespace folder (`ReplicatedStorage.ConstellaRemotes.<Namespace>`). Creating a second `Server` for the same namespace is refused, so it's always clear who owns a remote.
- **An event without a `Schema` goes from server to client only.** Client fires on it are rejected.
- **`Function` requires a `Schema`** (use `{}` for no arguments).
- **The server never calls `InvokeClient`**, because a client could hang it. Use events to send data to clients.
- **Rate limiting is on by default** (30 requests per second per player, per endpoint). Pass `RateLimit = false` only for endpoints you rate-limit some other way.
- **Leaving and rejoining:** per-player state is dropped on `PlayerRemoving`, so a player who rejoins starts with a fresh bucket and nothing leaks.

Validators are your code too (custom functions, `Check.refine` predicates). If one throws, the error goes to `OnError` as a server bug and the request is rejected as `InvalidArguments`. The client never sees the error text.

Validation only checks that the *shape* of a request is acceptable. Your handler still decides whether it's *allowed* in the game (for example, whether the player can afford the item). Never accept prices, rewards or outcomes from the client.

## Client vs server API

| | Server (`Network.Server`) | Client (`Network.Client`) |
| --- | --- | --- |
| Create | `Server.new(namespace, options?)` creates the folder | `Client.new(namespace, options?)` waits for the folder (default timeout 10s) |
| Events | `server:Event(name, config?)` | `client:Event(name)` |
| Receive | `event:Connect(function(player, ...) end)`. Only validated requests arrive | `event:Connect(function(...) end)` |
| Send | `event:Fire(player, ...)`, `FireAll`, `FireList`, `FireExcept` | `event:Fire(...)` |
| Functions | `server:Function(name, config)` then `fn:SetHandler(handler)` | `client:Function(name, { Timeout?, MaxInFlight? })` |
| Call | Not available (the server never invokes clients) | `fn:Invoke(...)` returns `(true, ...)` or `(false, code)` |
| Errors | Handler and validator errors go to `OnError`. Rejections go to `OnReject` and `GetStats` | Codes: `Timeout`, `TooManyRequests`, `RateLimited`, `Rejected`, `Unavailable`, `ServerError`, `NetworkError` |
| Cleanup | `server:Destroy()` removes the folder and every remote | `client:Destroy()` disconnects handlers |

`Server.new` raises if it's used on a client, and `Client.new` raises if it's used on the server.

`Invoke` never hangs: it returns `(false, "Timeout")` after the timeout (default 10 seconds). Luau can't cancel a timed-out `InvokeServer`, because the engine owns that wait, so its thread stays suspended until the server answers. To keep that bounded, each client function allows at most `MaxInFlight` calls (default 8) to be outstanding, counting timed-out ones that haven't come back yet. Beyond that, `Invoke` returns `(false, "TooManyRequests")` straight away without contacting the server. `fn:GetInFlight()` reports the current count.

## Endpoint config

| Field | Default | Description |
| --- | --- | --- |
| `Schema` | none | An array of validators, one per argument |
| `RateLimit` | `{ Count = 30, Per = 1 }` | `{ Count, Per }`, or `false` to disable |
| `MaxPayloadBytes` | 4096 | Estimated size limit |
| `Authorize` | none | `(player, ...) -> boolean` |
| `Unreliable` | `false` | Events only: creates an `UnreliableRemoteEvent` |

Server options: `Parent`, `OnReject(player, endpoint, reason, detail)`, `OnError(message)`, `Logger` (a [Debug](Debug.md) logger) and `Clock` (for tests).

## Validators (`Network.Check`)

Each validator is a function `(value) -> (ok, reason?)`, so you can write your own.

| Validator | Accepts |
| --- | --- |
| `Check.string(maxLength = 200)` | A valid UTF-8 string of at most `maxLength` bytes |
| `Check.number(min?, max?)` | A finite number (no NaN, no infinity) |
| `Check.integer(min?, max?)` | A finite whole number |
| `Check.boolean()` | `true` / `false` |
| `Check.literal(...)` | One of the listed values |
| `Check.optional(v)` | `nil`, or a value `v` accepts |
| `Check.union(...)` | A value any of the validators accepts |
| `Check.array(v, maxLength = 50)` | A dense array: no holes, no extra keys |
| `Check.record({ Key = v })` | Exactly these string keys. Unknown keys are rejected |
| `Check.map(k, v, maxEntries = 50)` | A key/value table |
| `Check.instance(className?, ancestor?)` | An Instance of that class, optionally inside `ancestor` |
| `Check.vector3(maxMagnitude?)` | A Vector3 with finite components |
| `Check.cframe()` | A CFrame with finite components |
| `Check.enum(Enum.X)` | An EnumItem of that Enum |
| `Check.refine(v, predicate, reason?)` | A value `v` accepts that also passes `predicate` |
| `Check.any()` | Anything. Avoid this for client input |

## Testing

`tests/server/Network.spec.luau` feeds stand-in players through the same internal entry points that remotes use. It covers malformed payloads, forged payloads, oversized payloads, rate limits, rejoining, authorization and handler errors.

The Play-mode integration test (`tests/*/NetworkIntegration.*`) acts as a hostile client against real remotes. The server then checks its own accept/reject counts.
