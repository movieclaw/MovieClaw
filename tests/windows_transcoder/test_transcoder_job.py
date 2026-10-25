"""一个转码任务：起 ffmpeg、解析进度、把产物送回 NAS。

ffmpeg 用 ``fake_ffmpeg.py`` 替身（按模式演成功、失败、卡死、停止），NAS 用 ``miniserver.FakeNas``；
整条链真实地走：进程、管道、中转文件、跟读、切段、分块回传、看门狗、暂停与停止。
"""

from __future__ import annotations

import contextlib
import json
import socket
import sys
import threading
import time
from pathlib import Path

import pytest
from fmp4 import init_segment
from miniserver import FakeNas, Upload, wait_until
from movieclaw_transcoder import job as job_module
from movieclaw_transcoder.job import Job, StreamRelay, _out_time_ms

FAKE = Path(__file__).with_name("fake_ffmpeg.py")
#: 虚拟环境里的 python.exe 在 Windows 上是个启动器（再起一个真解释器）：替身要直接用真解释器，
#: 杀进程才杀得到它
PYTHON = getattr(sys, "_base_executable", sys.executable)


class Harness:
    """一个任务连同它发出的消息、NAS 与退出信号。"""

    def __init__(self, tmp_path: Path, nas: FakeNas, mode: str, **message) -> None:
        self.nas = nas
        self.sent: list[dict] = []
        self.logs: list[str] = []
        self.exited = threading.Event()
        extra = message.pop("extra_args", [])
        base = {
            "job_id": "job-0001-abcdef12",
            "attempt_id": "attempt-1",
            "display_name": "样片",
            "ffmpeg_args": [
                str(FAKE),
                "--mode",
                mode,
                *extra,
                "-progress",
                "pipe:1",
                nas.stream_url,
            ],
            "segment_seconds": 4,
            "start_segment": 5,
        }
        self.message = {**base, **message}
        self.job = Job(
            self.message,
            ffmpeg=PYTHON,
            send=self.sent.append,
            log=self.logs.append,
        )

    def run(self) -> Harness:
        self.job.start(lambda _job: self.exited.set())
        return self

    def wait_exit(self, timeout: float = 30.0) -> Harness:
        assert self.exited.wait(timeout), f"任务没有收尾；已发消息：{self.types()}"
        return self

    def types(self) -> list[str]:
        return [message["type"] for message in self.sent]

    def of(self, kind: str) -> list[dict]:
        return [message for message in self.sent if message["type"] == kind]

    def relay_closed(self) -> bool:
        """任务收尾后，回环口的接收线程已经结束（口也关了）。"""
        relay = self.job._relay
        return relay is not None and not relay._thread.is_alive()


@pytest.fixture
def nas():
    with FakeNas() as server:
        yield server


# -- 渐进式任务：切段、回传、收尾 ------------------------------------------------


def test_a_progressive_job_cuts_the_stream_uploads_it_and_reports_the_milestones(tmp_path, nas):
    harness = Harness(tmp_path, nas, "ok", extra_args=["--fragments", "24"]).run().wait_exit()

    # 上报顺序：接单 → 进度 → 起播分段计时 → 终态，且恰好一个终态
    types = harness.types()
    assert types[0] == "job.accepted"
    assert types[-1] == "job.finished" and types.count("job.finished") == 1
    assert "job.failed" not in types
    assert all(
        m["job_id"] == "job-0001-abcdef12" and m["attempt_id"] == "attempt-1" for m in harness.sent
    )
    finished = harness.of("job.finished")[0]
    assert finished["exit_code"] == 0

    progress = harness.of("job.progress")
    assert progress and progress[-1]["phase"] == "end"
    assert progress[-1]["out_time_ms"] == 12_000  # ffmpeg 的 out_time_us 是微秒，换算成毫秒
    assert progress[-1]["speed"] == "1.5x"

    marks = {event["ev"] for m in harness.of("job.timeline") for event in m["events"]}
    assert {
        "spawn",
        "ffmpeg",
        "first_bytes",
        "init_up",
        "seg_up",
        "first_progress",
        "exit",
    } <= marks

    # 产物：init 整个传；12 秒、每 4 秒一格 → 第 5、6、7 段，每段 8 块 + 一个收尾块
    assert nas.named("init.mp4")[0].body == init_segment(with_audio=False)
    for segment in (5, 6, 7):
        parts = nas.named(f"seg{segment:05d}.m4s")
        assert [(u.part, u.final) for u in parts] == [(p, False) for p in range(8)] + [(8, True)]
        assert all(u.query["token"] == "tok" for u in parts)  # 带的是任务的签名令牌
    # 媒体字节不落盘：只有回环口，任务收尾时关掉
    assert harness.relay_closed()


def test_a_nas_that_refuses_a_segment_is_told_about_it_and_the_job_still_finishes(tmp_path):
    """重试用尽的产物上报 job.artifact_failed，NAS 按补片台账从这一片重启；任务本身照常跑完。"""

    def respond(upload: Upload) -> int:
        return 409 if upload.name == "seg00006.m4s" else 201

    with FakeNas(respond) as nas:
        harness = Harness(tmp_path, nas, "ok", extra_args=["--fragments", "24"]).run().wait_exit()

    (failure,) = harness.of("job.artifact_failed")
    assert (failure["name"], failure["status"]) == ("seg00006.m4s", 409)
    assert "job.finished" in harness.types()


def test_a_stream_too_broken_to_cut_fails_the_job_with_the_reason(tmp_path, nas):
    harness = Harness(tmp_path, nas, "garbage").run().wait_exit()

    (failure,) = harness.of("job.failed")
    assert "长度不合理" in failure["error"]
    assert "job.finished" not in harness.types()
    assert harness.relay_closed()


# -- 失败 -------------------------------------------------------------------


def test_an_ffmpeg_failure_reports_the_exit_code_and_the_tail_of_stderr(tmp_path, nas):
    harness = Harness(tmp_path, nas, "fail").run().wait_exit()

    (failure,) = harness.of("job.failed")
    assert failure["error"] == "ffmpeg 退出码 3" and failure["exit_code"] == 3
    tail = failure["stderr_tail"].splitlines()
    assert tail[-1] == "error line 59"
    assert len(tail) <= job_module.STDERR_TAIL_LINES  # 只留最后几十行
    assert len(failure["stderr_tail"]) <= 2000
    assert "job.finished" not in harness.types()


def test_progress_is_reported_as_soon_as_ffmpeg_prints_it(tmp_path, nas):
    """进度行很短：按固定字节数读管道会把第一条进度压住好几秒（ffmpeg 约每 0.5 秒打一组）。"""
    # 只写一条远小于 4096 字节的进度后保持管道打开：read(4096) 必须卡住，
    # read1 则能立即交付。不要把 Python 替身冷启动时间算进进度读取的时限。
    harness = Harness(tmp_path, nas, "progress-once").run()
    try:
        wait_until(lambda: harness.of("job.progress"), 20.0, "管道关闭前的第一条短进度")
        assert harness.job._process.poll() is None
        assert not harness.of("job.finished")
    finally:
        harness.job.stop()
        harness.wait_exit(15.0)


def test_a_silent_ffmpeg_is_killed_by_the_watchdog_and_reported(tmp_path, nas, monkeypatch):
    monkeypatch.setattr(job_module, "STALL_BEFORE_FIRST_PROGRESS_S", 0.4)
    monkeypatch.setattr(job_module, "WATCHDOG_TICK_S", 0.1)

    started = time.monotonic()
    harness = Harness(tmp_path, nas, "hang").run().wait_exit()

    (failure,) = harness.of("job.failed")
    assert "没有新的进度" in failure["error"] and "一直没有出第一帧" in failure["error"]
    assert time.monotonic() - started < 15  # 替身自己会等 20 秒：是看门狗把它杀了
    assert harness.job._process.poll() is not None


def test_a_job_without_a_command_fails_at_once(tmp_path, nas):
    harness = Harness(tmp_path, nas, "ok", ffmpeg_args=[]).run().wait_exit()

    (failure,) = harness.of("job.failed")
    assert failure["error"] == "任务缺少 ffmpeg_args"


def test_a_progressive_job_needs_the_stream_artifact_address(tmp_path, nas):
    harness = (
        Harness(
            tmp_path, nas, "ok", ffmpeg_args=[str(FAKE), "--mode", "ok", "http://nas/other.mp4"]
        )
        .run()
        .wait_exit()
    )

    (failure,) = harness.of("job.failed")
    assert "stream.mp4" in failure["error"]


# -- 非渐进式任务 ----------------------------------------------------------------


def test_a_job_without_progressive_segments_runs_the_command_as_the_nas_wrote_it(tmp_path, nas):
    """没有预生成播放列表的会话由 ffmpeg 的 HLS muxer 自己 PUT 回 NAS：地址原样交给 ffmpeg。"""
    dump = tmp_path / "args.json"
    message = {
        "job_id": "job-0002-abcdef12",
        "attempt_id": "attempt-2",
        "ffmpeg_args": [
            str(FAKE), "--mode", "plain", "--dump", str(dump), "-progress", "pipe:1",
            nas.base_url + "/live.m3u8?token=tok",
        ],
    }  # fmt: skip
    harness = Harness(tmp_path, nas, "plain")
    harness.message = message
    harness.job = Job(message, ffmpeg=PYTHON, send=harness.sent.append, log=harness.logs.append)

    harness.run().wait_exit()

    assert json.loads(dump.read_text(encoding="utf-8")) == message["ffmpeg_args"][1:]
    assert "job.finished" in harness.types()
    assert nas.uploads == []  # 不经过本机的上传代理


# -- 停止与暂停 -------------------------------------------------------------------


def test_stop_kills_ffmpeg_and_the_old_attempt_reports_no_terminal_state(tmp_path, nas):
    """seek 换轮次：旧一轮被杀，不报 finished 也不报 failed（NAS 已经在等新一轮）。"""
    # 每个片段间隔半秒（实时速度）：停下时第一段还在半路，不会碰巧已经收过尾
    harness = Harness(tmp_path, nas, "slow", extra_args=["--delay", "0.5"]).run()
    wait_until(lambda: harness.of("job.progress"), 20.0, "第一条进度")

    harness.job.stop(force=True)
    harness.wait_exit(15.0)

    assert harness.job._process.poll() is not None
    assert "job.finished" not in harness.types() and "job.failed" not in harness.types()
    assert not any(upload.final for upload in nas.uploads)  # 被叫停的一轮不补收尾块
    assert harness.relay_closed()


def test_pause_freezes_ffmpeg_and_resume_lets_it_go_on(tmp_path, nas, monkeypatch):
    """领先量节流：NAS 叫暂停就挂起 ffmpeg（进度不再前进），叫恢复才继续。"""
    monkeypatch.setattr(job_module, "PROGRESS_INTERVAL_S", 0.1)
    harness = Harness(tmp_path, nas, "slow").run()
    wait_until(lambda: len(harness.of("job.progress")) >= 3, 20.0, "进度在前进")

    harness.job.pause()
    time.sleep(0.5)  # 管道里已经在路上的先落地
    frozen = len(harness.of("job.progress"))
    time.sleep(1.0)
    assert len(harness.of("job.progress")) == frozen, "暂停之后 ffmpeg 不该再出进度"

    harness.job.resume()
    wait_until(lambda: len(harness.of("job.progress")) > frozen, 10.0, "恢复后进度继续")

    harness.job.stop()
    harness.wait_exit(15.0)


def test_a_job_that_is_paused_is_not_killed_by_the_watchdog(tmp_path, nas, monkeypatch):
    """被 NAS 暂停的任务不计时：挂起期间没有进度是预期之内。"""
    monkeypatch.setattr(job_module, "STALL_BETWEEN_PROGRESS_S", 0.4)
    monkeypatch.setattr(job_module, "WATCHDOG_TICK_S", 0.1)
    harness = Harness(tmp_path, nas, "slow").run()
    wait_until(lambda: harness.of("job.progress"), 20.0, "第一条进度")

    harness.job.pause()
    time.sleep(1.5)  # 比看门狗的窗口长得多
    assert "job.failed" not in harness.types()
    assert harness.job._process.poll() is None

    harness.job.resume()
    harness.job.stop()
    harness.wait_exit(15.0)


# -- 小零件 -----------------------------------------------------------------


@pytest.mark.parametrize(
    ("values", "expected"),
    [
        ({"out_time_us": "1500000"}, 1500),
        ({"out_time_ms": "2500000"}, 2500),  # ffmpeg 的 out_time_ms 名不符实，单位其实是微秒
        ({"out_time_us": "1500000", "out_time_ms": "9"}, 1500),
        ({"out_time_us": "N/A"}, None),
        ({}, None),
    ],
)
def test_ffmpeg_progress_time_is_read_in_milliseconds(values, expected):
    assert _out_time_ms(values) == expected


def connect_to(relay: StreamRelay) -> socket.socket:
    host, _, port = relay.url[len("tcp://") :].partition(":")
    return socket.create_connection((host, int(port)), timeout=5)


def test_the_relay_hands_over_what_ffmpeg_pushes_in_order_and_reports_the_end():
    received = bytearray()
    relay = StreamRelay(lambda data: received.extend(data), lambda reason: None)  # type: ignore[arg-type, return-value]
    relay.start()
    try:
        with connect_to(relay) as ffmpeg:
            ffmpeg.sendall(b"abc")
            wait_until(lambda: bytes(received) == b"abc", 5.0, "收到第一批")
            ffmpeg.sendall(b"def")
        assert relay.wait_drained(5.0)  # ffmpeg 关了连接：剩下的都交出去了
        assert bytes(received) == b"abcdef"
    finally:
        relay.stop()


def test_the_relay_stops_reading_when_the_consumer_says_the_stream_is_broken():
    reasons: list[str] = []
    relay = StreamRelay(lambda data: "流坏了", reasons.append)
    relay.start()
    try:
        with connect_to(relay) as ffmpeg:
            ffmpeg.sendall(b"first")
            wait_until(lambda: reasons, 5.0, "收到失败原因")
            assert relay.wait_drained(5.0)
            with contextlib.suppress(OSError):
                ffmpeg.sendall(b"more")
        time.sleep(0.3)
    finally:
        relay.stop()

    assert reasons == ["流坏了"]  # 报一次就不再读


def test_a_relay_nobody_connected_to_stops_at_once():
    """ffmpeg 起不来（命令错、被杀）时它根本没连过来：收尾不能卡在 accept 上。"""
    relay = StreamRelay(lambda data: None, lambda reason: None)
    relay.start()

    started = time.monotonic()
    relay.stop()

    assert time.monotonic() - started < 2.0
    assert relay.wait_drained(0.1)
    relay.stop()  # 重复收尾也安全
