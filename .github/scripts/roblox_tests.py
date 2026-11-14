"""Runs Constella's test suite on a real Roblox server through Open Cloud.

1. Publishes the CI place file (built from ci.project.json) to the CI place.
2. Runs the test suite in a Luau execution task on that exact version.
3. Prints the server logs and fails if any test failed.

Environment: ROBLOX_API_KEY, ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID.
The key needs universe-places:write and
universe.place.luau-execution-session:read/write for that experience.

Usage: python roblox_tests.py <place-file.rbxl>
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://apis.roblox.com"
TASK_TIMEOUT_SECONDS = 300
POLL_INTERVAL_SECONDS = 3

# Runs on the server. The tests live in ServerStorage so the place's own
# scripts can't start a second copy of the suite.
SCRIPT = """
local ServerStorage = game:GetService("ServerStorage")
local results = require(ServerStorage.ConstellaTests.RunTests)()
return {
	passed = results.passed,
	failed = results.failed,
	skipped = results.skipped,
	failures = results.failures,
}
"""


def request(method, url, key, body=None, content_type=None, attempts=5):
    headers = {"x-api-key": key}
    if content_type:
        headers["Content-Type"] = content_type
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                return json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")
            # 409 is what place publishing returns while Roblox is busy saving.
            retryable = error.code in (409, 429) or error.code >= 500
            if not retryable or attempt == attempts:
                sys.exit(f"{method} {url.split('?')[0]} failed: HTTP {error.code}: {detail}")
            wait = int(error.headers.get("Retry-After") or min(15 * attempt, 60))
            print(f"HTTP {error.code}, retrying in {wait}s")
            time.sleep(wait)
        except urllib.error.URLError as error:
            if attempt == attempts:
                sys.exit(f"{method} {url.split('?')[0]} failed: {error.reason}")
            time.sleep(2**attempt)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    key = os.environ["ROBLOX_API_KEY"].strip()
    universe = os.environ["ROBLOX_UNIVERSE_ID"].strip()
    place = os.environ["ROBLOX_PLACE_ID"].strip()

    with open(sys.argv[1], "rb") as file:
        place_file = file.read()
    published = request(
        "POST",
        f"{API}/universes/v1/{universe}/places/{place}/versions?versionType=Published",
        key,
        body=place_file,
        content_type="application/octet-stream",
    )
    version = published["versionNumber"]
    print(f"Published CI place version {version} ({len(place_file)} bytes)")

    task = request(
        "POST",
        f"{API}/cloud/v2/universes/{universe}/places/{place}/versions/{version}/luau-execution-session-tasks",
        key,
        body=json.dumps({"script": SCRIPT, "timeout": f"{TASK_TIMEOUT_SECONDS}s"}).encode(),
        content_type="application/json",
    )
    path = task["path"]
    print(f"Started task {path.rsplit('/', 1)[-1]}")

    deadline = time.time() + TASK_TIMEOUT_SECONDS + 120
    while task.get("state") not in ("COMPLETE", "FAILED", "CANCELLED"):
        if time.time() > deadline:
            sys.exit("Timed out waiting for the test task")
        time.sleep(POLL_INTERVAL_SECONDS)
        task = request("GET", f"{API}/cloud/v2/{path}", key)

    logs = request("GET", f"{API}/cloud/v2/{path}/logs?view=STRUCTURED&maxPageSize=10000", key)
    print("---- server output ----")
    for log in logs.get("luauExecutionSessionTaskLogs", []):
        for message in log.get("structuredMessages", []):
            prefix = {"WARNING": "WARN ", "ERROR": "ERROR "}.get(message.get("messageType"), "")
            print(prefix + message.get("message", ""))
    print("-----------------------")

    if task["state"] != "COMPLETE":
        error = task.get("error", {})
        sys.exit(f"Task {task['state']}: {error.get('code')}: {error.get('message')}")

    results = (task.get("output", {}).get("results") or [None])[0]
    if not isinstance(results, dict):
        sys.exit(f"Unexpected task output: {task.get('output')}")
    print(f"{results['passed']} passed, {results['failed']} failed, {results.get('skipped', 0)} skipped")
    for failure in results.get("failures") or []:
        print(f"::error title={failure.get('name')}::{failure.get('message')}")
    if results["failed"] > 0 or results["passed"] == 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
