"""Runs Constella's benchmarks on a real Roblox server through Open Cloud.

The place file (see the "Build the benchmark place" step in ci.yml) holds
this build as ReplicatedStorage.Packages.Constella and, optionally, a
baseline build as ReplicatedStorage.Packages.ConstellaBaseline. Both are
measured in the same server session, alternating case by case, so they can
be compared directly. The Markdown report is printed and, on GitHub Actions,
added to the job summary.

Exit status: 1 if the report lists a regression (a case more than 10% slower
than the baseline, with the 95% confidence interval above +5%), otherwise 0.
Problems reaching Roblox only produce a warning, so an outage can't block a
pull request.

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


def warn_and_exit(message):
    print(f"::warning::Benchmarks skipped: {message}")
    sys.exit(0)


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
    try:
        print(f"Published benchmark place version {roblox.publish(place_file)} ({len(place_file)} bytes)")
        path = roblox.start(SCRIPT.replace("{runs}", str(runs)))
        task = roblox.wait(path)
        roblox.print_logs("benchmarks", path)
    except SystemExit as error:  # request() exits on HTTP failures
        warn_and_exit(error.code)
    if task["state"] != "COMPLETE":
        error = task.get("error", {})
        warn_and_exit(f"task {task['state']}: {error.get('code')}: {error.get('message')}")
    report = (task.get("output", {}).get("results") or [None])[0]
    if not isinstance(report, str):
        warn_and_exit(f"unexpected output {task.get('output')}")

    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as file:
            file.write("## Benchmarks on a Roblox server\n\n")
            file.write("`[this build]` is this pull request; `[baseline]` is its base commit.\n\n")
            file.write(report + "\n")

    regressions = [line for line in report.splitlines() if line.startswith("REGRESSION |")]
    for line in regressions:
        print(f"::error::{line}")
    if regressions:
        sys.exit(1)
    print("No benchmark regressions")


if __name__ == "__main__":
    main()
