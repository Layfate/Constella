"""Install the just-published Wally version in a clean consumer and compare its library.

Run after publishing, from the tagged repository root. Never publishes anything.
"""

from pathlib import Path
import subprocess
import tempfile
import time
import tomllib


def main():
    package = tomllib.loads(Path("wally.toml").read_text(encoding="utf-8"))["package"]
    name, version = package["name"], package["version"]
    with tempfile.TemporaryDirectory(prefix="constella-consumer-") as directory:
        consumer = Path(directory)
        (consumer / "wally.toml").write_text(
            '[package]\nname = "constella-ci/consumer"\nversion = "0.0.0"\n'
            'registry = "https://github.com/UpliftGames/wally-index"\nrealm = "shared"\n'
            f'\n[dependencies]\nConstella = "{name}@{version}"\n',
            encoding="utf-8",
        )
        for attempt in range(3):
            result = subprocess.run(["wally", "install", "--project-path", directory], check=False)
            if result.returncode == 0:
                break
            if attempt == 2:
                raise RuntimeError(f"Clean consumer could not install {name}@{version}")
            time.sleep(5)
        candidates = [
            path.parent for path in (consumer / "Packages").rglob("init.luau")
            if f'local VERSION = "{version}"' in path.read_text(encoding="utf-8")
        ]
        if len(candidates) != 1:
            raise RuntimeError(f"Expected one installed Constella {version}, got {len(candidates)}")
        installed = candidates[0]
        library = Path("src/shared/Constella")
        for source in library.rglob("*.luau"):
            target = installed / source.relative_to(library)
            if not target.is_file() or target.read_text(encoding="utf-8") != source.read_text(encoding="utf-8"):
                raise RuntimeError(f"Consumer library differs from release: {source}")
        print(f"Clean consumer installed {name}@{version}; every library module matches the release")


if __name__ == "__main__":
    main()
