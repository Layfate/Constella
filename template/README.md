# Constella starter game

A small working game laid out the way [Game layout](https://github.com/Layfate/Constella/blob/main/docs/GameLayout.md) recommends: saved coins, a welcome reward, a server-checked shop and a HUD. Copy this folder to start a new game.

```
src/
├── shared/    → ReplicatedStorage.Shared       Items, Net
├── server/    → ServerScriptService.Server      Main.server + Services/
├── storage/   → ServerStorage                   Config/ (server-only)
└── client/    → StarterPlayerScripts.Client     Main.client + Controllers/
Packages/      → ReplicatedStorage.Packages       Constella goes here
```

## Use it

1. Copy `template/` somewhere new.
2. Put Constella in `Packages/`. The simplest way is to download `Constella.rbxm` from the [latest release](https://github.com/Layfate/Constella/releases/latest) into `Packages/`. Rojo syncs `.rbxm` files as-is.
3. Run `rojo serve` (or `rojo build -o Game.rbxl`) and press Play.

With Wally, add `Constella = "layfate/constella@0.3.6"` to a `wally.toml` and run `wally install` instead. Run [wally-package-types](https://github.com/JohnnyMorganz/wally-package-types) afterwards so type annotations like `Constella.Context` resolve.

## Before you publish

- Swap `MemoryAdapter` for ProfileStore in `PlayerDataService` (instructions at the top of that file). MemoryAdapter doesn't save anything.
- Replace the HUD with your own UI.

## Developing the template inside the Constella repo

`template.project.json` at the repository root syncs the template with the library source, for testing and type checking:

```bash
rojo build template.project.json -o build/template.rbxl
```
