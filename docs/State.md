# State

```lua
local State = require(Packages.Constella.State)

local health = State.new(100)
local maxHealth = State.new(100)
local percent = State.computed({ health, maxHealth }, function(h, m) return h / m end)

percent:Observe(function(value) bar.Size = UDim2.fromScale(value, 1) end)
health:Set(50)
```

## Guarantees

- `Set` with a value equal to the current one does nothing. Equality is `==`, NaN counts as equal to NaN, and tables compare by reference. Use `Options.Equals` for anything else.
- Subscribers receive `(newValue, oldValue)` and run like [Signal](Signal.md) listeners: in order, with errors isolated.
- Every `Set` is a batch. Values are written first and notifications come afterwards. A computed state that depends on several sources therefore notifies once per change. For example, in a diamond `a -> (b, c) -> d`, `d` notifies once.
- `State.batch(fn)` groups writes so each state notifies at most once. A state that changes and then changes back inside a batch doesn't notify.
- `Destroy` disconnects every subscriber. A computed state also stops listening to its sources. `Set` on a destroyed state raises an error, and `Get` returns the last value.
- If subscribers keep writing to each other for more than 100 rounds in one flush, an "update loop" error is raised.

## Rules

- Compute and selector functions must be pure and must not yield.
- The function passed to `State.batch` must not yield.
- Computed states are read-only. They have no `Set` or `Update`.

## API

| Member | Description |
| --- | --- |
| `State.new(value, { Equals? }?)` | Writable `Value<T>` |
| `State.computed(sources, fn, { Equals? }?)` | Read-only `Computed<T>`. `fn` receives the source values in order |
| `State.select(source, fn, options?)` | Shorthand for a single-source computed state |
| `State.batch(fn)` | Delivers notifications once `fn` returns. Re-raises errors from `fn` after delivery |
| `state:Get()` | |
| `state:Set(value)` / `state:Update(fn)` | Writable states only |
| `state:Subscribe(fn)` | `fn(new, old)`. Returns a Connection (works with `Cleanup:Add`) |
| `state:Observe(fn)` | Calls `fn(current)` right away, then on every change |
| `state:Destroy()` / `state:IsDestroyed()` | |
| `State.is(value)` | Type check |

## UI bindings

```lua
local binding = State.bind(coinsLabel, "Text", coins, function(value)
	return `Coins: {value}`
end)
State.bind(healthBar, "Size", healthFraction, function(f) return UDim2.fromScale(f, 1) end)
```

`State.bind(instance, property, state, transform?)` sets the property straight away and again on every change. It works with writable and computed states.

- An invalid property or source fails immediately.
- The binding ends when you call `binding:Disconnect()` (or add it to a Cleanup) or when the instance is destroyed.

To get server values onto the client, see [Replication](Replication.md).

## Not included

Automatic dependency tracking. Computed states use explicit source lists.
