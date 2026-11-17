"""Turns studio_load.ps1 results into Markdown.

Load results (one file per client count) become tables of measured traffic,
server time per tick and request round trips. A soak result becomes a
memory-over-time table with a leak verdict: the heap's floor (the lowest
sample in each window, i.e. right after a garbage collection) must not keep
rising.

Usage:
  python load_report.py build/load-load-1.json build/load-load-4.json ...
  python load_report.py --soak build/load-soak-4.json [--window 10] [--max-slope-kb 256]
"""

import argparse
import json
import statistics
import sys

PHASE_LABELS = {
    "Calibrate1000": "Calibration: 1,000-byte random string",
    "Calibrate4000": "Calibration: 4,000-byte random string",
    "RawInventory": "Plain RemoteEvent, whole inventory (hand-written baseline)",
    "ReplicationFull": "Replication, full value",
    "ReplicationDelta": "Replication, `Delta = true`",
    "Game": "Game tick (coins, 50-entry Delta leaderboard)",
}


def load(path):
    with open(path, encoding="utf-8") as file:
        result = json.load(file)
    if not result.get("Results"):
        sys.exit(f"{path}: no results ({result.get('Message')})")
    return result


def phases(results):
    return {phase["Name"]: phase for phase in results["Server"]}


def per_update_bytes(results, name):
    """Server-to-client bytes per update per client, above the idle baseline.

    Stats.DataSendKbps on the server is the average per connected client in
    KB/s (1 KB = 1,000 bytes); the calibration rows check that.
    """
    table = phases(results)
    idle, phase = table["Idle"]["ServerSendKbps"], table[name]
    rate = phase["UpdatesPerSecond"] or results["Rate"]
    return (phase["ServerSendKbps"] - idle) * 1000 / rate


def client_median(results, key, phase):
    values = [c["Phases"][phase][key] for c in results["ClientReports"] if phase in c["Phases"]]
    return statistics.median(values) if values else None


def fmt(value, digits=0):
    if value is None:
        return "–"
    return f"{value:,.{digits}f}"


def load_report(paths):
    runs = sorted((load(p) for p in paths), key=lambda r: r["Results"]["Clients"])
    first = runs[0]["Results"]
    counts = [r["Results"]["Clients"] for r in runs]
    head = " | ".join(f"{n} client{'s' if n > 1 else ''}" for n in counts)
    rule = " | ".join("---:" for _ in counts)
    out = []
    out.append(
        f"Real Studio clients, {first['Rate']} updates per second, {first['PhaseSeconds']} s per phase "
        f"(the first {first['WarmupSeconds']} s not measured), Constella {first['Version']}. "
        f"All runs: {', '.join(('passed' if r['Passed'] else 'FAILED: ' + r['Message']) for r in runs)}."
    )
    out.append("")
    out.append("**Server to each client, bytes per update** (engine-measured, above the idle baseline):")
    out.append("")
    out.append(f"| What is sent | {head} |")
    out.append(f"| --- | {rule} |")
    for name in ["Calibrate1000", "Calibrate4000", "RawInventory", "ReplicationFull", "ReplicationDelta", "Game"]:
        cells = " | ".join(fmt(per_update_bytes(r["Results"], name)) for r in runs)
        out.append(f"| {PHASE_LABELS[name]} | {cells} |")
    out.append("")
    out.append("**Server time per tick with real sends, median / 95th percentile (ms):**")
    out.append("")
    out.append(f"| Phase | {head} |")
    out.append(f"| --- | {rule} |")
    for name in ["RawInventory", "ReplicationFull", "ReplicationDelta", "Game"]:
        cells = []
        for r in runs:
            phase = phases(r["Results"])[name]
            cells.append(f"{phase['TickMsMedian']:.3f} / {phase['TickMsP95']:.3f}")
        out.append(f"| {PHASE_LABELS[name]} | {' | '.join(cells)} |")
    out.append("")
    out.append("**Requests and frames:**")
    out.append("")
    out.append(f"| | {head} |")
    out.append(f"| --- | {rule} |")
    rows = {
        "Client to server, bytes per request (engine-measured)": [],
        "Requests accepted / rejected (all must match what clients sent)": [],
        "`Ping` round trip, median (ms)": [],
        "Server frame time in the Game phase, median / 99th percentile (ms)": [],
        "Replication checks passed (every client has the server's exact value)": [],
    }
    for r in runs:
        res = r["Results"]
        rps = res["RequestsPerSecond"]
        idle = client_median(res, "SendKbps", "Idle")
        busy = client_median(res, "SendKbps", "Requests")
        # One Ping per second is sent alongside the requests.
        per_request = (busy - idle) * 1000 / (rps + 1) if idle is not None and busy is not None else None
        rows["Client to server, bytes per request (engine-measured)"].append(fmt(per_request))
        req = res["Requests"]
        rows["Requests accepted / rejected (all must match what clients sent)"].append(
            f"{req['Accepted']:,} / {req['Rejected']:,}"
        )
        pings = [c["PingMsMedian"] for c in res["ClientReports"] if c.get("PingMsMedian")]
        rows["`Ping` round trip, median (ms)"].append(fmt(statistics.median(pings), 1) if pings else "–")
        game = phases(res)["Game"]
        rows["Server frame time in the Game phase, median / 99th percentile (ms)"].append(
            f"{game['FrameMsMedian']:.1f} / {game['FrameMsP99']:.1f}"
        )
        checks = [ok for c in res["ClientReports"] for ok in c["Checks"].values()]
        rows["Replication checks passed (every client has the server's exact value)"].append(
            f"{sum(checks)} of {len(checks)}"
        )
    for label, cells in rows.items():
        out.append(f"| {label} | {' | '.join(cells)} |")
    return "\n".join(out)


def slope_per_hour(points):
    """Least-squares slope of (minute, value) points, per hour."""
    if len(points) < 2:
        return None
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    if den == 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den * 60


def floors(samples, key, window):
    """Lowest value in each `window`-minute window: the heap right after a GC."""
    buckets = {}
    for sample in samples:
        if sample.get(key) is None:
            continue
        bucket = int(sample["Minute"] // window)
        buckets.setdefault(bucket, []).append(sample[key])
    return [((bucket + 0.5) * window, min(values)) for bucket, values in sorted(buckets.items())]


def soak_report(path, window, max_slope_kb):
    result = load(path)
    res = result["Results"]
    server = res["Server"]
    out = []
    minutes = server[-1]["Minute"]
    if res.get("Workload") is False:
        out.append("**Control run:** clients connected, no Constella work.")
        out.append("")
    out.append(
        f"{res['Clients']} real Studio clients for {minutes:.0f} minutes ({res['Ticks']:,} ticks at {res['Rate']} per second), "
        f"Constella {res['Version']}. Result: {'passed' if result['Passed'] else 'FAILED: ' + result['Message']}."
    )
    out.append("")
    # The first window is warm-up (caches, runner threads, pools filling).
    server_floors = floors(server, "HeapMinKB", window)[1:]
    verdicts = []
    out.append(f"| Minute | Server Lua heap floor (KB) | Server instances | Tick median / p95 (ms) | Client Lua heap floor, median of clients (KB) |")
    out.append("| ---: | ---: | ---: | --- | ---: |")
    client_floor_sets = [floors(c["Soak"], "HeapMinKB", window) for c in res["ClientReports"]]
    for index, (minute, floor) in enumerate(floors(server, "HeapMinKB", window)):
        in_window = [s for s in server if int(s["Minute"] // window) == index]
        last = in_window[-1]
        client_values = [cf[index][1] for cf in client_floor_sets if index < len(cf)]
        out.append(
            f"| {minute:.0f} | {floor:,.0f} | {last['Instances']:,} | "
            f"{fmt(last.get('TickMsMedian'), 3)} / {fmt(last.get('TickMsP95'), 3)} | "
            f"{fmt(statistics.median(client_values)) if client_values else '–'} |"
        )
    out.append("")
    server_slope = slope_per_hour(server_floors)
    client_slopes = [slope_per_hour(cf[1:]) for cf in client_floor_sets]
    client_slopes = [s for s in client_slopes if s is not None]
    instances = [s["Instances"] for s in server if s["Minute"] >= window]
    tick_first = [s["TickMsMedian"] for s in server if s.get("TickMsMedian") and window <= s["Minute"] < 2 * window]
    tick_last = [s["TickMsMedian"] for s in server if s.get("TickMsMedian") and s["Minute"] >= minutes - window]
    out.append(f"- **Server heap floor trend** after the first {window} minutes: {fmt(server_slope, 1)} KB per hour.")
    if client_slopes:
        out.append(
            f"- **Client heap floor trend:** {fmt(min(client_slopes), 1)} to {fmt(max(client_slopes), 1)} KB per hour across clients."
        )
    out.append(f"- **Server instances** after warm-up: {min(instances):,} to {max(instances):,}.")
    if tick_first and tick_last:
        out.append(
            f"- **Tick time**, median: {statistics.median(tick_first):.3f} ms in the second window, "
            f"{statistics.median(tick_last):.3f} ms in the last."
        )
    req = res["Requests"]
    out.append(f"- **Requests:** {req['Accepted']:,} accepted and {req['Rejected']:,} rejected, exactly what the clients sent.")
    pool = res.get("Pool") or {}
    if pool:
        out.append(
            f"- **Pool:** {pool.get('Created', 0):,} created, {pool.get('Reused', 0):,} reuses, {pool.get('Active', 0)} active at the end."
        )
    out.append(f"- **Churn signal connections left at the end:** {res.get('SignalConnections')} (expected 0).")
    if server_slope is not None and server_slope > max_slope_kb:
        verdicts.append(f"server heap floor rises {server_slope:.0f} KB/h (limit {max_slope_kb})")
    for slope in client_slopes:
        if slope > max_slope_kb:
            verdicts.append(f"a client heap floor rises {slope:.0f} KB/h (limit {max_slope_kb})")
    if res.get("SignalConnections"):
        verdicts.append("churn signal kept connections")
    out.append("")
    out.append(
        "**Verdict: no growth.**"
        if not verdicts
        else "**Verdict: GROWTH:** " + "; ".join(verdicts)
    )
    return "\n".join(out), not verdicts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+")
    parser.add_argument("--soak", action="store_true")
    parser.add_argument("--window", type=float, default=10, help="minutes per heap-floor window")
    parser.add_argument("--max-slope-kb", type=float, default=256, help="largest allowed floor growth, KB per hour")
    args = parser.parse_args()
    if args.soak:
        text, ok = soak_report(args.paths[0], args.window, args.max_slope_kb)
        print(text)
        sys.exit(0 if ok else 1)
    print(load_report(args.paths))


if __name__ == "__main__":
    main()
