#!/usr/bin/env python3
"""Exercise real native players through media_proxy.py; app must be signed in.
The fixture is a single direct-play MP4 with enough bitrate to drain the buffer.
"""

import argparse
import json
import pathlib
import shlex
import subprocess
import time
import urllib.request

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--hdc", required=True)
p.add_argument("--fixture", required=True)
p.add_argument("--output", required=True)
p.add_argument("--proxy", default="http://127.0.0.1:53123")
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


def control(rate):
    request = urllib.request.Request(
        a.proxy + "/__control",
        data=json.dumps({"bytesPerSecond": rate}).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.load(urllib.request.urlopen(request, timeout=5))


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


def wait(case, predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        rs = records(case)
        if predicate(rs):
            return rs
        time.sleep(0.5)
    return records(case)


def state(rs):
    return next((r for r in reversed(rs) if r["event"] == "snapshot"), {})


try:
    for engine in ("avplayer", "mpv"):
        case = "network-" + engine + "-" + str(int(time.time() * 1000))
        folder = out / engine
        folder.mkdir(exist_ok=True)
        send({"command": "stop"})
        time.sleep(1)
        control(2_000_000)  # 16 Mbps; avoid hundreds of seconds of MPV read-ahead.
        send({**fixture, "caseId": case, "engine": engine, "startMs": 1, "proxyOrigin": a.proxy})
        rs = wait(case, lambda events: state(events).get("positionMs", 0) >= 2000, 75)
        before = state(rs)
        result = {"engine": engine, "started": before.get("playing", False), "beforeStall": before}
        result["proxyBefore"] = control(0)
        stalled = wait(case, lambda events: state(events).get("buffering", False), 50)
        result["bufferingObserved"] = state(stalled).get("buffering", False)
        frozen = state(stalled)
        time.sleep(4)
        result["stalledPositionDeltaMs"] = state(records(case)).get("positionMs", 0) - frozen.get(
            "positionMs", 0
        )
        restored_at = int(time.time() * 1000)
        result["proxyAfter"] = control(-1)
        rs = wait(
            case,
            lambda events, frozen=frozen: (
                state(events).get("positionMs", 0) > frozen.get("positionMs", 0) + 2000
                and not state(events).get("buffering", True)
            ),
            30,
        )
        after = state(rs)
        result["recovered"] = (
            after.get("playing", False)
            and not after.get("buffering", True)
            and after.get("positionMs", 0) > frozen.get("positionMs", 0) + 2000
        )
        end = next(
            (
                e
                for e in rs
                if e["event"] == "buffering" and e["detail"] == "end" and e["at"] >= restored_at
            ),
            None,
        )
        result["recoveryBufferMs"] = end["at"] - restored_at if end else None
        # A far seek requests uncached media. A short network stall must not
        # turn an otherwise recoverable seek into a permanent playback failure.
        send({"command": "pause"})
        time.sleep(0.5)
        target = min(after.get("positionMs", 0) + 600000, after.get("durationMs", 0) - 20000)
        control(0)
        send({"command": "seek", "positionMs": target})
        time.sleep(10)
        result["seekSurvived10sStall"] = state(records(case)).get("phase") != "failed"
        send({"command": "play"})
        seek_restored_at = int(time.time() * 1000)
        control(-1)
        rs = wait(
            case,
            lambda events, target=target: (
                state(events).get("playing", False)
                and state(events).get("positionMs", 0) > target + 1500
                and not state(events).get("buffering", True)
            ),
            40,
        )
        seek_after = state(rs)
        result["seekRecovered"] = (
            seek_after.get("playing", False) and seek_after.get("positionMs", 0) > target + 1500
        )
        result["seekRecoveryObservedMs"] = int(time.time() * 1000) - seek_restored_at
        result["engines"] = list(dict.fromkeys(e["engine"] for e in rs if e["engine"]))
        result["failures"] = [e["detail"] for e in rs if e["event"] == "failure"]
        hdc("shell", "uitest screenCap -p /data/local/tmp/mc-network.png")
        hdc("file", "recv", "/data/local/tmp/mc-network.png", str(folder / "recovered.png"))
        send({"command": "stop"})
        time.sleep(1)
        rs = records(case)
        result["disposed"] = any(e["event"] == "dispose" for e in rs)
        (folder / "events.json").write_text(json.dumps(rs, ensure_ascii=False, indent=2))
        (folder / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps(result, ensure_ascii=False), flush=True)
finally:
    control(-1)
    send({"command": "stop"})
