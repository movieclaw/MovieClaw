"""控制连接：握手、心跳、派单与重连（docs/design/remote-transcode.md §1、§3、§5.1）。

握手的 hello 直接交给服务端自己的解析（``RemoteWorkerRegistry``）验收；派单的并发门、重复下发、
seek 换轮次等逻辑用替身 ``Job``；真连接用 ``miniserver.FakeWebSocketServer``。
"""

from __future__ import annotations

import json
import threading
import types

import pytest
from miniserver import FakeWebSocketServer, close_frame, wait_until
from movieclaw_transcoder import PROTOCOL_VERSION, __version__
from movieclaw_transcoder import client as client_module
from movieclaw_transcoder.client import TranscoderClient, describe_rejection, ws_url
from movieclaw_transcoder.probe import Capabilities
from movieclaw_transcoder.telemetry import LoadSampler
from movieclaw_transcoder.websocket import HandshakeRejected, ServerClosed

from movieclaw_api.services.playback import remote_worker as remote_worker_module
from movieclaw_api.services.playback.remote_worker import RemoteWorkerRegistry

CAPS = Capabilities(
    ffmpeg_version="7.1.1-Jellyfin",
    encoders=("h264_nvenc", "hevc_nvenc"),
    filters=("scale_cuda", "tonemap_cuda", "tonemapx"),
    hw_decoders=("h264", "hevc", "vp9"),
    read_options=("skip_estimate_duration_from_pts",),
    hardware={
        "chip": "NVIDIA GeForce RTX 2070 SUPER",
        "cpu_cores": 16,
        "memory_bytes": 34359738368,
    },
)


class FakeJob:
    """替身 Job：记录收到的控制，不起 ffmpeg。"""

    instances: list[FakeJob] = []

    def __init__(self, message, *, ffmpeg, send, log):
        self.job_id = str(message.get("job_id") or "")
        self.attempt_id = str(message.get("attempt_id") or self.job_id)
        self.display_name = str(message.get("display_name") or "")
        self.message = message
        self.calls: list[tuple] = []
        FakeJob.instances.append(self)

    def start(self, on_exit):
        self.on_exit = on_exit
        self.calls.append(("start",))

    def stop(self, force=False):
        self.calls.append(("stop", force))

    def pause(self):
        self.calls.append(("pause",))

    def resume(self):
        self.calls.append(("resume",))


class FakeSocket:
    """只记发出的消息的控制连接。"""

    def __init__(self):
        self.sent: list[dict] = []

    def send_json(self, payload):
        self.sent.append(payload)


def make_client(tmp_path, *, max_jobs=1, statuses=None, logs=None) -> TranscoderClient:
    return TranscoderClient(
        server="http://nas:3000",
        token="tok",
        worker_id="gaming-pc",
        ffmpeg="ffmpeg",
        capabilities=CAPS,
        max_jobs=max_jobs,
        log=(logs.append if logs is not None else (lambda _message: None)),
        on_status=(
            (lambda kind, **fields: statuses.append((kind, fields)))
            if statuses is not None
            else (lambda _kind, **_fields: None)
        ),
    )


@pytest.fixture(autouse=True)
def fake_jobs(monkeypatch):
    FakeJob.instances = []
    monkeypatch.setattr(client_module, "Job", FakeJob)


@pytest.fixture
def connected(tmp_path):
    client = make_client(tmp_path)
    client._ws = FakeSocket()  # type: ignore[assignment]
    return client


# -- 地址与拒绝理由 -------------------------------------------------------------


@pytest.mark.parametrize(
    ("server", "expected"),
    [
        ("http://nas:3000", "ws://nas:3000/api/v1/transcode-worker/ws"),
        ("https://nas.example", "wss://nas.example/api/v1/transcode-worker/ws"),
        (
            "https://nas.example/movieclaw/",
            "wss://nas.example/movieclaw/api/v1/transcode-worker/ws",
        ),
    ],
)
def test_the_control_url_follows_the_servers_scheme_and_keeps_a_proxy_prefix(server, expected):
    assert ws_url(server) == expected


@pytest.mark.parametrize(
    ("error", "text", "kind"),
    [
        (ServerClosed(1008, "凭证无效或已被吊销，请重新配对"), "凭证无效", "auth"),
        (ServerClosed(1008, "服务端尚未启用远程转码，请打开开关"), "尚未启用", "remote_disabled"),
        (ServerClosed(1008, "Worker hello 格式错误"), "hello 格式错误", "other"),
        (ServerClosed(1008, ""), "NAS 拒绝了连接", "other"),
        (HandshakeRejected(403), "--reset", "other"),  # 旧版服务端只回空 403：两种原因都要说
        (HandshakeRejected(404), "找不到", "other"),
        (HandshakeRejected(400), "HTTP 400", "other"),
        (HandshakeRejected(502), "暂时不可用", None),  # 反向代理在等后端重启：照常退避
        (ServerClosed(1012, "连接已替换"), "连接已替换", None),
        (OSError("boom"), "boom", None),
    ],
)
def test_rejections_become_human_text_and_a_class(error, text, kind):
    reason, classified = describe_rejection(error)

    assert text in reason
    assert classified == kind


# -- hello -----------------------------------------------------------------


def test_hello_declares_exactly_what_this_machine_proved(tmp_path):
    hello = make_client(tmp_path, max_jobs=2)._hello()
    capabilities = hello["capabilities"]

    json.dumps(hello)  # 必须能序列化
    assert hello["type"] == "worker.hello"
    assert hello["protocol_version"] == PROTOCOL_VERSION
    assert hello["worker_version"] == __version__
    assert hello["worker_id"] == "gaming-pc"
    assert capabilities["platform"] == "Windows"
    assert capabilities["backends"] == ["nvenc"]
    assert capabilities["encoders"] == ["h264_nvenc", "hevc_nvenc"]
    assert capabilities["hw_decoders"] == ["h264", "hevc", "vp9"]
    assert capabilities["filters"] == ["scale_cuda", "tonemap_cuda", "tonemapx"]
    assert capabilities["read_options"] == ["skip_estimate_duration_from_pts"]
    assert capabilities["max_jobs"] == 2
    # 这个程序做不到的事不申报：NAS 就不会派给它
    assert capabilities["segment_types"] == ["fmp4"]  # 不接 MPEG-TS 分片（Infuse 等）
    assert capabilities["disc_sources"] is False  # 不读原盘
    assert capabilities["playback_progress"] is False  # 没有面板，不需要观众位置
    assert capabilities["progressive_segments"] is True
    assert capabilities["server_config"] is True


@pytest.mark.asyncio
async def test_the_servers_registry_accepts_the_hello_and_reads_the_same_capabilities(
    tmp_path, monkeypatch
):
    """hello 交给服务端自己的登记逻辑：能登记、读出来的就是申报的。"""
    monkeypatch.setattr(remote_worker_module, "remote_worker_enabled", lambda: True)

    class Socket:
        async def send_json(self, _message):
            pass

        async def close(self, **_):
            pass

    registry = RemoteWorkerRegistry()
    hello = make_client(tmp_path)._hello()

    connection = await registry.register(Socket(), hello, observed_base_url="http://nas:3000")  # type: ignore[arg-type]

    caps = connection.capabilities
    assert connection.worker_id == "gaming-pc"
    assert caps.backends == ("nvenc",)
    assert caps.segment_types == ("fmp4",)
    assert caps.progressive_segments is True
    assert caps.server_config is True
    assert caps.disc_sources is False and caps.playback_progress is False
    assert caps.hw_decoders == ("h264", "hevc", "vp9")
    assert caps.filters == ("scale_cuda", "tonemap_cuda", "tonemapx")
    assert caps.read_options == ("skip_estimate_duration_from_pts",)
    assert caps.hardware == CAPS.hardware
    # 命令装配看到的就是申报的能力
    assert caps.video_caps.hw_decoders == frozenset({"h264", "hevc", "vp9"})
    assert registry.has_capable_worker("nvenc", "fmp4")
    assert not registry.has_capable_worker("nvenc", "mpegts")  # TS 分片不会派给它
    assert not registry.has_capable_worker("nvenc", "fmp4", disc=True)  # 原盘也不会
    # 心跳里的负载也得被服务端接受：数值范围不对整条会被丢掉
    registry._update_load(connection, LoadSampler().sample())
    assert connection.load_seen > 0
    assert set(connection.load) >= {"cpu", "memory_pressure", "thermal_state"}


# -- 派单 -------------------------------------------------------------------


def start(client: TranscoderClient, job_id: str, attempt: str | None = None, **extra) -> None:
    client._handle(
        None,  # type: ignore[arg-type]
        {"type": "job.start", "job_id": job_id, "attempt_id": attempt or job_id, **extra},
    )


def test_job_start_creates_and_starts_a_job_that_the_client_tracks(connected):
    start(connected, "job-1", display_name="转码样本")

    (job,) = FakeJob.instances
    assert job.calls == [("start",)]
    assert job.display_name == "转码样本"
    assert list(connected._jobs) == ["job-1"]


def test_job_started_and_ended_reach_the_status_callback_for_the_app_shell(tmp_path):
    """app 外壳靠这两个事件在托盘上显示「转码中」；字段就是托盘要显示的。"""
    statuses = []
    client = make_client(tmp_path, statuses=statuses)
    client._ws = FakeSocket()  # type: ignore[assignment]
    start(client, "job-1", display_name="转码样本")

    assert statuses[-1] == ("job_started", {"job_id": "job-1", "name": "转码样本"})

    job = client._jobs["job-1"]
    job.on_exit(job)
    assert statuses[-1] == ("job_ended", {"job_id": "job-1"})


def test_job_stop_emits_ended_so_the_app_count_comes_back_down(tmp_path):
    """停止播放（含拖进度重启时的 force）会先把任务从表里摘掉，_job_exited 认身份会跳过；
    若不在这里补发 ended，外壳的「正在转码 N 路」只涨不降。"""
    statuses = []
    client = make_client(tmp_path, statuses=statuses)
    client._ws = FakeSocket()  # type: ignore[assignment]
    start(client, "job-1")
    assert statuses[-1][0] == "job_started"

    connected_stop = {"type": "job.stop", "job_id": "job-1"}
    client._handle(None, connected_stop)  # type: ignore[arg-type]

    assert [kind for kind, _ in statuses] == ["job_started", "job_ended"]
    assert client.active_jobs == 0
    # 旧一轮迟到的线程收尾不再重复发
    job = FakeJob.instances[0]
    job.on_exit(job)
    assert [kind for kind, _ in statuses] == ["job_started", "job_ended"]


def test_seek_replacement_reports_one_end_and_one_start(tmp_path):
    """拖进度：旧一轮结束、新一轮开始，两边的数量都对得上。"""
    statuses = []
    client = make_client(tmp_path, statuses=statuses)
    client._ws = FakeSocket()  # type: ignore[assignment]
    start(client, "job-1", "attempt-a")
    start(client, "job-1", "attempt-b")

    assert [kind for kind, _ in statuses] == ["job_started", "job_ended", "job_started"]
    assert client.active_jobs == 1


def test_dropping_the_connection_reports_every_job_ended(tmp_path):
    """断线时本地把所有 ffmpeg 收掉：外壳的计数也要归零，不能等重连。"""
    statuses = []
    client = make_client(tmp_path, max_jobs=2, statuses=statuses)
    client._ws = FakeSocket()  # type: ignore[assignment]
    start(client, "job-1")
    start(client, "job-2")

    client._stop_all_jobs()

    ended = [f["job_id"] for kind, f in statuses if kind == "job_ended"]
    assert sorted(ended) == ["job-1", "job-2"]
    assert client.active_jobs == 0


def test_active_jobs_reads_the_live_table_not_an_event_tally(tmp_path):
    """数量以任务表为准：外壳不必自己加减（那是这类计数漂移的来源）。"""
    client = make_client(tmp_path, statuses=[])
    client._ws = FakeSocket()  # type: ignore[assignment]
    assert client.active_jobs == 0
    start(client, "job-1")
    assert client.active_jobs == 1
    start(client, "job-1", "attempt-b")  # 换轮：表里仍是一个
    assert client.active_jobs == 1


def test_a_late_exit_of_a_replaced_attempt_does_not_emit_a_second_ended(tmp_path):
    """seek 换轮：旧一轮在顶掉的那一刻就报了 ended；它迟到的线程收尾认身份落空，
    不再重复发一次（否则外壳计数会被减两次）。"""
    statuses = []
    client = make_client(tmp_path, statuses=statuses)
    client._ws = FakeSocket()  # type: ignore[assignment]
    start(client, "job-1", "attempt-a")
    start(client, "job-1", "attempt-b")
    assert [kind for kind, _ in statuses] == ["job_started", "job_ended", "job_started"]

    old_job = next(job for job in FakeJob.instances if job.attempt_id == "attempt-a")
    old_job.on_exit(old_job)
    assert [kind for kind, _ in statuses] == ["job_started", "job_ended", "job_started"]


def test_a_repeated_start_of_the_same_attempt_is_acknowledged_not_run_twice(connected):
    """NAS 没等到回执重发：重新回执，不重复起 ffmpeg。"""
    start(connected, "job-1", "attempt-a")
    start(connected, "job-1", "attempt-a")

    assert len(FakeJob.instances) == 1
    assert connected._ws.sent == [  # type: ignore[union-attr]
        {"type": "job.accepted", "job_id": "job-1", "attempt_id": "attempt-a"}
    ]


def test_a_new_attempt_of_the_same_job_replaces_the_old_one_by_killing_it(connected):
    """seek 重启：NAS 马上下发新一轮，旧一轮没有交付价值，直接杀。"""
    start(connected, "job-1", "attempt-a")
    start(connected, "job-1", "attempt-b")

    old, new = FakeJob.instances
    assert old.calls == [("start",), ("stop", True)]
    assert new.calls == [("start",)]
    assert connected._jobs["job-1"] is new


def test_a_job_beyond_the_concurrency_limit_is_refused_so_the_nas_can_pick_another(tmp_path):
    client = make_client(tmp_path, max_jobs=1)
    client._ws = FakeSocket()  # type: ignore[assignment]
    start(client, "job-1")

    start(client, "job-2")

    assert [job.job_id for job in FakeJob.instances] == ["job-1"]
    assert client._ws.sent == [  # type: ignore[union-attr]
        {"type": "job.failed", "job_id": "job-2", "attempt_id": "job-2", "error": "Worker 并发已满"}
    ]


def test_a_start_without_a_job_id_is_ignored(connected):
    connected._handle(None, {"type": "job.start"})  # type: ignore[arg-type]

    assert FakeJob.instances == []


@pytest.mark.parametrize(("force", "expected"), [(True, True), (False, False), ("yes", False)])
def test_job_stop_removes_the_job_and_forwards_the_force_flag(connected, force, expected):
    start(connected, "job-1")
    message = {"type": "job.stop", "job_id": "job-1"}
    if force is not False:
        message["force"] = force

    connected._handle(None, message)  # type: ignore[arg-type]

    assert FakeJob.instances[0].calls[-1] == ("stop", expected)
    assert connected._jobs == {}


def test_pause_and_resume_keep_the_job_and_unknown_jobs_are_ignored(connected):
    start(connected, "job-1")

    connected._handle(None, {"type": "job.pause", "job_id": "job-1"})  # type: ignore[arg-type]
    connected._handle(None, {"type": "job.resume", "job_id": "job-1"})  # type: ignore[arg-type]
    connected._handle(None, {"type": "job.pause", "job_id": "ghost"})  # type: ignore[arg-type]

    assert FakeJob.instances[0].calls == [("start",), ("pause",), ("resume",)]
    assert "job-1" in connected._jobs


def test_a_finished_old_attempt_does_not_free_the_new_attempts_slot(connected):
    """旧线程的收尾不能把新一轮的条目弹掉，否则新一轮占着槽位却不在任务表里。"""
    start(connected, "job-1", "attempt-a")
    start(connected, "job-1", "attempt-b")
    old, new = FakeJob.instances

    old.on_exit(old)
    assert connected._jobs["job-1"] is new
    new.on_exit(new)
    assert connected._jobs == {}


def test_the_concurrency_limit_follows_the_server_within_one_to_four(connected):
    for value, expected in [(3, 3), (99, 3), (0, 3), (True, 3), ("2", 3), (4, 4), (1, 1)]:
        connected._handle(None, {"type": "worker.config", "max_jobs": value})  # type: ignore[arg-type]
        assert connected.max_jobs == expected


def test_unknown_control_messages_are_logged_once_and_ignored(tmp_path):
    logs: list[str] = []
    client = make_client(tmp_path, logs=logs)

    for _ in range(3):
        client._handle(None, {"type": "worker.something-new"})  # type: ignore[arg-type]
    client._handle(None, {"type": "worker.heartbeat.ack"})  # type: ignore[arg-type]
    client._handle(None, {"type": "job.playback"})  # type: ignore[arg-type]

    assert logs == ["忽略未知控制消息：worker.something-new"]


# -- 重连 -------------------------------------------------------------------


class Reconnect:
    """驱动 ``run_forever``：``_connect_once`` 依次抛出给定的异常，``wait`` 记下等了多久。

    最后一个异常是收尾哨兵：抛出时客户端已被叫停，循环在算等待之前就退出，所以它不产生等待。"""

    def __init__(self, client: TranscoderClient, failures, monkeypatch, clock=None):
        self.waits: list[float] = []
        self.remaining = list(failures)
        self.clock = clock if clock is not None else [0.0]

        def connect_once():
            failure = self.remaining.pop(0)
            if isinstance(failure, tuple):  # (这次连了多少秒才断, 异常)
                self.clock[0] += failure[0]
                failure = failure[1]
            if not self.remaining:
                client._stop.set()
            raise failure

        def wait(seconds=None):
            self.waits.append(seconds)
            return client._stop.is_set()

        monkeypatch.setattr(client, "_connect_once", connect_once)
        monkeypatch.setattr(client._stop, "wait", wait)
        monkeypatch.setattr(
            client_module, "time", types.SimpleNamespace(monotonic=lambda: self.clock[0])
        )


def test_a_server_that_rejects_us_is_retried_on_its_own_schedule_with_the_class(
    tmp_path, monkeypatch
):
    statuses: list = []
    client = make_client(tmp_path, statuses=statuses)
    reconnect = Reconnect(
        client,
        [
            ServerClosed(1008, "凭证无效或已被吊销，请重新配对"),
            ServerClosed(1008, "服务端尚未启用远程转码，请打开开关"),
            OSError("哨兵"),
        ],
        monkeypatch,
    )

    client.run_forever()

    assert reconnect.waits == [300.0, 60.0]  # 凭证失效慢慢试；开关没开每分钟问一次
    assert [(kind, fields["rejection"], fields["retry_seconds"]) for kind, fields in statuses] == [
        ("offline", "auth", 300.0),
        ("offline", "remote_disabled", 60.0),
    ]


def test_quick_failures_back_off_exponentially_and_a_long_connection_resets_it(
    tmp_path, monkeypatch
):
    client = make_client(tmp_path)
    reconnect = Reconnect(
        client,
        [
            OSError("a"),
            OSError("b"),
            OSError("c"),
            (120.0, OSError("连了两分钟才断")),  # 长连过：立即重连（没有等待），退避归位
            OSError("d"),
            OSError("哨兵"),
        ],
        monkeypatch,
    )

    client.run_forever()

    assert reconnect.waits == [2.0, 4.0, 8.0, 2.0]


def test_the_backoff_is_capped_at_thirty_seconds(tmp_path, monkeypatch):
    client = make_client(tmp_path)
    reconnect = Reconnect(client, [OSError("x")] * 8 + [OSError("哨兵")], monkeypatch)

    client.run_forever()

    assert reconnect.waits == [2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0, 30.0]


# -- 真连接 -----------------------------------------------------------------


@pytest.fixture
def fast_clock(monkeypatch):
    monkeypatch.setattr(client_module, "POLL_S", 0.05)
    monkeypatch.setattr(client_module, "HEARTBEAT_S", 0.05)


def connect(client: TranscoderClient, server: FakeWebSocketServer, monkeypatch) -> None:
    monkeypatch.setattr(client_module, "ws_url", lambda _server: server.url)
    client._connect_once()


def test_the_client_says_hello_then_goes_online_and_heartbeats_with_its_load(
    tmp_path, monkeypatch, fast_clock
):
    seen: dict = {}
    statuses: list = []
    client = make_client(tmp_path, statuses=statuses)
    hello = client._hello()  # 握手后并发上限会被服务端下发的值改写，所以先留一份

    def handler(peer):
        seen["hello"] = peer.read_json()
        peer.send_json({"type": "worker.accepted", "protocol_version": 1, "max_jobs": 2})
        beat = peer.read_json()
        while beat["type"] != "worker.heartbeat":
            beat = peer.read_json()
        seen["heartbeat"] = beat
        peer.send_json({"type": "worker.heartbeat.ack"})
        peer.send(close_frame(1008, "测试结束"))

    with FakeWebSocketServer(handler) as server, pytest.raises(ServerClosed):
        connect(client, server, monkeypatch)

    assert seen["hello"] == hello
    assert server.peer.headers["authorization"] == "Bearer tok"  # type: ignore[union-attr]
    assert set(seen["heartbeat"]["load"]) == {
        "cpu",
        "memory_pressure",
        "thermal_state",
        "memory_used_bytes",
    }
    assert ("online", {"server": "http://nas:3000", "max_jobs": 2}) in statuses
    assert client.max_jobs == 2  # 并发上限以服务端下发的为准


def test_jobs_are_killed_when_the_connection_drops_so_the_slot_is_free_for_the_redispatch(
    tmp_path, monkeypatch, fast_clock
):
    """断线后服务端已把这些任务判失败重派：旧进程占着任务表会把重派回来的新任务顶成「并发已满」。"""
    client = make_client(tmp_path)

    def handler(peer):
        peer.read_json()
        peer.send_json({"type": "worker.accepted", "max_jobs": 1})
        peer.send_json({"type": "job.start", "job_id": "job-1", "attempt_id": "a"})
        peer.read_frame(timeout=3.0)  # 等客户端的下一条消息（心跳）
        peer.send(close_frame(1012, "restart"))

    with FakeWebSocketServer(handler) as server, pytest.raises(ServerClosed):
        connect(client, server, monkeypatch)

    (job,) = FakeJob.instances
    assert job.calls == [("start",), ("stop", True)]
    assert client._jobs == {}


def test_a_server_that_never_accepts_is_dropped_after_the_handshake_window(
    tmp_path, monkeypatch, fast_clock
):
    monkeypatch.setattr(client_module, "HANDSHAKE_TIMEOUT_S", 0.3)
    client = make_client(tmp_path)

    def handler(peer):
        peer.read_json()  # 收下 hello，然后装死
        peer.read_frame(timeout=3.0)

    with FakeWebSocketServer(handler) as server, pytest.raises(OSError) as error:
        connect(client, server, monkeypatch)

    assert "没有完成握手" in str(error.value)


def test_a_half_open_connection_is_noticed_by_the_silence_window(tmp_path, monkeypatch, fast_clock):
    """服务端已判离线、这边却以为在线（Wi-Fi 睡眠唤醒、NAT 映射换了）：窗口内没响应就主动重连。"""
    monkeypatch.setattr(client_module, "SERVER_SILENCE_S", 0.4)
    client = make_client(tmp_path)

    def handler(peer):
        peer.read_json()
        peer.send_json({"type": "worker.accepted", "max_jobs": 1})
        while True:  # 收着心跳，但再也不回
            peer.read_frame(timeout=3.0)

    with FakeWebSocketServer(handler) as server, pytest.raises(OSError) as error:
        connect(client, server, monkeypatch)

    assert "没有任何响应" in str(error.value)


def test_stop_says_goodbye_and_ends_the_loop(tmp_path, monkeypatch, fast_clock):
    client = make_client(tmp_path)
    got: dict = {}
    hello_seen = threading.Event()

    def handler(peer):
        peer.read_json()
        hello_seen.set()
        peer.send_json({"type": "worker.accepted", "max_jobs": 1})
        while True:
            message = peer.read_json(timeout=3.0)
            if message["type"] == "worker.goodbye":
                got["goodbye"] = message
                return

    with FakeWebSocketServer(handler) as server:
        monkeypatch.setattr(client_module, "ws_url", lambda _server: server.url)
        thread = threading.Thread(target=client.run_forever, daemon=True)
        thread.start()
        wait_until(hello_seen.is_set, 5.0, "NAS 收到 hello")
        client.stop()
        thread.join(5.0)

    assert not thread.is_alive()
    assert got["goodbye"] == {"type": "worker.goodbye"}
