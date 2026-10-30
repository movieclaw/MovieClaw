#!/usr/bin/env python3
"""Check real EOF/replay with authenticated NAS fixtures."""

import argparse
import json
import pathlib
import shlex
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--hdc", required=True)
p.add_argument("--fixture", required=True, help="Single movie JSON, not a series with auto-next")
p.add_argument("--output", required=True)
a = p.parse_args()
out = pathlib.Path(a.output)
out.mkdir(parents=True, exist_ok=True)
fixture = json.loads(pathlib.Path(a.fixture).read_text())


def hdc(*args):
    return subprocess.run([a.hdc, *args], capture_output=True, text=True, timeout=30).stdout


def send(data):
    hdc(
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


def state(rs):
    return next((r for r in reversed(rs) if r["event"] == "snapshot"), {})


def wait(case, predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rs = records(case)
        if predicate(rs):
            return rs
        time.sleep(0.4)
    return records(case)


for engine in ("avplayer", "mpv"):
    case = "eof-" + engine + "-" + str(int(time.time() * 1000))
    folder = out / engine
    folder.mkdir(exist_ok=True)
    send({"command": "stop"})
    time.sleep(1)
    send({**fixture, "caseId": case, "engine": engine, "startMs": 1})
    rs = wait(case, lambda es: state(es).get("positionMs", 0) >= 1500, 75)
    initial = state(rs)
    duration = initial.get("durationMs", 0)
    send({"command": "seek", "positionMs": max(1, duration - 6000)})
    rs = wait(case, lambda es: state(es).get("phase") == "ended", 25)
    ended = state(rs)
    result = {
        "engine": engine,
        "started": initial.get("playing", False),
        "durationMs": duration,
        "ended": ended.get("phase") == "ended",
        "endPositionMs": ended.get("positionMs"),
    }
    send({"command": "play"})
    rs = wait(
        case,
        lambda es: (
            state(es).get("playing", False) and 1000 < state(es).get("positionMs", 0) < 20000
        ),
        25,
    )
    replay = state(rs)
    result["replayedFromBeginning"] = (
        replay.get("playing", False) and 1000 < replay.get("positionMs", 0) < 20000
    )
    hdc("shell", "uitest screenCap -p /data/local/tmp/mc-lifecycle.png")
    hdc("file", "recv", "/data/local/tmp/mc-lifecycle.png", str(folder / "replay.png"))
    send({"command": "stop"})
    time.sleep(1)
    rs = records(case)
    result["disposed"] = any(e["event"] == "dispose" for e in rs)
    (folder / "events.json").write_text(json.dumps(rs, ensure_ascii=False, indent=2))
    (folder / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result), flush=True)
