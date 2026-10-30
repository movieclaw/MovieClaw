#!/usr/bin/env python3
"""Summarize device evidence without treating a moving clock as proof of visible video."""

import argparse
import csv
import json
import pathlib
import re
import statistics

from PIL import Image, ImageDraw, ImageOps

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("results")
parser.add_argument(
    "--app-uid", type=int, help="Only count audio streams owned by this installed app UID"
)
args = parser.parse_args()
root = pathlib.Path(args.results)
rows = []
cases = []


def ui_error(node):
    attributes = node.get("attributes", {})
    if attributes.get("id") == "player-error":
        return attributes.get("text", "")
    for child in node.get("children", []):
        found = ui_error(child)
        if found:
            return found
    return ""


for path in sorted(root.glob("*/result.json")):
    result = json.loads(path.read_text())
    events = json.loads((path.parent / "events.json").read_text())
    request = next((e for e in events if e["event"] == "request"), None)
    playing = next((e for e in events if e["event"] == "snapshot" and e["playing"]), None)
    sequence = []
    for event in events:
        candidate = event["engine"]
        if candidate and (not sequence or sequence[-1] != candidate):
            sequence.append(candidate)
    engine = sequence[-1] if sequence else ""
    buffers = [e for e in events if e["event"] == "buffered" and e["engine"] == engine]
    startup_buffer = 0
    startup_buffer_observed = False
    rebuffer = 0
    seek_buffer = 0
    seek_buffer_observed = False
    seek_command = next(
        (e for e in events if e["event"] == "command" and e["detail"] == "seek"), None
    )
    starts = {}
    for event in events:
        if event["event"] != "buffering":
            continue
        if event["detail"] == "start":
            starts[event["engine"]] = event
        elif event["engine"] in starts:
            start = starts.pop(event["engine"])
            duration = event["at"] - start["at"]
            if seek_command and start["at"] >= seek_command["at"]:
                seek_buffer += duration
                seek_buffer_observed = True
            elif playing and start["at"] < playing["at"]:
                startup_buffer += duration
                startup_buffer_observed = True
            elif start["playing"]:
                rebuffer += duration
    one_second = next((e for e in buffers if int(e["detail"]) >= 1000), None)
    audio_path = path.parent / "audio-playing.txt"
    audio = audio_path.read_text() if audio_path.exists() else ""
    streams = re.split(r"  Stream [0-9]+\n", audio)[1:]
    audio_running = sum(
        "Status: RUNNING" in stream
        and (args.app_uid is None or f"User Id: {args.app_uid}\n" in stream)
        for stream in streams
    )
    picture = result.get("pictureResumed", {})
    visual_review = result["playbackAdvanced"] and (
        picture.get("nonBlackFraction", 0) < 0.01 or result.get("pictureDifference", 0) < 1
    )
    delivery = result.get("delivery", [])
    plan = delivery[-1] if delivery else {}
    native_audio = [t for t in (result.get("tracks", [[]]) or [[]])[-1] if t["kind"] == "audio"]
    selected = [i for i, t in enumerate(native_audio) if t["selected"]]
    requested_track = result["case"].get("trackRef")
    track_matches = None
    if requested_track and result["playbackAdvanced"]:
        planned = (plan.get("audio") or {}).get("track_ref")
        if plan.get("tier") == 0:
            track_matches = (
                selected == [int(requested_track.split(":")[1])] and planned == requested_track
            )
        else:
            track_matches = len(selected) == 1 and planned == requested_track
    # Only a callback from the final engine establishes a displayed first frame.
    frame = next((e for e in events if e["event"] == "firstFrame" and e["engine"] == engine), None)
    frame_ms = frame["at"] - request["at"] if frame and request else None
    sessions = [e for e in events if e["event"] == "session"]
    session = sessions[-1] if sessions else None
    opening = next(
        (
            e
            for e in events
            if e["event"] == "snapshot"
            and e["phase"] == "opening"
            and e["engine"] == engine
            and (not session or e["at"] >= session["at"])
        ),
        None,
    )
    engine_playing = next(
        (
            e
            for e in events
            if e["event"] == "snapshot"
            and e["playing"]
            and e["engine"] == engine
            and (not opening or e["at"] >= opening["at"])
        ),
        None,
    )
    inspection = next(
        (e for e in events if e["event"] == "command" and e["detail"] == "tracks"), None
    )
    continuous = [
        e
        for e in events
        if e["event"] == "snapshot"
        and e["engine"] == engine
        and e["playing"]
        and inspection
        and e["at"] < inspection["at"]
    ]
    first_advance = (
        next((e for e in continuous if e["positionMs"] > continuous[0]["positionMs"]), None)
        if continuous
        else None
    )
    clock_confirmed = (
        next((e for e in continuous if e["positionMs"] >= continuous[0]["positionMs"] + 1500), None)
        if continuous
        else None
    )
    # Separate startup/initial-seek latency from sustained playback speed.
    startup_clock_wait = first_advance["at"] - continuous[0]["at"] if first_advance else None
    if first_advance:
        continuous = [e for e in continuous if e["at"] >= first_advance["at"]]
    clock_ratio = None
    if len(continuous) > 1 and continuous[-1]["at"] > continuous[0]["at"]:
        clock_ratio = round(
            (continuous[-1]["positionMs"] - continuous[0]["positionMs"])
            / (continuous[-1]["at"] - continuous[0]["at"]),
            3,
        )
    row = {
        "case": path.parent.name,
        "fileId": result["case"]["fileId"],
        "format": json.dumps(
            result["case"].get("audioFormat", result["case"].get("format", [])), ensure_ascii=False
        ),
        "playbackAdvanced": result["playbackAdvanced"],
        "pause": result["pause"],
        "seek": result["seek"],
        "resume": result["resume"],
        "disposed": result["disposed"],
        "engines": " -> ".join(sequence),
        "sessions": ";".join(result["sessions"]),
        "errorText": re.sub(
            r"https?://[^\s\"<>]+",
            "[media URL]",
            ui_error(json.loads((path.parent / "layout.json").read_text())),
        ),
        "fallbackReasons": ";".join(result.get("fallbacks", [])),
        "failures": ";".join(result["failures"]),
        "firstFrameMs": frame_ms,
        "playingMs": result["playingMs"],
        "negotiationMs": sessions[0]["at"] - request["at"] if sessions and request else None,
        "enginePlayingMs": engine_playing["at"] - opening["at"]
        if engine_playing and opening
        else None,
        "engineFirstFrameMs": frame["at"] - opening["at"] if frame and opening else None,
        "startupBufferMs": startup_buffer if startup_buffer_observed else None,
        "rebufferMs": rebuffer,
        "seekBufferMs": seek_buffer if seek_buffer_observed else None,
        "cache1sMs": one_second["at"] - request["at"] if one_second and request else None,
        "peakCacheSeconds": max((int(e["detail"]) / 1000 for e in buffers), default=None),
        "tier": plan.get("tier"),
        "audioAction": (plan.get("audio") or {}).get("action"),
        "requestedAudio": requested_track,
        "selectedAudioOrdinals": str(selected),
        "audioSelectionMatches": track_matches,
        "audioExpected": bool(
            (plan.get("audio") or {}).get("codec") or native_audio or requested_track
        ),
        "audioRunningStreams": audio_running,
        "visualReviewNeeded": visual_review,
        "pictureDifference": result.get("pictureDifference"),
        "playbackClockRatio": clock_ratio,
        "startupClockWaitMs": startup_clock_wait,
        "clockAdvanceMs": clock_confirmed["at"] - request["at"]
        if clock_confirmed and request
        else None,
    }
    rows.append(row)
    cases.append((path.parent, result))

with (root / "results.csv").open("w", newline="") as output:
    if rows:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def distribution(key, predicate=lambda r: True):
    values = sorted(r[key] for r in rows if r[key] is not None and predicate(r))
    if not values:
        return None
    return {
        "count": len(values),
        "min": min(values),
        "median": statistics.median(values),
        "p95": values[min(len(values) - 1, int(0.95 * len(values)))],
        "max": max(values),
    }


summary = {
    "completed": len(rows),
    "playbackAdvanced": sum(r["playbackAdvanced"] for r in rows),
    "controlsPassed": sum(
        all(r[k] for k in ("playbackAdvanced", "pause", "seek", "resume", "disposed")) for r in rows
    ),
    "fallbackCases": sum(" -> " in r["engines"] for r in rows),
    "audioSelectionFailures": [r["case"] for r in rows if r["audioSelectionMatches"] is False],
    "unverifiedAudioCases": [
        r["case"] for r in rows if r["requestedAudio"] and r["audioSelectionMatches"] is None
    ],
    "audioRunning": sum(r["audioRunningStreams"] > 0 for r in rows),
    "missingExpectedAudio": [
        r["case"]
        for r in rows
        if r["playbackAdvanced"] and r["audioExpected"] and r["audioRunningStreams"] == 0
    ],
    "visualReviewNeeded": [r["case"] for r in rows if r["visualReviewNeeded"]],
    "slowClockCases": [
        r["case"]
        for r in rows
        if r["playbackClockRatio"] is not None and r["playbackClockRatio"] < 0.8
    ],
    "failedCases": [r["case"] for r in rows if not r["playbackAdvanced"]],
    "firstFrameMs": distribution("firstFrameMs"),
    "mpvPlayingMs": distribution("playingMs", lambda r: r["engines"].endswith("mpv")),
    "clockAdvanceMs": distribution("clockAdvanceMs"),
    "startupClockWaitMs": distribution("startupClockWaitMs"),
    "negotiationMs": distribution("negotiationMs"),
    "enginePlayingMs": distribution("enginePlayingMs"),
    "startupBufferMs": distribution("startupBufferMs"),
    "seekBufferMs": distribution("seekBufferMs"),
    "rebufferCases": [r["case"] for r in rows if r["rebufferMs"] > 0],
}
(root / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
print(json.dumps(summary, ensure_ascii=False, indent=2))


def surface_bounds(node):
    attributes = node.get("attributes", {})
    if attributes.get("id") == "player-surface":
        return tuple(int(x) for x in re.findall(r"\d+", attributes["bounds"]))
    for child in node.get("children", []):
        found = surface_bounds(child)
        if found:
            return found
    return None


for page in range((len(cases) + 11) // 12):
    sheet = Image.new("RGB", (1920, 1000), "#222222")
    draw = ImageDraw.Draw(sheet)
    for offset, (folder, result) in enumerate(cases[page * 12 : page * 12 + 12]):
        x, y = (offset % 3) * 640, (offset // 3) * 250
        bounds = surface_bounds(json.loads((folder / "layout.json").read_text()))
        label = folder.name + " | " + " -> ".join(result["engines"])
        draw.text((x + 8, y + 4), label, fill="white")
        for column, name in enumerate(
            ("playing", "resumed") if result["playbackAdvanced"] else ("failure",)
        ):
            path = folder / (name + ".png")
            if not path.exists():
                continue
            with Image.open(path) as screenshot:
                frame = (
                    screenshot.crop(bounds) if bounds and result["playbackAdvanced"] else screenshot
                )
                frame = ImageOps.contain(frame, (316, 214))
                sheet.paste(frame, (x + column * 320, y + 25))
    sheet.save(root / f"contact-{page + 1:02d}.jpg", quality=85)
