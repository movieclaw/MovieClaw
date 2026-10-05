"""公开演示站模式（docs/design/demo-site.md）的行为测试。

演示站把超管与成员的账号密码公布在登录页，守卫是它唯一的安全边界，所以
这里的重点是「默认拒绝」的兜底：以超管身份遍历 OpenAPI 里全部写接口，白名单
之外必须一律 403 DEMO_READ_ONLY——以后新增写接口忘了考虑演示站，这里直接红。

其余覆盖：登录页的演示账号、公开账号不被限速锁死、设备列表与活动页脱敏、
图片代理域名白名单、应用内更新整体失效。
"""

from __future__ import annotations

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services import demo as demo_service
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.image_proxy import ImageProxy
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box

_AUTH = "/api/v1/auth"
_ADMIN = {"username": "admin", "password": "movieclaw"}
_MEMBER = {"username": "family", "password": "movieclaw"}


@pytest.fixture
def accounts_file(tmp_path):
    path = tmp_path / "accounts.json"
    path.write_text(
        json.dumps(
            {
                "notice": "演示站只读",
                "accounts": [
                    {**_ADMIN, "label": "超级管理员", "description": "全部功能只读"},
                    {**_MEMBER, "label": "家庭成员"},
                ],
                "members": [{"username": "family", "nickname": "家人"}],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    return path


@pytest.fixture
def client(tmp_path, monkeypatch, accounts_file):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    monkeypatch.setenv("MOVIECLAW_DEMO_ACCOUNTS_FILE", str(accounts_file))
    monkeypatch.delenv("MOVIECLAW_DEMO_MODE", raising=False)
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()

    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as c:
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def _enable_demo(monkeypatch) -> None:
    """建站（建号、建成员）走正常模式，之后再切进演示模式——与部署流程一致。"""
    monkeypatch.setenv("MOVIECLAW_DEMO_MODE", "true")
    get_settings.cache_clear()
    demo_service.reset_demo_state()


def _login(client: TestClient, account: dict, **headers: str) -> str:
    client.cookies.clear()
    resp = client.post(
        f"{_AUTH}/login", json={**account, "remember": False}, headers=headers or None
    )
    assert resp.status_code == 200, resp.text
    return client.cookies.get("movieclaw_session")


def _use(client: TestClient, cookie: str) -> None:
    client.cookies.clear()
    client.cookies.set("movieclaw_session", cookie)


def _provision(client: TestClient) -> tuple[str, int]:
    """正常模式下建超管与一个成员，返回 (超管 Cookie, 成员 id)。"""
    assert client.post(f"{_AUTH}/bootstrap", json=_ADMIN).status_code == 200
    admin_cookie = client.cookies.get("movieclaw_session")
    created = client.post("/api/v1/members", json=_MEMBER)
    assert created.status_code == 200, created.text
    return admin_cookie, created.json()["data"]["id"]


def _assert_demo_denied(resp: httpx.Response, *, contains: str | None = None) -> None:
    assert resp.status_code == 403, resp.text
    body = resp.json()
    assert body["code"] == demo_service.DEMO_READ_ONLY_CODE, body
    if contains is not None:
        assert contains in body["message"], body


# ---------------------------------------------------------------------------
# 默认关闭：不开演示模式时产品行为不变
# ---------------------------------------------------------------------------


def test_demo_mode_is_off_by_default(client: TestClient) -> None:
    admin_cookie, member_id = _provision(client)
    _use(client, admin_cookie)
    assert client.get(f"{_AUTH}/bootstrap").json()["data"]["demo"] is None
    assert client.get(f"{_AUTH}/me").json()["data"]["demo"] is False
    # 正常模式下成员管理照常可写
    resp = client.put(f"/api/v1/members/{member_id}", json={"nickname": "家人"})
    assert resp.status_code == 200, resp.text


# ---------------------------------------------------------------------------
# 账号与成员：改密码、改成员、删成员一律拒绝
# ---------------------------------------------------------------------------


def test_demo_blocks_account_and_member_writes(client: TestClient, monkeypatch) -> None:
    admin_cookie, member_id = _provision(client)
    _enable_demo(monkeypatch)
    _use(client, admin_cookie)

    _assert_demo_denied(
        client.put(
            f"{_AUTH}/password",
            json={"old_password": _ADMIN["password"], "new_password": "hijacked-123"},
        ),
        contains="密码",
    )
    _assert_demo_denied(client.put(f"{_AUTH}/profile", json={"nickname": "x"}))
    _assert_demo_denied(
        client.post("/api/v1/members", json={"username": "evil", "password": "evil-pass-1"}),
        contains="成员",
    )
    _assert_demo_denied(client.put(f"/api/v1/members/{member_id}", json={"nickname": "x"}))
    _assert_demo_denied(client.post(f"/api/v1/members/{member_id}/reset-password"))
    _assert_demo_denied(client.put(f"/api/v1/members/{member_id}/status", json={"enabled": False}))
    _assert_demo_denied(client.delete(f"/api/v1/members/{member_id}"))

    # 成员自己也不能改密码
    _login(client, _MEMBER)
    _assert_demo_denied(
        client.put(
            f"{_AUTH}/password",
            json={"old_password": _MEMBER["password"], "new_password": "hijacked-123"},
        )
    )

    # 什么都没变：原密码照常能登录，成员还在
    admin_cookie = _login(client, _ADMIN)
    assert [m["username"] for m in client.get("/api/v1/members").json()["data"]] == ["family"]


def test_demo_allows_browsing_login_and_account_switching(client: TestClient, monkeypatch) -> None:
    admin_cookie, _ = _provision(client)
    _enable_demo(monkeypatch)
    _use(client, admin_cookie)

    me = client.get(f"{_AUTH}/me").json()["data"]
    assert me["demo"] is True and me["role"] == "admin"
    assert client.get("/api/v1/members").status_code == 200
    assert client.get("/api/v1/libraries").status_code == 200

    # 登录（并入账号袋）→ 切换账号 → 退出，都属于访客自己的登录态
    member = client.post(f"{_AUTH}/login", json=_MEMBER)
    assert member.status_code == 200, member.text
    switched = client.post(f"{_AUTH}/accounts/switch", json={"username": "admin"})
    assert switched.status_code == 200, switched.text
    assert client.post(f"{_AUTH}/logout", json={}).status_code == 200


@pytest.mark.parametrize("account", [_ADMIN, _MEMBER])
@pytest.mark.parametrize("client_type", ["tvos", "macos"])
def test_demo_app_pairing_full_flow(client: TestClient, monkeypatch, account, client_type) -> None:
    """模拟 App 出码、手机批准、App 兑换并访问媒体库，权限跟随批准者。"""
    _provision(client)
    _enable_demo(monkeypatch)
    _login(client, account)
    response = client.post(
        f"{_AUTH}/device/authorize",
        json={"client_type": client_type, "client_name": "演示 App"},
    )
    assert response.status_code == 200, response.text
    grant = response.json()["data"]
    request = client.get(f"{_AUTH}/devices/requests/{grant['user_code']}")
    assert request.status_code == 200, request.text
    assert request.json()["data"]["source_ip"] == ""
    assert client.post(
        f"{_AUTH}/device/token", json={"device_code": grant["device_code"]}
    ).status_code == 202
    approved = client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve")
    assert approved.status_code == 200, approved.text
    response = client.post(f"{_AUTH}/device/token", json={"device_code": grant["device_code"]})
    assert response.status_code == 200, response.text
    token = response.json()["data"]["token"]
    client.cookies.clear()
    headers = {"Authorization": f"Bearer {token}"}
    me = client.get(f"{_AUTH}/me", headers=headers).json()["data"]
    assert (me["username"], me["demo"], me["device"]["kind"]) == (
        account["username"], True, client_type
    )
    assert client.get("/api/v1/libraries", headers=headers).status_code == 200
    _assert_demo_denied(client.post("/api/v1/members", json={}, headers=headers))
    _assert_demo_denied(client.post(
        f"{_AUTH}/devices/cleanup",
        json={"inactive_days": 1, "all": True, "dry_run": False},
        headers=headers,
    ))
    assert client.post(
        f"{_AUTH}/device/token", json={"device_code": grant["device_code"]}
    ).status_code == 400


@pytest.mark.parametrize("client_type", ["cli", "worker"])
def test_demo_rejects_non_app_pairing(client: TestClient, monkeypatch, client_type) -> None:
    _provision(client)
    # 普通模式遗留的配对挑战：切入演示模式后同样不能批准或兑换。
    grant = client.post(
        f"{_AUTH}/device/authorize",
        json={"client_type": client_type, "client_name": "程序设备"},
    ).json()["data"]
    _enable_demo(monkeypatch)
    _assert_demo_denied(client.post(
        f"{_AUTH}/device/authorize",
        json={"client_type": client_type, "client_name": "程序设备"},
    ))
    _assert_demo_denied(client.get(f"{_AUTH}/devices/requests/{grant['user_code']}"))
    _assert_demo_denied(client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve"))
    _assert_demo_denied(client.post(
        f"{_AUTH}/device/token", json={"device_code": grant["device_code"]}
    ))


def test_demo_blocks_sensitive_reads(client: TestClient, monkeypatch) -> None:
    admin_cookie, _ = _provision(client)
    _enable_demo(monkeypatch)
    _use(client, admin_cookie)
    _assert_demo_denied(client.get("/api/v1/fs/browse", params={"path": "/"}))
    _assert_demo_denied(client.get("/api/v1/system/logs"))
    _assert_demo_denied(client.get("/api/v1/extension/token"))
    _assert_demo_denied(client.get("/api/v1/sites/catalog"), contains="PT")
    # 完整接口清单：公开账号登录后就能拿，等于绕开了关闭的 /docs
    _assert_demo_denied(client.get("/api/v1/spec"))

    # 发现照常开放、订阅面板能预检，只有确认订阅被拒，并说明演示站不会真的下载
    for method, operation in [
        ("GET", "ui.discovery.get"),
        ("GET", "discover.filter-titles"),
        ("POST", "search.titles"),
        ("POST", "ui.subscriptions.preview-title"),
    ]:
        assert demo_service.rejection_for(method, operation) is None, operation
    _assert_demo_denied(
        client.post("/api/v1/subscriptions", json={"title_ref": "tmdb:movie:1"}),
        contains="不会真的订阅",
    )


# ---------------------------------------------------------------------------
# 守护测试：白名单之外的写接口一律拒绝
# ---------------------------------------------------------------------------


def test_every_unlisted_write_is_rejected_in_demo_mode(client: TestClient, monkeypatch) -> None:
    """行为级默认拒绝：以超管身份请求 OpenAPI 里每一条写接口，白名单之外必须
    403 DEMO_READ_ONLY（守卫先于参数校验与业务逻辑执行，哑参数足够）。"""
    from tests.api.test_auth import fill_path_params

    admin_cookie, _ = _provision(client)
    # 生产环境刻意关闭 HTTP 接口清单；守护测试直接枚举应用，仍覆盖全部业务路由。
    openapi = client.app.openapi()
    _enable_demo(monkeypatch)
    _use(client, admin_cookie)

    checked = 0
    for path, methods in openapi["paths"].items():
        url = fill_path_params(path)
        for method, operation in methods.items():
            if method.upper() in {"GET", "HEAD", "OPTIONS"}:
                continue
            if operation["operationId"] in demo_service.ALLOWED_WRITE_OPERATIONS:
                continue
            resp = client.request(method.upper(), url, json={})
            assert resp.status_code == 403 and resp.json()["code"] == "DEMO_READ_ONLY", (
                f"演示站守卫漏挡写接口：{method.upper()} {path}（{operation['operationId']}）"
                f" → {resp.status_code} {resp.text[:200]}"
            )
            checked += 1
            # 被拒的请求可能换掉了当前会话以外的任何东西——保险起见每次复位 Cookie
            _use(client, admin_cookie)

    assert checked > 100, f"守护测试只扫到 {checked} 条写接口，枚举逻辑可能失效"


def test_demo_tables_reference_real_operations(client: TestClient) -> None:
    """白名单 / 黑名单里的 operation_id 都必须真实存在：接口改名后这里提醒同步。"""
    openapi = client.app.openapi()
    operations = {
        op["operationId"] for methods in openapi["paths"].values() for op in methods.values()
    }
    missing_writes = demo_service.ALLOWED_WRITE_OPERATIONS - operations
    missing_reads = set(demo_service.BLOCKED_READ_OPERATIONS) - operations
    assert not missing_writes, f"演示站写白名单里有不存在的接口：{sorted(missing_writes)}"
    assert not missing_reads, f"演示站读黑名单里有不存在的接口：{sorted(missing_reads)}"


@pytest.mark.parametrize("account", [_ADMIN, _MEMBER])
def test_demo_allows_reel_browsing_and_events(client: TestClient, monkeypatch, account) -> None:
    """主干新增刷片：公开账号仍能浏览、上报曝光；媒体管理写操作继续默认拒绝。"""
    _provision(client)
    _enable_demo(monkeypatch)
    _login(client, account)
    assert client.get("/api/v1/reels").status_code == 200
    assert client.get("/api/v1/reels/facets").status_code == 200
    resp = client.post(
        "/api/v1/reels/events", json={"events": [{"reel_id": "demo-reel", "kind": "impression"}]}
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["accepted"] == 1


def test_demo_accepts_qoe_reports_but_blocks_diagnostic_reads(
    client: TestClient, monkeypatch
) -> None:
    """新播放记录允许收尾上报，但不能经编号明细或小样本统计看到其他访客的日志与文字。"""
    _provision(client)
    _enable_demo(monkeypatch)
    resp = client.post(
        "/api/v1/playback/metrics",
        json={
            "attempt_id": "demo-qoe",
            "tier": 0,
            "engine": "native",
            "client": "web",
            "outcome": "failed",
            "log_tail": "访客的诊断日志",
        },
    )
    assert resp.status_code == 200, resp.text
    _assert_demo_denied(client.get("/api/v1/playback/attempts/demo-qoe"))
    _assert_demo_denied(client.get("/api/v1/playback/stats/qoe"))
    # 活动页现用的不含日志的档位汇总仍可读。
    assert client.get("/api/v1/playback/stats").status_code == 200


# ---------------------------------------------------------------------------
# 登录页账号提示与限速
# ---------------------------------------------------------------------------


def test_demo_bootstrap_lists_public_accounts(client: TestClient, monkeypatch) -> None:
    _provision(client)
    _enable_demo(monkeypatch)
    client.cookies.clear()
    demo = client.get(f"{_AUTH}/bootstrap").json()["data"]["demo"]
    assert demo["notice"] == "演示站只读"
    assert [(a["username"], a["password"], a["label"]) for a in demo["accounts"]] == [
        ("admin", "movieclaw", "超级管理员"),
        ("family", "movieclaw", "家庭成员"),
    ]


def test_demo_public_accounts_cannot_be_locked_out(client: TestClient, monkeypatch) -> None:
    """故意输错公开账号的密码不会把别的访客锁在门外；非公开用户名照常限速。"""
    _provision(client)
    _enable_demo(monkeypatch)
    client.cookies.clear()
    for _ in range(8):
        wrong = client.post(f"{_AUTH}/login", json={"username": "admin", "password": "wrong"})
        assert wrong.status_code == 401
    assert client.post(f"{_AUTH}/login", json=_ADMIN).status_code == 200

    statuses = [
        client.post(f"{_AUTH}/login", json={"username": "nobody", "password": "wrong"}).status_code
        for _ in range(6)
    ]
    assert statuses[-1] == 429


# ---------------------------------------------------------------------------
# 访客隐私
# ---------------------------------------------------------------------------


def test_demo_hides_other_visitors_devices(client: TestClient, monkeypatch) -> None:
    _provision(client)
    _enable_demo(monkeypatch)
    # 两位访客先后用同一个公开账号登录（设备名来自各自的 User-Agent）
    _login(client, _ADMIN, **{"User-Agent": "Mozilla/5.0 (Windows NT 10.0) Firefox/130.0"})
    mine = _login(
        client, _ADMIN, **{"User-Agent": "Mozilla/5.0 (Macintosh; Mac OS X 10_15_7) Safari/605.1"}
    )
    _use(client, mine)
    devices = client.get(f"{_AUTH}/devices").json()["data"]
    others = [d for d in devices if not d["current"]]
    assert others, devices
    for device in others:
        assert device["name"].startswith("其他访客的")
        assert device["last_seen_ip"] is None
        assert device["platform"] is None


def test_anonymous_playback_client_keeps_only_server_derived_names() -> None:
    assert demo_service.anonymous_playback_client("MovieClaw iOS", "iPhone · iOS 26.0") == (
        "MovieClaw iOS",
        "iPhone · iOS 26.0",
    )
    # Jellyfin 协议的客户端名与设备名是访客自报的任意文字
    assert demo_service.anonymous_playback_client("任意文字", "任意设备名") == (
        "第三方播放器",
        "访客设备",
    )


# ---------------------------------------------------------------------------
# 图片代理与应用内更新
# ---------------------------------------------------------------------------


async def _fake_resolver(host: str) -> list[str]:
    return ["93.184.216.34"]


async def test_demo_image_proxy_only_serves_allowed_hosts(monkeypatch) -> None:
    from movieclaw_api.services.image_proxy import _demo_allowed_hosts

    _enable_demo(monkeypatch)
    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, headers={"Content-Type": "image/jpeg"}, content=b"jpeg")

    proxy = ImageProxy(
        transport=httpx.MockTransport(handler),
        resolver=_fake_resolver,
        allowed_host_suffixes=_demo_allowed_hosts(),
    )
    content, _ = await proxy.fetch("https://image.tmdb.org/t/p/w500/a.jpg")
    assert content == b"jpeg"
    content, _ = await proxy.fetch("https://assets.fanart.tv/fanart/a.jpg")
    assert content == b"jpeg"
    with pytest.raises(BadRequestException):
        await proxy.fetch("https://img.example-host.com/a.png")
    # 后缀匹配按域名边界，不能被 eviltmdb.org 这类名字骗过
    with pytest.raises(BadRequestException):
        await proxy.fetch("https://eviltmdb.org/a.png")
    await proxy.aclose()
    get_settings.cache_clear()


def test_demo_disables_in_app_update(monkeypatch) -> None:
    from movieclaw_api.services import app_update

    monkeypatch.setenv("MOVIECLAW_RUNTIME_VERSION", "17")
    monkeypatch.delenv("MOVIECLAW_DEMO_MODE", raising=False)
    get_settings.cache_clear()
    try:
        assert app_update._runtime_version() == 17
        monkeypatch.setenv("MOVIECLAW_DEMO_MODE", "true")
        get_settings.cache_clear()
        assert app_update._runtime_version() is None
    finally:
        get_settings.cache_clear()


# ---------------------------------------------------------------------------
# 上线安全：空库不能被抢注、登录与冒用演示设备
# ---------------------------------------------------------------------------


def test_demo_mode_rejects_bootstrap_on_empty_data(client: TestClient, monkeypatch) -> None:
    """data/ 被清空后以演示模式启动：首次引导必须被拒，陌生人不能抢注超管。"""
    _enable_demo(monkeypatch)
    _assert_demo_denied(client.post(f"{_AUTH}/bootstrap", json=_ADMIN))


def test_demo_closes_api_docs_regardless_of_app_env(client: TestClient, monkeypatch) -> None:
    monkeypatch.setenv("APP_ENV", "local")
    _enable_demo(monkeypatch)
    from movieclaw_api.app import create_app

    app = create_app()
    assert app.docs_url is None and app.openapi_url is None and app.redoc_url is None


def test_demo_limits_login_rate_per_address(client: TestClient, monkeypatch) -> None:
    """公开账号不按用户名锁定，但按来源地址限频：脚本刷登录拖不垮服务。"""
    _provision(client)
    _enable_demo(monkeypatch)
    monkeypatch.setattr(demo_service, "LOGIN_LIMIT_UNKNOWN_ADDRESS", 3)
    monkeypatch.setattr(demo_service, "LOGIN_LIMIT_PER_ADDRESS", 3)
    client.cookies.clear()
    statuses = [client.post(f"{_AUTH}/login", json=_ADMIN).status_code for _ in range(4)]
    assert statuses == [200, 200, 200, 429]
    body = client.post(f"{_AUTH}/login", json=_MEMBER).json()
    assert body["code"] == "TOO_MANY_ATTEMPTS" and "登录过于频繁" in body["message"]


def test_demo_login_rate_limit_is_off_outside_demo_mode(monkeypatch) -> None:
    monkeypatch.delenv("MOVIECLAW_DEMO_MODE", raising=False)
    get_settings.cache_clear()
    monkeypatch.setattr(demo_service, "LOGIN_LIMIT_PER_ADDRESS", 0)
    demo_service.ensure_login_allowed("203.0.113.9")  # 不抛


def test_spoofed_seeded_device_only_shows_preset_text() -> None:
    """访客走 Jellyfin 登录时自报设备标识，冒用演示设备也只能显示预设文案。"""
    from movieclaw_api.services import demo_activity

    assert demo_activity.display_client("demo-family-atv", "不当文字", "不当文字") == (
        "Infuse",
        "客厅 Apple TV",
    )
    # 只是前缀相同不算演示设备，按访客脱敏
    assert not demo_activity.is_seeded_device("demo-anything")
    assert demo_activity.display_client("demo-anything", "不当文字", "不当文字") == (
        "第三方播放器",
        "访客设备",
    )
