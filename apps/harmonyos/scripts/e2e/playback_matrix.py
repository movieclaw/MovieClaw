#!/usr/bin/env python3
"""Run authenticated NAS fixtures through the debug phone UI and real native engines.
Input: JSON array of caseId/itemId/fileId/season/episode/engine (no credentials).
The app must already be logged in. Records device timestamps, not host timing guesses.
"""

import argparse
import json
import pathlib
import re
import shlex
import subprocess
import time

from PIL import Image, ImageChops, ImageStat

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--hdc", required=True)
p.add_argument("--matrix", required=True)
p.add_argument("--output", required=True)
p.add_argument("--startup-timeout", type=int, default=70)
p.add_argument("--play-seconds", type=int, default=8)
p.add_argument("--resume-timeout", type=int, default=30)
a = p.parse_args()
out = pathlib.Path(a.output)
out.mkdir(parents=True, exist_ok=True)


def hdc(*args):
    command = subprocess.run([a.hdc, *args], capture_output=True, text=True, timeout=30, check=True)
    if "[Fail]" in command.stdout or "[Empty]" in command.stdout:
        raise RuntimeError(
            "Device command failed; preserve this run as interrupted, not a playback result"
        )
    return command.stdout


def send(data):
    return hdc(
        "shell",
        "aa start -b io.movieclaw.HUAWEI -a EntryAbility --ps mcPlaybackTest "
        + shlex.quote(json.dumps(data, separators=(",", ":"))),
    )


def records(case):
    result = []
    for line in hdc("shell", "hilog -x -T MCPlaybackTest").splitlines():
        try:
            r = json.loads(line[line.index("{") :])
            if r.get("caseId") == case:
                result.append(r)
        except (ValueError, json.JSONDecodeError):
            pass
    return result


def snap(folder, name):
    hdc("shell", "uitest screenCap -p /data/local/tmp/mc-matrix.png")
    hdc("file", "recv", "/data/local/tmp/mc-matrix.png", str(folder / (name + ".png")))


def picture(path):
    with Image.open(path) as image:
        w, h = image.size
        return image.crop((w // 10, h * 45 // 100, w * 9 // 10, h * 55 // 100)).convert("L")


def picture_stats(path):
    image = picture(path)
    histogram = image.histogram()
    return {
        "meanLuma": ImageStat.Stat(image).mean[0],
        "lumaStddev": ImageStat.Stat(image).stddev[0],
        "nonBlackFraction": sum(histogram[17:]) / sum(histogram),
    }


def ui(folder):
    hdc("shell", "uitest dumpLayout -p /data/local/tmp/mc-matrix.json")
    hdc("file", "recv", "/data/local/tmp/mc-matrix.json", str(folder / "layout.json"))


def last_state(rs):
    return next((r for r in reversed(rs) if r["event"] == "snapshot"), {})


cases = json.loads(pathlib.Path(a.matrix).read_text())
for index, original in enumerate(cases):
    case = dict(original)
    case.setdefault("startMs", 1)
    if case["startMs"] == 0:
        case["startMs"] = 1  # Explicit beginning; do not resume the account's saved position.
    folder = out / case["caseId"]
    folder.mkdir(exist_ok=True)
    if (folder / "result.json").exists():
        continue
    case["caseId"] += "-" + str(int(time.time() * 1000))
    send({"command": "stop"})
    time.sleep(0.8)
    send(case)
    deadline = time.monotonic() + a.startup_timeout
    played = False
    start = None
    while time.monotonic() < deadline:
        rs = records(case["caseId"])
        states = [r for r in rs if r["event"] == "snapshot" and r["playing"]]
        if states:
            start = states[0]
            if states[-1]["positionMs"] - start["positionMs"] >= 1500:
                played = True
                break
        if last_state(rs).get("phase") == "failed":
            ui(folder)
            if "player-error" in (folder / "layout.json").read_text():
                break  # A transient engine failure can still lead to another server tier.
        # Surface failure may precede engine creation (server rejection / consent).
        if not start and len(rs) and time.monotonic() > deadline - a.startup_timeout + 10:
            ui(folder)
            layout = (folder / "layout.json").read_text()
            if "player-error" in layout or "软件转码" in layout:
                break
        time.sleep(0.5)
    result = {"case": case, "playbackAdvanced": played, "pause": None, "seek": None, "resume": None}
    if played:
        time.sleep(a.play_seconds)
        send({"command": "tracks"})
        time.sleep(0.3)
        snap(folder, "playing")
        (folder / "audio-playing.txt").write_text(
            hdc("shell", "hidumper -s AudioDistributed -a '-p'")
        )
        result["picturePlaying"] = picture_stats(folder / "playing.png")
        send({"command": "pause"})
        pause_started = time.monotonic()
        paused = last_state(records(case["caseId"]))
        while paused.get("phase") != "paused" and time.monotonic() - pause_started < 5:
            time.sleep(0.2)
            paused = last_state(records(case["caseId"]))
        result["pauseObservedMs"] = round((time.monotonic() - pause_started) * 1000)
        time.sleep(2)
        still = last_state(records(case["caseId"]))
        result["pause"] = (
            paused.get("phase") == "paused"
            and not still.get("playing", True)
            and abs(still.get("positionMs", 0) - paused.get("positionMs", 0)) <= 250
        )
        target = min(
            paused.get("positionMs", 0) + 30000, max(0, paused.get("durationMs", 0) - 10000)
        )
        send({"command": "seek", "positionMs": target})
        time.sleep(2)
        sought = last_state(records(case["caseId"]))
        result["seek"] = abs(sought.get("positionMs", 0) - target) <= 3000
        result["seekTargetMs"] = target
        send({"command": "play"})
        resume_started = time.monotonic()
        time.sleep(4)
        resumed = last_state(records(case["caseId"]))
        while time.monotonic() - resume_started < a.resume_timeout:
            if (
                resumed.get("playing", False)
                and resumed.get("positionMs", 0) > sought.get("positionMs", 0) + 1000
            ):
                break
            if resumed.get("phase") == "failed":
                break
            time.sleep(0.5)
            resumed = last_state(records(case["caseId"]))
        result["resumeWaitMs"] = round((time.monotonic() - resume_started) * 1000)
        result["resume"] = (
            resumed.get("playing", False)
            and resumed.get("positionMs", 0) > sought.get("positionMs", 0) + 1000
        )
        snap(folder, "resumed")
        result["pictureResumed"] = picture_stats(folder / "resumed.png")
        difference = ImageChops.difference(
            picture(folder / "playing.png"), picture(folder / "resumed.png")
        )
        result["pictureDifference"] = ImageStat.Stat(difference).mean[0]
    else:
        errors = hdc("shell", "hilog -x -L E")
        errors = "\n".join(
            line
            for line in errors.splitlines()
            if re.search(r"Player|Audio|Codec|Decoder|Demux|Downloader|HiStreamer", line)
        )
        errors = re.sub(r"https?://[^\s\"\']+", "[redacted-url]", errors)
        (folder / "native-errors.log").write_text(errors)
        snap(folder, "failure")
    ui(folder)
    send({"command": "stop"})
    time.sleep(0.8)
    rs = records(case["caseId"])
    result["disposed"] = any(r["event"] == "dispose" for r in rs)
    request = next((r for r in rs if r["event"] == "request"), None)
    first_frame = next((r for r in rs if r["event"] == "firstFrame"), None)
    result["firstFrameMs"] = first_frame["at"] - request["at"] if first_frame and request else None
    result["playingMs"] = start["at"] - request["at"] if start and request else None
    result["engines"] = []
    for event in rs:
        engine = event["engine"]
        if engine and (not result["engines"] or result["engines"][-1] != engine):
            result["engines"].append(engine)
    result["tracks"] = [json.loads(r["detail"]) for r in rs if r["event"] == "tracks"]
    result["delivery"] = [json.loads(r["detail"]) for r in rs if r["event"] == "delivery"]
    result["sessions"] = [r["detail"] for r in rs if r["event"] == "session"]
    result["fallbacks"] = [r["detail"] for r in rs if r["event"] == "fallback"]
    result["failures"] = [r["detail"] for r in rs if r["event"] == "failure"]
    result["buffering"] = [r for r in rs if r["event"] == "buffering"]
    (folder / "events.json").write_text(json.dumps(rs, ensure_ascii=False, indent=2))
    (folder / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(
        json.dumps({"index": index + 1, "total": len(cases), **result}, ensure_ascii=False),
        flush=True,
    )
