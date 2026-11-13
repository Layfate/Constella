# Cleanup

```lua
local Cleanup = require(Packages.Constella.Cleanup)

local cleanup = Cleanup.new()
local part = cleanup:Add(Instance.new("Part"))
cleanup:Connect(part.Touched, onTouched)
cleanup:Add(task.spawn(loop))
cleanup:Add(function() print("done") end)
cleanup:Destroy()
```

## What it can clean

| Value | Action |
| --- | --- |
| `function` | Called |
| `thread` | `task.cancel` (deferred if the thread is currently running) |
| `Instance` | `:Destroy()` |
| `RBXScriptConnection` | `:Disconnect()` |
| table with `Destroy`, `Disconnect` or `Cancel` | The first of those methods it has is called (Signals, Connections, States, nested Cleanups, Promises) |
| anything else | Pass the method name: `cleanup:Add(tween, "Cancel")` |

## Guarantees

- Resources are disposed in reverse order of addition (LIFO).
- `Clean` and `Destroy` are idempotent, and no resource is disposed twice.
- If a disposal fails, all the other resources are still cleaned, and one aggregated error is raised afterwards.
- After `Destroy`, anything you `Add` is disposed immediately. This makes it safe when async work finishes after its owner is gone.
- Resources added by a disposer while `Clean` is running are cleaned in the same pass.

## API

| Member | Description |
| --- | --- |
| `Cleanup.new()` | |
| `cleanup:Add(resource, method?)` | Returns `resource` |
| `cleanup:Set(key, resource, method?)` | Replaces (and cleans) whatever was stored under `key`. `Set(key, nil)` cleans and clears the key |
| `cleanup:Get(key)` | |
| `cleanup:Remove(keyOrResource)` | Cleans one resource now. Returns `false` if it wasn't found. Keys are checked first |
| `cleanup:Detach(keyOrResource)` | Stops tracking without cleaning. Returns the resource |
| `cleanup:Connect(signal, fn)` | Connects and tracks. Works with RBXScriptSignal and Constella Signal |
| `cleanup:Extend()` | A child Cleanup that's destroyed along with this one |
| `cleanup:AttachToInstance(instance)` | Destroys this Cleanup when `instance.Destroying` fires |
| `cleanup:Clean()` | Cleans everything. The Cleanup stays usable |
| `cleanup:Destroy()` | Cleans everything and marks it destroyed |
| `cleanup:Count()` / `cleanup:IsDestroyed()` | |
| `Cleanup.is(value)` | Type check |

Disposers shouldn't yield. If one does, `Clean` yields too.
