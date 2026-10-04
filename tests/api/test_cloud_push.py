"""MovieClaw Cloud 与 App 推送的端到端测试（docs/design/cloud-push.md）。

用进程内的假云端和假中继（httpx.MockTransport）按协议应答，从管理员点「连接」开始，
走完：配对 → 续签上报 → App 登记 → 事件推送 → 中继收到密文 → 用 App 的密钥解开。
再覆盖异常：拒绝、过期、解绑、版本不受支持、断开时云端连不上、令牌失效、通道切换。
"""

from __future__ import annotations

import functools
import json
import secrets
import time
from collections.abc import Callable
from urllib.parse import parse_qs

import httpx
import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.push import crypto
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box

_AUTH = "/api/v1/auth"
_ADMIN = {"username": "admin", "password": "s3cret-pass"}
_MEMBER = {"username": "family", "password": "family-pass-1"}
_CLOUD = "https://cloud.test"
_PUSH = "https://push.test"
_OFFICIAL_TOPIC = "io.movieclaw.app"


# ----------------------------------------------------------------------
# 假云端 + 假中继
# ----------------------------------------------------------------------


class FakeCloud:
    """按云端协议应答：发现文档、配对、续签、解绑。"""

    def __init__(self) -> None:
        self.approval = "pending"  # pending / approved / denied
        self.renew_reply: tuple[int, dict] | None = None  # 覆盖续签的应答
        self.unbind_down = False
        self.revoked = False
        self.secret = "mcs_" + secrets.token_urlsafe(16)
        self.reports: list[dict] = []
        self.push_endpoints = [_PUSH]
        self.requests: list[str] = []
        self.issued = 0
        self.limits: dict[str, int] = {"day": 5000, "device_day": 500}

    def grant(self) -> dict:
        self.issued += 1
        return {
            "access_token": f"jwt-{self.issued}",
            "token_type": "Bearer",
            "expires_in": 86400,
            "scope": "push",
            "scopes": ["push"],
            "limits": dict(self.limits),
            "capabilities": ["push"],
            "renew_interval": 3600,
            "account": {"display": "a•••@example.com"},
        }

    def handle(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        self.requests.append(f"{request.method} {path}")
        if path == "/.well-known/movieclaw-cloud":
            return httpx.Response(
                200,
                json={
                    "api": _CLOUD,
                    "push_endpoints": [
                        {"url": u, "priority": i + 1} for i, u in enumerate(self.push_endpoints)
                    ],
                    "min_instance_version": "",
                },
            )
        if path == "/v1/instance/device-code":
            form = parse_qs(request.content.decode())
            assert form["scope"] == ["push"]
            assert form["instance_version"][0]
            return httpx.Response(
                200,
                json={
                    "device_code": "dc-" + secrets.token_hex(8),
                    "user_code": "WDJB-MJHT",
                    "verification_uri": "https://movieclaw.test/activate",
                    "verification_uri_complete": "https://movieclaw.test/activate?code=WDJB-MJHT",
                    "expires_in": 600,
                    "interval": 0.05,
                },
            )
        if path == "/v1/instance/token":
            if self.approval == "pending":
                return httpx.Response(400, json={"error": "authorization_pending"})
            if self.approval == "denied":
                return httpx.Response(400, json={"error": "access_denied"})
            return httpx.Response(
                200,
                json={**self.grant(), "instance_id": "inst-1", "instance_secret": self.secret},
            )
        if path == "/v1/instance/renew":
            assert request.headers["authorization"] == f"Bearer {self.secret}"
            body = json.loads(request.content)
            self.reports.append(body["report"])
            if self.renew_reply is not None:
                status, payload = self.renew_reply
                return httpx.Response(status, json=payload)
            if self.revoked:
                return httpx.Response(
                    401,
                    json={
                        "success": False,
                        "code": "INSTANCE_REVOKED",
                        "message": "这台实例已经解绑",
                    },
                )
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "code": "OK",
                    "message": "success",
                    "data": {**self.grant(), "instance_id": "inst-1", "notices": []},
                },
            )
        if path == "/v1/instance/unbind":
            if self.unbind_down:
                return httpx.Response(503, json={})
            self.revoked = True
            return httpx.Response(200, json={"success": True, "data": {"revoked": True}})
        return httpx.Response(404, json={})


class FakeRelay:
    """按推送中继协议应答：/v1/info 与 /v1/push。"""

    def __init__(self, *, topics: list[str], mode: str, token: str | None = None) -> None:
        self.topics = topics
        self.mode = mode
        self.token = token
        self.down = False
        self.reject = False  # 整批 401（令牌失效、在官网解绑了）
        self.results: dict[str, str | dict] = {}  # 设备令牌 → 结果码，或完整的单条结果
        self.messages: list[dict] = []
        self.bearers: list[str | None] = []
        self.info_bearers: list[str | None] = []  # 带凭证调 /v1/info（例行检查）时的凭证

    def handle(self, request: httpx.Request) -> httpx.Response:
        if self.down:
            raise httpx.ConnectError("连不上", request=request)
        if request.url.path == "/v1/info":
            bearer = request.headers.get("authorization", "").removeprefix("Bearer ") or None
            self.info_bearers.append(bearer)
            # 协议 §4.1：凭证有效时多一个 quota，无效时照常返回
            quota = (
                {"day": {"limit": 5000, "used": 7, "remaining": 4993, "reset_at": 1767312000}}
                if bearer and bearer.startswith("jwt-")
                else None
            )
            return httpx.Response(
                200,
                json={
                    **({"quota": quota} if quota else {}),
                    "protocol": 1,
                    "software": "movieclaw-push/test",
                    "aud": "https://push.test",
                    "platforms": ["apns"],
                    "environments": ["production", "development"],
                    "topics": self.topics,
                    "types": {"alert": {}, "background": {}},
                    "auth": {"mode": self.mode},
                    "limits": {"day": 5000, "device_day": 500},
                    "max_batch": 100,
                },
            )
        if request.url.path == "/v1/push":
            bearer = request.headers.get("authorization", "").removeprefix("Bearer ") or None
            if self.reject:
                return httpx.Response(401, json={"error": "unauthorized", "message": "实例已解绑"})
            if self.mode == "static" and bearer != self.token:
                return httpx.Response(401, json={"error": "unauthorized", "message": "令牌无效"})
            if self.mode == "issuer" and not (bearer or "").startswith("jwt-"):
                return httpx.Response(
                    401, json={"error": "unauthorized", "message": "凭证无效或已过期"}
                )
            messages = json.loads(request.content)["messages"]
            if not messages:
                return httpx.Response(
                    400, json={"error": "bad_request", "message": "messages 不能为空"}
                )
            self.bearers.append(bearer)
            self.messages.extend(messages)
            results = []
            for m in messages:
                code = self.results.get(m["token"], "ok")
                if isinstance(code, dict):
                    result = {"id": m["id"], **code}
                else:
                    result = {"id": m["id"], "result": code}
                    if code == "rate_limited":
                        result.update(
                            reason="day",
                            limit="day",
                            retry_after=3600,
                            message="今天的推送已达上限",
                        )
                results.append(result)
            return httpx.Response(
                200,
                json={
                    "results": results,
                    "quota": {
                        "day": {
                            "limit": 5000,
                            "used": len(self.messages),
                            "remaining": 4990,
                            "reset_at": 1767312000,
                        }
                    },
                },
            )
        return httpx.Response(404, json={})


class World:
    def __init__(self) -> None:
        self.cloud = FakeCloud()
        self.relays: dict[str, FakeRelay] = {
            "push.test": FakeRelay(topics=[_OFFICIAL_TOPIC], mode="issuer"),
            "push2.test": FakeRelay(topics=[_OFFICIAL_TOPIC], mode="issuer"),
            "relay.lan": FakeRelay(
                topics=["com.yi.movieclaw"], mode="static", token="mcpush_ab12_secret"
            ),
        }
        self.hosts: list[str] = []

    def transport(self) -> httpx.MockTransport:
        def handler(request: httpx.Request) -> httpx.Response:
            self.hosts.append(request.url.host)
            if request.url.host == "cloud.test":
                return self.cloud.handle(request)
            relay = self.relays.get(request.url.host)
            if relay is None:
                raise httpx.ConnectError("没有这个地址", request=request)
            return relay.handle(request)

        return httpx.MockTransport(handler)


@pytest.fixture
def world(tmp_path, monkeypatch):  # type: ignore[no-untyped-def]
    w = World()
    transport = w.transport()
    monkeypatch.setattr(
        "movieclaw_api.services.cloud.client.egress_transport", lambda *a, **k: transport
    )
    monkeypatch.setattr(
        "movieclaw_api.services.push.relay.egress_transport", lambda *a, **k: transport
    )
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'push.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("MOVIECLAW_CLOUD_URL", _CLOUD)
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    from movieclaw_api.services.push import channels, events, me

    channels.reset_runtime()
    me.reset_state()
    events.reset_state()
    # 推送的几个等待（攒一攒再发）在测试里缩到零点几秒
    monkeypatch.setattr(events, "_ALERT_DELAY_S", 0.2)
    monkeypatch.setattr(events, "_MERGE_QUIET_S", 0.2)
    # 配对轮询与配对后首次续签同理：生产下限是 1 秒，每个用例连接云端要白等两秒
    from movieclaw_api.services.cloud import service as cloud_service

    monkeypatch.setattr(cloud_service, "_PAIRING_MIN_INTERVAL_S", 0.05)
    monkeypatch.setattr(cloud_service, "_FIRST_RENEW_DELAY_S", 0.05)
    yield w
    events.reset_state()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


@pytest.fixture
def client(world):  # type: ignore[no-untyped-def]
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        c.post(f"{_AUTH}/bootstrap", json=_ADMIN)
        c.post(f"{_AUTH}/login", json=_ADMIN)
        yield c


def _data(resp: httpx.Response) -> dict:
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def _in_app(client: TestClient, trigger: Callable[[], None]) -> None:
    """在应用自己的事件循环里调业务产生点（推送是在那个循环里起的后台任务）。"""

    async def run() -> None:
        trigger()

    assert client.portal is not None
    client.portal.call(run)


def _wait(predicate: Callable[[], bool], timeout: float = 8.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError("等待超时")


def _connect(client: TestClient, world: World) -> dict:
    status = _data(client.post("/api/v1/cloud/pairing", json={"instance_name": "客厅 NAS"}))
    assert status["state"] == "pairing"
    world.cloud.approval = "approved"
    _wait(lambda: _data(client.get("/api/v1/cloud"))["state"] == "connected")
    # 等第一次续签的结果落库（云端先收到上报、实例后保存，中间有一小段空档）
    _wait(lambda: _data(client.get("/api/v1/cloud"))["last_report"] is not None)
    return _data(client.get("/api/v1/cloud"))


def _as_app(client: TestClient, bearer: str, method: str, url: str, **kwargs) -> httpx.Response:  # type: ignore[no-untyped-def]
    """以 App 的身份请求：只带设备令牌，不带浏览器里的会话 Cookie（真实 App 没有它）。"""
    saved = dict(client.cookies)
    client.cookies.clear()
    try:
        return client.request(method, url, headers={"Authorization": f"Bearer {bearer}"}, **kwargs)
    finally:
        for name, value in saved.items():
            client.cookies.set(name, value)


def _app_login(client: TestClient, who: dict, *, installation: str, name: str) -> str:
    saved = dict(client.cookies)
    client.cookies.clear()
    try:
        resp = client.post(
            f"{_AUTH}/device/login",
            json={**who, "client": {"kind": "ios", "installation_id": installation, "name": name}},
        )
    finally:
        for cookie, value in saved.items():
            client.cookies.set(cookie, value)
    return _data(resp)["token"]


def _register(
    client: TestClient, bearer: str, *, token: str, topic: str = _OFFICIAL_TOPIC
) -> tuple[str, bytes]:
    key = secrets.token_bytes(32)
    key_id = crypto.b64url(secrets.token_bytes(8))
    resp = _as_app(
        client,
        bearer,
        "PUT",
        "/api/v1/push/me/registration",
        json={
            "token": token,
            "topic": topic,
            "environment": "production",
            "types": ["alert"],
            "key_id": key_id,
            "key": crypto.b64url(key),
            "permission": "authorized",
        },
    )
    assert resp.status_code == 200, resp.text
    return key_id, key


def _open(message: dict, key: bytes) -> dict:
    return json.loads(crypto.open_sealed(message["payload"], key=key))


def _raise_notice(
    client: TestClient,
    key: str,
    *,
    source: str,
    title: str,
    message: str = "",
    payload: dict | None = None,
    severity: str = "error",
) -> None:
    """在应用里点亮一条待处理事项（和业务代码一样走 upsert_notice）。"""
    from movieclaw_api.services.system_notice import upsert_notice
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeSeverity

    async def go() -> None:
        async with get_database().session() as session:
            await upsert_notice(
                session,
                dedupe_key=key,
                severity=NoticeSeverity(severity),
                source=source,
                title=title,
                message=message,
                payload=payload,
            )

    assert client.portal is not None
    client.portal.call(go)


def _create_member(client: TestClient) -> None:
    resp = client.post("/api/v1/members", json={**_MEMBER, "nickname": "家人"})
    assert resp.status_code in (200, 201), resp.text


# ----------------------------------------------------------------------
# 连接
# ----------------------------------------------------------------------


def test_not_connected_sends_nothing(client: TestClient, world: World) -> None:
    status = _data(client.get("/api/v1/cloud"))
    assert status["state"] == "disconnected"
    assert status["connection"] is None and status["pairing"] is None
    assert status["custom_cloud_url"] is True
    channels = _data(client.get("/api/v1/push/channels"))
    official = channels["channels"][0]
    assert official["id"] == "official" and official["state"] == "inactive"
    assert official["status_text"] == "未连接 MovieClaw Cloud"
    assert world.hosts == []  # 未连接时对云端、官方中继不发任何请求


def test_connect_renew_and_report(client: TestClient, world: World) -> None:
    status = _data(client.post("/api/v1/cloud/pairing", json={"instance_name": "客厅 NAS"}))
    pairing = status["pairing"]
    assert pairing["user_code"] == "WDJB-MJHT" and pairing["status"] == "pending"
    assert pairing["qrcode_image"].startswith("data:image/svg+xml;base64,")
    assert pairing["instance_name"] == "客厅 NAS"
    assert "dc-" not in json.dumps(status)  # device_code 不出现在任何响应里

    status = _connect(client, world)
    connection = status["connection"]
    assert connection["account_display"] == "a•••@example.com"
    assert connection["scopes"] == ["push"] and connection["instance_name"] == "客厅 NAS"
    assert status["health"] == "ok"
    report = world.cloud.reports[0]
    assert report["instance_version"] and report["os"] and report["arch"]
    # 续签前带上令牌例行检查官方中继：上报里有检查时间，没推送过就没有 last_success_at
    assert world.relays["push.test"].info_bearers[-1] == "jwt-1"
    assert report["relay"]["reachable"] is True and report["relay"]["checked_at"].endswith("Z")
    assert "last_success_at" not in report["relay"] and "error" not in report["relay"]
    assert status["last_report"]["instance_version"] == report["instance_version"]

    # 关掉统计后只上报版本信息
    _data(client.put("/api/v1/cloud/settings", json={"report_stats": False}))
    _data(client.post("/api/v1/cloud/renew"))
    assert set(world.cloud.reports[-1]) == {"instance_version", "runtime_version", "os", "arch"}

    channels = _data(client.get("/api/v1/push/channels"))
    assert channels["cloud_state"] == "connected"
    assert channels["channels"][0]["state"] == "ok"
    # 已连接时重复连接被拒
    assert client.post("/api/v1/cloud/pairing", json={}).status_code == 409


def test_pairing_denied(client: TestClient, world: World) -> None:
    _data(client.post("/api/v1/cloud/pairing", json={}))
    world.cloud.approval = "denied"
    _wait(lambda: (_data(client.get("/api/v1/cloud"))["pairing"] or {}).get("status") == "denied")
    status = _data(client.get("/api/v1/cloud"))
    assert status["state"] == "pairing" and "拒绝" in status["pairing"]["message"]
    status = _data(client.delete("/api/v1/cloud/pairing"))
    assert status["state"] == "disconnected"


def test_revoked_on_website(client: TestClient, world: World) -> None:
    _connect(client, world)
    world.cloud.revoked = True
    _data(client.post("/api/v1/cloud/renew"))
    status = _data(client.get("/api/v1/cloud"))
    assert status["state"] == "disconnected"
    assert status["last_disconnect"]["reason"] == "revoked"
    notices = _data(client.get("/api/v1/system/notices"))
    items = notices["items"] if isinstance(notices, dict) else notices
    assert any("断开" in n["title"] and n["source"] == "cloud" for n in items)


def test_version_unsupported_keeps_credentials(client: TestClient, world: World) -> None:
    _connect(client, world)
    world.cloud.renew_reply = (
        403,
        {"success": False, "code": "VERSION_UNSUPPORTED", "message": "实例版本 0.1 已不再受支持"},
    )
    status = _data(client.post("/api/v1/cloud/renew"))
    assert status["state"] == "connected" and status["health"] == "unsupported"
    official = _data(client.get("/api/v1/push/channels"))["channels"][0]
    assert official["state"] == "error" and "不再受支持" in official["status_text"]
    # 升级后（云端恢复受理）下一次续签自动恢复
    world.cloud.renew_reply = None
    status = _data(client.post("/api/v1/cloud/renew"))
    assert status["health"] == "ok"


def test_relay_check_reports_unreachable_and_survives_restart(
    client: TestClient, world: World
) -> None:
    """例行检查连不上官方中继：上报原因和开始时间，开始时间跨续签保持；恢复后清掉。
    结果存库，进程重启（运行期状态清零）后最近一次成功推送的时间还在。"""
    from movieclaw_api.services.push import channels

    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="inst-iphone-1", name="iPhone")
    _register(client, bearer, token="ab" * 32)
    assert _data(client.post("/api/v1/push/me/test"))["sent"] == 1
    official = world.relays["push.test"]

    official.down = True
    world.relays["push2.test"].down = True
    _data(client.post("/api/v1/cloud/renew"))
    first = world.cloud.reports[-1]["relay"]
    assert first["reachable"] is False and "连不上" in first["error"]
    assert first["failing_since"] and first["last_success_at"]
    _data(client.post("/api/v1/cloud/renew"))
    assert world.cloud.reports[-1]["relay"]["failing_since"] == first["failing_since"]

    official.down = False
    world.relays["push2.test"].down = False
    channels.reset_runtime()  # 模拟重启：内存里的最近成功清零
    _data(client.post("/api/v1/cloud/renew"))
    after = world.cloud.reports[-1]["relay"]
    assert after["reachable"] is True and "error" not in after and "failing_since" not in after
    assert after["last_success_at"] == first["last_success_at"]
    assert channels.runtime(channels.OFFICIAL_ID).quota["day"]["used"] == 7


def test_renew_failure_keeps_token(client: TestClient, world: World) -> None:
    _connect(client, world)
    world.cloud.renew_reply = (503, {})
    status = _data(client.post("/api/v1/cloud/renew"))
    assert status["state"] == "connected" and status["health"] == "unreachable"
    assert _data(client.get("/api/v1/push/channels"))["channels"][0]["state"] == "warning"


def test_disconnect_when_cloud_unreachable(client: TestClient, world: World) -> None:
    _connect(client, world)
    world.cloud.unbind_down = True
    resp = client.post("/api/v1/cloud/disconnect", json={})
    assert resp.status_code == 409 and resp.json()["code"] == "CLOUD_UNREACHABLE"
    status = _data(client.post("/api/v1/cloud/disconnect", json={"force": True}))
    assert status["state"] == "disconnected" and status["last_disconnect"] is None


# ----------------------------------------------------------------------
# 登记与推送
# ----------------------------------------------------------------------


def test_registration_requires_app_credentials(client: TestClient, world: World) -> None:
    # 网页会话登记不了
    resp = client.put(
        "/api/v1/push/me/registration", json={"permission": "authorized", "token": None}
    )
    assert resp.status_code == 403
    bearer = _app_login(client, _ADMIN, installation="inst-iphone-1", name="iPhone")
    bad = _as_app(
        client,
        bearer,
        "PUT",
        "/api/v1/push/me/registration",
        json={"permission": "authorized", "token": "a1" * 32},
    )
    assert bad.status_code == 400  # token、key_id、key 要么都有要么都没有
    # 只上报权限状态
    resp = _as_app(
        client, bearer, "PUT", "/api/v1/push/me/registration", json={"permission": "denied"}
    )
    assert _data(resp)["status"] == "permission_denied"


def test_push_end_to_end_through_official_relay(client: TestClient, world: World) -> None:
    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="inst-iphone-1", name="iPhone 16 Pro")
    device_token = "ab" * 32
    key_id, key = _register(client, bearer, token=device_token)

    mine = _data(client.get("/api/v1/push/me"))
    assert mine["instance_ready"] is True
    assert mine["ready_devices"] == 1 and mine["attention"] == []
    # 设备页上同一台设备的推送状态
    listed = _data(client.get("/api/v1/auth/devices"))
    phone = next(d for d in listed if d["name"] == "iPhone 16 Pro")
    assert phone["push"] == {"status": "ok", "status_text": "能收到"}
    assert all(d["push"] is None for d in listed if d["kind"] == "web")

    # 测试通知：同步返回结果，中继收到的是密文，用 App 的密钥解得开
    result = _data(client.post("/api/v1/push/me/test"))
    assert result["sent"] == 1 and result["results"][0]["result"] == "ok"
    relay = world.relays["push.test"]
    message = relay.messages[-1]
    assert relay.bearers[-1] == "jwt-2"  # 用的是续签拿到的最新令牌
    assert message["topic"] == _OFFICIAL_TOPIC and message["environment"] == "production"
    assert message["type"] == "alert" and message["aps"] == {"sound": "default"}
    assert message["payload"].startswith(f"v1.{key_id}.")
    assert "测试" not in json.dumps(message, ensure_ascii=False)  # 明文里没有任何内容
    plain = _open(message, key)
    assert plain["title"] == "测试通知" and plain["type"] == "alert"
    assert plain["server"]["name"] == "客厅 NAS" and plain["account"]["id"] == "0"
    assert plain["open"] == "/settings/notifications"

    # 待处理事项 → 推给管理员，同一个问题用同一个 collapse_id
    _raise_notice(
        client, "site:mteam", source="site", title="站点登录失效", message="请更新 Cookie"
    )
    _wait(lambda: len(relay.messages) >= 2)
    alert = relay.messages[-1]
    plain = _open(alert, key)
    assert plain["title"] == "站点登录失效" and plain["open"] == "/settings/sites"
    assert plain["source"] == "server"  # 管理员告警：连了多台服务器时标服务器名
    assert alert["collapse_id"] and len(alert["collapse_id"]) == 16

    # 覆盖视图：官方 App 的设备走官方通道
    # 通道上只汇总设备数，每台设备都有通道时没有「缺口」
    view = _data(client.get("/api/v1/push/channels"))
    assert view["channels"][0]["device_count"] == 1 and view["uncovered"] == []
    # 上报里带上了按平台汇总的设备数（没有设备名）
    _data(client.post("/api/v1/cloud/renew"))
    assert world.cloud.reports[-1]["devices"] == [
        {"platform": "ios", "app_version": "", "count": 1}
    ]
    assert world.cloud.reports[-1]["relay"]["reachable"] is True


def test_same_phone_two_accounts_gets_one_push(client: TestClient, world: World) -> None:
    _connect(client, world)
    _create_member(client)
    token = "cd" * 32
    admin_bearer = _app_login(client, _ADMIN, installation="shared-ipad-1", name="客厅 iPad")
    member_bearer = _app_login(client, _MEMBER, installation="shared-ipad-1", name="客厅 iPad")
    _register(client, admin_bearer, token=token)
    _, member_key = _register(client, member_bearer, token=token)

    from movieclaw_api.services.push import notify

    async def build(_session, member_id):  # type: ignore[no-untyped-def]
        return notify.AlertContent(title=f"给 {member_id}")

    relay = world.relays["push.test"]
    _in_app(client, lambda: notify.notify("imported", {0, 1}, build))
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.3)
    assert len(relay.messages) == 1
    # 用最近登记的那个账号的密钥（两个账号都在这台 iPad 上，用哪个都解得开）
    assert _open(relay.messages[0], member_key)["title"] == "给 1"


def test_preferences_and_member_view(client: TestClient, world: World) -> None:
    _connect(client, world)
    _create_member(client)
    member_bearer = _app_login(client, _MEMBER, installation="member-phone-1", name="家人的手机")
    _register(client, member_bearer, token="ef" * 32)
    view = _data(_as_app(client, member_bearer, "GET", "/api/v1/push/me"))
    keys = {e["key"] for e in view["events"]}
    assert "system_alert" not in keys and "imported" in keys and view["is_admin"] is False
    view = _data(
        _as_app(
            client,
            member_bearer,
            "PUT",
            "/api/v1/push/me/preferences",
            json={"events": {"imported": False, "system_alert": True}},
        )
    )
    assert next(e for e in view["events"] if e["key"] == "imported")["enabled"] is False

    from movieclaw_api.services.push import notify

    async def build(_session, _member_id):  # type: ignore[no-untyped-def]
        return notify.AlertContent(title="入库")

    relay = world.relays["push.test"]
    _in_app(client, lambda: notify.notify("imported", {1}, build))  # 关掉了：不发
    _in_app(client, lambda: notify.notify("download_started", {1}, build))  # 默认关：不发
    _in_app(client, lambda: notify.notify("new_device", {1}, build))  # 默认开：发
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.3)
    assert len(relay.messages) == 1


def test_unregistered_token_clears_registration(client: TestClient, world: World) -> None:
    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="inst-old-1", name="旧手机")
    token = "aa" * 32
    _register(client, bearer, token=token)
    world.relays["push.test"].results[token] = "unregistered"
    result = _data(client.post("/api/v1/push/me/test"))
    assert result["results"][0]["result"] == "unregistered"
    mine = _data(client.get("/api/v1/push/me"))
    assert mine["ready_devices"] == 0 and mine["attention"] == []  # 等 App 下次启动重新登记


def test_official_failover_to_backup_endpoint(client: TestClient, world: World) -> None:
    world.cloud.push_endpoints = [_PUSH, "https://push2.test"]
    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="inst-iphone-2", name="iPhone")
    _register(client, bearer, token="bb" * 32)
    world.relays["push.test"].down = True
    result = _data(client.post("/api/v1/push/me/test"))
    assert result["results"][0]["result"] == "ok"
    assert len(world.relays["push2.test"].messages) == 1


def test_new_device_login_notifies_other_devices(client: TestClient, world: World) -> None:
    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="inst-iphone-3", name="我的 iPhone")
    _, key = _register(client, bearer, token="cc" * 32)
    relay = world.relays["push.test"]
    _app_login(client, _ADMIN, installation="inst-ipad-9", name="新 iPad")
    _wait(lambda: len(relay.messages) >= 1)
    plain = _open(relay.messages[-1], key)
    assert plain["title"] == "新设备登录了你的账号" and "新 iPad" in plain["body"]
    assert "「客厅 NAS」" in plain["body"] and plain["source"] == "account"
    # 同一台设备重新登录不算新设备
    count = len(relay.messages)
    _app_login(client, _ADMIN, installation="inst-ipad-9", name="新 iPad")
    time.sleep(0.5)
    assert len(relay.messages) == count


# ----------------------------------------------------------------------
# 自建中继
# ----------------------------------------------------------------------


def test_custom_relay_lifecycle(client: TestClient, world: World) -> None:
    probe = _data(client.post("/api/v1/push/relays/probe", json={"url": "http://relay.lan/"}))
    assert probe["reachable"] and probe["auth_mode"] == "static" and probe["error"] is None
    assert probe["url"] == "http://relay.lan" and probe["topics"] == ["com.yi.movieclaw"]
    assert any("没有设备" in w for w in probe["warnings"])

    # 令牌不对、缺令牌都加不进去
    assert client.post("/api/v1/push/relays", json={"url": "http://relay.lan"}).status_code == 400
    wrong = client.post(
        "/api/v1/push/relays", json={"url": "http://relay.lan", "token": "mcpush_xx_wrong"}
    )
    assert wrong.status_code == 400 and "不认这个令牌" in wrong.json()["message"]
    view = _data(
        client.post(
            "/api/v1/push/relays",
            json={"name": "书房中继", "url": "http://relay.lan", "token": "mcpush_ab12_secret"},
        )
    )
    custom = view["channels"][1]
    assert custom["name"] == "书房中继" and custom["state"] == "ok"
    assert custom["token_hint"] == "mcpush_ab12…" and "secret" not in json.dumps(view)

    # 自己打包的 App 走自建中继（没连云也能用）
    bearer = _app_login(client, _ADMIN, installation="inst-self-1", name="自签 iPhone")
    _, key = _register(client, bearer, token="dd" * 32, topic="com.yi.movieclaw")
    result = _data(client.post("/api/v1/push/me/test"))
    assert result["results"][0]["result"] == "ok"
    relay = world.relays["relay.lan"]
    assert relay.bearers[-1] == "mcpush_ab12_secret"
    assert _open(relay.messages[-1], key)["title"] == "测试通知"

    view = _data(client.get("/api/v1/push/channels"))
    assert view["channels"][1]["device_count"] == 1 and view["uncovered"] == []

    # 停用后没有可用通道
    relay_id = custom["id"]
    view = _data(client.patch(f"/api/v1/push/relays/{relay_id}", json={"enabled": False}))
    assert view["channels"][1]["state"] == "inactive"
    assert view["uncovered"] == [{"topic": "com.yi.movieclaw", "device_count": 1}]
    attention = _data(client.get("/api/v1/push/me"))["attention"]
    assert [a["status"] for a in attention] == ["no_channel"]
    _data(client.delete(f"/api/v1/push/relays/{relay_id}"))
    assert len(_data(client.get("/api/v1/push/channels"))["channels"]) == 1


def test_official_channel_switch(client: TestClient, world: World) -> None:
    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="inst-iphone-4", name="iPhone")
    _register(client, bearer, token="ee" * 32)
    view = _data(client.put("/api/v1/push/channels/official", json={"enabled": False}))
    assert (
        view["channels"][0]["state"] == "inactive"
        and view["channels"][0]["status_text"] == "已停用"
    )
    result = _data(client.post("/api/v1/push/me/test"))
    assert result["results"] == [] or result["results"][0]["result"] == "no_channel"
    assert _data(client.get("/api/v1/push/me"))["instance_ready"] is False


# ----------------------------------------------------------------------
# 配图签名
# ----------------------------------------------------------------------


def test_push_image_signature(client: TestClient, world: World) -> None:
    import asyncio

    from movieclaw_api.services.push import images

    tmdb = get_settings().tmdb_image_base_url.rstrip("/") + "/w780/abc.jpg"
    path = asyncio.run(images.image_path(tmdb))
    assert path and path.startswith("/api/v1/push/images/")
    assert asyncio.run(images.resolve_image(path.rsplit("/", 1)[-1])) == tmdb
    assert asyncio.run(images.image_path("https://evil.example/x.jpg")) is None
    assert client.get("/api/v1/push/images/forged-token").status_code == 404


# ----------------------------------------------------------------------
# 订阅入库：推给订阅的人，看不到的不推
# ----------------------------------------------------------------------


def test_imported_goes_to_subscribers_who_can_see_it(client: TestClient, world: World) -> None:
    from movieclaw_api.services.subscription.wanted_fulfillment import close_fulfilled_wanted
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import (
        FileSource,
        LibraryFile,
        MediaItem,
        RuleSet,
        Subscription,
        SubscriptionFollower,
        WantedItem,
        WantedStatus,
        utcnow,
    )
    from movieclaw_db.repositories.library_repo import LibraryRepository

    _connect(client, world)
    _create_member(client)
    admin_bearer = _app_login(client, _ADMIN, installation="admin-phone-1", name="管理员的手机")
    member_bearer = _app_login(client, _MEMBER, installation="member-phone-2", name="家人的手机")
    _, admin_key = _register(client, admin_bearer, token="a0" * 32)
    _, member_key = _register(client, member_bearer, token="b0" * 32)
    relay = world.relays["push.test"]
    relay.messages.clear()

    async def seed_and_import(access_mode: str) -> tuple[int, int, int]:
        async with get_database().session() as session:
            library = await LibraryRepository(session).create(
                name=f"剧集库-{access_mode}", kind="tv", root_paths=[f"/media/tv-{access_mode}"]
            )
            library.access_mode = access_mode
            item = MediaItem(
                kind="tv",
                tmdb_id=200 if access_mode == "everyone" else 201,
                title="漫长的季节",
                original_title="The Long Season",
                year=2023,
            )
            rule_set = RuleSet(name=f"默认-{access_mode}", spec={})
            session.add_all([library, item, rule_set])
            await session.commit()
            await session.refresh(item)
            await session.refresh(rule_set)
            subscription = Subscription(
                media_item_id=item.id, kind="tv", rule_set_id=rule_set.id, library_id=library.id
            )  # 管理员发起
            session.add(subscription)
            await session.commit()
            await session.refresh(subscription)
            session.add(SubscriptionFollower(subscription_id=subscription.id, member_id=1))
            session.add(
                WantedItem(
                    subscription_id=subscription.id,
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=7,
                    status=WantedStatus.GRABBED,
                    info_hash=f"hash-{access_mode}",
                    grabbed_at=utcnow(),
                )
            )
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=7,
                    file_path=f"/media/tv-{access_mode}/漫长的季节/S01E07.mkv",
                    size_bytes=1,
                    source=FileSource.IMPORTED,
                )
            )
            await session.commit()
            assert await close_fulfilled_wanted(session, item.id) == 1
            return library.id, item.id, subscription.id

    # 对全员开放的库：发起人（管理员）和关注者（成员）都收到，各自用自己的密钥
    assert client.portal is not None
    library_id, item_id, _ = client.portal.call(seed_and_import, "everyone")
    _wait(lambda: len(relay.messages) >= 2)
    by_token = {m["token"]: m for m in relay.messages}
    member_plain = _open(by_token["b0" * 32], member_key)
    assert member_plain["title"] == "漫长的季节 更新了"
    assert member_plain["body"] == "第 1 季第 7 集已入库，点开就能看"
    assert member_plain["open"] == f"/library/{library_id}/item/{item_id}?season=1&episode=7"
    assert member_plain["account"] == {"id": "1", "name": "家人"}
    assert "source" not in member_plain  # 内容类不标来源：点开时 App 自动切过去
    assert _open(by_token["a0" * 32], admin_key)["title"] == "漫长的季节 更新了"

    # 只对选中成员开放、家人不在名单里：家人看不到，就不推给家人
    relay.messages.clear()
    client.portal.call(seed_and_import, "selected")
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.5)
    assert [m["token"] for m in relay.messages] == ["a0" * 32]


def test_episode_label() -> None:
    from movieclaw_api.services.push.events import episode_label

    assert episode_label([(0, 0)]) == ""
    assert episode_label([(2, 7)]) == "第 2 季第 7 集"
    assert episode_label([(0, 3)]) == "特别篇第 3 集"
    assert episode_label([(1, 1), (1, 2), (1, 3)]) == "第 1 季 3 集"
    assert episode_label([(1, 8), (2, 1)]) == "2 集"


# ----------------------------------------------------------------------
# 媒体库有新片
# ----------------------------------------------------------------------


def test_library_new_arrivals(client: TestClient, world: World) -> None:
    from datetime import timedelta

    from movieclaw_api.services.push import arrivals
    from movieclaw_api.settings import get_setting_store
    from movieclaw_api.settings.cloud import ArrivalsProgress
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import (
        FileSource,
        LibraryFile,
        MediaItem,
        RuleSet,
        Subscription,
        utcnow,
    )
    from movieclaw_db.repositories.library_repo import LibraryRepository

    _connect(client, world)
    _create_member(client)
    admin_bearer = _app_login(client, _ADMIN, installation="arr-admin-1", name="管理员手机")
    member_bearer = _app_login(client, _MEMBER, installation="arr-member-1", name="家人手机")
    _register(client, admin_bearer, token="c1" * 32)
    _, member_key = _register(client, member_bearer, token="d1" * 32)
    relay = world.relays["push.test"]
    assert client.portal is not None

    async def seed_libraries() -> tuple[int, int, int]:
        async with get_database().session() as session:
            repo = LibraryRepository(session)
            movies = await repo.create(name="电影", kind="movie", root_paths=["/m"])
            shows = await repo.create(name="剧集", kind="tv", root_paths=["/t"])
            fresh = await repo.create(name="刚建的库", kind="movie", root_paths=["/f"])
            old = utcnow() - timedelta(days=3)
            movies.created_at = shows.created_at = old  # 老库；fresh 是刚建的
            session.add_all([movies, shows])
            await session.commit()
            return movies.id, shows.id, fresh.id

    movies_id, shows_id, fresh_id = client.portal.call(seed_libraries)
    # 家人打开「媒体库有新片」，只关心电影库和刚建的库
    view = _data(
        _as_app(
            client,
            member_bearer,
            "PUT",
            "/api/v1/push/me/preferences",
            json={"events": {"library_new": True}, "library_ids": [movies_id, fresh_id]},
        )
    )
    assert view["library_ids"] == [movies_id, fresh_id]
    assert {lib["name"] for lib in view["libraries"]} >= {"电影", "剧集", "刚建的库"}

    async def start_progress() -> None:
        await get_setting_store().set(
            ArrivalsProgress(started_at=utcnow() - timedelta(seconds=1), marks={})
        )

    client.portal.call(start_progress)

    async def add_files(
        specs: list[tuple[int, str, str, tuple[int, int], FileSource]],
    ) -> list[int]:
        ids = []
        async with get_database().session() as session:
            for library_id, kind, title, (season, episode), source in specs:
                item = (
                    await session.execute(
                        __import__("sqlmodel").select(MediaItem).where(MediaItem.title == title)
                    )
                ).scalar_one_or_none()
                if item is None:
                    item = MediaItem(
                        kind=kind,
                        tmdb_id=1000 + abs(hash(title)) % 100000,
                        title=title,
                        original_title=title,
                        year=2024,
                    )
                    session.add(item)
                    await session.commit()
                    await session.refresh(item)
                session.add(
                    LibraryFile(
                        library_id=library_id,
                        media_item_id=item.id,
                        season_number=season,
                        episode_number=episode,
                        file_path=f"/x/{library_id}/{title}/{season}-{episode}-{len(ids)}-{utcnow().timestamp()}.mkv",
                        size_bytes=1,
                        source=source,
                    )
                )
                ids.append(item.id)
            await session.commit()
        return ids

    def run_check() -> int:
        async def go() -> int:
            return await arrivals.check_once(utcnow() + timedelta(minutes=10))

        return client.portal.call(go)

    # ① 电影库来了一部新片 → 家人收到单条；管理员没打开这项，收不到
    (movie_id,) = client.portal.call(
        add_files, [(movies_id, "movie", "流浪地球 2", (0, 0), FileSource.IMPORTED)]
    )
    assert run_check() == 1
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.3)
    assert [m["token"] for m in relay.messages] == ["d1" * 32]
    plain = _open(relay.messages[-1], member_key)
    assert plain["title"] == "新片：流浪地球 2" and "已加入「电影」" in plain["body"]
    assert plain["open"].startswith(f"/library/{movies_id}/item/{movie_id}")

    # ② 同一部又来一个更好的版本（洗版）→ 不算新片
    relay.messages.clear()
    client.portal.call(add_files, [(movies_id, "movie", "流浪地球 2", (0, 0), FileSource.IMPORTED)])
    assert run_check() == 0

    # ③ 一批三部 → 合成一条
    client.portal.call(
        add_files,
        [
            (movies_id, "movie", "奥本海默", (0, 0), FileSource.SCANNED),
            (movies_id, "movie", "沙丘 2", (0, 0), FileSource.SCANNED),
            (movies_id, "movie", "首尔之春", (0, 0), FileSource.SCANNED),
        ],
    )
    assert run_check() == 1
    _wait(lambda: len(relay.messages) >= 1)
    plain = _open(relay.messages[-1], member_key)
    assert plain["title"] == "「电影」新增 3 部" and "奥本海默" in plain["body"]
    assert plain["open"] == f"/library/{movies_id}"

    # ④ 家人自己订阅了的片：对账先推了「入库完成」，「媒体库有新片」不再重复推给他
    relay.messages.clear()

    async def subscribe_as_member(title: str) -> tuple[int, int]:
        async with get_database().session() as session:
            item = MediaItem(
                kind="movie", tmdb_id=900001, title=title, original_title=title, year=2024
            )
            rule_set = RuleSet(name=f"规则-{title}", spec={})
            session.add_all([item, rule_set])
            await session.commit()
            await session.refresh(item)
            await session.refresh(rule_set)
            subscription = Subscription(
                media_item_id=item.id,
                kind="movie",
                rule_set_id=rule_set.id,
                created_by_member_id=1,
            )
            session.add(subscription)
            await session.commit()
            await session.refresh(subscription)
            return subscription.id, item.id

    subscription_id, item_id = client.portal.call(subscribe_as_member, "我订阅的片")
    client.portal.call(add_files, [(movies_id, "movie", "我订阅的片", (0, 0), FileSource.IMPORTED)])
    from movieclaw_api.services.push import events as push_events

    _in_app(
        client,
        lambda: push_events.imported(
            subscription_id=subscription_id,
            item_id=item_id,
            title="我订阅的片",
            year=2024,
            kind="movie",
            units=[(0, 0)],
            image_url=None,
        ),
    )
    _wait(lambda: len(relay.messages) >= 1)
    assert _open(relay.messages[-1], member_key)["title"] == "我订阅的片 已入库"
    run_check()
    time.sleep(0.5)
    assert len(relay.messages) == 1  # 只有那条「入库完成」
    relay.messages.clear()

    # ⑤ 没勾选的剧集库、刚建的库的首次扫描 → 都不推
    client.portal.call(
        add_files,
        [
            (shows_id, "tv", "漫长的季节", (1, 7), FileSource.IMPORTED),
            (fresh_id, "movie", "首次扫描出来的", (0, 0), FileSource.SCANNED),
        ],
    )
    run_check()
    time.sleep(0.5)
    assert relay.messages == []

    # ⑥ 还在陆续入库（5 分钟内有新行）就先不发
    client.portal.call(add_files, [(movies_id, "movie", "刚到的", (0, 0), FileSource.IMPORTED)])

    async def check_now() -> int:
        return await arrivals.check_once(utcnow())

    assert client.portal.call(check_now) == 0


def test_new_version_pushed_once(client: TestClient, world: World) -> None:
    from movieclaw_api.schemas.app_update import UpdateCheckView
    from movieclaw_api.services import app_update

    _connect(client, world)
    _create_member(client)
    admin_bearer = _app_login(client, _ADMIN, installation="ver-admin-1", name="管理员手机")
    member_bearer = _app_login(client, _MEMBER, installation="ver-member-1", name="家人手机")
    _, admin_key = _register(client, admin_bearer, token="e1" * 32)
    _register(client, member_bearer, token="f1" * 32)
    relay = world.relays["push.test"]
    relay.messages.clear()

    def check(version: str) -> None:
        view = UpdateCheckView(
            current_version="0.30.0",
            latest_version=version,
            update_available=True,
            compatible=True,
            requires_runtime=17,
            changelog="",
            published_at="",
            latest_known_bad=False,
        )

        async def go() -> None:
            await app_update._record_app_check(view)

        assert client.portal is not None
        client.portal.call(go)

    check("0.31.0")
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.3)
    assert [m["token"] for m in relay.messages] == ["e1" * 32]  # 只推管理员
    plain = _open(relay.messages[-1], admin_key)
    assert plain["title"] == "MovieClaw 0.31.0 可以更新了" and plain["open"] == "/settings/app"

    check("0.31.0")  # 每小时的检查不会反复推同一个版本
    time.sleep(0.5)
    assert len(relay.messages) == 1
    check("0.31.1")
    _wait(lambda: len(relay.messages) >= 2)

    # 管理员关掉这一项就不推
    _data(client.put("/api/v1/push/me/preferences", json={"events": {"new_version": False}}))
    check("0.32.0")
    time.sleep(0.5)
    assert len(relay.messages) == 2
    # 成员看不到这个开关
    keys = {
        e["key"] for e in _data(_as_app(client, member_bearer, "GET", "/api/v1/push/me"))["events"]
    }
    assert "new_version" not in keys


def _notify(client: TestClient, members: set[int], title: str) -> None:
    """在应用的事件循环里推一条简单的「入库完成」（只看收件人、偏好和设备）。"""
    from movieclaw_api.services.push.notify import AlertContent, notify

    async def build(_session, _member_id: int) -> AlertContent:  # type: ignore[no-untyped-def]
        return AlertContent(title=title)

    _in_app(client, lambda: notify("imported", set(members), build))


def _seed_subscription(
    client: TestClient, *, kind: str, title: str, creator: int | None, followers: list[int]
) -> tuple[int, int]:
    """建一个订阅（发起人 + 关注者），返回 (订阅 id, 条目 id)。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import MediaItem, RuleSet, Subscription, SubscriptionFollower

    async def go() -> tuple[int, int]:
        async with get_database().session() as session:
            item = MediaItem(
                kind=kind,
                tmdb_id=500000 + abs(hash(title)) % 100000,
                title=title,
                original_title=title,
                year=2024,
            )
            rule_set = RuleSet(name=f"规则-{title}", spec={})
            session.add_all([item, rule_set])
            await session.commit()
            await session.refresh(item)
            await session.refresh(rule_set)
            subscription = Subscription(
                media_item_id=item.id,
                kind=kind,
                rule_set_id=rule_set.id,
                created_by_member_id=creator,
            )
            session.add(subscription)
            await session.commit()
            await session.refresh(subscription)
            for member_id in followers:
                session.add(
                    SubscriptionFollower(subscription_id=subscription.id, member_id=member_id)
                )
            await session.commit()
            return subscription.id or 0, item.id or 0

    assert client.portal is not None
    return client.portal.call(go)


def test_manual_download_landing_in_library_folder(client: TestClient, world: World) -> None:
    """直接下进库目录的手动下载：扫描入账后按路径对上，「入库完成」推给点下载的家人，
    他开着「媒体库有新片」也不重复；别的家人照常收到「媒体库有新片」。"""
    from datetime import timedelta

    from sqlmodel import select

    from movieclaw_api.services.push import arrivals
    from movieclaw_api.services.push import downloads as push_downloads
    from movieclaw_api.settings import get_setting_store
    from movieclaw_api.settings.cloud import ArrivalsProgress
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import FileSource, LibraryFile, MediaItem, PushDownloadWatch, utcnow
    from movieclaw_db.repositories.library_repo import LibraryRepository

    _connect(client, world)
    _create_member(client)
    member_bearer = _app_login(client, _MEMBER, installation="manual-m-1", name="家人手机")
    admin_bearer = _app_login(client, _ADMIN, installation="manual-a-1", name="管理员手机")
    _, member_key = _register(client, member_bearer, token="a2" * 32)
    _, admin_key = _register(client, admin_bearer, token="a3" * 32)
    for bearer in (member_bearer, admin_bearer):
        _data(
            _as_app(
                client,
                bearer,
                "PUT",
                "/api/v1/push/me/preferences",
                json={"events": {"library_new": True}},
            )
        )
    relay = world.relays["push.test"]
    relay.messages.clear()
    assert client.portal is not None

    async def seed() -> tuple[int, int]:
        await get_setting_store().set(
            ArrivalsProgress(started_at=utcnow() - timedelta(seconds=1), marks={})
        )
        # 家人在搜索页选「电影」库下载：记下是他点的（下到库目录里的条目目录）
        await push_downloads.remember(
            member_id=1,
            info_hash="ABCDEF",
            save_path="/m/我下载的片 (2024)",
            download_name="Mine.2024.1080p",
        )
        async with get_database().session() as session:
            library = await LibraryRepository(session).create(
                name="电影", kind="movie", root_paths=["/m"]
            )
            library.created_at = utcnow() - timedelta(days=3)
            item = MediaItem(
                kind="movie", tmdb_id=777001, title="我下载的片", original_title="Mine", year=2024
            )
            session.add_all([library, item])
            await session.commit()
            await session.refresh(item)
            # 下载完，库目录扫描把它入了账
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=item.id,
                    season_number=0,
                    episode_number=0,
                    file_path="/m/我下载的片 (2024)/Mine.2024.1080p/Mine.2024.1080p.mkv",
                    size_bytes=1,
                    source=FileSource.SCANNED,
                )
            )
            await session.commit()
            return library.id or 0, item.id or 0

    library_id, item_id = client.portal.call(seed)

    async def check(minutes: int) -> int:
        return await arrivals.check_once(utcnow() + timedelta(minutes=minutes))

    # 刚入账还不到 3 分钟：先不推
    client.portal.call(check, 1)
    time.sleep(0.3)
    assert relay.messages == []
    # 安静了：点下载的家人收到「入库完成」，管理员收到「媒体库有新片」，各一条
    client.portal.call(check, 10)
    _wait(lambda: len(relay.messages) >= 2)
    time.sleep(0.5)
    assert sorted(m["token"] for m in relay.messages) == sorted(["a2" * 32, "a3" * 32])
    by_token = {m["token"]: m for m in relay.messages}
    mine = _open(by_token["a2" * 32], member_key)
    assert mine["title"] == "我下载的片 已入库"
    assert mine["open"].startswith(f"/library/{library_id}/item/{item_id}")
    assert _open(by_token["a3" * 32], admin_key)["title"] == "新片：我下载的片"

    async def watches() -> list[str]:
        async with get_database().session() as session:
            rows = (await session.execute(select(PushDownloadWatch))).scalars()
            return [w.info_hash for w in rows]

    assert client.portal.call(watches) == []  # 对上就用掉了
    relay.messages.clear()
    client.portal.call(check, 20)
    time.sleep(0.5)
    assert relay.messages == []


def test_rate_limits_only_block_what_they_hit(client: TestClient, world: World) -> None:
    """一台手机到了「每台设备每天」的上限只挡它；整台服务器的额度用完才停通道；
    云端调了额度，续签之后马上恢复。"""
    _connect(client, world)
    _create_member(client)
    admin_bearer = _app_login(client, _ADMIN, installation="rl-admin-install", name="管理员手机")
    member_bearer = _app_login(client, _MEMBER, installation="rl-member-install", name="家人手机")
    _register(client, admin_bearer, token="e2" * 32)
    _register(client, member_bearer, token="f2" * 32)
    relay = world.relays["push.test"]
    relay.messages.clear()
    relay.results["e2" * 32] = {
        "result": "rate_limited",
        "reason": "device_day",
        "limit": "device_day",
        "retry_after": 3600,
        "message": "这台设备今天收到的推送已达上限",
    }
    _notify(client, {0, 1}, "第一条")
    _wait(lambda: len(relay.messages) >= 2)
    relay.messages.clear()
    _notify(client, {0, 1}, "第二条")
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.3)
    assert [m["token"] for m in relay.messages] == ["f2" * 32]  # 只挡管理员那台

    # 整台服务器今天的额度用完：通道停发，设置页说明原因
    relay.results["f2" * 32] = "rate_limited"
    relay.messages.clear()
    _notify(client, {1}, "第三条")
    _wait(lambda: len(relay.messages) >= 1)
    relay.messages.clear()
    _notify(client, {1}, "第四条")
    time.sleep(0.5)
    assert relay.messages == []
    official = _data(client.get("/api/v1/push/channels"))["channels"][0]
    assert official["state"] == "warning" and "上限" in official["status_text"]

    # 云端给这台服务器加了额度：续签拿到新限额，不用等到 UTC 零点
    relay.results.clear()
    world.cloud.limits = {"day": 20000, "device_day": 500}
    _data(client.post("/api/v1/cloud/renew"))
    _notify(client, {1}, "第五条")
    _wait(lambda: len(relay.messages) >= 1)


def test_official_relay_rejection_renews_early(
    client: TestClient, world: World, monkeypatch
) -> None:  # type: ignore[no-untyped-def]
    """官方中继拒绝令牌（在官网解绑了）：马上续签一次，很快显示「已断开」，不等一小时。"""
    import types

    from movieclaw_api.services.cloud import service as cloud_service

    monkeypatch.setattr(cloud_service, "random", types.SimpleNamespace(uniform=lambda a, b: a))
    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="rej-1-install", name="iPhone")
    _register(client, bearer, token="ab" * 32)
    reports = len(world.cloud.reports)
    world.relays["push.test"].reject = True
    world.cloud.revoked = True

    result = _data(_as_app(client, bearer, "POST", "/api/v1/push/me/test"))
    assert result["results"][0]["result"] == "queued"
    _wait(lambda: _data(client.get("/api/v1/cloud"))["state"] == "disconnected")
    assert len(world.cloud.reports) == reports + 1
    # 中继回了 401：连得通（上报给云端的 reachable 不能说成「连不上」）
    assert world.cloud.reports[-1]["relay"]["reachable"] is True


def test_official_relay_without_auth_keeps_working(client: TestClient, world: World) -> None:
    """运营方把官方中继切到不要凭证（停运时的退路）：令牌过期了也照样推。"""
    from datetime import timedelta

    from movieclaw_api.settings import CloudSetting, get_setting_store
    from movieclaw_db.models import utcnow

    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="open-1-install", name="iPhone")
    _register(client, bearer, token="ac" * 32)
    relay = world.relays["push.test"]
    relay.mode = "none"
    _data(client.post("/api/v1/push/relays/official/refresh"))

    async def expire() -> None:
        store = get_setting_store()
        cloud = (await store.get(CloudSetting)).model_copy(deep=True)
        cloud.token_expires_at = utcnow() - timedelta(hours=1)
        await store.set(cloud)

    assert client.portal is not None
    client.portal.call(expire)
    relay.messages.clear()
    result = _data(_as_app(client, bearer, "POST", "/api/v1/push/me/test"))
    assert result["results"][0]["result"] == "ok"
    assert relay.bearers[-1] is None  # 不带凭证


def test_registration_survives_cold_start_and_token_races(
    client: TestClient, world: World
) -> None:
    """冷启动先只报了权限：已有的令牌留着；关了通知才清。旧令牌的失效结果不动新登记。"""
    from sqlmodel import select

    from movieclaw_api.services.push import registration
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import LoginDevice

    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="cold-1-install", name="iPhone")
    _register(client, bearer, token="a5" * 32)
    view = _data(
        _as_app(
            client,
            bearer,
            "PUT",
            "/api/v1/push/me/registration",
            json={"permission": "authorized"},
        )
    )
    assert view["registered"] is True and view["status"] == "ok"

    _register(client, bearer, token="a6" * 32)  # 令牌换了

    async def stale_result() -> str | None:
        async with get_database().session() as session:
            device = (
                await session.execute(select(LoginDevice).where(LoginDevice.name == "iPhone"))
            ).scalar_one()
        await registration.mark_unregistered(device.id or 0, "a5" * 32)  # 旧令牌晚到的结果
        await registration.mark_problem(device.id or 0, "bad_token", "a5" * 32)
        async with get_database().session() as session:
            device = await session.get(LoginDevice, device.id)
            assert device is not None
            return f"{device.push_token}|{device.push_problem}"

    assert client.portal is not None
    assert client.portal.call(stale_result) == f"{'a6' * 32}|None"

    view = _data(
        _as_app(
            client, bearer, "PUT", "/api/v1/push/me/registration", json={"permission": "denied"}
        )
    )
    assert view["registered"] is False and view["status"] == "permission_denied"


def test_shared_phone_uses_the_account_still_on_it(client: TestClient, world: World) -> None:
    """一台手机登了两个账号，其中一个只在手机上退出了（服务器上还留着登记）：
    共同的通知用还在手机上的那个账号的密钥；只给已退出那个账号的，不再推到这台手机。"""
    from datetime import timedelta

    from sqlalchemy import update

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import LoginDevice, utcnow

    _connect(client, world)
    _create_member(client)
    token = "b5" * 32
    admin_bearer = _app_login(client, _ADMIN, installation="share-2-install", name="iPad")
    member_bearer = _app_login(client, _MEMBER, installation="share-2-install", name="iPad")
    _register(client, admin_bearer, token=token)
    _, member_key = _register(client, member_bearer, token=token)

    async def age_admin() -> None:
        async with get_database().session() as session:
            await session.execute(
                update(LoginDevice)
                .where(LoginDevice.member_id == 0)
                .values(push_registered_at=utcnow() - timedelta(days=8))
            )
            await session.commit()

    assert client.portal is not None
    client.portal.call(age_admin)
    relay = world.relays["push.test"]
    relay.messages.clear()
    _notify(client, {0, 1}, "两个人都收的")
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.3)
    assert len(relay.messages) == 1
    assert _open(relay.messages[0], member_key)["title"] == "两个人都收的"
    relay.messages.clear()
    _notify(client, {0}, "只给管理员的")
    time.sleep(0.6)
    assert relay.messages == []


def test_system_alerts_fold_into_one(client: TestClient, world: World) -> None:
    """待处理事项：一次故障冒出来一串只推根因；同时冒出的合成一条；马上好了的不推；
    6 小时内复发不再推。"""
    from movieclaw_api.services.system_notice import resolve_notices
    from movieclaw_db.engine import get_database

    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="alert-1-install", name="iPhone")
    _, key = _register(client, bearer, token="c6" * 32)
    relay = world.relays["push.test"]
    relay.messages.clear()

    group = "downloader.landing:1:/x"
    for torrent, sub in (("aa", 5), ("bb", 6)):
        _raise_notice(
            client,
            f"subscription.landing:{sub}:{torrent}",
            source="subscription",
            title=f"订阅 {sub} 的种子无法入库",
            payload={"subscription_id": sub, "grouped_under": group},
        )
    _raise_notice(
        client, group, source="downloader", title="目录 /x 看不到", payload={"group_key": group}
    )
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.5)
    assert len(relay.messages) == 1
    plain = _open(relay.messages[0], key)
    assert plain["title"] == "目录 /x 看不到" and plain["open"] == "/settings/downloaders"

    relay.messages.clear()
    _raise_notice(client, "site:a", source="site", title="站点 A 登录失效")
    _raise_notice(client, "site:b", source="site", title="站点 B 登录失效", severity="warning")
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.5)
    assert len(relay.messages) == 1
    plain = _open(relay.messages[0], key)
    assert plain["title"] == "有 2 个问题需要处理" and "站点 A 登录失效" in plain["body"]

    async def resolve(key: str) -> None:
        async with get_database().session() as session:
            await resolve_notices(session, dedupe_key=key)

    assert client.portal is not None
    relay.messages.clear()
    _raise_notice(client, "downloader:9", source="downloader", title="下载器连不上")
    client.portal.call(resolve, "downloader:9")  # 马上又好了
    client.portal.call(resolve, "site:a")
    _raise_notice(client, "site:a", source="site", title="站点 A 登录失效")  # 6 小时内复发
    time.sleep(0.8)
    assert relay.messages == []


def test_subscription_pushes_merge_and_skip_the_clicker(client: TestClient, world: World) -> None:
    """一集一集入账的季包、一集一集验证的洗版，各合成一条；手动选种的人自己不收「开始下载」。"""
    from movieclaw_api.services.push import events as push_events

    _connect(client, world)
    _create_member(client)
    admin_bearer = _app_login(client, _ADMIN, installation="merge-a-install", name="管理员手机")
    member_bearer = _app_login(client, _MEMBER, installation="merge-m-install", name="家人手机")
    _, admin_key = _register(client, admin_bearer, token="d8" * 32)
    _register(client, member_bearer, token="d9" * 32)
    for bearer in (admin_bearer, member_bearer):
        _data(
            _as_app(
                client,
                bearer,
                "PUT",
                "/api/v1/push/me/preferences",
                json={"events": {"download_started": True, "upgraded": True}},
            )
        )
    subscription_id, item_id = _seed_subscription(
        client, kind="tv", title="漫长的季节", creator=None, followers=[1]
    )
    relay = world.relays["push.test"]
    relay.messages.clear()

    def imported(episode: int) -> None:
        push_events.imported(
            subscription_id=subscription_id,
            item_id=item_id,
            title="漫长的季节",
            year=2023,
            kind="tv",
            units=[(1, episode)],
            image_url=None,
        )

    _in_app(client, lambda: imported(1))
    _in_app(client, lambda: imported(2))
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.6)
    mine = [m for m in relay.messages if m["token"] == "d8" * 32]
    assert len(mine) == 1
    plain = _open(mine[0], admin_key)
    assert plain["title"] == "漫长的季节 更新了" and plain["body"].startswith("第 1 季 2 集")

    relay.messages.clear()

    def upgraded(episode: int) -> None:
        push_events.upgraded(
            subscription_id=subscription_id,
            item_id=item_id,
            title="漫长的季节",
            year=2023,
            unit=(1, episode),
            old_label="1080p",
            new_label="2160p",
            image_url=None,
        )

    _in_app(client, lambda: upgraded(1))
    _in_app(client, lambda: upgraded(2))
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.6)
    mine = [m for m in relay.messages if m["token"] == "d8" * 32]
    assert len(mine) == 1
    assert _open(mine[0], admin_key)["body"] == "第 1 季 2 集 · 1080p → 2160p"

    relay.messages.clear()
    _in_app(
        client,
        lambda: push_events.download_started(
            subscription_id=subscription_id,
            item_id=item_id,
            title="漫长的季节",
            year=2023,
            units=[(1, 3)],
            detail="2160p",
            upgrade=False,
            image_url=None,
            skip_member_id=0,  # 管理员自己在订阅页选的种
        ),
    )
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.4)
    assert [m["token"] for m in relay.messages] == ["d9" * 32]


def test_new_device_rules(client: TestClient, world: World) -> None:
    """新设备登录：别的设备登录提醒；自己退出又登录回来不算；Infuse 第一次登录提醒、
    再登录不提醒；在手机上批准配对，这台手机自己不收提醒。"""
    _connect(client, world)
    phone = _app_login(client, _ADMIN, installation="nd-phone-install", name="我的 iPhone")
    _, key = _register(client, phone, token="e7" * 32)
    relay = world.relays["push.test"]
    relay.messages.clear()

    ipad = _app_login(client, _ADMIN, installation="nd-ipad-install", name="iPad")
    _wait(lambda: len(relay.messages) >= 1)
    assert "「iPad」" in _open(relay.messages[-1], key)["body"]

    relay.messages.clear()
    assert _as_app(client, ipad, "DELETE", "/api/v1/auth/devices/current").status_code == 200
    _app_login(client, _ADMIN, installation="nd-ipad-install", name="iPad")
    time.sleep(0.6)
    assert relay.messages == []

    header = (
        'MediaBrowser Client="Infuse", Device="Living Room", DeviceId="atv-1", Version="8.2"'
    )
    resp = client.post(
        "/Users/AuthenticateByName",
        json={"Username": _ADMIN["username"], "Pw": _ADMIN["password"]},
        headers={"Authorization": header},
    )
    assert resp.status_code == 200, resp.text
    _wait(lambda: len(relay.messages) >= 1)
    body = _open(relay.messages[-1], key)["body"]
    assert "「Living Room」（Infuse）" in body
    relay.messages.clear()
    resp = client.post(
        "/Users/AuthenticateByName",
        json={"Username": _ADMIN["username"], "Pw": _ADMIN["password"]},
        headers={"Authorization": header},
    )
    assert resp.status_code == 200
    time.sleep(0.6)
    assert relay.messages == []

    started = client.post(
        f"{_AUTH}/device/authorize",
        json={"client_type": "cli", "client_name": "mclaw", "installation_id": "cli-1-install"},
    )
    user_code = _data(started)["user_code"]
    approved = _as_app(client, phone, "POST", f"{_AUTH}/devices/requests/{user_code}/approve")
    assert approved.status_code == 200, approved.text
    time.sleep(0.6)
    assert relay.messages == []  # 批准的就是这台手机，不用再提醒它


def test_library_new_kinds_and_unrecognized_files(client: TestClient, world: World) -> None:
    """图片库不推、也不出现在可选的库里；「其他」库叫「新视频」；认不出的文件等认出来
    再按正确的片名推；扫进来的老文件（给库加了个目录）不算新片。"""
    from datetime import timedelta

    from movieclaw_api.services.push import arrivals
    from movieclaw_api.settings import get_setting_store
    from movieclaw_api.settings.cloud import ArrivalsProgress
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import FileSource, LibraryFile, MediaItem, utcnow
    from movieclaw_db.repositories.library_repo import LibraryRepository

    _connect(client, world)
    bearer = _app_login(client, _ADMIN, installation="kinds-1-install", name="iPhone")
    _, key = _register(client, bearer, token="f7" * 32)
    _data(
        _as_app(
            client,
            bearer,
            "PUT",
            "/api/v1/push/me/preferences",
            json={"events": {"library_new": True}},
        )
    )
    relay = world.relays["push.test"]
    assert client.portal is not None

    async def seed() -> dict[str, int]:
        await get_setting_store().set(
            ArrivalsProgress(started_at=utcnow() - timedelta(seconds=1), marks={})
        )
        async with get_database().session() as session:
            repo = LibraryRepository(session)
            libs = {
                "movie": await repo.create(name="电影", kind="movie", root_paths=["/m"]),
                "video": await repo.create(
                    name="家庭录像", kind="video", source="local", root_paths=["/v"]
                ),
                "photo": await repo.create(
                    name="相册", kind="photo", source="local", root_paths=["/p"]
                ),
            }
            for lib in libs.values():
                lib.created_at = utcnow() - timedelta(days=3)
                session.add(lib)
            await session.commit()
            return {k: v.id or 0 for k, v in libs.items()}

    libs = client.portal.call(seed)
    view = _data(_as_app(client, bearer, "GET", "/api/v1/push/me"))
    assert [lib["name"] for lib in view["libraries"]] == ["电影", "家庭录像"]

    async def add(
        library: str, title: str, *, source: str = "local", unidentified: bool = False,
        mtime_days: float = 0,
    ) -> int:
        async with get_database().session() as session:
            item = MediaItem(
                kind={"movie": "movie", "video": "video", "photo": "photo"}[library],
                source=source,
                external_id=f"local-{title}" if source == "local" else None,
                tmdb_id=None if source == "local" else 880000 + abs(hash(title)) % 10000,
                title=title,
                original_title=title,
                year=2024,
            )
            session.add(item)
            await session.commit()
            await session.refresh(item)
            mtime = utcnow() - timedelta(days=mtime_days)
            row = LibraryFile(
                library_id=libs[library],
                media_item_id=item.id,
                season_number=0,
                episode_number=0,
                file_path=f"/{library}/{title}.mkv",
                size_bytes=1,
                file_mtime_ns=int(mtime.timestamp() * 1e9),
                source=FileSource.SCANNED,
                unidentified_code="no_match" if unidentified else None,
            )
            session.add(row)
            await session.commit()
            await session.refresh(row)
            return row.id or 0

    def check() -> int:
        async def go() -> int:
            return await arrivals.check_once(utcnow() + timedelta(minutes=10))

        return client.portal.call(go)

    relay.messages.clear()
    client.portal.call(add, "photo", "IMG_0001")
    client.portal.call(add, "video", "2026-09-20 生日")
    raw_row = client.portal.call(
        functools.partial(add, "movie", "Some.Raw.Name.2024", unidentified=True)
    )
    client.portal.call(functools.partial(add, "movie", "老片子", source="tmdb", mtime_days=400))
    check()
    _wait(lambda: len(relay.messages) >= 1)
    time.sleep(0.5)
    assert len(relay.messages) == 1  # 只有家庭录像那条
    plain = _open(relay.messages[0], key)
    assert plain["title"] == "新视频：2026-09-20 生日"

    # 认出来了（重新识别把文件挂到 TMDB 条目上）：按正确的片名推
    async def recognize() -> None:
        async with get_database().session() as session:
            item = MediaItem(
                kind="movie", tmdb_id=990001, title="流浪地球 3", original_title="W3", year=2027
            )
            session.add(item)
            await session.commit()
            await session.refresh(item)
            row = await session.get(LibraryFile, raw_row)
            assert row is not None
            row.media_item_id = item.id
            row.unidentified_code = None
            session.add(row)
            await session.commit()

    relay.messages.clear()
    client.portal.call(recognize)
    check()
    _wait(lambda: len(relay.messages) >= 1)
    assert _open(relay.messages[-1], key)["title"] == "新片：流浪地球 3"
