"""样片矩阵：Windows 转码器（NVENC）对各类片源的实测（docs/design/remote-transcode.md §7.3）。

「其他平台后端要先完成能力声明、编码参数和样片矩阵验证」——这份测试就是那张矩阵的可重复版本：
每一行造一段样片，走真实的 NAS → Worker → NVENC → 回传 → 客户端解码，量三样东西：

- 结果对不对：播放列表能从头解到尾、帧数与片长对得上、输出规格（分辨率 / 8-bit / BT.709）符合预期；
- 起播多快：从点播放（开会话）到第一个分片完整可取；
- 稳态多快：Worker 从出第一批字节到转完的速度（倍实时）。

要把整张表跑一遍约十几分钟，默认跳过：``MOVIECLAW_MATRIX=1`` 打开，``MOVIECLAW_MATRIX_OUT=<文件>``
把每行结果以 JSON 行追加进去（文档里的表就是据此整理的）。需要 NVIDIA 显卡与 jellyfin-ffmpeg，
见 ``windows_transcoder_stack``。
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from typing import Any

import pytest
from pgs_sup import make_sup
from windows_transcoder_stack import (
    diagnostics,
    end_session,
    make_source,
    require_nvenc_worker,
    running_stack,
    seed,
    start_session,
    wait_for,
)

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not os.environ.get("MOVIECLAW_MATRIX"), reason="样片矩阵要十几分钟，MOVIECLAW_MATRIX=1 才跑"
    ),
]

HDR10_TAGS = (
    "format=p010le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc"
)
HLG_TAGS = (
    "format=p010le,setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc"
)
BT2020_SDR_TAGS = (
    "format=p010le,setparams=color_primaries=bt2020:color_trc=bt709:colorspace=bt2020nc"
)
BT709_10BIT_TAGS = "format=p010le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"


@dataclass
class Case:
    id: str
    label: str
    make: dict[str, Any]
    request: dict[str, Any] = field(default_factory=dict)
    #: 期望输出高度（None = 不查）与是否期望成功
    height: int | None = 1080
    expect: str = "ok"  # ok | fail
    seconds: int = 30
    #: 内封一条 PGS 字幕（1–4 秒出现一个白色矩形）并要求烧录进画面，逐像素核对
    burn: bool = False


CASES = [
    # —— SDR，NVDEC 能硬解的编码 ——
    Case(
        "h264-1080p-to-720p",
        "H.264 8-bit 1080p → 720p（网页选画质上限）",
        dict(codec="libx264", video_extra=("-preset", "veryfast", "-profile:v", "high")),
        request=dict(max_height=720),
        height=720,
    ),
    Case("hevc-1080p", "HEVC 8-bit 1080p SDR → 1080p", dict(codec="hevc_nvenc")),
    Case("hevc-1080p60", "HEVC 8-bit 1080p60 SDR → 1080p", dict(codec="hevc_nvenc", rate=60)),
    Case("hevc-4k", "HEVC 8-bit 4K SDR → 1080p", dict(codec="hevc_nvenc", size="3840x2160")),
    Case(
        "hevc-10bit-bt709",
        "HEVC 10-bit 1080p（BT.709）→ 1080p 8-bit",
        dict(codec="hevc_nvenc", pix_fmt="p010le", vf=BT709_10BIT_TAGS),
    ),
    Case(
        "hevc-longgop",
        "HEVC 1080p 长 GOP + B 帧（x265）→ 1080p",
        dict(
            codec="libx265",
            video_extra=(
                "-preset",
                "ultrafast",
                "-x265-params",
                "keyint=250:bframes=8:rc-lookahead=20:log-level=error",
            ),
        ),
    ),
    Case(
        "vp9-1080p",
        "VP9 1080p → 1080p",
        dict(
            codec="libvpx-vp9",
            video_extra=("-deadline", "realtime", "-cpu-used", "8", "-row-mt", "1"),
        ),
    ),
    Case(
        "mpeg2-1080p", "MPEG-2 1080p → 1080p", dict(codec="mpeg2video", video_extra=("-b:v", "20M"))
    ),
    Case(
        "mpeg4-720p",
        "MPEG-4 part 2 720p → 720p",
        dict(codec="mpeg4", size="1280x720", video_extra=("-b:v", "6M")),
        height=720,
    ),
    Case(
        "vp8-720p",
        "VP8 720p → 720p",
        dict(
            codec="libvpx", size="1280x720", video_extra=("-deadline", "realtime", "-cpu-used", "8")
        ),
        height=720,
    ),
    # —— SDR，NVDEC 解不了、要退到 CPU 软解的编码（RTX 20 系没有 AV1 硬解；Hi10P 各代都不行）——
    Case(
        "av1-1080p",
        "AV1 1080p（本卡无 AV1 硬解）→ 1080p",
        dict(codec="libsvtav1", video_extra=("-preset", "12", "-g", "48")),
    ),
    Case(
        "h264-hi10p-1080p",
        "H.264 High 10 1080p（无硬解）→ 720p（网页选画质上限）",
        dict(
            codec="libx264",
            pix_fmt="yuv420p10le",
            video_extra=("-preset", "veryfast", "-profile:v", "high10"),
        ),
        request=dict(max_height=720),
        height=720,
    ),
    # —— 色彩：要走色彩空间转换（CPU 滤镜）而非 tone-map ——
    Case(
        "bt2020-sdr-10bit",
        "HEVC 10-bit BT.2020 SDR → BT.709",
        dict(codec="hevc_nvenc", pix_fmt="p010le", vf=BT2020_SDR_TAGS),
    ),
    # —— HDR：tonemap_cuda 整条链在显卡上 ——
    Case(
        "hdr10-4k",
        "HDR10 4K → 1080p SDR",
        dict(codec="hevc_nvenc", size="3840x2160", pix_fmt="p010le", vf=HDR10_TAGS),
    ),
    Case(
        "hdr10-1080p",
        "HDR10 1080p → 1080p SDR",
        dict(codec="hevc_nvenc", pix_fmt="p010le", vf=HDR10_TAGS),
    ),
    Case(
        "hlg-4k",
        "HLG 4K → 1080p SDR",
        dict(codec="hevc_nvenc", size="3840x2160", pix_fmt="p010le", vf=HLG_TAGS),
    ),
    # —— 字幕烧录：PGS 是位图，只能压进画面；叠字幕在 CPU 上，编码仍在 NVENC ——
    Case(
        "pgs-burn-1080p",
        "PGS 字幕烧录（H.264 1080p：NVDEC 解码 → CPU 叠字幕 → NVENC）",
        dict(codec="libx264", video_extra=("-preset", "veryfast", "-profile:v", "high")),
        burn=True,
    ),
    Case(
        "pgs-burn-hdr10",
        "PGS 字幕烧录 + HDR10（CPU 色调映射 → 叠字幕 → NVENC）→ 1080p SDR",
        dict(codec="hevc_nvenc", pix_fmt="p010le", vf=HDR10_TAGS),
        burn=True,
    ),
    # —— 音频：客户端只收 AAC，其余编码都要转，多声道要降混 ——
    Case(
        "audio-ac3-5.1",
        "音频 AC-3 5.1 → AAC 立体声",
        dict(codec="hevc_nvenc", audio=("-c:a", "ac3", "-ac", "6")),
    ),
    Case(
        "audio-eac3-5.1",
        "音频 E-AC-3 5.1 → AAC 立体声",
        dict(codec="hevc_nvenc", audio=("-c:a", "eac3", "-ac", "6")),
    ),
    Case(
        "audio-dts-5.1",
        "音频 DTS 5.1 → AAC 立体声",
        dict(
            codec="hevc_nvenc", audio=("-strict", "-2", "-c:a", "dca", "-ac", "6", "-b:a", "768k")
        ),
    ),
    Case("audio-flac", "音频 FLAC 立体声 → AAC", dict(codec="hevc_nvenc", audio=("-c:a", "flac"))),
]


def _ffprobe(stack, args: list[str], target: str) -> dict[str, Any]:
    done = subprocess.run(
        [stack["ffprobe"], "-v", "error", *args, "-of", "json", target],
        capture_output=True,
        timeout=300,
    )
    assert done.returncode == 0, done.stderr.decode(errors="replace")[-600:]
    return json.loads(done.stdout)


def _first_segment_seconds(stack, data: dict[str, Any], started: float) -> float:
    """点播放 → 第一个分片完整可取（播放列表、init、seg0 都拿到）。"""
    client = stack["client"]
    playlist = client.get(data["stream_url"])
    assert playlist.status_code == 200, playlist.text
    base = data["stream_url"].split("index.m3u8")[0]
    query = data["stream_url"].split("?", 1)[1]
    init = re.search(r'URI="([^"]+)"', playlist.text)
    segment = next(line for line in playlist.text.splitlines() if line and not line.startswith("#"))
    for name in ([init.group(1)] if init else []) + [segment]:
        target = name if name.startswith(("http", "/")) else base + name
        if "?" not in target:
            target += "?" + query
        fetched = client.get(target)
        assert fetched.status_code in (200, 206), (name, fetched.status_code)
    return time.monotonic() - started


#: 烧录用例里字幕矩形的位置与时间（make_sup 的参数），以及它里面 / 外面的取样点
SUP_RECT = dict(video_w=1920, video_h=1080, x=560, y=900, w=800, h=100, start_s=1.0, end_s=4.0)
INSIDE, OUTSIDE = (960, 950), (960, 300)


def _pixel(stack, data: dict[str, Any], seconds: float, point: tuple[int, int]) -> tuple[int, ...]:
    """客户端像素：把转码出来的第 ``seconds`` 秒解成一帧，取一个点附近 16×16 的平均 RGB。"""
    average = f"crop=16:16:{point[0]}:{point[1]},scale=1:1:flags=area"
    done = subprocess.run(
        [
            stack["ffmpeg"], "-v", "error", "-ss", str(seconds),
            "-i", stack["url"] + data["stream_url"],
            "-frames:v", "1", "-vf", average, "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
        ],
        capture_output=True,
        timeout=120,
    )  # fmt: skip
    detail = done.stderr.decode(errors="replace")[-400:]
    assert done.returncode == 0 and len(done.stdout) == 3, detail
    return tuple(done.stdout)


def _record(row: dict[str, Any]) -> None:
    print("MATRIX", json.dumps(row, ensure_ascii=False))
    out = os.environ.get("MOVIECLAW_MATRIX_OUT")
    if out:
        with open(out, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    ffmpeg, _caps = require_nvenc_worker()
    with running_stack(tmp_path_factory.mktemp("windows-transcoder-matrix"), ffmpeg) as running:
        yield running


@pytest.mark.parametrize("case", CASES, ids=[case.id for case in CASES])
def test_matrix(stack, case):
    make, request = dict(case.make), dict(case.request)
    if case.burn:
        sup = stack["tmp"] / f"{case.id}.sup"
        sup.write_bytes(make_sup(**SUP_RECT))
        make["extra_inputs"] = ("-f", "sup", "-i", str(sup))
        make["extra_output"] = ("-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:s", "copy")
        request["subtitle_track"] = "embedded:0"
    source = make_source(stack, f"{case.id}.mkv", **make, seconds=case.seconds)
    started = time.monotonic()
    data = start_session(stack, seed(stack, source), **request)
    row: dict[str, Any] = {
        "case": case.id,
        "label": case.label,
        "tier": data["decision"]["tier"],
        "tone_map": (data["decision"].get("video") or {}).get("tone_map"),
        "video_action": (data["decision"].get("video") or {}).get("action"),
        "burn_subtitle": (data["decision"].get("video") or {}).get("burn_subtitle"),
    }
    try:
        row["backend"] = diagnostics(stack, data)["backend"]
        try:
            row["first_segment_s"] = round(_first_segment_seconds(stack, data, started), 2)
        except AssertionError as exc:  # 取不到第一个分片：照常等任务收尾，把原因记进这一行
            row["first_segment_error"] = str(exc)[:200]
        info = wait_for(
            lambda: (lambda d: d if d["job_state"] in {"job.finished", "job.failed"} else None)(
                diagnostics(stack, data)
            ),
            case.seconds * 4 + 60,
            "转码结束",
        )
        row["job_state"] = info["job_state"]
        marks = {e["ev"]: e["wt"] for e in info["timeline"] if e["ev"].startswith("w_")}
        row["worker_ms"] = marks
        if info["job_state"] == "job.finished" and {"w_first_bytes", "w_exit"} <= set(marks):
            row["speed_x"] = round(
                case.seconds / ((marks["w_exit"] - marks["w_first_bytes"]) / 1000), 1
            )
        if info["job_state"] == "job.failed":
            row["error"] = (info.get("job_error") or "")[:300]
            row["stderr_tail"] = (info.get("job_stderr_tail") or "")[-1500:]
        elif "first_segment_error" not in row:
            stream = _ffprobe(
                stack,
                [
                    "-count_frames",
                    "-select_streams",
                    "v:0",
                    "-show_entries",
                    "stream=codec_name,profile,width,height,pix_fmt,color_space,color_transfer,color_primaries,nb_read_frames",
                ],
                stack["url"] + data["stream_url"],
            )["streams"][0]
            row["output"] = stream
            if case.burn:
                row["pixels"] = {
                    "inside_2s": _pixel(stack, data, 2, INSIDE),
                    "outside_2s": _pixel(stack, data, 2, OUTSIDE),
                    "inside_5s": _pixel(stack, data, 5, INSIDE),
                }
    finally:
        end_session(stack, data)
    row["ok"] = row.get("job_state") == "job.finished" and "output" in row
    _record(row)

    if case.expect == "fail":
        assert not row["ok"], row
        return
    assert row["ok"], row
    output = row["output"]
    assert output["codec_name"] == "h264" and output["pix_fmt"] == "yuv420p", output
    if case.height:
        assert output["height"] == case.height, output
    frames = int(output["nb_read_frames"])
    assert abs(frames - case.seconds * (60 if "1080p60" in case.id else 24)) <= 3, output
    if row["tone_map"] or "bt2020-sdr" in case.id:
        assert output.get("color_transfer") in (None, "bt709"), output
        assert output.get("color_primaries") in (None, "bt709"), output
    if case.burn:
        pixels = row["pixels"]
        assert row["burn_subtitle"] == "embedded:0", row
        assert all(c > 200 for c in pixels["inside_2s"]), f"字幕没烧进画面：{pixels}"
        assert not all(c > 200 for c in pixels["outside_2s"]), f"矩形外不该是白色：{pixels}"
        assert not all(c > 200 for c in pixels["inside_5s"]), f"字幕结束后应消失：{pixels}"
