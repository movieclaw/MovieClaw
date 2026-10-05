#!/usr/bin/env python3
"""Report macOS Release traces. Run-loop idle latency is not input-to-photon latency."""
import argparse
import json
import math
import statistics
import xml.etree.ElementTree as ET
from pathlib import Path


def percentile(values, fraction):
    return sorted(values)[math.ceil(len(values) * fraction) - 1] if values else None


def input_summary(events):
    latencies = [e["t"] - e["start"] for e in events if e["ev"] == "input.commit"]
    delivered = [e for e in events if e["ev"] == "input.commit" and "received" in e]
    return {
        "samples": len(latencies), "p95_ms": percentile(latencies, .95),
        "p99_ms": percentile(latencies, .99), "max_ms": max(latencies, default=None),
        "queue_p95_ms": percentile([e["received"] - e["start"] for e in delivered], .95),
        "after_delivery_p95_ms": percentile([e["t"] - e["received"] for e in delivered], .95),
        "measures": "input-to-main-run-loop-idle; confirm presentation separately",
    }


def hitch_summary(path, pid, active_seconds):
    root = ET.parse(path).getroot()
    refs = {e.attrib["id"]: e for e in root.iter() if "id" in e.attrib}

    def resolve(element):
        return refs[element.attrib["ref"]] if "ref" in element.attrib else element

    durations = []
    for row in root.iter("row"):
        process = resolve(row[2])
        process_pid = process.find("pid")
        if process_pid is not None and int(resolve(process_pid).text) == pid:
            durations.append(float(resolve(row[1]).text) / 1e6)
    return {
        "count": len(durations), "total_ms": sum(durations),
        "max_ms": max(durations, default=0),
        "ratio_ms_per_s": sum(durations) / active_seconds,
    }


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def resource_summary(resources):
    converted = all("cpu_timebase" in r for r in resources)
    return {
        "samples": len(resources),
        "cpu_measurement_valid": converted,
        "cpu_average_percent": (
            statistics.mean(r["cpu_percent"] for r in resources) if converted else None
        ),
        "footprint_first_mb": resources[0]["footprint_mb"],
        "footprint_last_mb": resources[-1]["footprint_mb"],
        "footprint_peak_mb": max(r["footprint_mb"] for r in resources),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace")
    parser.add_argument("--resources")
    parser.add_argument("--hitches")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--active-seconds", type=float)
    args = parser.parse_args()
    events = read_jsonl(args.trace)
    summary = {"input": input_summary(events)}
    summary["first_run_loop_idle_ms"] = next(
        (e["t"] for e in events if e["ev"] == "app.firstCommit"), None
    )
    if args.resources:
        resources = read_jsonl(args.resources)
        if resources:
            summary["resources"] = resource_summary(resources)
    if args.hitches:
        if args.pid is None or args.active_seconds is None or args.active_seconds <= 0:
            parser.error(
                "--hitches requires --pid and a positive --active-seconds (exclude idle time)"
            )
        summary["hitches"] = hitch_summary(args.hitches, args.pid, args.active_seconds)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
