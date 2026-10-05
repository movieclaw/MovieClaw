"""登录设备的端到端测试（docs/design/login-devices.md）。

覆盖：
1. 原生 App 用账号密码换设备令牌；同一台设备重登替换旧令牌、换人登录各占一行；
2. 网页登录也是一台登录设备：退出登录即在服务端作废；升级前的签名会话仍被接受；
3. 签发权按客户端类型：App 与浏览器能批准配对、创建令牌，命令行令牌塞进 Cookie 也没用；
4. 失效联动：改密（配对的默认保留 / 勾选一并注销）、停用、重置、删除、全部下线；
5. 「我的设备」：只能看、改、注销自己的，超管能看全体；Jellyfin 播放器合并展示；
6. 活动页：App 的播放挂在登录设备名下，可以从活动页注销。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box

_AUTH = "/api/v1/auth"
_ADMIN = {"username": "admin", "password": "s3cret-pass"}
_MEMBER = {"username": "family", "password": "family-pass-1"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()

    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        assert c.post(f"{_AUTH}/bootstrap", json=_ADMIN).status_code == 200
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def _app_login(
    client: TestClient, account: dict, *, installation: str = "install-ios-0001", name="iPhone Air"
) -> dict:
    """模拟 iOS App 登录，返回响应 data（token / device / session）。"""
    resp = TestClient(client.app).post(
        f"{_AUTH}/device/login",
        json={
            **account,
            "client": {
                "kind": "ios",
                "installation_id": installation,
                "name": name,
                "platform": "iOS 26.0 · iPhone18,4",
                "client_version": "0.28.0",
            },
        },
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def _as(client: TestClient, token: str) -> TestClient:
    """一个只带 Bearer 头、不带 Cookie 的客户端（模拟 App / 命令行）。"""
    other = TestClient(client.app)
    other.headers["Authorization"] = f"Bearer {token}"
    return other


def _create_member(client: TestClient) -> int:
    """以超管 Cookie 建一个默认成员，返回成员 id（client 须处于超管网页登录态）。"""
    created = client.post("/api/v1/members", json=_MEMBER)
    assert created.status_code == 200, created.text
    return created.json()["data"]["id"]


def _pair_cli(approver: TestClient, *, name: str = "mclaw@mac") -> str:
    """以 approver 的身份批准一台命令行，返回令牌。"""
    anon = TestClient(approver.app)
    grant = anon.post(
        f"{_AUTH}/device/authorize", json={"client_type": "cli", "client_name": name}
    ).json()["data"]
    approved = approver.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve")
    assert approved.status_code == 200, approved.text
    return anon.post(f"{_AUTH}/device/token", json={"device_code": grant["device_code"]}).json()[
        "data"
    ]["token"]


# ---------------------------------------------------------------------------
# 1. App 登录
# ---------------------------------------------------------------------------


def test_app_login_issues_a_long_lived_device_token(client: TestClient) -> None:
    data = _app_login(client, _ADMIN)
    assert data["token"].startswith("mclaw_")
    assert data["session"]["username"] == "admin"
    assert data["session"]["device"]["kind"] == "ios"
    device = data["device"]
    assert (device["kind"], device["name"], device["family"]) == ("ios", "iPhone Air", "login")
    assert device["expires_at"] is None  # 长期有效：不再「满 30 天必须重新输密码」
    assert device["current"] is True

    app = _as(client, data["token"])
    me = app.get(f"{_AUTH}/me").json()["data"]
    assert me["device"] == {"id": device["id"], "kind": "ios", "name": "iPhone Air"}
    listed = app.get(f"{_AUTH}/devices").json()["data"]
    assert listed[0]["id"] == device["id"] and listed[0]["current"] is True


def test_mac_app_logs_in_as_a_login_device_without_push(client: TestClient) -> None:
    """Mac App 与 iPhone / Apple TV 同一种登录设备（人直接操作、随改密下线）；
    本期不接推送，「我的设备」里不给它挂推送状态（PUSH_KINDS 刻意不含 macos）。"""
    resp = TestClient(client.app).post(
        f"{_AUTH}/device/login",
        json={
            **_ADMIN,
            "client": {
                "kind": "macos",
                "installation_id": "macos-install-0001",
                "name": "书房的 MacBook",
                "platform": "macOS 26.0 · arm64",
            },
        },
    )
    assert resp.status_code == 200, resp.text
    device = resp.json()["data"]["device"]
    assert (device["kind"], device["kind_label"], device["family"]) == ("macos", "Mac App", "login")
    listed = _as(client, resp.json()["data"]["token"]).get(f"{_AUTH}/devices").json()["data"]
    mac = next(d for d in listed if d["kind"] == "macos")
    # 服务器开着推送时也不挂推送状态、不能登记：
    # 见 test_cloud_push.test_apps_without_push_get_no_push_hint
    assert mac["push"] is None


def test_app_login_wrong_password_is_rejected_and_throttled(client: TestClient) -> None:
    anon = TestClient(client.app)
    body = {
        "username": "admin",
        "password": "wrong",
        "client": {"kind": "ios", "installation_id": "install-ios-0001"},
    }
    codes = [anon.post(f"{_AUTH}/device/login", json=body).status_code for _ in range(6)]
    assert codes[0] == 401
    assert codes[-1] == 429  # 与网页登录同一套限速


def test_relogin_on_the_same_device_replaces_the_old_token(client: TestClient) -> None:
    first = _app_login(client, _ADMIN)["token"]
    second = _app_login(client, _ADMIN)["token"]
    assert _as(client, first).get(f"{_AUTH}/me").status_code == 401
    assert _as(client, second).get(f"{_AUTH}/me").status_code == 200
    kinds = [d["kind"] for d in _as(client, second).get(f"{_AUTH}/devices").json()["data"]]
    assert kinds.count("ios") == 1


def test_two_people_on_one_phone_each_get_a_device(client: TestClient) -> None:
    """一台手机登多个账号是正常用法：换人登录不覆盖别人的那枚令牌。"""
    client.post(f"{_AUTH}/login", json=_ADMIN)
    _create_member(client)
    admin_app = _app_login(client, _ADMIN)["token"]
    member_app = _app_login(client, _MEMBER)["token"]
    assert _as(client, admin_app).get(f"{_AUTH}/me").json()["data"]["username"] == "admin"
    assert _as(client, member_app).get(f"{_AUTH}/me").json()["data"]["username"] == "family"


# ---------------------------------------------------------------------------
# 2. 网页会话
# ---------------------------------------------------------------------------


def test_web_login_is_a_device_and_logout_revokes_it(client: TestClient) -> None:
    client.cookies.clear()
    assert client.post(f"{_AUTH}/login", json=_ADMIN).status_code == 200
    cookie = client.cookies.get("movieclaw_session")
    assert cookie.startswith("mclaw_")
    me = client.get(f"{_AUTH}/me").json()["data"]
    assert me["device"]["kind"] == "web"

    assert client.post(f"{_AUTH}/logout").status_code == 200
    # Cookie 被人拷走过也没用：退出即在服务端作废
    stolen = TestClient(client.app)
    stolen.cookies.set("movieclaw_session", cookie)
    assert stolen.get(f"{_AUTH}/me").status_code == 401


def test_legacy_signed_session_still_works_and_counts_as_a_person(client: TestClient) -> None:
    """升级前签发的签名会话 Cookie 仍被接受直至自然过期，并且能管理设备。"""
    from movieclaw_api.services import auth as auth_service

    token, _ = client.portal.call(auth_service.issue_session_token, "admin")
    legacy = TestClient(client.app)
    legacy.cookies.set("movieclaw_session", token)
    me = legacy.get(f"{_AUTH}/me").json()["data"]
    assert me["username"] == "admin" and me["device"] is None
    assert legacy.get(f"{_AUTH}/devices").status_code == 200


def test_cli_token_smuggled_into_the_cookie_is_rejected(client: TestClient) -> None:
    """Cookie 通道只认网页会话：命令行令牌塞进 Cookie 不会变成「人在浏览器里」。"""
    client.post(f"{_AUTH}/login", json=_ADMIN)
    cli_token = _pair_cli(client)
    smuggled = TestClient(client.app)
    smuggled.cookies.set("movieclaw_session", cli_token)
    assert smuggled.get(f"{_AUTH}/me").status_code == 401


# ---------------------------------------------------------------------------
# 3. 签发权：按客户端类型
# ---------------------------------------------------------------------------


def test_app_can_approve_pairing_and_mint_tokens(client: TestClient) -> None:
    """App 是人直接操作的第一方客户端：能批准命令行、能手工创建令牌（超管）。"""
    app = _as(client, _app_login(client, _ADMIN)["token"])
    cli_token = _pair_cli(app)
    assert _as(client, cli_token).get(f"{_AUTH}/me").status_code == 200
    created = app.post(f"{_AUTH}/tokens", json={"name": "nas-cron"})
    assert created.status_code == 200, created.text


# ---------------------------------------------------------------------------
# 4. 失效联动
# ---------------------------------------------------------------------------


def test_member_password_change_keeps_current_device_and_paired_ones(client: TestClient) -> None:
    client.post(f"{_AUTH}/login", json=_ADMIN)
    _create_member(client)
    phone = _app_login(client, _MEMBER, installation="install-phone-01")["token"]
    tablet = _app_login(client, _MEMBER, installation="install-ipad-001", name="iPad")["token"]
    web = TestClient(client.app)
    web.post(f"{_AUTH}/login", json=_MEMBER)
    cli = _pair_cli(_as(client, phone))

    resp = _as(client, phone).put(
        f"{_AUTH}/password",
        json={"old_password": _MEMBER["password"], "new_password": "brand-new-pass-9"},
    )
    assert resp.status_code == 200, resp.text
    assert _as(client, phone).get(f"{_AUTH}/me").status_code == 200  # 当前这台保留
    assert _as(client, tablet).get(f"{_AUTH}/me").status_code == 401
    assert web.get(f"{_AUTH}/me").status_code == 401
    assert _as(client, cli).get(f"{_AUTH}/me").status_code == 200  # 配对的默认保留


def test_password_change_can_sign_out_paired_devices_too(client: TestClient) -> None:
    client.post(f"{_AUTH}/login", json=_ADMIN)
    cli = _pair_cli(client)
    resp = client.put(
        f"{_AUTH}/password",
        json={
            "old_password": _ADMIN["password"],
            "new_password": "brand-new-pass-9",
            "sign_out_paired": True,
        },
    )
    assert resp.status_code == 200, resp.text
    assert "命令行与转码器也已注销" in resp.json()["message"]
    assert _as(client, cli).get(f"{_AUTH}/me").status_code == 401
    assert client.get(f"{_AUTH}/me").status_code == 200


def test_admin_password_change_does_not_touch_members(client: TestClient) -> None:
    """超管改密只注销超管自己的其他登录：成员的设备与超管的密码无关。"""
    client.post(f"{_AUTH}/login", json=_ADMIN)
    _create_member(client)
    member_app = _app_login(client, _MEMBER)["token"]
    admin_app = _app_login(client, _ADMIN, installation="install-admin-1")["token"]

    resp = client.put(
        f"{_AUTH}/password",
        json={"old_password": _ADMIN["password"], "new_password": "brand-new-pass-9"},
    )
    assert resp.status_code == 200
    assert _as(client, admin_app).get(f"{_AUTH}/me").status_code == 401
    assert _as(client, member_app).get(f"{_AUTH}/me").status_code == 200


def test_disabling_and_signing_out_a_member(client: TestClient) -> None:
    client.post(f"{_AUTH}/login", json=_ADMIN)
    member_id = _create_member(client)
    app = _app_login(client, _MEMBER)["token"]
    cli = _pair_cli(_as(client, app))
    listed = client.get("/api/v1/members").json()["data"]
    assert listed[0]["device_count"] == 2

    # 全部下线：网页、App、命令行都注销，账号本身还能再登录
    resp = client.post(f"/api/v1/members/{member_id}/sign-out")
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["device_count"] == 0
    assert _as(client, app).get(f"{_AUTH}/me").status_code == 401
    assert _as(client, cli).get(f"{_AUTH}/me").status_code == 401

    # 停用：设备行一并删掉，重新启用不会让旧令牌复活
    app = _app_login(client, _MEMBER)["token"]
    client.put(f"/api/v1/members/{member_id}/status", json={"enabled": False})
    client.put(f"/api/v1/members/{member_id}/status", json={"enabled": True})
    assert _as(client, app).get(f"{_AUTH}/me").status_code == 401


def test_resetting_a_member_password_keeps_paired_devices(client: TestClient) -> None:
    """重置多半是成员忘了密码：App、网页下线，配对的命令行保留。"""
    client.post(f"{_AUTH}/login", json=_ADMIN)
    member_id = _create_member(client)
    app = _app_login(client, _MEMBER)["token"]
    cli = _pair_cli(_as(client, app))
    assert client.post(f"/api/v1/members/{member_id}/reset-password").status_code == 200
    assert _as(client, app).get(f"{_AUTH}/me").status_code == 401
    assert _as(client, cli).get(f"{_AUTH}/me").status_code == 200


def test_deleting_a_member_removes_their_devices(client: TestClient) -> None:
    client.post(f"{_AUTH}/login", json=_ADMIN)
    member_id = _create_member(client)
    app = _app_login(client, _MEMBER)["token"]
    assert client.delete(f"/api/v1/members/{member_id}").status_code == 200
    assert _as(client, app).get(f"{_AUTH}/me").status_code == 401
    owners = {d["owner_id"] for d in client.get(f"{_AUTH}/devices?all=true").json()["data"]}
    assert member_id not in owners


# ---------------------------------------------------------------------------
# 5. 我的设备
# ---------------------------------------------------------------------------


def test_devices_are_scoped_to_their_owner(client: TestClient) -> None:
    client.post(f"{_AUTH}/login", json=_ADMIN)
    _create_member(client)
    admin_phone = _app_login(client, _ADMIN, installation="install-admin-1")
    member = _as(client, _app_login(client, _MEMBER)["token"])

    mine = member.get(f"{_AUTH}/devices").json()["data"]
    assert {d["owner_username"] for d in mine} == {"family"}
    assert member.get(f"{_AUTH}/devices?all=true").status_code == 403
    # 别人的设备：看不见、改不了、注销不了（一律 404，不泄露存在与否）
    admin_device_id = admin_phone["device"]["id"]
    assert member.delete(f"{_AUTH}/devices/{admin_device_id}").status_code == 404
    assert (
        member.patch(f"{_AUTH}/devices/{admin_device_id}", json={"name": "x"}).status_code == 404
    )

    # 超管能看全体（带上主人），也能注销成员的设备
    everyone = client.get(f"{_AUTH}/devices?all=true").json()["data"]
    assert {"admin", "family"} <= {d["owner_username"] for d in everyone}
    member_device = next(d for d in everyone if d["owner_username"] == "family")
    assert client.delete(f"{_AUTH}/devices/{member_device['id']}").status_code == 200
    assert member.get(f"{_AUTH}/me").status_code == 401


def test_renaming_a_device(client: TestClient) -> None:
    data = _app_login(client, _ADMIN)
    app = _as(client, data["token"])
    resp = app.patch(f"{_AUTH}/devices/{data['device']['id']}", json={"name": "客厅的 iPhone"})
    assert resp.status_code == 200, resp.text
    assert app.get(f"{_AUTH}/me").json()["data"]["device"]["name"] == "客厅的 iPhone"


def test_jellyfin_players_are_listed_and_revocable(client: TestClient) -> None:
    """Infuse 这类播放器的凭证仍在自己的表里，但在「我的设备」里一起管理。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import JellyfinDevice

    async def seed() -> None:
        async with get_database().session() as session:
            session.add(
                JellyfinDevice(
                    member_id=0,
                    token="f" * 32,
                    device_id="infuse-apple-tv",
                    client="Infuse",
                    device_name="客厅 Apple TV",
                    version="8.1",
                )
            )
            await session.commit()

    client.portal.call(seed)
    client.post(f"{_AUTH}/login", json=_ADMIN)
    players = [d for d in client.get(f"{_AUTH}/devices").json()["data"] if d["kind"] == "jellyfin"]
    assert [(p["kind_label"], p["name"], p["renamable"]) for p in players] == [
        ("Infuse", "客厅 Apple TV", False)
    ]
    assert (
        client.patch(f"{_AUTH}/devices/{players[0]['id']}", json={"name": "x"}).status_code == 400
    )
    assert client.delete(f"{_AUTH}/devices/{players[0]['id']}").status_code == 200
    remaining = client.get(f"{_AUTH}/devices").json()["data"]
    assert [d for d in remaining if d["kind"] == "jellyfin"] == []


def test_cleaning_up_devices_unused_for_days(client: TestClient) -> None:
    """一次注销 N 天没用过的设备：本机永远不清，dry_run 只列不注销，范围跟着视图走。"""
    from datetime import timedelta

    from sqlalchemy import update

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import JellyfinDevice, LoginDevice
    from movieclaw_db.models.base import utcnow

    client.post(f"{_AUTH}/login", json=_ADMIN)
    _create_member(client)
    old_phone = _app_login(client, _ADMIN, installation="install-old-1", name="旧 iPhone")
    fresh_phone = _app_login(client, _ADMIN, installation="install-new-1", name="新 iPhone")
    member_phone = _app_login(client, _MEMBER, installation="install-fam-1", name="家人 iPhone")
    long_ago = utcnow() - timedelta(days=40)

    async def age() -> None:
        async with get_database().session() as session:
            await session.execute(
                update(LoginDevice)
                .where(LoginDevice.name.in_(["旧 iPhone", "家人 iPhone"]))  # type: ignore[attr-defined]
                .values(last_seen_at=long_ago)
            )
            # 本机（这个浏览器）也很久没记过活跃：照样不能被清
            await session.execute(
                update(LoginDevice)
                .where(LoginDevice.kind == "web")
                .values(last_seen_at=long_ago, created_at=long_ago)
            )
            session.add(
                JellyfinDevice(
                    member_id=0,
                    token="e" * 32,
                    device_id="infuse-old",
                    client="Infuse",
                    device_name="旧播放器",
                    last_seen_at=long_ago,
                )
            )
            await session.commit()

    client.portal.call(age)

    def names(resp) -> set[str]:  # type: ignore[no-untyped-def]
        assert resp.status_code == 200, resp.text
        return {d["name"] for d in resp.json()["data"]["devices"]}

    url = f"{_AUTH}/devices/cleanup"
    assert names(client.post(url, json={"inactive_days": 30, "dry_run": True})) == {
        "旧 iPhone",
        "旧播放器",
    }
    assert names(client.post(url, json={"inactive_days": 60, "dry_run": True})) == set()
    assert names(
        client.post(url, json={"inactive_days": 30, "all": True, "dry_run": True})
    ) == {"旧 iPhone", "旧播放器", "家人 iPhone"}
    # dry_run 什么都没动（不能拿旧手机的令牌去验：一用就刷新了它的最近活跃）
    listed = {d["name"] for d in client.get(f"{_AUTH}/devices").json()["data"]}
    assert {"旧 iPhone", "旧播放器"} <= listed

    member = _as(client, member_phone["token"])
    assert member.post(url, json={"inactive_days": 30, "all": True}).status_code == 403

    resp = client.post(url, json={"inactive_days": 30})
    assert names(resp) == {"旧 iPhone", "旧播放器"}
    assert resp.json()["message"] == "已注销 2 台设备"
    assert _as(client, old_phone["token"]).get(f"{_AUTH}/me").status_code == 401
    assert _as(client, fresh_phone["token"]).get(f"{_AUTH}/me").status_code == 200
    assert member.get(f"{_AUTH}/me").status_code == 200  # 只清了自己的
    assert client.get(f"{_AUTH}/me").status_code == 200  # 本机还在
    left = {d["name"] for d in client.get(f"{_AUTH}/devices").json()["data"]}
    assert "旧 iPhone" not in left and "旧播放器" not in left and "新 iPhone" in left


# ---------------------------------------------------------------------------
# 6. 活动页
# ---------------------------------------------------------------------------


def test_app_playback_is_revocable_from_the_activity_page(client: TestClient) -> None:
    """App 的播放挂在登录设备名下：活动页「注销此设备」即作废它的令牌。"""
    from movieclaw_api.services.playback.watch import web_device_id

    data = _app_login(client, _ADMIN)
    row_id = int(data["device"]["id"].removeprefix("ld-"))
    assert web_device_id("ios-abc", member_id=0, login_device_id=row_id) == data["device"]["id"]

    client.post(f"{_AUTH}/login", json=_ADMIN)
    resp = client.delete(f"/api/v1/playback/devices/{data['device']['id']}")
    assert resp.status_code == 200, resp.text
    assert "iPhone Air" in resp.json()["message"]
    assert _as(client, data["token"]).get(f"{_AUTH}/me").status_code == 401


def test_logging_in_again_in_the_same_browser_retires_the_old_session(client: TestClient) -> None:
    """同一个浏览器里同一个账号又登录了一次：被换下来的旧会话在服务端一并作废，
    「我的设备」里不会多出一行再也用不到、却仍然有效的会话。"""
    client.cookies.clear()
    client.post(f"{_AUTH}/login", json=_ADMIN)
    first = client.cookies.get("movieclaw_session")
    client.post(f"{_AUTH}/login", json=_ADMIN)
    second = client.cookies.get("movieclaw_session")
    assert first != second
    stale = TestClient(client.app)
    stale.cookies.set("movieclaw_session", first)
    assert stale.get(f"{_AUTH}/me").status_code == 401
    webs = [d for d in client.get(f"{_AUTH}/devices").json()["data"] if d["kind"] == "web"]
    assert len(webs) == 2  # 建号那次（bootstrap）的会话 + 现在这一枚
