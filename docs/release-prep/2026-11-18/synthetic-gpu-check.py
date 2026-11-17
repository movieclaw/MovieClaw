#!/usr/bin/env python3
"""Run only in an already authorized GPU environment; no deployment or private inputs.

Read-only inventory:
  python synthetic-gpu-check.py --inventory-only
Candidate-source test, using the installed runtime dependencies and actual FFmpeg:
  PYTHONPATH=/path/to/candidate/src python synthetic-gpu-check.py --backend vaapi
Repeat separately for qsv / nvenc on corresponding hardware. GPU activity sampling,
visual HDR checks and player/device checks remain separate release requirements.
"""

import argparse
import array
import hashlib
import json
import math
import os
import platform
import shutil
import subprocess
import tempfile
import time
from fractions import Fraction
from pathlib import Path

EXPECTED_SOURCE = "94cb972c0fbfc6d0705c7ab724cc69bb536f109c2d7940ff76f31dcee15545c7"


def probe_media(path: Path) -> dict:
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-count_frames",
            "-show_streams",
            "-show_format",
            "-of",
            "json",
            str(path),
        ],
        capture_output=True,
        check=True,
        timeout=60,
    )
    return json.loads(proc.stdout)


def validate_output(
    path: Path,
    *,
    expected_duration: float,
    expected_frames: int,
    fps: float,
    expected_start: float | None = None,
) -> dict:
    """Validate coverage and decoded test-pattern/tone content, not just exit status."""
    assert expected_duration > 0 and expected_frames > 0 and fps > 0
    media = probe_media(path)
    video = next(s for s in media["streams"] if s["codec_type"] == "video")
    duration = float(media["format"]["duration"])
    # One boundary video frame and two AAC frames for encoder priming / tail padding.
    tolerance = 1 / fps + 2 * 1024 / 48000
    assert math.isfinite(duration) and abs(duration - expected_duration) <= tolerance, (
        f"remaining duration: expected {expected_duration}, got {duration}, tolerance {tolerance}"
    )
    frames = int(video.get("nb_read_frames", "0"))
    assert abs(frames - expected_frames) <= 1 and frames > 0, (
        f"video frames: expected {expected_frames} +/- 1, decoded {frames}"
    )
    # A single frame has no inter-frame rate; ffprobe may report 0/0 or an estimate.
    if frames > 1:
        rate = video.get("avg_frame_rate")
        if rate in (None, "N/A", "0/0"):
            rate = video.get("r_frame_rate", "0/1")
        frame_rate = float(Fraction("0/1" if rate == "0/0" else rate))
        assert abs(frame_rate - fps) < 0.001, f"video frame rate: expected {fps}, got {frame_rate}"
    audio = next((s for s in media["streams"] if s["codec_type"] == "audio"), None)
    assert audio and audio["codec_name"] == "aac", "AAC audio is missing or has the wrong codec"
    assert audio.get("channels") == 2, "audio channels must be stereo"

    raw_video = subprocess.run(
        [
            "ffmpeg",
            "-xerror",
            "-v",
            "error",
            "-i",
            str(path),
            "-map",
            "0:v:0",
            "-an",
            "-vf",
            "scale=32:18,format=gray",
            "-fps_mode",
            "passthrough",
            "-f",
            "rawvideo",
            "-",
        ],
        capture_output=True,
        check=True,
        timeout=60,
    ).stdout
    frame_size = 32 * 18
    assert raw_video and len(raw_video) % frame_size == 0, "video content is empty or incomplete"
    decoded_frames = len(raw_video) // frame_size
    assert decoded_frames == frames, "actual decoded video frames differ from ffprobe count"
    timeline = json.loads(
        subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_frames",
                "-show_entries",
                "frame=best_effort_timestamp_time,duration_time,pkt_duration_time",
                "-of",
                "json",
                str(path),
            ],
            capture_output=True,
            check=True,
            timeout=60,
        ).stdout
    )["frames"]
    assert len(timeline) == decoded_frames, "video timestamp/frame count mismatch"
    pts = [float(frame["best_effort_timestamp_time"]) for frame in timeline]
    gaps = [b - a for a, b in zip(pts[:-1], pts[1:], strict=True)]
    assert all(0 < gap <= 2 / fps + 0.001 for gap in gaps), "video timestamp gap or regression"
    last_duration = float(timeline[-1].get("duration_time", 1 / fps))
    video_duration = pts[-1] - pts[0] + last_duration
    assert abs(video_duration - expected_duration) <= tolerance, (
        f"video duration: expected {expected_duration}, got {video_duration}"
    )
    if expected_start is not None:
        assert abs(pts[0] - expected_start) <= tolerance, (
            f"video seek start: expected {expected_start}, got {pts[0]}"
        )
    assert max(raw_video) - min(raw_video) > 16, "video content has no test-pattern contrast"
    motion = 0.0
    if decoded_frames > 1:
        motion = sum(
            abs(a - b) for a, b in zip(raw_video[frame_size:], raw_video[:-frame_size], strict=True)
        ) / ((decoded_frames - 1) * frame_size)
        assert motion > 0.1, "video content is frozen instead of the moving test pattern"
    raw_audio = subprocess.run(
        [
            "ffmpeg",
            "-xerror",
            "-v",
            "error",
            "-i",
            str(path),
            "-map",
            "0:a:0",
            "-vn",
            "-ac",
            "2",
            "-ar",
            "48000",
            "-c:a",
            "pcm_s16le",
            "-f",
            "s16le",
            "-",
        ],
        capture_output=True,
        check=True,
        timeout=60,
    ).stdout
    assert raw_audio and len(raw_audio) % 4 == 0, "audio content is empty or has incomplete samples"
    audio_duration = len(raw_audio) / (48000 * 2 * 2)
    assert abs(audio_duration - expected_duration) <= tolerance, (
        f"audio duration: expected {expected_duration}, got {audio_duration}"
    )
    samples = array.array("h", raw_audio)
    rms = math.sqrt(sum(value * value for value in samples) / len(samples))
    assert rms > 50, "audio content is silent instead of the synthetic tone"
    return {
        "expected_duration": expected_duration,
        "duration": duration,
        "duration_tolerance": tolerance,
        "expected_frames": expected_frames,
        "video_frames": decoded_frames,
        "video_duration": video_duration,
        "video_start": pts[0],
        "frame_tolerance": 1,
        "video_motion": motion,
        "audio_codec": audio["codec_name"],
        "audio_channels": audio["channels"],
        "audio_duration": audio_duration,
        "audio_rms": rms,
    }


def inventory() -> dict:
    result = {"os": platform.system(), "release": platform.release(), "arch": platform.machine()}
    for name, args in {
        "ffmpeg_version": ["ffmpeg", "-version"],
        "encoders": ["ffmpeg", "-hide_banner", "-encoders"],
        "filters": ["ffmpeg", "-hide_banner", "-filters"],
        "hwaccels": ["ffmpeg", "-hide_banner", "-hwaccels"],
    }.items():
        if shutil.which(args[0]):
            proc = subprocess.run(args, capture_output=True, text=True, timeout=15)
            result[name] = proc.stdout
    result["drm"] = []
    if shutil.which("lspci"):
        pci = subprocess.run(["lspci", "-nn"], capture_output=True, text=True, timeout=15)
        result["pci_display"] = [
            line
            for line in pci.stdout.splitlines()
            if any(kind in line for kind in ["VGA", "3D controller", "Display controller"])
        ]
    for node in sorted(Path("/dev/dri").glob("renderD*")):
        device = Path("/sys/class/drm") / node.name / "device/uevent"
        fields = {}
        if device.exists():
            fields = dict(
                line.split("=", 1) for line in device.read_text().splitlines() if "=" in line
            )
        result["drm"].append(
            {
                "node": str(node),
                "readable": os.access(node, os.R_OK),
                "writable": os.access(node, os.W_OK),
                "driver": fields.get("DRIVER"),
                "pci_id": fields.get("PCI_ID"),
            }
        )
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory-only", action="store_true")
    parser.add_argument("--backend", choices=["vaapi", "qsv", "nvenc"])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    details = inventory()
    if args.inventory_only:
        print(json.dumps(details, indent=2))
        return
    if not args.backend:
        parser.error("--backend is required for encoding tests")
    if args.output:
        args.output.mkdir(parents=True, exist_ok=False)
        root = args.output.resolve()
    else:
        root = Path(tempfile.mkdtemp(prefix="movieclaw-synthetic-gpu-"))

    # Import the fixed candidate's source, not an arbitrary running app installation.
    from movieclaw_api import __version__
    from movieclaw_api.services.playback import ffmpeg_args
    from movieclaw_api.services.playback.hwprobe import probe_backends
    from movieclaw_playback.decide import AudioPlan, PlaybackPlan, PlaybackTier, VideoPlan

    source = Path(ffmpeg_args.__file__)
    report = {
        "version": __version__,
        "source": str(source),
        "ffmpeg_args_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "backend": args.backend,
        "inventory": details,
        "cases": [],
        "gpu_activity": "NOT VERIFIED: attach existing GPU monitor samples separately",
        "visual_hdr_and_players": "NOT VERIFIED: separate manual release requirements",
    }

    def save() -> None:
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(name: str, argv: list[str]) -> None:
        (root / f"{name}.argv.json").write_text(json.dumps(argv, indent=2))
        with (root / f"{name}.out").open("w") as out, (root / f"{name}.err").open("w") as err:
            proc = subprocess.run(argv, stdout=out, stderr=err, timeout=300)
        if proc.returncode:
            report["error"] = {"case": name, "exit_code": proc.returncode}
            save()
            raise SystemExit(f"FAIL {name}; evidence: {root}")

    save()
    if __version__ != "0.51.0" or report["ffmpeg_args_sha256"] != EXPECTED_SOURCE:
        raise SystemExit(f"BLOCKED: wrong candidate source; evidence: {root}")
    status = next(s for s in probe_backends(force=True) if s.name == args.backend)
    backend = ffmpeg_args.HW_BACKENDS[args.backend]
    report["probe_available"] = status.available
    report["native_tonemap"] = ffmpeg_args.native_tonemap_filter(backend)
    save()
    if not status.available or not report["native_tonemap"]:
        raise SystemExit(f"BLOCKED: hardware/native HDR chain unavailable; evidence: {root}")

    for hdr in [False, True]:
        name = "hdr-pq" if hdr else "sdr-dts"
        sample = root / f"{name}.mkv"
        color = "bt2020:smpte2084:bt2020nc" if hdr else "bt709:bt709:bt709"
        primaries, transfer, matrix = color.split(":")
        filters = (
            f"format={'yuv420p10le' if hdr else 'yuv420p'},"
            f"setparams=color_primaries={primaries}:color_trc={transfer}:colorspace={matrix}"
        )
        run(
            f"generate-{name}",
            [
                "ffmpeg",
                "-hide_banner",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"testsrc2=size={'3840x2160' if hdr else '1920x1080'}:rate=12:duration=8",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=48000:duration=8",
                "-vf",
                filters,
                "-c:v",
                "libx265",
                "-preset",
                "ultrafast",
                "-x265-params",
                "log-level=error:pools=2:frame-threads=2",
                "-g",
                "24",
                "-c:a",
                "dca",
                "-strict",
                "-2",
                "-b:a",
                "768k",
                "-shortest",
                str(sample),
            ],
        )
        streams = probe_media(sample)["streams"]
        video = next(s for s in streams if s["codec_type"] == "video")
        assert video["codec_name"] == "hevc"
        assert video["color_transfer"] == transfer
        assert any(s["codec_name"] == "dts" for s in streams)
        source_frames = int(video["nb_read_frames"])
        fps = float(Fraction(video["avg_frame_rate"]))
        assert source_frames == 96 and fps == 12, "synthetic source must contain all 8 seconds"
        for seek in [None, 0, 2000, 5000]:
            audio_only = seek is None
            start = seek or 0
            case = f"{name}-audio-only" if audio_only else f"{name}-seek-{start}"
            target = root / case
            target.mkdir()
            plan = PlaybackPlan(
                tier=PlaybackTier.AUDIO_TRANSCODE
                if audio_only
                else PlaybackTier.HARDWARE_TRANSCODE,
                file_id=1,
                container="hls-fmp4",
                video=VideoPlan(action="copy", codec="hevc")
                if audio_only
                else VideoPlan(
                    action="transcode",
                    codec="h264",
                    height=720,
                    source_codec="hevc",
                    source_bit_depth=10 if hdr else 8,
                    tone_map=hdr,
                ),
                audio=AudioPlan(
                    action="transcode", track_ref="embedded:0", codec="aac", channels=2
                ),
                reason="release synthetic hardware verification",
            )
            command = ffmpeg_args.build_hls_command(
                plan,
                source_path=str(sample),
                session_dir=target,
                start_ms=start,
                start_number=start // 4000,
                hw_backend=None if audio_only else args.backend,
            )
            argv = list(command.argv)
            if not audio_only:
                assert argv[argv.index("-c:v") + 1] == backend.encoder
                assert "-noautoscale" in argv
                assert (
                    argv[argv.index("-hwaccel_output_format") + 1] == backend.hwaccel_output_format
                )
            argv[-1:-1] = ["-progress", "pipe:1"]
            before = time.monotonic()
            run(case, argv)
            output = probe_media(command.playlist_path)
            v = next(s for s in output["streams"] if s["codec_type"] == "video")
            assert v["codec_name"] == ("hevc" if audio_only else "h264")
            assert v["height"] == (video["height"] if audio_only else 720)
            if hdr and not audio_only:
                assert all(
                    v[k] == "bt709" for k in ["color_space", "color_transfer", "color_primaries"]
                )
            progress = dict(
                line.split("=", 1)
                for line in (root / f"{case}.out").read_text().splitlines()
                if "=" in line
            )
            assert progress.get("progress") == "end"
            assert int(progress.get("drop_frames", "0")) == 0
            try:
                validation = validate_output(
                    command.playlist_path,
                    expected_duration=source_frames / fps - start / 1000,
                    expected_frames=source_frames - math.ceil(start / 1000 * fps),
                    fps=fps,
                    expected_start=start / 1000,
                )
            except (AssertionError, ValueError, subprocess.CalledProcessError) as exc:
                report["error"] = {"case": case, "reason": str(exc)}
                save()
                raise SystemExit(f"FAIL {case}: {exc}; evidence: {root}") from exc
            report["cases"].append(
                {
                    "case": case,
                    "pass": True,
                    "seconds": round(time.monotonic() - before, 3),
                    "drop_frames": progress.get("drop_frames"),
                    "streams": output["streams"],
                    "validation": validation,
                }
            )
            save()
    print(f"PASS six hardware + two audio-only cases; remaining manual requirements: {root}")


if __name__ == "__main__":
    main()
