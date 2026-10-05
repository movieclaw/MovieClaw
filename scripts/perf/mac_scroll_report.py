#!/usr/bin/env python3
"""Summarize macOS scroll smoothness from PerfTrace `frames` events (MacFrameMonitor).

Each trace is one bench run; segments with the same name across runs are pooled (frame-weighted).
`--base` compares against a baseline set of traces.
"""
import argparse
import json
import statistics
from pathlib import Path


def frames(path):
    out = []
    for line in Path(path).read_text().splitlines():
        if line.strip():
            event = json.loads(line)
            if event.get("ev") == "frames":
                out.append(event)
    return out


def pool(traces):
    """seg name -> list of per-run summaries (order of first appearance kept)."""
    by_seg = {}
    for path in traces:
        for event in frames(path):
            by_seg.setdefault(event["seg"], []).append(event)
    return by_seg


def combine(runs):
    """Pool runs of one segment: totals are summed, distributional values take the median across runs."""
    dur = sum(r["dur_ms"] for r in runs)
    hitch = sum(r["hitch_ms"] for r in runs)
    dropped = sum(r["dropped"] for r in runs)
    period = statistics.median(r["period_ms"] for r in runs)
    return {
        "runs": len(runs),
        "dur_s": dur / 1000,
        "hitch_ratio": hitch / (dur / 1000) if dur else 0,
        "drop_pct": dropped / (dur / period) * 100 if dur else 0,
        "p95_ms": statistics.median(r["p95_ms"] for r in runs),
        "p99_ms": statistics.median(r["p99_ms"] for r in runs),
        "max_ms": max(r["max_ms"] for r in runs),
        "over50": sum(r["over50"] for r in runs),
        "over100": sum(r["over100"] for r in runs),
        "busy_pct": statistics.median(r["main_busy_pct"] for r in runs),
        "long_tasks": sum(r["long_tasks"] for r in runs),
        "ratio_spread": (min(r["hitch_ratio"] for r in runs), max(r["hitch_ratio"] for r in runs)),
    }


COLUMNS = [("hitch_ratio", "hitch ms/s", "{:.1f}"), ("drop_pct", "drop%", "{:.1f}"), ("p95_ms", "p95", "{:.1f}"),
           ("p99_ms", "p99", "{:.1f}"), ("max_ms", "max", "{:.0f}"), ("over50", ">50ms", "{}"),
           ("busy_pct", "main busy%", "{:.0f}"), ("long_tasks", "long tasks", "{}")]


def table(current, base=None):
    names = list(current)
    head = f"{'segment':<16}{'runs':>5}{'secs':>7}" + "".join(f"{label:>13}" for _, label, _ in COLUMNS)
    lines = [head, "-" * len(head)]
    for name in names:
        c = combine(current[name])
        row = f"{name:<16}{c['runs']:>5}{c['dur_s']:>7.1f}"
        for key, _, fmt in COLUMNS:
            cell = fmt.format(c[key])
            if base and name in base:
                cell += f"({fmt.format(combine(base[name])[key])})"
            row += f"{cell:>13}"
        lines.append(row)
        lines.append(f"{'':<28}hitch ms/s per run: {', '.join(f'{r['hitch_ratio']:.1f}' for r in current[name])}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("traces", nargs="+")
    parser.add_argument("--base", nargs="+", help="baseline traces; shown in parentheses")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    current = pool(args.traces)
    base = pool(args.base) if args.base else None
    if args.json:
        print(json.dumps({name: combine(runs) for name, runs in current.items()}, indent=2))
    else:
        print(table(current, base))


if __name__ == "__main__":
    main()
