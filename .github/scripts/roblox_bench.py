"""Runs Constella's benchmarks on a real Roblox server through Open Cloud.

The place file (see the "Build the benchmark place" step in ci.yml) holds
this build as ReplicatedStorage.Packages.Constella and, optionally, a
baseline build as ReplicatedStorage.Packages.ConstellaBaseline. Both are
measured in the same server session, alternating case by case, so they can
be compared directly. The Markdown report is printed and, on GitHub Actions,
added to the job summary.

Environment: ROBLOX_API_KEY, ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID.

Usage: python roblox_bench.py <place-file.rbxl> [runs]
"""

import os
import sys

from roblox_tests import Roblox

SCRIPT = """
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local packages = ReplicatedStorage.Packages
local builds = { { Name = "this build", Module = packages.Constella } }
if packages:FindFirstChild("ConstellaBaseline") then
	table.insert(builds, { Name = "baseline", Module = packages.ConstellaBaseline })
end
return require(ServerStorage.ConstellaBenchmarks.RunBenchmarks)({ Runs = {runs}, Packages = builds })
"""


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    runs = int(sys.argv[2]) if len(sys.argv) == 3 else 5
    roblox = Roblox(
        os.environ["ROBLOX_API_KEY"].strip(),
        os.environ["ROBLOX_UNIVERSE_ID"].strip(),
        os.environ["ROBLOX_PLACE_ID"].strip(),
    )
    with open(sys.argv[1], "rb") as file:
        place_file = file.read()
    print(f"Published benchmark place version {roblox.publish(place_file)} ({len(place_file)} bytes)")

    path = roblox.start(SCRIPT.replace("{runs}", str(runs)))
    task = roblox.wait(path)
    roblox.print_logs("benchmarks", path)
    if task["state"] != "COMPLETE":
        error = task.get("error", {})
        sys.exit(f"Benchmark task {task['state']}: {error.get('code')}: {error.get('message')}")
    report = (task.get("output", {}).get("results") or [None])[0]
    if not isinstance(report, str):
        sys.exit(f"Unexpected benchmark output: {task.get('output')}")

    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as file:
            file.write("## Benchmarks on a Roblox server\n\n")
            file.write("`[this build]` is this pull request; `[baseline]` is its base commit.\n\n")
            file.write(report + "\n")


if __name__ == "__main__":
    main()
