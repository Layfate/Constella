"""Runs Constella's tests on real Roblox servers through Open Cloud.

1. Publishes the CI place file (built from ci.project.json) to the CI place.
2. Runs the test suite in a Luau execution task on that exact version.
3. Runs the live Data scenarios from tests/server/Live.luau, each task on
   its own server: a player moving to a second server (two servers at once)
   and many sessions open at once.
4. Prints the server logs and fails if anything failed.

Environment: ROBLOX_API_KEY, ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID.
The key needs universe-places:write and
universe.place.luau-execution-session:read/write for that experience.

Usage: python roblox_tests.py <place-file.rbxl>
"""

import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

API = "https://apis.roblox.com"
TASK_TIMEOUT_SECONDS = 300
POLL_INTERVAL_SECONDS = 3
# ProfileStore holds a MessagingService subscription per active profile, and a
# server with no players allows about 20, so stay under that.
MANY_SESSIONS = 15

# The tests live in ServerStorage so the place's own scripts can't start a
# second copy of the suite.
SUITE = """
local ServerStorage = game:GetService("ServerStorage")
local results = require(ServerStorage.ConstellaTests.RunTests)()
return {
	passed = results.passed,
	failed = results.failed,
	skipped = results.skipped,
	failures = results.failures,
}
"""

LIVE = """
local Live = require(game:GetService("ServerStorage").ConstellaTests.Live)
return Live.{call}
"""


def request(method, url, key, body=None, content_type=None, attempts=6):
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
            # 409 is what place publishing returns while Roblox is busy saving
            # (or while the place is open in Studio).
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


class Roblox:
    def __init__(self, key, universe, place):
        self.key, self.universe, self.place = key, universe, place
        self.version = None

    def publish(self, place_file):
        published = request(
            "POST",
            f"{API}/universes/v1/{self.universe}/places/{self.place}/versions?versionType=Published",
            self.key,
            body=place_file,
            content_type="application/octet-stream",
        )
        self.version = published["versionNumber"]
        return self.version

    def start(self, script):
        task = request(
            "POST",
            f"{API}/cloud/v2/universes/{self.universe}/places/{self.place}/versions/{self.version}/luau-execution-session-tasks",
            self.key,
            body=json.dumps({"script": script, "timeout": f"{TASK_TIMEOUT_SECONDS}s"}).encode(),
            content_type="application/json",
        )
        return task["path"]

    def wait(self, path):
        deadline = time.time() + TASK_TIMEOUT_SECONDS + 120
        task = {}
        while task.get("state") not in ("COMPLETE", "FAILED", "CANCELLED"):
            if time.time() > deadline:
                sys.exit(f"Timed out waiting for task {path}")
            time.sleep(POLL_INTERVAL_SECONDS)
            task = request("GET", f"{API}/cloud/v2/{path}", self.key)
        return task

    def print_logs(self, label, path):
        logs = request("GET", f"{API}/cloud/v2/{path}/logs?view=STRUCTURED&maxPageSize=10000", self.key)
        print(f"---- {label}: server output ----")
        for log in logs.get("luauExecutionSessionTaskLogs", []):
            for message in log.get("structuredMessages", []):
                prefix = {"WARNING": "WARN ", "ERROR": "ERROR "}.get(message.get("messageType"), "")
                print(prefix + message.get("message", ""))

    def result(self, label, path):
        task = self.wait(path)
        self.print_logs(label, path)
        if task["state"] != "COMPLETE":
            error = task.get("error", {})
            return None, f"{label}: task {task['state']}: {error.get('code')}: {error.get('message')}"
        results = (task.get("output", {}).get("results") or [None])[0]
        if not isinstance(results, dict):
            return None, f"{label}: unexpected output {task.get('output')}"
        if results.get("error"):
            return results, f"{label}: {results['error']}"
        return results, None


def check_suite(results):
    problems = []
    print(f"Suite: {results['passed']} passed, {results['failed']} failed, {results.get('skipped', 0)} skipped")
    for failure in results.get("failures") or []:
        problems.append(f"{failure.get('name')}: {failure.get('message')}")
    if results["passed"] == 0:
        problems.append("no tests ran")
    return problems


def check_handoff(held, took):
    print(
        f"Server A ({held.get('server')}): loaded in {held.get('loadSeconds', 0):.2f}s, "
        f"session taken over after {held.get('lostAfterSeconds', 0):.1f}s, kicked: {held.get('kicked')!r}"
    )
    print(
        f"Server B ({took.get('server')}): loaded in {took.get('loadSeconds', 0):.2f}s, "
        f"saw Coins = {took.get('seen')}, stored Coins = {took.get('stored')}"
    )
    expectations = [
        (held.get("server") != took.get("server"), "A and B ran on the same server"),
        (held.get("saved") is True, "A's save failed"),
        (held.get("lost") is True, "A's session was never taken over"),
        (held.get("stillActive") is False, "A's profile stayed active after the takeover"),
        (bool(held.get("kicked")), "A didn't remove the player after losing the session"),
        (took.get("seen") == 111, f"B saw Coins = {took.get('seen')}, not A's 111"),
        (took.get("shutdown") is True, "B's shutdown didn't finish"),
        (took.get("stored") == 222, f"B's save stored {took.get('stored')}, not 222"),
        (not held.get("errors"), f"A reported errors: {held.get('errors')}"),
        (not took.get("errors"), f"B reported errors: {took.get('errors')}"),
    ]
    return [f"handoff: {message}" for passed, message in expectations if not passed]


def check_many(many):
    print(
        f"Many sessions: {many.get('loaded')}/{many.get('count')} loaded in {many.get('loadSeconds', 0):.1f}s, "
        f"{many.get('saved')}/{many.get('count')} saved, shutdown {many.get('shutdown')} "
        f"in {many.get('shutdownSeconds', 0):.1f}s"
    )
    count = many.get("count")
    expectations = [
        (many.get("loaded") == count, "not every profile loaded"),
        (many.get("saved") == count, "not every profile saved the right value"),
        (many.get("shutdown") is True, "shutdown didn't finish within its budget"),
        (not many.get("errors"), f"errors: {many.get('errors')}"),
    ]
    return [f"many sessions: {message}" for passed, message in expectations if not passed]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    roblox = Roblox(
        os.environ["ROBLOX_API_KEY"].strip(),
        os.environ["ROBLOX_UNIVERSE_ID"].strip(),
        os.environ["ROBLOX_PLACE_ID"].strip(),
    )
    with open(sys.argv[1], "rb") as file:
        place_file = file.read()
    print(f"Published CI place version {roblox.publish(place_file)} ({len(place_file)} bytes)")

    problems = []
    suite, error = roblox.result("test suite", roblox.start(SUITE))
    problems += [error] if error else check_suite(suite)

    # Fresh names every run, so runs never share data.
    run = "%08x" % random.getrandbits(32)
    user = random.randint(10_000_000, 99_999_999)
    hold = roblox.start(LIVE.replace("{call}", f'holdSession("ConstellaHandoff_{run}", {user}, 150)'))
    time.sleep(5)  # let A start first; B also waits before it loads
    take = roblox.start(LIVE.replace("{call}", f'takeOverSession("ConstellaHandoff_{run}", {user}, 20)'))
    many = roblox.start(
        LIVE.replace("{call}", f'manySessions("ConstellaLoad_{run}", {MANY_SESSIONS}, {user * 100})')
    )
    held, error_a = roblox.result("server A", hold)
    took, error_b = roblox.result("server B", take)
    many_result, error_many = roblox.result("many sessions", many)
    problems += [e for e in (error_a, error_b, error_many) if e]
    if held and took and not (error_a or error_b):
        problems += check_handoff(held, took)
    if many_result and not error_many:
        problems += check_many(many_result)

    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        sys.exit(1)
    print("All Roblox server checks passed")


if __name__ == "__main__":
    main()
