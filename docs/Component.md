# Component

Attaches behaviour to every Instance that has a CollectionService tag.

```lua
local Spinner = { Tag = "Spinner" }

function Spinner:Start()
	self.Cleanup:Connect(RunService.Heartbeat, function(dt)
		self.Instance.CFrame *= CFrame.Angles(0, dt, 0)
	end)
end

local spinners = Component.new(Spinner)
spinners:Run()
```

## Definition

| Field | Description |
| --- | --- |
| `Tag` | The CollectionService tag (required) |
| `Ancestors` | Instances count only while they're inside one of these. Default `{ workspace }` |
| `Filter(instance)` | Return `true` to accept an instance (for example, `instance:IsA("BasePart")`) |
| `Start(self)` | Runs on attach, on its own thread |
| `Stop(self)` | Runs on detach, before `self.Cleanup` is destroyed |
| any other function | Becomes a method on each object (`self:Method()`) |

Each object has `self.Instance`, `self.Cleanup` (a [Cleanup](Cleanup.md) that's destroyed on detach) and `self.Component` (the manager).

## Guarantees

- **Ancestry safety.** A tagged instance outside `Ancestors` isn't attached, so tagged templates in ServerStorage are ignored. When an instance moves out, or streams out on a client, it's detached. When it moves back, a fresh object is attached.
- **Detach order** is: cancel a suspended `Start` thread, then `Stop`, then `Cleanup:Destroy()`, then the `Removed` event. This applies to manager destruction, tag removal and streaming/ancestry removal. A Start that detaches itself is already running and must return cooperatively. Errors in Stop or Cleanup are reported.
- **Start errors.** If `Start` errors before it yields, the object is detached, the error is reported and `Added` doesn't fire. An error after a yield is reported, and the object stays attached.
- **Destroy** on the manager detaches every object and stops observing the tag.

## API

| Member | Description |
| --- | --- |
| `Component.new(definition, { OnError? }?)` | Creates the manager. Nothing happens until `Run` |
| `manager:Run()` | Attaches to existing tagged instances and watches for new ones. Can be called once |
| `manager.Added` / `manager.Removed` | Signals that receive the object |
| `manager:Get(instance)` / `manager:GetAll()` | |
| `manager:Destroy()` | |

Tag and ancestry events can be deferred (Workspace.SignalBehavior), so changes take effect at the next resumption point, not instantly.
