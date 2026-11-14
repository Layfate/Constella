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
benchmarks/             benchmark suite (see docs/Benchmarks.md)
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

### Testing against real ProfileStore

Add [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) (verified with 1.0.3) to the dev place as a ModuleScript named `ProfileStore` in `ServerStorage`. `tests/server/ProfileStore.spec.luau` then runs Data against it, always in ProfileStore's mock mode, so no real data is touched. Without ProfileStore, those tests are reported as skipped.

## Benchmarks

```lua
print(require(game.ServerScriptService.ConstellaBenchmarks.RunBenchmarks)())
```

Run this in the Studio command bar (Edit mode). To compare with other libraries, add `Signal` (sleitnick/signal) and `Trove` (sleitnick/trove) ModuleScripts to `ServerStorage.BenchmarkLibs`. If you change a hot path, re-run the benchmarks and update [docs/Benchmarks.md](docs/Benchmarks.md).

## Lint, format and type check

```bash
selene src tests examples benchmarks
stylua src tests examples benchmarks     # add --check to verify without changing files
```

Type checking uses [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) with Roblox definitions and a Rojo sourcemap:

```bash
rojo sourcemap dev.project.json --output sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
  --definitions=@roblox=globalTypes.d.luau --base-luaurc=.luaurc \
  src tests examples benchmarks
```

`globalTypes.d.luau` comes from the luau-lsp repository, at the version pinned in [`.github/workflows/ci.yml`](.github/workflows/ci.yml). GitHub Actions runs all three checks with the same pinned versions on every push and pull request.

## Conventions

- `--!strict` and exported types on every public API.
- Constructors are `X.new(...)`. Module-level functions are lowerCamelCase (`State.computed`). Methods and option keys are PascalCase (`:Connect`, `{ OnError = ... }`).
- Every class has `X.is(value)`. Every disposable object has an idempotent `:Destroy()`, so it can be added to a Cleanup.
- No globals and no singleton services. Modules load lazily from the root.
- Fail loudly. Invalid input raises an error that names the problem. Errors that can't reach a caller go to an `OnError` hook, or are re-raised on a separate thread. They're never swallowed.
- Never trust the client. Server-only modules refuse to run on clients.

More detail is in [docs/Architecture.md](docs/Architecture.md).

## Tests in CI

The `roblox-tests` job builds `ci.project.json` (the package, the tests in `ServerStorage` and a pinned ProfileStore), publishes it to a dedicated CI experience, and runs the suite there with Open Cloud's Luau execution API ([`.github/scripts/roblox_tests.py`](.github/scripts/roblox_tests.py)). It needs:

- the repository secret `ROBLOX_API_KEY`: a user API key with `universe-places:write` and `universe.place.luau-execution-session:read`/`write`, limited to the CI experience;
- the repository variables `ROBLOX_UNIVERSE_ID` and `ROBLOX_PLACE_ID` of that experience.

Keep the CI place closed in Studio: while it's open, publishing to it fails with HTTP 409.

The integration tests also work in Studio's **Server & Clients** mode: every client runs its half, and the server checks each player against its own counts.

## Releasing

1. Set the new version in `src/shared/Constella/init.luau`, `wally.toml`, `pesde.toml`, the README badge and install lines, `docs/README.md` and `tests/server/Root.spec.luau`.
2. Turn the changelog's Unreleased section into the new version, with upgrade notes for any behaviour change.
3. Run the whole suite in Studio, push, and wait for CI.
4. Publish a GitHub release with the tag `vX.Y.Z`. The release workflow builds `Constella.rbxm` from that tag and attaches it.

## Pull requests

- Add or update tests for any behaviour you change, and make sure the whole suite passes in Studio.
- CI must pass: format, lint, type check, and the test suite on a Roblox server. Pull requests from forks don't get the Open Cloud key, so that last job is skipped for them and a maintainer runs it.
- Update the module's page in `docs/` and add an entry to `CHANGELOG.md`.
- Don't make performance claims without a benchmark to back them up.
