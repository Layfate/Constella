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
- **Leaving and rejoining:** per-player state is dropped on `PlayerRemoving`, so a player who rejoins starts with a fresh bucket and nothing leaks. A request that arrives after `PlayerRemoving` is dropped (a function answers `Unavailable`), so it can't create new state for a player who is gone.

### What the payload check protects (and what it doesn't)

The size, depth and value-count check runs **after** Roblox has already received and decoded the request, because a remote's arguments only reach Luau once the engine has deserialized them. So the check:

- **does protect your server's CPU time and logic:** an oversized or deeply nested request is rejected before validators, `Authorize` or your handler touch it, and it can't make them loop over huge tables;
- **doesn't save bandwidth or decoding work:** the bytes have already crossed the network, and Roblox has already decoded them. Roblox's own remote limits and throttling cover that layer.

The size is Constella's estimate of the decoded values, not the exact wire size (see [Known limitations](README.md)). If you need to shrink what's sent over the network, encode it yourself, for example into a `buffer`, or use a dedicated serializer such as Zap or Blink for that traffic. Constella's checks still apply to whatever reaches the handler.

Validators are your code too (custom functions, `Check.refine` predicates). If one throws, the error goes to `OnError` as a server bug and the request is rejected as `InvalidArguments`. The client never sees the error text.

Validation only checks that the *shape* of a request is acceptable. Your handler still decides whether it's *allowed* in the game (for example, whether the player can afford the item). Never accept prices, rewards or outcomes from the client.

## Contracts (typed endpoints)

A contract declares one namespace's endpoints in a ModuleScript that both sides require (for example in `ReplicatedStorage.Shared`): each endpoint's name, its argument Schema and, for the type checker, its argument and result types. The server and the client then get **typed** endpoints from it, so a handler, a call and the declaration can't drift apart without a type error.

```lua
-- ReplicatedStorage.Shared.ShopContract
local Constella = require(ReplicatedStorage.Packages.Constella)
local Contract, Check = Constella.Network.Contract, Constella.Network.Check

return Contract.define({
	Namespace = "Shop",
	-- client -> server, answered by the server: (itemId) -> (result, balance)
	Purchase = Contract.fn({ Check.string(20) }) :: Constella.ContractFunction<(string), (string, number)>,
	-- server -> client only (no Schema)
	CoinsChanged = Contract.event() :: Constella.ContractEvent<(number)>,
})
```

```lua
-- Server
local server = Network.Server.new(ShopContract.Namespace)
local purchase = server:FunctionOf(ShopContract.Purchase, {
	RateLimit = { Count = 2, Per = 1 },
	Authorize = function(player, itemId) -- typed: (Player, string)
		return isUnlocked(player, itemId)
	end,
})
purchase:SetHandler(function(player, itemId) -- itemId: string
	return "Purchased", 90 -- checked against (string, number)
end)
server:EventOf(ShopContract.CoinsChanged):Fire(player, 90) -- Fire(player, "90") is a type error

-- Client
local shop = Network.Client.new(ShopContract.Namespace)
local ok, result, balance = shop:FunctionOf(ShopContract.Purchase):Invoke("Sword") -- Invoke(5) is a type error
shop:EventOf(ShopContract.CoinsChanged):Connect(function(coins) -- coins: number
end)
```

- **Nothing changes at runtime.** `EventOf` and `FunctionOf` create (or find) the same endpoint `Event` and `Function` do, behind the same five gates, with the contract's Schema. A request through a contract endpoint costs the same as through a plain one ([Benchmarks](Benchmarks.md)). `Event(name)` and `Function(name)` are unchanged.
- **Server-only settings stay on the server.** `RateLimit`, `MaxPayloadBytes`, `Authorize` and `Unreliable` go in the server's config. A `Schema` there is an error, because two Schemas could disagree.
- **Schemas are public.** A contract is shared code, so clients can read its Schemas. A Schema checks the *shape* of a request, which is no secret. A check that depends on server-only knowledge (ownership, prices, cooldowns) belongs in `Authorize` or the handler, never in a contract's `Check.refine`.
- `Contract.define` names each endpoint after its key, checks the names, and freezes the contract and its Schemas: changing the array you passed has no effect afterwards. `Namespace` is required. An endpoint can be in one contract only, and `EventOf`/`FunctionOf` refuse an endpoint from another namespace or a hand-made table.
- **Types.** Write them with the root types `Constella.ContractEvent<T...>` and `Constella.ContractFunction<A..., R...>`. Exported types are only reachable through a module bound directly to `require`, so `Constella.Network.Contract.Event` doesn't work as a type. The typed endpoints are `Constella.TypedServerEvent<T...>`, `TypedServerFunction<A..., R...>`, `TypedClientEvent<T...>` and `TypedClientFunction<A..., R...>`.
- **Limits.** Luau can't check that a Schema matches the declared types: `Contract.fn({ Check.number() }) :: Constella.ContractFunction<(string), ()>` type-checks. Keep each cast next to its Schema. On the client, `Invoke` still returns `(boolean, ...any)`, because on failure the second value is an error code, not the first result.

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
| Contracts | `server:EventOf(endpoint, config?)`, `server:FunctionOf(endpoint, config?)` | `client:EventOf(endpoint)`, `client:FunctionOf(endpoint, options?)` |
| Cleanup | `server:Destroy()` removes the folder and every remote | `event:Destroy()` disconnects that event's handlers; `client:Destroy()` disconnects every handler connected through the client |

`Server.new` raises if it's used on a client, and `Client.new` raises if it's used on the server.

A client event is held by its client only while it has connections, so events that are looked up and dropped, or destroyed, can be collected. Connections the game disconnects itself are dropped from the event as it goes. Before 0.4.0, every `client:Event(name)` call and every connection was kept until `client:Destroy()`, so looking an event up once per respawn grew memory without bound.

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

Server options also include `MaxInFlightPerPlayer` (16), `MaxInFlight` (256) and `RejectLogInterval` (5 seconds). Concurrent request limits apply across every endpoint in the namespace, before validators or authorization can yield, and stay occupied until all handlers return. Excess events are dropped; functions return `RateLimited`. `GetStats()[endpoint].Rejected.Busy` counts concurrency rejections, and `InFlight` reports currently occupied requests. A player disconnect does not free slots still occupied by running work.

Logger warnings aggregate rejection counts per endpoint and reason. The first rejection logs immediately; subsequent warnings occur when another rejection arrives after the interval. `Count` includes rejections since the preceding warning. `OnReject` and `GetStats` still count every rejection. Set `RejectLogInterval = 0` to log every rejection. Client `MaxInFlight` limits protect that client; enforce server limits independently.

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

`tests/server/Network.spec.luau` feeds stand-in players through the same internal entry points that remotes use. It covers malformed payloads, forged payloads, oversized payloads, rate limits, rejoining, authorization and handler errors. `tests/server/Contract.spec.luau` runs the same gates through contract endpoints and covers the client-event fixes. `tests/types/` checks that misusing a contract (a wrong argument, handler or result type) is a type error.

The Play-mode integration test (`tests/*/NetworkIntegration.*`) acts as a hostile client against real remotes, including contract endpoints declared in `tests/shared/IntegrationContract.luau`. The server then checks its own accept/reject counts.
