"""Downloads the benchmark comparison libraries pinned in .github/bench-libs.json.

Each file comes from raw.githubusercontent.com at its pinned commit and must
match its SHA-256, or nothing is written. Then a Rojo project is written that
adds them (as ServerStorage.BenchmarkLibs) and the benchmark suite to a base
project, optionally with a second build of the package as
ReplicatedStorage.Packages.ConstellaBaseline.

Usage:
  python fetch_bench_libs.py [--out build/libs] [--base ci.project.json]
                             [--baseline build/baseline/src/shared/Constella]
                             [--project bench.generated.project.json]
"""

import argparse
import hashlib
import json
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]


def fetch(lib):
    url = f"https://raw.githubusercontent.com/{lib['repo']}/{lib['commit']}/{lib['path']}"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != lib["sha256"]:
        sys.exit(f"SHA-256 mismatch for {lib['label']} ({url}): got {digest}, expected {lib['sha256']}")
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="build/libs")
    parser.add_argument("--base", default="ci.project.json")
    parser.add_argument("--baseline", default=None)
    parser.add_argument("--project", default="bench.generated.project.json")
    args = parser.parse_args()

    pins = json.loads((ROOT / ".github/bench-libs.json").read_text(encoding="utf-8"))["libs"]
    out = ROOT / args.out
    for lib in pins:
        data = fetch(lib)
        target = out / lib["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        print(f"ok  {lib['label']:45} {lib['sha256'][:16]}...")

    project = json.loads((ROOT / args.base).read_text(encoding="utf-8"))
    tree = project["tree"]
    if args.baseline:
        tree["ReplicatedStorage"]["Packages"]["ConstellaBaseline"] = {"$path": args.baseline}
    storage = tree.setdefault("ServerStorage", {"$className": "ServerStorage"})
    storage["ConstellaBenchmarks"] = {"$path": "benchmarks"}
    libs = {"$className": "Folder"}
    rel = pathlib.PurePosixPath(args.out)
    for lib in pins:
        name = lib["name"]
        if "/" in name:
            continue  # a child of another library's folder
        file = pathlib.PurePosixPath(lib["file"])
        # A library made of several files is a folder with init.luau.
        libs[name] = {"$path": str(rel / (file.parent if file.name.startswith("init.") else file))}
    storage["BenchmarkLibs"] = libs
    (ROOT / args.project).write_text(json.dumps(project, indent="\t"), encoding="utf-8")
    print(f"wrote {args.project}")


if __name__ == "__main__":
    main()
