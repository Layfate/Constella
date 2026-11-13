# Pool

Bounded reuse of objects such as projectiles, effects and UI rows.

```lua
local bullets = Pool.instances(BulletTemplate, { MaxIdle = 16, MaxActive = 32, Prewarm = 8 })

local bullet = bullets:TryAcquire()
if bullet then
	bullet.CFrame = origin
	bullet.Parent = workspace
	task.delay(1, bullets.Release, bullets, bullet)
end
```

## Guarantees

- **Bounded active count.** `MaxActive` caps how many objects can be out at once. `TryAcquire` returns `nil` at the cap, and `Acquire` raises.
- **Bounded memory.** `MaxIdle` (default 64) caps how many released objects are kept. Any extra objects are destroyed when they're released.
- **Deterministic release.** Releasing an object that isn't currently acquired from this pool raises an error. That covers releasing twice and releasing an object from another pool.
- **Safe reset.** If `Reset` fails, the object is destroyed instead of being reused in an unknown state, and the error is raised.
- **Destroy.** Idle objects are destroyed immediately. Objects still acquired are destroyed when they're released.

## API

| Member | Description |
| --- | --- |
| `Pool.new({ Create, Reset?, OnAcquire?, Destroy?, MaxIdle?, MaxActive?, Prewarm? })` | A generic pool. `Destroy` defaults to `:Destroy()` |
| `Pool.instances(template, { Reset?, MaxIdle?, MaxActive?, Prewarm? }?)` | Clones `template`. Released clones are set to `Parent = nil` after your Reset runs |
| `pool:Acquire()` / `pool:TryAcquire()` | |
| `pool:Release(object)` | |
| `pool:IsActive(object)` | |
| `pool:Prewarm(count)` | Creates idle objects, up to `MaxIdle` |
| `pool:Clear()` | Destroys the idle objects |
| `pool:GetStats()` | `{ Idle, Active, Created, Destroyed, Reused }` |
| `pool:Destroy()` | |

Objects must be unique values (Instances or tables). A pool of plain numbers or strings can't tell the copies apart.
