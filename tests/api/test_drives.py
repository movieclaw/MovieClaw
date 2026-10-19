"""网盘存储层骨架（docs/design/cloud-storage.md §3.1、§8、§11）。

用一个测试内的假网盘插件，主进程与独立进程各跑一遍：

- 可用的网盘来自插件登记（类型、能力、登录方式原样到接口）；
- 扫码登录：宿主在后台跟着插件的流程走，扫完码建账号；同一网盘用户重新登录更新原账号；
- Cookie 登录：手动粘贴与浏览器扩展推送（按插件声明的域名分发）；
- 调用包装：插件换了凭据先落库（成功、出错都一样）；只有登录失效让账号进「要重新登录」
  并亮待处理事项，之后的调用不再打到插件；限流挡后台与用户操作、不挡播放；重新登录复位状态、消退提醒；
- 按请求限速：插件经 SDK 网络出口每发一个请求领一个名额、计一次预算；账号中途被限流就停下；
  超时按多久没有进展算；
- 账号设置的范围校验、移除账号。
"""

from __future__ import annotations

import asyncio
import json
import sys
import textwrap
import time
from functools import partial

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events

ADMIN = {"username": "admin", "password": "s3cret-pass"}

PLUGIN = """
import asyncio
import itertools

import httpx

from movieclaw_sdk import net, plugin
from movieclaw_sdk.drives import (
    DRIVE_BACKENDS,
    AccountInfo,
    AuthExpired,
    Capabilities,
    Choice,
    DriveBackend,
    Login,
    LoginFlow,
    LoginOption,
    LoginResult,
    RateLimited,
    RemoteFile,
    RemoteTree,
)

_ids = itertools.count(1)


class FakeDrive(DriveBackend):
    type = "fake"
    title = "假网盘"
    accent_color = "#2a77ff"
    capabilities = Capabilities(
        writable=True,
        rapid_upload_hashes=("sha1",),
        list_hashes=True,
        default_qps=50.0,
        default_daily_budget=1000,
        default_read_slots=3,
    )
    login = Login(
        scan=True,
        cookie_domains=("fake.example",),
        hint="用手机 App 扫码",
        options=(
            LoginOption(
                key="device",
                label="登录端",
                default="mini",
                choices=(Choice("mini", "小程序端"), Choice("web", "网页端", "会与浏览器互踢")),
            ),
        ),
    )

    def __init__(self):
        self.flows = {}

    async def begin_login(self, options):
        flow_id = f"f{next(_ids)}"
        self.flows[flow_id] = {"polls": 0, "device": options["device"]}
        return LoginFlow(flow_id=flow_id, status="pending", qr=f"fake://qr/{flow_id}")

    async def login_state(self, flow_id):
        flow = self.flows[flow_id]
        flow["polls"] += 1
        if flow["polls"] < 2:
            return LoginFlow(flow_id=flow_id, status="scanned", message="已扫描，请在手机上确认")
        return LoginFlow(
            flow_id=flow_id,
            status="confirmed",
            result=LoginResult(
                user_id="u1",
                display_name="测试盘",
                credentials={"token": "t0", "device": flow["device"]},
            ),
        )

    async def login_with_cookie(self, cookie_header):
        parts = dict(p.strip().split("=", 1) for p in cookie_header.split(";") if "=" in p)
        if "UID" not in parts:
            raise ValueError("Cookie 不全：缺少 UID")
        return LoginResult(
            user_id=parts["UID"],
            display_name="网页盘",
            credentials={"token": "t0", "UID": parts["UID"]},
        )

    async def account_info(self, account):
        token = account.credentials["token"]
        if token == "dead":
            raise AuthExpired("登录已失效")
        if token.startswith("limited"):
            account.credentials = {**account.credentials, "token": "limited-rotated"}
            raise RateLimited("访问太频繁", 30)
        account.credentials = {**account.credentials, "token": f"t{int(token[1:]) + 1}"}
        return AccountInfo(display_name="测试盘", vip="VIP", quota_total=100, quota_used=40)

    async def list_tree(self, account, dir_id):
        # 像真网盘那样一页一个请求，经 SDK 网络出口（这里的上游换成假的）
        if dir_id == "stuck":
            await asyncio.sleep(30)
        transport = net._Paced(httpx.MockTransport(lambda request: httpx.Response(200, json={})))
        async with httpx.AsyncClient(transport=transport) as client:
            for page in range(int(dir_id)):
                await client.get(f"https://fake.example/files?page={page}")
        return RemoteTree(
            files=tuple(
                RemoteFile(remote_id=str(i), name=f"{i}.mkv", size=1, rel_path=f"{i}.mkv")
                for i in range(int(dir_id))
            )
        )


@plugin("fake-drive", title="假网盘")
async def apply(ctx) -> None:
    ctx.contribute(DRIVE_BACKENDS, "fake", FakeDrive())
"""


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch):
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.services.drives import accounts, gateway
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'drives.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setattr(accounts, "LOGIN_POLL_S", 0.05)
    monkeypatch.setattr(accounts, "LOGIN_LINGER_S", 60.0)
    gateway.reset_state()
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "fake_drive.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: fake-drive
              local: true
              module: fake_drive
              runtime: {request.param}
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as test_client:
        assert test_client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
        yield test_client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


def _scan_login(client: TestClient, device: str = "mini") -> dict:
    started = client.post(
        "/api/v1/drives/logins", json={"backend": "fake", "options": {"device": device}}
    )
    assert started.status_code == 201, started.text
    view = started.json()["data"]
    assert view["status"] == "pending" and view["qr_image"].startswith("data:image/svg+xml")
    deadline = time.monotonic() + 10
    while view["status"] != "confirmed":
        assert time.monotonic() < deadline, view
        time.sleep(0.05)
        view = client.get(f"/api/v1/drives/logins/{view['login_id']}").json()["data"]
    return view


def _raw_row(client: TestClient, account_id: int):
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository

    async def load():
        async with get_database().session() as session:
            row = await DriveAccountRepository(session).get(account_id)
            return row, DriveAccountRepository.credentials(row)

    return call(client, load)


def _set_token(client: TestClient, account_id: int, token: str) -> None:
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository

    async def save():
        async with get_database().session() as session:
            await DriveAccountRepository(session).save_credentials(
                account_id, {"token": token, "device": "mini"}
            )

    call(client, save)


def _notices(client: TestClient) -> list[str]:
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import SystemNotice

    async def load():
        async with get_database().session() as session:
            rows = (await session.execute(select(SystemNotice))).scalars().all()
            return [f"{r.dedupe_key}:{r.status}" for r in rows]

    return call(client, load)


def test_backends_come_from_plugins(client) -> None:
    data = client.get("/api/v1/drives/backends").json()["data"]
    assert [b["type"] for b in data] == ["fake"]
    fake = data[0]
    assert fake["title"] == "假网盘" and fake["accent_color"] == "#2a77ff"
    assert fake["capabilities"]["rapid_upload_hashes"] == ["sha1"]
    assert fake["capabilities"]["default_read_slots"] == 3
    login = fake["login"]
    assert login["scan"] is True and login["cookie"] is True
    assert login["options"][0]["default"] == "mini"
    assert [c["label"] for c in login["options"][0]["choices"]] == ["小程序端", "网页端"]


def test_scan_login_creates_one_account_per_user(client) -> None:
    view = _scan_login(client)
    account = view["account"]
    assert view["created"] is True and view["message"] == "已添加：测试盘"
    assert account["name"] == "测试盘" and account["login_method"] == "scan"
    assert account["login_detail"] == "小程序端"
    # 登录后立刻读了一次资料（容量），插件在这次调用里换了令牌，新令牌先落库
    assert account["quota_total"] == 100 and account["vip"] == "VIP"
    row, creds = _raw_row(client, account["id"])
    assert creds == {"token": "t1", "device": "mini"}
    # 密文是 base64，碰巧含「t1」两个字符不算泄露：看明文 JSON 片段
    assert '"token"' not in row.credentials and row.credentials.startswith("enc::"), "凭据加密落库"

    # 用户改了名字；同一网盘用户再扫一次码：更新原账号，不新建、不改名
    renamed = client.patch(f"/api/v1/drives/accounts/{account['id']}", json={"name": "影视仓库"})
    assert renamed.status_code == 200
    again = _scan_login(client, device="web")
    assert again["created"] is False and again["account"]["id"] == account["id"]
    assert again["account"]["name"] == "影视仓库" and again["account"]["login_detail"] == "网页端"
    listed = client.get("/api/v1/drives/accounts").json()["data"]
    assert [a["id"] for a in listed] == [account["id"]]
    assert listed[0]["backend_title"] == "假网盘" and listed[0]["backend_available"] is True


def test_login_options_are_validated(client) -> None:
    bad = client.post(
        "/api/v1/drives/logins", json={"backend": "fake", "options": {"device": "tv"}}
    )
    assert bad.status_code == 400 and "不在可选范围内" in bad.text
    missing = client.post("/api/v1/drives/logins", json={"backend": "nope"})
    assert missing.status_code == 409 and "没有安装能连接「nope」网盘的存储插件" in missing.text


def test_cookie_login_by_paste_and_by_extension(client) -> None:
    pasted = client.post(
        "/api/v1/drives/accounts/cookie", json={"backend": "fake", "cookie": "UID=u2; SEID=s"}
    )
    assert pasted.status_code == 201, pasted.text
    account = pasted.json()["data"]["account"]
    assert account["login_method"] == "cookie" and account["login_detail"] == "网页端"
    incomplete = client.post(
        "/api/v1/drives/accounts/cookie", json={"backend": "fake", "cookie": "SEID=s"}
    )
    assert incomplete.status_code == 400 and "Cookie 不全" in incomplete.text

    # 浏览器扩展：域名不是资源站点，按插件声明的域名（含子域名）交给网盘
    token = client.post("/api/v1/extension/token").json()["data"]["token"]
    headers = {"Authorization": f"Bearer {token}"}
    # 扩展先拉「支持的站点」判断当前网页能不能同步：网盘声明的域名在里面，已有 Cookie 账号算已配置
    sites = client.get("/api/v1/extension/sites", headers=headers).json()["data"]
    drive_site = next(s for s in sites if s["site_id"] == "drive:fake")
    assert drive_site["domain"] == "fake.example" and drive_site["display_name"] == "假网盘"
    assert drive_site["configured"] is True and drive_site["usable"] is True
    pushed = client.post(
        "/api/v1/extension/cookies",
        json={"domain": "www.fake.example", "cookie": "UID=u2; SEID=new"},
        headers=headers,
    )
    assert pushed.status_code == 200, pushed.text
    body = pushed.json()
    assert body["message"] == "已更新网盘账号的登录"
    assert body["data"]["display_name"] == "假网盘 · 网页盘" and body["data"]["usable"] is True
    assert len(client.get("/api/v1/drives/accounts").json()["data"]) == 1
    unknown = client.post(
        "/api/v1/extension/cookies",
        json={"domain": "unknown.example", "cookie": "a=b"},
        headers=headers,
    )
    assert unknown.status_code == 404


def test_relogin_from_an_account_card_must_be_the_same_user(client) -> None:
    pasted = client.post(
        "/api/v1/drives/accounts/cookie", json={"backend": "fake", "cookie": "UID=u2; SEID=s"}
    )
    account_id = pasted.json()["data"]["account"]["id"]

    # 粘贴了另一个人的 Cookie：拒绝，不悄悄新建一个账号
    other = client.post(
        "/api/v1/drives/accounts/cookie",
        json={"backend": "fake", "cookie": "UID=u3; SEID=s", "relogin": account_id},
    )
    assert other.status_code == 400 and "登录的是另一个账号（网页盘）" in other.text
    same = client.post(
        "/api/v1/drives/accounts/cookie",
        json={"backend": "fake", "cookie": "UID=u2; SEID=new", "relogin": account_id},
    )
    assert same.status_code == 201 and same.json()["data"]["account"]["id"] == account_id

    # 扫码扫到的是 u1，不是要重新登录的 u2：登录失败，账号不变
    started = client.post(
        "/api/v1/drives/logins",
        json={"backend": "fake", "options": {"device": "mini"}, "relogin": account_id},
    ).json()["data"]
    deadline = time.monotonic() + 10
    view = started
    while view["status"] not in ("confirmed", "failed"):
        assert time.monotonic() < deadline, view
        time.sleep(0.05)
        view = client.get(f"/api/v1/drives/logins/{started['login_id']}").json()["data"]
    assert view["status"] == "failed" and "登录的是另一个账号（测试盘）" in view["message"]
    assert [a["id"] for a in client.get("/api/v1/drives/accounts").json()["data"]] == [account_id]


def test_auth_expired_blocks_the_account_until_relogin(client) -> None:
    account_id = _scan_login(client)["account"]["id"]
    _set_token(client, account_id, "dead")
    failed = client.post(f"/api/v1/drives/accounts/{account_id}/refresh")
    assert failed.status_code == 400 and "登录已失效" in failed.text
    view = client.get("/api/v1/drives/accounts").json()["data"][0]
    assert view["status"] == "auth_expired"
    assert _notices(client) == [f"drive:{account_id}:active"]

    # 之后的调用直接拒绝，不再打到插件（插件那边的凭据没变就说明没调用）
    _set_token(client, account_id, "t5")
    blocked = client.post(f"/api/v1/drives/accounts/{account_id}/refresh")
    assert blocked.status_code == 400 and "需要重新登录" in blocked.text
    assert _raw_row(client, account_id)[1]["token"] == "t5"

    # 重新扫码：状态复位、提醒消退
    _scan_login(client)
    view = client.get("/api/v1/drives/accounts").json()["data"][0]
    assert view["status"] == "ok"
    assert _notices(client) == [f"drive:{account_id}:resolved"]


def _set_qps(client: TestClient, account_id: int, qps: float) -> None:
    response = client.patch(f"/api/v1/drives/accounts/{account_id}", json={"qps": qps})
    assert response.status_code == 200, response.text


def test_rate_limit_pauses_background_and_user_calls_but_not_playback(client) -> None:
    from movieclaw_api.services.drives import gateway
    from movieclaw_sdk import drives as dv

    account_id = _scan_login(client)["account"]["id"]
    _set_token(client, account_id, "limited")
    failed = client.post(f"/api/v1/drives/accounts/{account_id}/refresh")
    assert failed.status_code == 400 and "访问太频繁" in failed.text
    # 出错时插件也换了凭据：照样先落库
    assert _raw_row(client, account_id)[1]["token"] == "limited-rotated"
    view = client.get("/api/v1/drives/accounts").json()["data"][0]
    assert view["status"] == "rate_limited" and view["status_until"] is not None

    async def background():
        try:
            await gateway.call(account_id, "account_info", priority=gateway.Priority.BACKGROUND)
        except dv.RateLimited as exc:
            return exc.message
        return None

    assert "分钟后恢复" in call(client, background)
    # 用户操作也不打出去（每多一次被拒，网盘的冷却就往后推），告诉用户还要等多久
    _set_token(client, account_id, "t1")
    refused = client.post(f"/api/v1/drives/accounts/{account_id}/refresh")
    assert refused.status_code == 400 and "分钟后恢复" in refused.text
    assert _raw_row(client, account_id)[1]["token"] == "t1"
    # 播放照常尝试（插件这次成功，状态复位）
    call(client, gateway.call, account_id, "account_info", priority=gateway.Priority.PLAYBACK)
    assert client.get("/api/v1/drives/accounts").json()["data"][0]["status"] == "ok"
    assert client.post(f"/api/v1/drives/accounts/{account_id}/refresh").status_code == 200


def test_every_request_of_a_call_takes_its_own_slot(client) -> None:
    from movieclaw_api.services.drives import gateway

    account_id = _scan_login(client)["account"]["id"]
    _set_qps(client, account_id, 20)

    async def list_pages():
        before = gateway.usage_today(account_id)
        started = time.monotonic()
        tree = await gateway.call(
            account_id, "list_tree", priority=gateway.Priority.BACKGROUND, dir_id="8"
        )
        return len(tree.files), time.monotonic() - started, gateway.usage_today(account_id) - before

    files, elapsed, used = call(client, list_pages)
    assert files == 8
    # 8 个请求 8 个名额：调用本身领一个给第一个请求，后 7 个各领一个，逐个按 20 次 / 秒排队
    assert used == 8
    assert elapsed >= 7 / 20 * 0.9


def test_paging_stops_as_soon_as_the_account_is_rate_limited(client) -> None:
    from datetime import timedelta

    from movieclaw_api.services.drives import gateway
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import utcnow
    from movieclaw_db.models.drive_account import DRIVE_STATUS_RATE_LIMITED
    from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository
    from movieclaw_sdk import drives as dv

    account_id = _scan_login(client)["account"]["id"]
    _set_qps(client, account_id, 10)

    async def list_until_limited():
        before = gateway.usage_today(account_id)
        task = asyncio.ensure_future(
            gateway.call(account_id, "list_tree", priority=gateway.Priority.BACKGROUND, dir_id="40")
        )
        await asyncio.sleep(0.35)
        # 别的调用这时吃了网盘的限流
        async with get_database().session() as session:
            await DriveAccountRepository(session).set_status(
                account_id, DRIVE_STATUS_RATE_LIMITED, "访问太频繁", utcnow() + timedelta(minutes=5)
            )
        try:
            await task
        except dv.RateLimited as exc:
            return exc.message, gateway.usage_today(account_id) - before
        raise AssertionError("翻页没有停下")

    message, used = call(client, list_until_limited)
    assert "分钟后恢复" in message
    assert used < 10
    # 是宿主叫停的、不是网盘报的错：账号状态保持原样，冷却不往后推
    assert _raw_row(client, account_id)[0].status_message == "访问太频繁"


def test_timeout_counts_time_without_progress(client, monkeypatch) -> None:
    from movieclaw_api.services.drives import gateway
    from movieclaw_sdk import drives as dv

    account_id = _scan_login(client)["account"]["id"]
    _set_qps(client, account_id, 4)
    monkeypatch.setitem(gateway.TIMEOUTS, "list_tree", 0.6)
    # 8 页按 4 次 / 秒要翻近 2 秒，比超时长得多；但一直有进展，不算超时
    tree = call(
        client,
        gateway.call,
        account_id,
        "list_tree",
        priority=gateway.Priority.BACKGROUND,
        dir_id="8",
    )
    assert len(tree.files) == 8
    started = time.monotonic()
    with pytest.raises(dv.Transient, match="响应超时"):
        call(
            client,
            gateway.call,
            account_id,
            "list_tree",
            priority=gateway.Priority.BACKGROUND,
            dir_id="stuck",
        )
    assert time.monotonic() - started < 5


def test_background_stops_at_its_share_of_the_daily_budget(client) -> None:
    from movieclaw_api.services.drives import gateway
    from movieclaw_sdk import drives as dv

    account_id = _scan_login(client)["account"]["id"]
    assert (
        client.patch(
            f"/api/v1/drives/accounts/{account_id}", json={"daily_budget": 100}
        ).status_code
        == 200
    )

    async def burn():
        done = 0
        try:
            for _ in range(100):
                await gateway.call(account_id, "account_info", priority=gateway.Priority.BACKGROUND)
                done += 1
        except dv.RateLimited as exc:
            return done, exc.message
        return done, None

    used_before = client.get("/api/v1/drives/accounts").json()["data"][0]["used_today"]
    done, message = call(client, burn)
    assert used_before + done == 70 and "余量留给播放" in message
    # 用户操作不受预算拦截
    assert client.post(f"/api/v1/drives/accounts/{account_id}/refresh").status_code == 200
    assert client.get("/api/v1/drives/accounts").json()["data"][0]["used_today"] == 71


def test_settings_ranges_reset_and_delete(client) -> None:
    account_id = _scan_login(client)["account"]["id"]
    url = f"/api/v1/drives/accounts/{account_id}"
    view = client.get("/api/v1/drives/accounts").json()["data"][0]
    assert view["read_slots"] == 3 and view["read_slots_custom"] is False, "默认取插件声明"
    assert client.patch(url, json={"read_slots": 11}).status_code == 400
    changed = client.patch(url, json={"read_slots": 5}).json()["data"]
    assert changed["read_slots"] == 5 and changed["read_slots_custom"] is True
    reset = client.patch(url, json={"reset": ["read_slots"]}).json()["data"]
    assert reset["read_slots"] == 3 and reset["read_slots_custom"] is False
    assert client.patch(url, json={"name": "  "}).status_code == 400

    assert client.delete(url).status_code == 200
    assert client.get("/api/v1/drives/accounts").json()["data"] == []
    assert client.delete(url).status_code == 404


def test_limiter_lets_playback_jump_the_queue() -> None:
    """限速排队：等待中的调用按优先级放行，播放后到也排在后台前面。"""
    from movieclaw_api.services.drives.gateway import Priority, _Limiter

    async def scenario() -> list[str]:
        limiter = _Limiter()
        order: list[str] = []
        await limiter.acquire(20.0, Priority.BACKGROUND)  # 占掉当前名额，后面的都要排队

        async def go(name: str, priority: Priority) -> None:
            await limiter.acquire(20.0, priority)
            order.append(name)

        background = [asyncio.create_task(go(f"bg{i}", Priority.BACKGROUND)) for i in range(3)]
        await asyncio.sleep(0)
        playback = asyncio.create_task(go("play", Priority.PLAYBACK))
        await asyncio.gather(*background, playback)
        return order

    order = asyncio.run(scenario())
    assert order[0] == "play" and sorted(order[1:]) == ["bg0", "bg1", "bg2"]


def test_limiter_cancelled_waiter_leaves_the_queue() -> None:
    from movieclaw_api.services.drives.gateway import Priority, _Limiter

    async def scenario() -> bool:
        limiter = _Limiter()
        await limiter.acquire(10.0, Priority.USER)
        stuck = asyncio.create_task(limiter.acquire(10.0, Priority.PLAYBACK))
        await asyncio.sleep(0.01)
        stuck.cancel()
        await asyncio.gather(stuck, return_exceptions=True)
        # 取消的那个不能占着队头：下一个调用照常在一个间隔内拿到名额
        await asyncio.wait_for(limiter.acquire(10.0, Priority.BACKGROUND), 1.0)
        return True

    assert asyncio.run(scenario())


def test_credentials_never_show_up_in_account_views(client) -> None:
    _scan_login(client)
    raw = json.dumps(client.get("/api/v1/drives/accounts").json())
    assert "t1" not in raw and "credentials" not in raw
