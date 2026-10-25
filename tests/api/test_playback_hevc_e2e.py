"""播放转码出 HEVC（#1008）的端到端：真 HTTP + 真 ffmpeg，登录 → 决策 → 起会话 → 按播放列表
拉回 init 与分片 → ffprobe 看出的是什么编码。

测试机没有显卡：PATH 里包一层 ffmpeg 把 VAAPI 命令换成软件编码（hevc_vaapi → libx265、
h264_vaapi → libx264，同离线导出的用例），硬件自检结论直接登记，其余全是真代码。片源用
MPEG-2：浏览器解不了，必然走硬件转码。
"""

from __future__ import annotations

import os
import shutil
import sys
from functools import partial
from pathlib import Path

import pytest
from tests.api.test_offline_download import _FAKE_VAAPI_FFMPEG
from tests.api.test_playback_e2e import (
    _run,
    _seed,
    client,  # noqa: F401 — 夹具
    fetch_whole_stream,
    probe_streams,
    start,
    wait_for_segments,
)

from movieclaw_api.services.playback.ffmpeg_args import register_hevc_encoder

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None,
        reason="需要系统 ffmpeg/ffprobe",
    ),
]

#: 能解 H.264 与 1080p 以内 HEVC、带 HEVC 回退的网页播放器
HEVC_BROWSER = {
    "video": [{"codec": "h264"}, {"codec": "hevc", "max_height": 1080}],
    "audio": [{"codec": "aac"}],
    "containers": ["mp4", "hls-fmp4"],
    "hevc_transcode": True,
}


@pytest.fixture
def fake_vaapi(client, tmp_path, monkeypatch):  # noqa: F811
    from movieclaw_api.api.routes import playback as routes_playback
    from movieclaw_api.services.playback import plan as plan_mod

    real = shutil.which("ffmpeg")
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir()
    script = bin_dir / "ffmpeg"
    script.write_text(_FAKE_VAAPI_FFMPEG.format(python=sys.executable, real=real))
    script.chmod(0o755)
    log = tmp_path / "ffmpeg.log"
    log.touch()
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_FFMPEG_LOG", str(log))
    vaapi = lambda: ("vaapi",)  # noqa: E731
    monkeypatch.setattr(routes_playback, "available_backends", vaapi)
    monkeypatch.setattr(routes_playback, "available_local_backends", vaapi)
    monkeypatch.setattr(routes_playback, "remote_worker_available", lambda *_a, **_k: False)
    monkeypatch.setattr(plan_mod, "hardware_available", lambda: True)
    register_hevc_encoder("vaapi", ())  # 自检：HEVC 真编通过
    yield log
    register_hevc_encoder("vaapi", None)


def _mpeg2_file(client, tmp_path: Path) -> int:  # noqa: F811
    root = tmp_path / "m"
    root.mkdir(parents=True, exist_ok=True)
    path = root / "mpeg2.mkv"
    _run([
        "ffmpeg", "-v", "error",
        "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=6",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=6",
        "-c:v", "mpeg2video", "-g", "25", "-c:a", "aac", "-shortest", "-y", str(path),
    ])  # fmt: skip
    return client.portal.call(partial(_seed, path, codec="mpeg2video", container="mkv"))


def _video_stream(client, data, tmp_path) -> dict:  # noqa: F811
    wait_for_segments(client, data, count=1)
    streams = probe_streams(fetch_whole_stream(client, data, tmp_path))
    return next(s for s in streams if s["codec_type"] == "video")


def test_hardware_transcode_outputs_hevc_for_a_client_that_opts_in(
    client, tmp_path, fake_vaapi  # noqa: F811
):
    file_id = _mpeg2_file(client, tmp_path)
    data = start(client, file_id, capability=HEVC_BROWSER)
    assert data["decision"]["tier"] == 3, data["decision"]
    assert data["decision"]["video"]["codec"] == "hevc"
    assert data["hw_backend"] == "vaapi"
    video = _video_stream(client, data, tmp_path)
    assert video["codec_name"] == "hevc" and video["codec_tag_string"] == "hvc1", video
    assert video["profile"] == "Main"
    commands = fake_vaapi.read_text()
    assert "-c:v hevc_vaapi" in commands and "h264_vaapi" not in commands
    # 码率按 HEVC 阶梯（台账没记片高，目标按 1080p：H.264 6M → HEVC 4M）
    assert "-maxrate 4M" in commands
    # master 不写 CODECS：HEVC 的 level 由编码器自己选，写不准
    master = client.get(data["stream_url"].replace("index.m3u8", "master.m3u8"))
    if master.status_code == 200:
        assert "CODECS" not in master.text


@pytest.mark.parametrize(
    "capability",
    [
        # 老客户端：没申报 hevc_transcode（它们把 HEVC 解不了当作硬件档失败，会直接降到软转）
        {**HEVC_BROWSER, "hevc_transcode": False},
        # 申报了但解不了 HEVC
        {**HEVC_BROWSER, "video": [{"codec": "h264"}]},
        # 能解的 HEVC 高度不够
        {**HEVC_BROWSER, "video": [{"codec": "h264"}, {"codec": "hevc", "max_height": 144}]},
    ],
    ids=["old-client", "no-hevc-decoder", "hevc-too-short"],
)
def test_hardware_transcode_stays_h264_otherwise(
    client, tmp_path, fake_vaapi, capability  # noqa: F811
):
    file_id = _mpeg2_file(client, tmp_path)
    data = start(client, file_id, capability=capability)
    assert data["decision"]["tier"] == 3, data["decision"]
    assert data["decision"]["video"]["codec"] == "h264"
    assert _video_stream(client, data, tmp_path)["codec_name"] == "h264"
    assert "hevc_vaapi" not in fake_vaapi.read_text()


def test_gpu_without_a_hevc_self_test_stays_h264(client, tmp_path, fake_vaapi):  # noqa: F811
    register_hevc_encoder("vaapi", None)  # 显卡 H.264 能编、HEVC 探不通
    file_id = _mpeg2_file(client, tmp_path)
    data = start(client, file_id, capability=HEVC_BROWSER)
    assert data["decision"]["video"]["codec"] == "h264"
    assert _video_stream(client, data, tmp_path)["codec_name"] == "h264"


def test_hevc_failure_retry_without_the_flag_gets_hardware_h264(
    client, tmp_path, fake_vaapi  # noqa: F811
):
    """客户端的回退：HEVC 放不了就不带 hevc_transcode 重来、不记硬件档失败——拿到的是硬件
    H.264，不是软件转码或同意弹窗。"""
    file_id = _mpeg2_file(client, tmp_path)
    first = start(client, file_id, capability=HEVC_BROWSER)
    assert first["decision"]["video"]["codec"] == "hevc"
    retry = start(
        client, file_id, capability={**HEVC_BROWSER, "hevc_transcode": False}, failed_tiers=[]
    )
    assert retry["decision"]["outcome"] == "plan" and retry["decision"]["tier"] == 3
    assert retry["decision"]["video"]["codec"] == "h264" and retry["hw_backend"] == "vaapi"


def test_hevc_that_cannot_start_falls_back_to_h264_on_the_server(
    client, tmp_path, fake_vaapi, monkeypatch  # noqa: F811
):
    """自检只编一秒合成画面：真实片子上 HEVC 起步即退时，服务端当场改出 H.264 重开——任何客户端
    （包括没实现回退的）拿到的都是能放的会话，而不是 503 错误页。"""
    monkeypatch.setenv("FAKE_HEVC_FAIL", "start")
    file_id = _mpeg2_file(client, tmp_path)
    data = start(client, file_id, capability=HEVC_BROWSER)
    assert data["decision"]["tier"] == 3, data["decision"]
    assert data["decision"]["video"]["codec"] == "h264"
    assert data["hw_backend"] == "vaapi"
    assert _video_stream(client, data, tmp_path)["codec_name"] == "h264"
    commands = fake_vaapi.read_text()
    assert "-c:v hevc_vaapi" in commands and "-c:v h264_vaapi" in commands
