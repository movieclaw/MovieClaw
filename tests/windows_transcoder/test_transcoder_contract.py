"""Windows 转码器与服务端之间写死在两边的约定。

这个程序是独立的纯标准库包，不 import 服务端；凡是两边必须逐字一致的东西（协议版本、机器名规则、
探测用的滤镜串、拒绝理由的措辞、产物名、NAS 下发命令里的产物地址）都在这里对照服务端的真实代码：
改了一边忘了另一边，这里先红。
"""

from __future__ import annotations

import inspect
import re
from pathlib import Path

import pytest
from movieclaw_transcoder import PROTOCOL_VERSION, config, probe
from movieclaw_transcoder.job import Job
from movieclaw_transcoder.uploader import split_artifact_url
from movieclaw_transcoder.websocket import rejection_kind

from movieclaw_api.api.routes import transcode_worker as transcode_worker_routes
from movieclaw_api.services import login_devices
from movieclaw_api.services.playback import ffmpeg_args, remote_worker
from movieclaw_api.services.playback.ffmpeg_args import WorkerVideoCaps, build_hls_command
from movieclaw_playback.decide import AudioPlan, PlaybackPlan, PlaybackTier, VideoPlan


def test_the_protocol_version_is_the_servers():
    assert PROTOCOL_VERSION == remote_worker.REMOTE_WORKER_PROTOCOL_VERSION


def test_a_worker_id_this_package_makes_is_one_the_server_accepts():
    assert config.WORKER_ID_RE.pattern == remote_worker._WORKER_ID.pattern
    for host in ("DESKTOP-ABC_1", "我的电脑", "a" * 100, "  my pc  "):
        assert remote_worker._WORKER_ID.fullmatch(config.sanitize_worker_id(host))


def test_workers_pair_as_the_worker_kind():
    assert "worker" in login_devices.PAIRING_KINDS


def test_the_self_test_hdr_chain_is_exactly_the_one_the_nas_sends():
    """探测用的滤镜串必须就是真实转码用的那一串，否则「探测过了」没有意义。"""
    assert probe.NVENC_TONEMAP == ffmpeg_args.NVENC_TONEMAP


def test_every_filter_the_nas_looks_for_is_one_this_worker_can_declare():
    needed = {
        ffmpeg_args.HW_BACKENDS["nvenc"].scale_filter,
        ffmpeg_args.NVENC_TONEMAP.split("=", 1)[0],
        ffmpeg_args._SOFTWARE_TONEMAP.split("=", 1)[0],
    }
    assert needed <= set(probe.REPORTED_FILTERS)


def test_the_rejection_reasons_the_server_writes_are_told_apart():
    """Worker 靠措辞分类 1008（凭证失效 / 开关没开）；服务端改文案时这里先红。"""
    source = inspect.getsource(transcode_worker_routes)
    reasons = re.findall(r'reason = "([^"]+)"', source)

    kinds = {reason: rejection_kind(reason) for reason in reasons}

    assert "auth" in kinds.values() and "remote_disabled" in kinds.values(), kinds
    assert len([k for k in kinds.values() if k == "auth"]) == 1
    assert len([k for k in kinds.values() if k == "remote_disabled"]) == 1


@pytest.mark.parametrize("index", [0, 7, 99999])
def test_the_artifact_names_this_worker_uploads_pass_the_servers_whitelist(index):
    pattern = transcode_worker_routes._ARTIFACT_NAME
    assert pattern.fullmatch("init.mp4")
    assert pattern.fullmatch(f"seg{index:05d}.m4s")  # ProgressiveUploader 用的就是这个格式
    assert not pattern.fullmatch("stream.mp4")  # 整条分片化 MP4 从不传给 NAS，只在本机切


def test_the_server_reads_the_device_name_it_pairs_under_as_the_worker_id():
    """配对时用的名字就是之后握手的 worker_id：NAS 把设备记录改名对齐，「设备」页上看到的一致。"""
    source = inspect.getsource(transcode_worker_routes)
    assert "device.name != connection.worker_id" in source


# -- NAS 下发的命令 ---------------------------------------------------------------

WIN_CAPS = WorkerVideoCaps(
    hw_decoders=frozenset({"h264", "hevc"}),
    filters=frozenset({"scale_cuda", "tonemap_cuda", "tonemapx"}),
    read_options=frozenset({"skip_estimate_duration_from_pts"}),
)
ARTIFACTS = "http://nas:3000/api/v1/transcode-worker/sessions/S1/artifacts"


def nas_command(**overrides) -> list[str]:
    plan = PlaybackPlan(
        tier=PlaybackTier.HARDWARE_TRANSCODE,
        file_id=1,
        container="hls-fmp4",
        video=VideoPlan(
            action="transcode", codec="h264", height=1080, source_codec="hevc", source_bit_depth=10
        ),
        audio=AudioPlan(action="transcode", codec="aac", channels=2, track_ref="embedded:0"),
    )
    return build_hls_command(
        plan,
        source_path="http://nas:3000/api/v1/transcode-worker/source/1?token=src",
        session_dir=Path("/data/transcodes/S1"),
        hw_backend="nvenc",
        worker_caps=WIN_CAPS,
        start_number=3,
        output_base_url=ARTIFACTS,
        output_url_suffix="?token=abc",
        progressive=True,
        **overrides,
    ).argv


def test_a_progressive_command_ends_in_the_stream_address_this_worker_redirects():
    argv = nas_command()

    assert split_artifact_url(argv[-1]) == (ARTIFACTS, "token=abc")
    assert argv[-1].split("?", 1)[0].endswith("/stream.mp4")
    assert "-progress" in argv and argv[argv.index("-progress") + 1] == "pipe:1"


def test_the_job_swaps_exactly_that_address_for_a_loopback_relay():
    argv = nas_command()
    message = {
        "job_id": "job-0001-abcdef12",
        "ffmpeg_args": argv[1:],  # NAS 的命令以 "ffmpeg" 开头，Worker 自己有 ffmpeg 路径
        "segment_seconds": ffmpeg_args.SEGMENT_SECONDS,
        "start_segment": 3,
    }
    job = Job(message, ffmpeg="ffmpeg", send=lambda _m: None, log=lambda _m: None)

    redirected = job._redirect_stream_output(list(argv[1:]))
    job._uploader.cancel()  # type: ignore[union-attr]
    job._relay.stop()  # type: ignore[union-attr]

    assert re.fullmatch(r"tcp://127\.0\.0\.1:\d+", redirected[-1])
    assert redirected[:-1] == argv[1:-1]  # 其余参数一个字不动


def test_the_nas_asks_for_idr_frames_on_the_segment_grid():
    """切段靠关键帧：-force_key_frames 把关键帧压在 4 秒栅格上，NVENC 要 -forced-idr 才出 IDR。"""
    argv = nas_command()

    assert argv[argv.index("-force_key_frames") + 1] == (
        f"expr:gte(t,n_forced*{ffmpeg_args.SEGMENT_SECONDS})"
    )
    assert argv[argv.index("-forced-idr") + 1] == "1"
    assert argv[argv.index("-c:v") + 1] == "h264_nvenc"


def test_the_fragmented_mp4_flags_the_segmenter_relies_on_are_all_there():
    """分片器读的是 frag_keyframe 切开的片段、default_base_moof 的偏移、frag_discont 的真实时间。"""
    argv = nas_command()
    flags = argv[argv.index("-movflags") + 1]

    for flag in ("frag_keyframe", "delay_moov", "default_base_moof", "frag_discont"):
        assert flag in flags
    assert argv[argv.index("-frag_duration") + 1] == str(ffmpeg_args.PROGRESSIVE_FRAGMENT_US)
