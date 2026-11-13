# Contributing to Constella

Thanks for helping. This page covers setup, tests and the conventions the codebase follows.

## Setup

```bash
rokit install                  # rojo, wally, selene, stylua
rojo serve dev.project.json    # then connect from the Rojo plugin in Studio
```

Or build the dev place as a file with `rojo build dev.project.json -o ConstellaDev.rbxl`.

## Project layout

```
src/shared/Constella/   the package (ReplicatedStorage.Packages.Constella)
src/server/             demo server app (player data, rewards, a networked shop)
src/client/             demo client app (replicated coins label, shop client)
examples/               one zero-setup script per module
tests/server/           unit tests (TestKit + *.spec modules) and the server halves of integration tests
tests/client/           client halves of the Network and Replication integration tests
docs/                   reference documentation
assets/                 logo files
default.project.json    package build (Wally, pesde, .rbxm)
dev.project.json        full dev place: package, demo, examples and tests
```

## Tests

Press **Play** in the dev place. The unit tests run automatically and print:

```
[Constella tests] N passed, M failed
```

Two integration tests also run, across a real server and client:

- **Network:** a hostile client sends valid, malformed, forged and excessive requests. The server checks that it accepted and rejected exactly what it should have.
- **Replication:** the client checks it sees its own private values but never another player's, that public updates arrive, and that `State.bind` updates a real UI label.

Each prints `[Constella integration] ... PASS`.

To run the unit tests without pressing Play, use the Studio command bar:

```lua
require(game.ServerScriptService.ConstellaTests.RunTests)()
```

A spec is a ModuleScript named `Something.spec` that returns `function(t, Constella)` and uses `t.describe`, `t.it` and `t.expect`. See [tests/server/TestKit.luau](tests/server/TestKit.luau).

## Lint and format

```bash
selene src tests examples
stylua src tests examples      # add --check to verify without changing files
```

## Conventions

- `--!strict` and exported types on every public API.
- Constructors are `X.new(...)`. Module-level functions are lowerCamelCase (`State.computed`). Methods and option keys are PascalCase (`:Connect`, `{ OnError = ... }`).
- Every class has `X.is(value)`. Every disposable object has an idempotent `:Destroy()`, so it can be added to a Cleanup.
- No globals and no singleton services. Modules load lazily from the root.
- Fail loudly. Invalid input raises an error that names the problem. Errors that can't reach a caller go to an `OnError` hook, or are re-raised on a separate thread. They're never swallowed.
- Never trust the client. Server-only modules refuse to run on clients.

More detail is in [docs/Architecture.md](docs/Architecture.md).

## Pull requests

- Add or update tests for any behaviour you change, and make sure the whole suite passes in Studio.
- Update the module's page in `docs/` and add an entry to `CHANGELOG.md`.
- Don't make performance claims without a benchmark to back them up.
