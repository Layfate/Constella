"""Builds the Wally and pesde packages and checks that each contains exactly
the library (src/shared/Constella) plus the files its registry needs.

Wally 0.3.2 ignores `include` and has no negated `exclude` patterns, so a new
top-level file could otherwise end up in the published package unnoticed.

Needs `wally` and `pesde` on PATH. Run from the repository root.
"""

import pathlib
import subprocess
import sys
import tarfile
import zipfile

LIBRARY = sorted(
    path.as_posix() for path in pathlib.Path("src/shared/Constella").rglob("*.luau")
)


def check(name, actual, extra):
    expected = sorted(LIBRARY + extra)
    actual = sorted(actual)
    if actual == expected:
        print(f"{name}: {len(actual)} files, exactly the library")
        return True
    print(f"::error::The {name} package doesn't contain exactly the library")
    for path in sorted(set(actual) - set(expected)):
        print(f"  unexpected: {path}")
    for path in sorted(set(expected) - set(actual)):
        print(f"  missing:    {path}")
    return False


def main():
    subprocess.run(["wally", "package", "--output", "wally.zip"], check=True)
    with zipfile.ZipFile("wally.zip") as archive:
        wally = [name for name in archive.namelist() if not name.endswith("/")]
    pathlib.Path("wally.zip").unlink()

    subprocess.run(["pesde", "install"], check=True)
    subprocess.run(["pesde", "publish", "--dry-run", "--yes"], check=True)
    with tarfile.open("package.tar.gz") as archive:
        pesde = [member.name.removeprefix("./") for member in archive.getmembers() if member.isfile()]
    pathlib.Path("package.tar.gz").unlink()

    ok = check("Wally", wally, ["LICENSE", "README.md", "default.project.json", "wally.toml"])
    ok = check("pesde", pesde, ["LICENSE", "README.md", "pesde.toml"]) and ok
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
