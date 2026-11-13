# Zone

Enter and exit detection for players, parts, models or anything else that has a position.

```lua
local zone = Zone.new(workspace.ShopArea, { ExitPadding = 1 })
zone:TrackPlayers()
zone.Entered:Connect(function(player) openShop(player) end)
zone.Exited:Connect(function(player) closeShop(player) end)
```

## Shapes

| Shape | Notes |
| --- | --- |
| A `BasePart` | Follows the part as it moves. The zone is destroyed when the part is. Ball-shaped `Part`s are spheres; every other part is treated as its box |
| `{ CFrame = cf, Size = size }` | A fixed, possibly rotated, box |
| `{ Position = p, Radius = r }` | A fixed sphere |

## How it works

- Tracked items are point-tested every `Interval` seconds (default 0.1) on Heartbeat, or whenever you call `zone:Step()` (set `AutoUpdate = false` for full control).
- A cheap bounding-sphere distance check rejects far-away items before the exact box test runs.
- **ExitPadding** adds hysteresis. An item that's inside only exits once it's more than `ExitPadding` studs outside the zone, which stops events flickering at the edges. Entering always uses the real boundary.
- Events fire after every item has been evaluated, in tracking order, so handlers can safely call Track or Untrack.
- If an item has no position (for example, a player with no character), it counts as outside.

## Item positions

| Item | Position |
| --- | --- |
| `Player` | The character's `HumanoidRootPart` |
| `BasePart` | `Position`. The item is untracked automatically when it's destroyed |
| `Model` | `GetPivot().Position` |
| `Attachment` | `WorldPosition` |
| anything else | `zone:Track(item, function() return position end)` |

## API

| Member | Description |
| --- | --- |
| `Zone.new(shape, { Interval?, ExitPadding?, AutoUpdate?, OnError? }?)` | |
| `zone.Entered` / `zone.Exited` | [Signals](Signal.md) that receive the item |
| `zone:Track(item, getPosition?)` / `zone:Untrack(item)` | Untracking an item that's inside fires `Exited` |
| `zone:TrackPlayers()` | Tracks all current and future players, and untracks them when they leave |
| `zone:Contains(position, padding?)` | |
| `zone:IsInside(item)` / `zone:GetInside()` | |
| `zone:Step()` | Evaluates now |
| `zone:Destroy()` | Stops everything. `Exited` is **not** fired for items that were inside |

## Limitations

Zones test points, not volumes: a part counts as inside when its *position* is inside. Mesh and union shapes aren't supported; use a box or sphere that covers the area. Each zone has its own Heartbeat connection. A shared spatial index for hundreds of zones is a possible future addition.
