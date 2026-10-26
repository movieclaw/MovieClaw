"""真实 HTTP/WS → Windows 转码器（NVENC）→ 回传 → 客户端解码。

起一个隔离的 NAS（临时数据库、本机硬件入口屏蔽，强制走远程协议），再起一个真的
``python -m movieclaw_transcoder``：走设备授权配对、握手、派单、渐进式回传、seek 重启、暂停与停止。
需要 NVIDIA 显卡与 jellyfin-ffmpeg（``MOVIECLAW_TEST_FFMPEG`` 指到 ffmpeg 可执行文件，
或在 PATH 里），没有就整个文件跳过；CI 没有显卡，不跑。本机跑：
``pytest -m integration tests/playback/test_windows_transcoder_e2e.py``。
"""

from __future__ import annotations

import json
import subprocess
import time

import pytest
from windows_transcoder_stack import (
    WORKER_NAME,
    decode,
    diagnostics,
    end_session,
    make_source,
    require_nvenc_worker,
    running_stack,
    seed,
    start_session,
    wait_for,
    worker_status,
)

pytestmark = [pytest.mark.integration]


@pytest.fixture(scope="module")
def nvenc():
    """(ffmpeg 路径, 本机探出的能力)；这台机器不能登记为 NVENC 转码器就跳过。"""
    return require_nvenc_worker()


@pytest.fixture(scope="module")
def stack(tmp_path_factory, nvenc):
    ffmpeg, caps = nvenc
    with running_stack(tmp_path_factory.mktemp("windows-transcoder-e2e"), ffmpeg) as running:
        running["caps"] = caps
        yield running


def test_pairing_registers_a_nvenc_worker_with_declared_capabilities(stack):
    """走完设备授权后在线：后端是 nvenc，能力是它本机实测申报的，并发上限由服务端下发。"""
    worker = worker_status(stack)
    assert worker["backends"] == ["nvenc"]
    assert worker["platform"] == "Windows"
    assert worker["ffmpeg_version"]
    assert worker["hw_decoders"] == list(stack["caps"].hw_decoders)
    assert worker["filters"] == list(stack["caps"].filters)
    assert worker["hardware"].get("cpu_cores", 0) > 0
    assert worker["max_jobs"] >= 1
    assert worker["online"] is True


def _worker_devices(stack) -> list[dict]:
    devices = stack["client"].get("/api/v1/auth/devices").json()["data"]
    return [device for device in devices if device["kind"] == "worker"]


def test_reset_unpairs_this_machine_and_pairing_again_replaces_the_credential(stack):
    """``--reset``：在 NAS 上注销这台电脑的凭证、清掉本机令牌，然后重新配对。
    重新配对后设备列表里仍是一台，而不是越积越多；结束时新的 Worker 在线，不影响其他用例。"""
    (old,) = _worker_devices(stack)
    assert old["name"] == WORKER_NAME and old["connected"]
    config_file = stack["tmp"] / "worker-home" / "config.json"
    before = json.loads(config_file.read_text(encoding="utf-8"))
    assert before["token"]

    stack["worker"].terminate()  # 同机只允许一个转码器：--reset 也要拿同一把锁
    stack["worker"].wait(timeout=10)
    wait_for(lambda: not _worker_devices(stack)[0]["connected"], 30, "NAS 看到它离线")

    _process, output = stack["launch"]("--reset")
    wait_for(
        lambda: any("已在 NAS 上注销" in line for line in output.lines),
        60,
        lambda: f"注销旧凭证；输出：{output.text()[-600:]}",
    )
    assert _worker_devices(stack) == [], "旧凭证应当已被注销"

    stack["approve"](output)  # 重新配对
    wait_for(
        lambda: [d for d in _worker_devices(stack) if d["connected"]],
        60,
        "重新配对后上线",
    )
    (new,) = _worker_devices(stack)
    assert new["name"] == WORKER_NAME
    after = json.loads(config_file.read_text(encoding="utf-8"))
    assert after["token"] and after["token"] != before["token"]  # 换了新凭证
    assert after["installation_id"] == before["installation_id"]  # 还是同一台机器


def test_sdr_transcode_streams_segments_back_and_plays(stack):
    data = start_session(stack, seed(stack, make_source(stack, "sdr.mkv")))
    try:
        assert data["decision"]["tier"] == 3
        assert diagnostics(stack, data)["worker_id"] == "e2e-win"
        playback = decode(stack, data, seconds=3)
        assert playback.returncode == 0, playback.stderr.decode(errors="replace")[-2000:]
    finally:
        end_session(stack, data)
    assert "Traceback" not in stack["output"].text(), stack["output"].text()[-3000:]


def test_seek_restarts_the_job_and_still_plays(stack):
    """拖到没转到的位置：NAS 叫停旧一轮（force）、从目标分片起重开一轮，新一轮的产物接上播放。"""
    data = start_session(stack, seed(stack, make_source(stack, "seek.mkv", seconds=60)))
    try:
        assert decode(stack, data, seconds=2).returncode == 0
        far = decode(stack, data, seconds=3, seek=40)
        assert far.returncode == 0, far.stderr.decode(errors="replace")[-2000:]
        info = diagnostics(stack, data)
        assert info["job_state"] in {"job.accepted", "job.progress", "job.finished"}, info
        assert info["worker_id"] == "e2e-win"
    finally:
        end_session(stack, data)
    assert "Traceback" not in stack["output"].text(), stack["output"].text()[-3000:]


def test_lead_pause_suspends_the_job_and_stop_releases_the_slot(stack):
    """转码头领先播放头 120 秒：NAS 叫 Worker 暂停（挂起 ffmpeg，进度不再前进）；结束会话时
    被挂起的 ffmpeg 也能被叫停，并发名额随之释放。"""
    long = make_source(stack, "long.mkv", seconds=420, size="1280x720")
    data = start_session(stack, seed(stack, long))
    try:
        wait_for(lambda: "lead" in diagnostics(stack, data)["pause_reasons"], 90, "领先量触发暂停")
        before = diagnostics(stack, data)["job_out_time_ms"]
        time.sleep(3)
        assert diagnostics(stack, data)["job_out_time_ms"] == before, "暂停之后 ffmpeg 不该再出进度"
        assert worker_status(stack)["active_jobs"] == 1
    finally:
        end_session(stack, data)
    wait_for(lambda: worker_status(stack)["active_jobs"] == 0, 20, "并发名额释放")
    # 名额释放后能立刻接下一单
    again = start_session(stack, seed(stack, make_source(stack, "next.mkv", seconds=10)))
    try:
        assert decode(stack, again, seconds=2).returncode == 0
    finally:
        end_session(stack, again)


def test_hdr10_runs_the_whole_tonemap_chain_on_the_gpu(stack):
    """HDR10 源：声明了 tonemap_cuda，NAS 就让色调映射、缩放、编码全留在显卡上；输出 SDR BT.709。"""
    assert "tonemap_cuda" in stack["caps"].filters
    source = make_source(
        stack,
        "hdr10.mkv",
        pix_fmt="p010le",
        vf="format=p010le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc",
    )
    data = start_session(stack, seed(stack, source))
    try:
        assert data["decision"]["tier"] == 3
        assert diagnostics(stack, data)["backend"] == "nvenc"
        playback = decode(stack, data, seconds=3)
        assert playback.returncode == 0, playback.stderr.decode(errors="replace")[-2000:]
        probed = subprocess.run(
            [
                stack["ffprobe"], "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=pix_fmt,color_transfer,color_primaries",
                "-of", "json", stack["url"] + data["stream_url"],
            ],
            capture_output=True,
            timeout=60,
        )  # fmt: skip
        stream = json.loads(probed.stdout)["streams"][0]
        assert stream["pix_fmt"] == "yuv420p"
        assert stream.get("color_transfer") in (None, "bt709"), stream
    finally:
        end_session(stack, data)
    assert "Traceback" not in stack["output"].text(), stack["output"].text()[-3000:]


def test_startup_timeline_is_reported_to_the_nas(stack):
    """Worker 把这一轮的起播分段计时（ffmpeg 起来、首批字节、init 与首片传到 NAS）报给 NAS，
    并进会话时间线，诊断面板看得见起播慢在哪一段。"""
    data = start_session(stack, seed(stack, make_source(stack, "timeline.mkv")))
    try:
        assert decode(stack, data, seconds=2).returncode == 0
        marks = {
            entry["ev"]: entry["wt"]
            for entry in diagnostics(stack, data)["timeline"]
            if entry["ev"].startswith("w_")
        }
        print("worker timeline (ms since job.start):", marks)
        assert {"w_ffmpeg", "w_first_bytes", "w_init_up", "w_seg_up"} <= set(marks), marks
        assert marks["w_ffmpeg"] <= marks["w_first_bytes"] <= marks["w_init_up"]
    finally:
        end_session(stack, data)
