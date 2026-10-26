"""应用编排（model）：配对全流程、ffmpeg 三态、任务计数——配对走真实 HTTP（迷你 NAS），
ffmpeg 探测与转码内核用替身。"""

from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from movieclaw_transcoder.config import Config, config_path
from movieclaw_transcoder.probe import Capabilities, FfmpegProblem
from movieclaw_transcoder_app import ffmpeg_install
from movieclaw_transcoder_app.model import AppModel

CAPS_STUB = Capabilities(
    ffmpeg_version="8.1.3-Jellyfin",
    encoders=("h264_nvenc",),
    filters=("scale_cuda",),
    hw_decoders=("h264",),
    read_options=(),
    hardware={"chip": "NVIDIA GeForce RTX 2070 SUPER"},
)


class FakeClient:
    """替身内核：记构造参数，run_forever 挂到 stop。"""

    instances: list[FakeClient] = []

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.stopped = False
        self.active_jobs = 0
        self._done = threading.Event()
        FakeClient.instances.append(self)

    def run_forever(self) -> None:
        self._done.wait()

    def stop(self) -> None:
        self.stopped = True
        self._done.set()


class FakeNasAuth:
    """设备授权配对用的迷你 NAS：health / authorize / token / revoke 四个端点。"""

    def __init__(self) -> None:
        self.approved: set[str] = set()  # 已批准的 user_code
        self.device_codes: dict[str, str] = {}  # user_code -> device_code
        self.counter = 0
        self.revocations = 0
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args) -> None:
                pass

            def _json(self, status: int, body: dict) -> None:
                raw = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _body(self) -> dict:
                length = int(self.headers.get("Content-Length") or 0)
                try:
                    return json.loads(self.rfile.read(length) or b"{}")
                except ValueError:
                    return {}

            def do_GET(self) -> None:  # noqa: N802 - http.server 的约定名
                if self.path == "/api/v1/health":
                    self._json(200, {"service": "movieclaw"})
                else:
                    self._json(404, {})

            def do_POST(self) -> None:  # noqa: N802
                if self.path == "/api/v1/auth/device/authorize":
                    outer.counter += 1
                    user_code = f"TEST-{outer.counter:04d}"
                    device_code = f"dev-{outer.counter}"
                    outer.device_codes[user_code] = device_code
                    self._json(
                        200,
                        {
                            "data": {
                                "user_code": user_code,
                                "device_code": device_code,
                                "verification_uri_complete": f"http://nas/auth?code={user_code}",
                                "interval": 0.05,
                                "expires_in": 300,
                            }
                        },
                    )
                elif self.path == "/api/v1/auth/device/token":
                    device_code = str(self._body().get("device_code") or "")
                    approved = {
                        outer.device_codes[code]
                        for code in outer.approved
                        if code in outer.device_codes
                    }
                    if device_code and device_code in approved:
                        self._json(200, {"data": {"token": f"tok-{device_code}"}})
                    else:
                        self._json(202, {"data": {}})
                else:
                    self._json(404, {})

            def do_DELETE(self) -> None:  # noqa: N802
                if self.path == "/api/v1/auth/devices/current":
                    outer.revocations += 1
                    self.send_response(204)
                    self.end_headers()
                else:
                    self._json(404, {})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def approve(self, user_code: str) -> None:
        self.approved.add(user_code)

    def close(self) -> None:
        self.server.shutdown()


def wait_snapshot(model: AppModel, predicate, *, what: str = "状态", timeout: float = 10.0):
    deadline = time.monotonic() + timeout
    last = model.snapshot()
    while time.monotonic() < deadline:
        last = model.snapshot()
        if predicate(last):
            return last
        time.sleep(0.02)
    raise AssertionError(f"等待超时：{what}（最后快照：{last}）")


@pytest.fixture()
def nas():
    server = FakeNasAuth()
    yield server
    server.close()


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("MOVIECLAW_TRANSCODER_HOME", str(tmp_path / "home"))
    return tmp_path / "home"


@pytest.fixture(autouse=True)
def fake_kernel(monkeypatch):
    """替身转码内核：AppModel 的 client_factory 没开缝，这里替换类本身。"""
    FakeClient.instances = []
    import movieclaw_transcoder_app.model as model_module

    monkeypatch.setattr(model_module, "TranscoderClient", FakeClient)


def make_model(probe_holder: dict | None = None, **kwargs) -> tuple[AppModel, list[str]]:
    holder = probe_holder or {"fn": lambda *args, **kwargs: CAPS_STUB}
    opened: list[str] = []
    kwargs.setdefault("browser_open", opened.append)
    # 包一层让 holder["fn"] 后续被测试改掉也能生效
    model = AppModel(
        log=lambda _message: None, probe_fn=lambda *a, **k: holder["fn"](*a, **k), **kwargs
    )
    return model, opened


class _CountingClient:
    """只提供 active_jobs 的替身内核：验证外壳的计数来自任务表而不是事件累加。"""

    def __init__(self, *, active_jobs: int) -> None:
        self.active_jobs = active_jobs


def existing_ffmpeg(tmp_path) -> str:
    path = tmp_path / "ffmpeg.exe"
    path.write_bytes(b"MZ")
    return str(path)


def pair_to_ready(model: AppModel, nas: FakeNasAuth) -> None:
    model.start()
    model.pair(nas.url)
    approved = wait_snapshot(model, lambda snap: snap.phase == "approving", what="进入批准页")
    nas.approve(approved.pairing_code)
    wait_snapshot(model, lambda snap: snap.phase == "ready", what="配对完成")


# -- 启动 ---------------------------------------------------------------------


def test_unpaired_starts_on_onboarding():
    model, _ = make_model()
    model.start()
    assert model.snapshot().phase == "onboarding"


def test_a_known_address_without_a_token_pairs_right_away(nas):
    """地址在（上次配到一半、或命令行给了 --server）却没有令牌：双击打开就该等批准，
    不必再手点一次「连接并配对」。"""
    Config(server=nas.url).save()
    model, _ = make_model()

    model.start()

    approved = wait_snapshot(model, lambda snap: snap.phase == "approving", what="自动进批准页")
    assert approved.pairing_code
    nas.approve(approved.pairing_code)
    wait_snapshot(model, lambda snap: snap.phase == "ready", what="配对完成")


def test_paired_config_resumes_without_pairing(tmp_path):
    Config(
        server="http://nas:3000", token="tok", worker_id="pc", ffmpeg=existing_ffmpeg(tmp_path)
    ).save()
    model, _ = make_model()
    model.start()

    snapshot = wait_snapshot(model, lambda snap: snap.ffmpeg_state == "ready", what="ffmpeg 就绪")

    assert snapshot.phase == "ready"
    assert snapshot.gpu == "NVIDIA GeForce RTX 2070 SUPER"
    assert len(FakeClient.instances) == 1
    assert FakeClient.instances[0].kwargs["token"] == "tok"


# -- 配对 ---------------------------------------------------------------------


def test_pair_flow_reaches_ready_and_starts_the_kernel(tmp_path, nas):
    Config(ffmpeg=existing_ffmpeg(tmp_path)).save()
    model, opened = make_model()
    pair_to_ready(model, nas)

    wait_snapshot(
        model,
        lambda snap: snap.ffmpeg_state == "ready" and len(FakeClient.instances) == 1,
        what="内核启动",
    )
    assert opened == ["http://nas/auth?code=TEST-0001"]
    saved = json.loads(config_path().read_text(encoding="utf-8"))
    assert saved["token"] == "tok-dev-1"
    assert saved["server"] == nas.url
    assert FakeClient.instances[0].kwargs["server"] == nas.url
    assert FakeClient.instances[0].kwargs["capabilities"].ffmpeg_version == "8.1.3-Jellyfin"


def test_pairing_to_a_dead_address_reports_the_reason():
    model, _ = make_model()
    model.start()
    model.pair("http://127.0.0.1:1")

    snapshot = wait_snapshot(model, lambda snap: snap.pairing_error != "", what="配对报错")

    assert "连不上" in snapshot.pairing_error
    assert snapshot.phase == "onboarding"


def test_cancel_pairing_returns_to_onboarding(nas):
    model, _ = make_model()
    model.start()
    model.pair(nas.url)
    wait_snapshot(model, lambda snap: snap.phase == "approving", what="进入批准页")

    model.cancel_pairing()

    snapshot = wait_snapshot(model, lambda snap: snap.phase == "onboarding", what="回到引导")
    assert snapshot.pairing_error == ""


def test_reset_pairing_revokes_and_clears(tmp_path, nas):
    Config(ffmpeg=existing_ffmpeg(tmp_path)).save()
    model, _ = make_model()
    pair_to_ready(model, nas)
    wait_snapshot(model, lambda snap: len(FakeClient.instances) == 1, what="内核启动")

    model.reset_pairing()

    wait_snapshot(model, lambda snap: snap.phase == "onboarding", what="回到引导")
    assert nas.revocations == 1
    assert json.loads(config_path().read_text(encoding="utf-8"))["token"] == ""
    assert FakeClient.instances[0].stopped


# -- ffmpeg -------------------------------------------------------------------


def test_probe_failure_shows_the_problem_and_retry_recovers(tmp_path, nas):
    def broken_probe(*args, **kwargs):
        raise FfmpegProblem("缺 scale_cuda 滤镜")

    holder = {"fn": broken_probe}
    Config(ffmpeg=existing_ffmpeg(tmp_path)).save()
    model, _ = make_model(probe_holder=holder)
    pair_to_ready(model, nas)

    snapshot = wait_snapshot(model, lambda snap: snap.ffmpeg_state == "error", what="进入错误")
    assert "scale_cuda" in snapshot.ffmpeg_error
    assert FakeClient.instances == []  # 自检没过，内核不该启动

    holder["fn"] = lambda *args, **kwargs: CAPS_STUB
    model.retry_ffmpeg()
    wait_snapshot(
        model,
        lambda snap: snap.ffmpeg_state == "ready" and len(FakeClient.instances) == 1,
        what="恢复就绪",
    )


def test_download_flow_installs_official_ffmpeg(tmp_path, nas, monkeypatch):
    installed_path = tmp_path / "installed" / "ffmpeg.exe"
    installed_path.parent.mkdir(parents=True)
    installed_path.write_bytes(b"MZ")
    calls: dict[str, object] = {}
    release = ffmpeg_install.FFmpegRelease(version="8.1.3-1", url="u", digest="d", size=3)

    def fake_latest_release(*args, **kwargs):
        return release

    def fake_install(release_arg, versions_root, *, progress=None, **kwargs):
        calls["release"] = release_arg
        calls["progress"] = progress
        return installed_path

    monkeypatch.setattr(ffmpeg_install, "latest_release", fake_latest_release)
    monkeypatch.setattr(ffmpeg_install, "install", fake_install)

    model, _ = make_model()
    pair_to_ready(model, nas)

    wait_snapshot(model, lambda snap: snap.ffmpeg_state == "ready", what="下载后就绪")
    assert calls["release"] is release
    saved = json.loads(config_path().read_text(encoding="utf-8"))
    assert saved["ffmpeg"] == str(installed_path)
    assert len(FakeClient.instances) == 1


def test_download_failure_leaves_an_error_and_a_retry_path(nas, monkeypatch):
    def no_release(*args, **kwargs):
        raise ffmpeg_install.FfmpegInstallError("连不上发布页")

    monkeypatch.setattr(ffmpeg_install, "latest_release", no_release)

    model, _ = make_model()
    model.start()
    model.pair(nas.url)
    approved = wait_snapshot(model, lambda snap: snap.phase == "approving", what="进入批准页")
    nas.approve(approved.pairing_code)

    snapshot = wait_snapshot(model, lambda snap: snap.ffmpeg_state == "error", what="下载报错")

    assert "连不上发布页" in snapshot.ffmpeg_error
    assert snapshot.phase == "ready"


# -- 内核状态事件 ---------------------------------------------------------------


def test_connection_and_job_events_update_the_snapshot():
    model, _ = make_model()
    model._on_status("connecting")
    assert model.snapshot().connection == "connecting"

    model._on_status("online", max_jobs=2)
    snapshot = model.snapshot()
    assert snapshot.connection == "online" and snapshot.max_jobs == 2

    # 数量以内核的任务表为准：事件只是「变了」的信号，外壳不自己加减
    model._client = _CountingClient(active_jobs=2)
    model._on_status("job_started", job_id="j2", name="剧集")
    snapshot = model.snapshot()
    assert snapshot.active_jobs == 2 and snapshot.job_name == "剧集"

    model._client = _CountingClient(active_jobs=1)
    model._on_status("job_ended", job_id="j2")
    assert model.snapshot().active_jobs == 1

    model._client = _CountingClient(active_jobs=0)
    model._on_status("job_ended", job_id="j1")
    snapshot = model.snapshot()
    assert snapshot.active_jobs == 0 and snapshot.job_name == ""

    model._on_status("offline", reason="NAS 重启了", rejection="other")
    snapshot = model.snapshot()
    assert snapshot.connection == "offline" and snapshot.active_jobs == 0
    assert snapshot.connection_hint == ""

    model._on_status("offline", reason="凭证失效", rejection="auth")
    assert "重新配对" in model.snapshot().connection_hint
