#!/usr/bin/env python3
"""Run native playback, seek, track-switch and transport-fault regressions.

Build and install the Debug App first. Pass a JSON mapping of sample names to
playback routes (see tests/playback-samples.example.json). Set MC_SIM, MC_SERVER
and optionally MC_TEST_USERNAME / MC_TEST_PASSWORD for an automatic login.
Results and full App/proxy logs are written under MC_FAULT_OUT.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import re
import sys

import faultlab as lab

CASES = [
    ("mp4", 42, "12:+10,22:300"),
    ("mkv", 56, "12:+600,24:60"),
    ("bluray", 55, "15:+600,28:60"),
    ("dvd-folder", 50, "12:+300,24:60"),
    ("udf-dvd", 50, "12:+300,24:60"),
    ("vc1-bluray", 55, "15:+600,28:60"),
    ("bluray-iso", 55, "15:+600,28:60"),
]


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", type=Path)
    args = parser.parse_args()
    samples = json.loads(args.samples.read_text())
    missing = [name for name, _, _ in CASES if not samples.get(name)]
    if missing:
        parser.error("Missing playback routes: " + ", ".join(missing))
    if os.environ.get("MC_TEST_PASSWORD"):
        lab.EXTRA += ["-mcServer", os.environ["MC_SERVER"],
                      "-mcUser", os.environ["MC_TEST_USERNAME"],
                      "-mcPass", os.environ["MC_TEST_PASSWORD"]]
    results = []
    for name, seconds, seeks in CASES:
        lab.ROUTES[name] = samples[name]
        extra = ["-mcPurgeByteCache", "YES", "-mcAutoSeek", seeks]
        if name == "mkv":
            extra += ["-mcAutoAudio", "30:embedded:1", "-mcAutoSubtitle", "34:embedded:0,38:off"]
        lab.SCENARIOS[name] = lab.scenario(name, seconds, "play", extra=extra)
        report, passed = await lab.run(name)
        log = Path(lab.OUT, f"{name}.log").read_text(errors="replace")
        landed = len(re.findall(r"\[SeekTrace\].*耗时 \d+ 毫秒", log))
        passed = passed and landed >= 2 and "[FrameStats] native" in log
        if name == "mkv":
            # Observe the engine reload and continued audio delivery, plus the
            # consumer's subtitle selection, not just the scheduled actions.
            switched = "selectAudioTrack: scheduling switch" in log
            after_switch = log.split("selectAudioTrack: scheduling switch", 1)[-1]
            switched = switched and "[FrameStats] native" in after_switch and "音频交付" in after_switch
            passed = passed and switched and "[Tracks] 字幕选择 embedded:0" in log and "[Tracks] 字幕选择 off" in log
        results.append({"name": name, "passed": passed, "seekLandings": landed})
        print(report + f"\n  Seek landings: {landed}; {'PASS' if passed else 'FAIL'}", flush=True)
    lab.ROUTES["mkv"] = samples["mp4"]
    for name in ("open-refuse", "mid-cut", "slow-start"):
        report, passed = await lab.run(name)
        log = Path(lab.OUT, f"{name}.log").read_text(errors="replace")
        passed = passed and "[FrameStats] native" in log
        results.append({"name": name, "passed": passed})
        print(report, flush=True)
    Path(lab.OUT, "results.json").write_text(json.dumps(results, indent=2) + "\n")
    failed = [result["name"] for result in results if not result["passed"]]
    print(f"Playback regression failures: {failed}", flush=True)
    return bool(failed)


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
