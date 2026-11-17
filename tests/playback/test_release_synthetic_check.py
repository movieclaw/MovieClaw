"""The release checker must reject validly encoded but incomplete synthetic outputs."""

import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "docs/release-prep/2026-11-18/synthetic-gpu-check.py"


@pytest.fixture
def checker():
    spec = importlib.util.spec_from_file_location("synthetic_gpu_check", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_truncated_no_audio_cannot_pass_full_checker(checker, tmp_path, monkeypatch):
    from movieclaw_api.services.playback import ffmpeg_args, hwprobe

    def fake_run(argv, **kwargs):
        if argv[0] == "ffprobe":
            path = Path(argv[-1])
            source = path.suffix == ".mkv"
            hdr = "hdr-pq" in str(path)
            copy = source or "audio-only" in str(path)
            video = {
                "codec_type": "video",
                "codec_name": "hevc" if copy else "h264",
                "height": (2160 if hdr else 1080) if copy else 720,
                "color_transfer": "smpte2084" if hdr and copy else "bt709",
                "color_primaries": "bt2020" if hdr and copy else "bt709",
                "color_space": "bt2020nc" if hdr and copy else "bt709",
                "avg_frame_rate": "12/1",
                "nb_read_frames": "96" if source else "1",
            }
            streams = [video]
            if source:
                streams.append({"codec_type": "audio", "codec_name": "dts", "channels": 1})
            data = {"streams": streams, "format": {"duration": "8" if source else "0.04"}}
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(data), stderr="")
        if hasattr(kwargs.get("stdout"), "write"):
            kwargs["stdout"].write("frame=1\ndrop_frames=0\nprogress=end\n")
        return subprocess.CompletedProcess(argv, 0, stdout=b"", stderr=b"")

    monkeypatch.setattr(checker, "inventory", lambda: {})
    monkeypatch.setattr(checker.subprocess, "run", fake_run)
    monkeypatch.setattr(
        hwprobe, "probe_backends", lambda **kwargs: [SimpleNamespace(name="vaapi", available=True)]
    )
    monkeypatch.setattr(ffmpeg_args, "native_tonemap_filter", lambda *args: "tonemap_vaapi")
    output = tmp_path / "incomplete"
    monkeypatch.setattr(sys, "argv", ["checker", "--backend", "vaapi", "--output", str(output)])
    with pytest.raises(SystemExit, match="FAIL"):
        checker.main()
    report = json.loads((output / "report.json").read_text())
    assert report["cases"] == []
    assert "duration" in report["error"]["reason"]


@pytest.fixture
def hls(tmp_path):
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        pytest.skip("real FFmpeg/ffprobe required")

    def create(*, duration=2.0, start=0.0, mode="valid"):
        root = tmp_path / f"{mode}-{duration}-{start}"
        root.mkdir()
        rate = 25 if mode in ("one-frame", "single-valid") else 12
        video = (
            f"color=black:size=320x180:rate={rate}:duration={duration + start}"
            if mode == "blank-video"
            else f"testsrc2=size=320x180:rate={rate}:duration={duration + start}"
        )
        if mode == "frozen-video":
            video = "testsrc2=size=320x180:rate=12:duration=0.083333,loop=loop=-1:size=1:start=0"
        audio = (
            f"anullsrc=r=48000:cl=stereo:d={duration + start}"
            if mode == "silent-audio"
            else f"sine=frequency=440:sample_rate=48000:duration={duration + start}"
        )
        if mode == "short-audio":
            audio = "sine=frequency=440:sample_rate=48000:duration=0.04"
        command = ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", video]
        if mode != "no-audio" and mode != "one-frame":
            command += ["-f", "lavfi", "-i", audio]
        command += [
            "-ss",
            str(start),
            "-t",
            str(duration),
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            str(rate),
            "-sc_threshold",
            "0",
        ]
        if mode in ("no-audio", "one-frame"):
            command += ["-an"]
        else:
            command += [
                "-c:a",
                "ac3" if mode == "wrong-audio-codec" else "aac",
                "-ac",
                "1" if mode == "mono-audio" else "2",
            ]
        path = root / "index.m3u8"
        command += [
            "-hls_time",
            "0.5",
            "-hls_list_size",
            "0",
            "-hls_segment_type",
            "fmp4",
            str(path),
        ]
        subprocess.run(command, check=True, capture_output=True, timeout=60)
        return path

    return create


@pytest.mark.integration
@pytest.mark.parametrize(
    ("duration", "start"), [(0.04, 0), (0.5, 0), (2, 0), (1.5, 0.5), (0.5, 1.5)]
)
def test_real_short_and_seek_outputs_pass(checker, hls, duration, start):
    fps = 25 if duration < 0.1 else 12
    result = checker.validate_output(
        hls(duration=duration, start=start, mode="single-valid" if duration < 0.1 else "valid"),
        expected_duration=duration,
        expected_frames=round(duration * fps),
        fps=fps,
    )
    assert result["video_frames"] == round(duration * fps)
    assert result["audio_channels"] == 2
    assert result["audio_rms"] > 50


@pytest.mark.integration
@pytest.mark.parametrize(
    ("mode", "message"),
    [
        ("no-audio", "AAC audio"),
        ("wrong-audio-codec", "AAC audio"),
        ("mono-audio", "audio channels"),
        ("silent-audio", "audio content"),
        ("short-audio", "audio duration"),
        ("blank-video", "video content"),
        ("frozen-video", "video content"),
    ],
)
def test_real_invalid_content_is_rejected(checker, hls, mode, message):
    with pytest.raises(AssertionError, match=message):
        checker.validate_output(
            hls(mode=mode),
            expected_duration=2,
            expected_frames=24,
            fps=12,
        )


@pytest.mark.integration
def test_real_single_frame_rejected_even_when_container_duration_is_spoofed(
    checker, hls, monkeypatch
):
    path = hls(duration=0.04, mode="one-frame")
    actual = checker.probe_media(path)
    assert int(actual["streams"][0]["nb_read_frames"]) == 1
    actual["format"]["duration"] = "2"
    monkeypatch.setattr(checker, "probe_media", lambda _: actual)
    with pytest.raises(AssertionError, match="video frames"):
        checker.validate_output(path, expected_duration=2, expected_frames=24, fps=12)


@pytest.mark.integration
def test_actual_decode_rejects_spoofed_frame_and_audio_metadata(checker, hls, monkeypatch):
    path = hls(duration=0.04, mode="one-frame")
    metadata = checker.probe_media(path)
    metadata["format"]["duration"] = "2"
    metadata["streams"][0]["nb_read_frames"] = "24"
    metadata["streams"][0]["avg_frame_rate"] = "12/1"
    metadata["streams"].append({"codec_type": "audio", "codec_name": "aac", "channels": 2})
    monkeypatch.setattr(checker, "probe_media", lambda _: metadata)
    with pytest.raises(AssertionError, match="actual decoded video frames"):
        checker.validate_output(path, expected_duration=2, expected_frames=24, fps=12)


@pytest.mark.integration
def test_full_length_output_from_wrong_seek_window_is_rejected(checker, hls):
    with pytest.raises(AssertionError, match="video seek start"):
        checker.validate_output(
            hls(),
            expected_duration=2,
            expected_frames=24,
            fps=12,
            expected_start=1.5,
        )
