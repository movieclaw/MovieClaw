"""设备授权协议的端到端测试（docs/design/device-auth.md、docs/design/login-devices.md）。

覆盖四块：
1. 全链路：发起 → 按配对码查看 → 批准 → 兑换 → 令牌可用，且令牌归属批准者；
2. 异常路径：轮询过快、被拒绝、过期、重放兑换、来源限流；
3. 形态上限：转码器凭证被业务接口默认拒绝（遍历全路由验证，新增业务路由不需要
   额外标注也会被挡住）；
4. 签发权：程序类凭证（命令行、转码器、手工令牌）造不出新凭证、注销不了别人的
   设备，只能注销自己。
"""

from __future__ import annotations

import asyncio
import time

import pytest
from fastapi.testclient import TestClient

import movieclaw_api.services.auth as auth_service
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box

_AUTH = "/api/v1/auth"
_ADMIN = {"username": "admin", "password": "s3cret-pass"}
_MEMBER = {"username": "family", "password": "family-pass-1"}


def _make_client(tmp_path, monkeypatch, *, name: str, peer=None):  # type: ignore[no-untyped-def]
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / f'{name}.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / f".{name}_secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()

    from movieclaw_api.app import create_app

    kwargs = {"client": peer} if peer else {}
    return TestClient(create_app(), **kwargs)


@pytest.fixture
def client(tmp_path, monkeypatch):
    with _make_client(tmp_path, monkeypatch, name="test") as c:
        c.post(f"{_AUTH}/bootstrap", json=_ADMIN)
        c.post(f"{_AUTH}/login", json=_ADMIN)
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


@pytest.fixture
def lan_client(tmp_path, monkeypatch):
    """来源地址可辨的客户端。

    默认 TestClient 的 client host 是字符串 "testclient"，不是合法 IP，会被
    判成「认不出来源」——那正好覆盖容器 NAT 的场景，但按来源限流的用例需要
    一个真实地址。
    """
    with _make_client(tmp_path, monkeypatch, name="lan", peer=("192.168.1.42", 51000)) as c:
        c.post(f"{_AUTH}/bootstrap", json=_ADMIN)
        c.post(f"{_AUTH}/login", json=_ADMIN)
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def _authorize(client: TestClient, *, client_type: str = "cli", name: str = "claude-code@mac"):
    resp = client.post(
        f"{_AUTH}/device/authorize",
        json={"client_type": client_type, "client_name": name},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def _redeem(client: TestClient, device_code: str):
    return client.post(f"{_AUTH}/device/token", json={"device_code": device_code})


def _pair(client: TestClient, *, client_type: str = "cli", name: str = "claude-code@mac") -> str:
    """走完一次配对（以 client 当前的身份批准），返回令牌明文。"""
    grant = _authorize(client, client_type=client_type, name=name)
    approved = client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve")
    assert approved.status_code == 200, approved.text
    return _redeem(client, grant["device_code"]).json()["data"]["token"]


def _paired_devices(client: TestClient) -> list[dict]:
    """「我的设备」里配对 / 手工创建的那一类（命令行、转码器、手工令牌）。"""
    devices = client.get(f"{_AUTH}/devices").json()["data"]
    return [d for d in devices if d["family"] == "paired"]


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# 全链路
# ---------------------------------------------------------------------------


def test_full_pairing_flow_grants_usable_token(client: TestClient) -> None:
    """发起 → 按码查看 → 批准 → 兑换 → 令牌能调业务接口，且令牌只交付这一次。"""
    grant = _authorize(client)
    assert grant["user_code"].startswith("MCLW-")
    assert grant["verification_uri"].endswith("/settings/devices")
    # 带码的链接：设备打开它，批准页只显示这一条请求
    assert grant["verification_uri_complete"] == (
        f"{grant['verification_uri']}?code={grant['user_code']}"
    )
    assert grant["expires_in"] == auth_service.DEVICE_CODE_TTL_SECONDS

    # 配对码不是凭据：它出现在网页上，而 device_code 只有客户端有
    assert grant["device_code"] != grant["user_code"]

    request = client.get(f"{_AUTH}/devices/requests/{grant['user_code']}").json()["data"]
    assert request["client_name"] == "claude-code@mac"
    assert request["requires_admin"] is False

    assert _redeem(client, grant["device_code"]).status_code == 202

    approve = client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve")
    assert approve.status_code == 200, approve.text

    granted = _redeem(client, grant["device_code"])
    assert granted.status_code == 200, granted.text
    data = granted.json()["data"]
    token = data["token"]
    assert token.startswith("mclaw_")
    assert data["granted_by"] == "admin"

    # 令牌可用：Bearer 走的是与会话 Cookie 相同的授权路径，身份就是批准者
    fresh = TestClient(client.app)
    me = fresh.get(f"{_AUTH}/me", headers=_bearer(token))
    assert me.status_code == 200, me.text
    assert me.json()["data"]["username"] == "admin"
    assert me.json()["data"]["device"]["kind"] == "cli"

    # 兑换一次即作废：重放同一个 device_code 不再返回令牌
    assert _redeem(client, grant["device_code"]).status_code == 400

    # 批准后请求不再可查，这台命令行进入「我的设备」
    assert client.get(f"{_AUTH}/devices/requests/{grant['user_code']}").status_code == 400
    paired = _paired_devices(client)
    assert [(d["name"], d["kind"], d["owner_username"]) for d in paired] == [
        ("claude-code@mac", "cli", "admin")
    ]


def test_revoking_token_cuts_off_the_device(client: TestClient) -> None:
    """注销是唯一的事后止损手段，必须立即生效。"""
    token = _pair(client)
    device_id = _paired_devices(client)[0]["id"]
    assert client.delete(f"{_AUTH}/devices/{device_id}").status_code == 200

    fresh = TestClient(client.app)
    assert fresh.get(f"{_AUTH}/me", headers=_bearer(token)).status_code == 401


def test_repairing_the_same_machine_replaces_its_old_token(client: TestClient) -> None:
    """同一台机器（同一安装标识）重新配对：旧令牌作废、设备不重复出现。"""

    def pair_once() -> str:
        grant = client.post(
            f"{_AUTH}/device/authorize",
            json={
                "client_type": "cli",
                "client_name": "mclaw@mac",
                "installation_id": "install-0123456789",
                "platform": "darwin/arm64",
                "client_version": "0.28.0",
            },
        ).json()["data"]
        client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve")
        return _redeem(client, grant["device_code"]).json()["data"]["token"]

    first = pair_once()
    second = pair_once()
    fresh = TestClient(client.app)
    assert fresh.get(f"{_AUTH}/me", headers=_bearer(first)).status_code == 401
    assert fresh.get(f"{_AUTH}/me", headers=_bearer(second)).status_code == 200
    paired = _paired_devices(client)
    assert len(paired) == 1
    assert paired[0]["platform"] == "darwin/arm64"
    assert paired[0]["client_version"] == "0.28.0"


# ---------------------------------------------------------------------------
# 异常路径
# ---------------------------------------------------------------------------


def test_polling_too_fast_backs_off_without_voiding_the_challenge(client: TestClient) -> None:
    """轮询过快只让客户端退避——正常用户的重试不该被当成攻击而作废挑战。"""
    grant = _authorize(client)
    assert _redeem(client, grant["device_code"]).status_code == 202
    assert _redeem(client, grant["device_code"]).status_code == 429

    # 挑战仍然活着：批准后照样能兑换
    client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve")
    assert _redeem(client, grant["device_code"]).status_code == 200


def test_denied_request_grants_nothing(client: TestClient) -> None:
    """拒绝不生成任何令牌，客户端拿到 400 后应当停止轮询。"""
    grant = _authorize(client)
    assert client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/deny").status_code == 200

    assert _redeem(client, grant["device_code"]).status_code == 400
    assert _paired_devices(client) == []


def test_expired_challenge_stops_the_client(client: TestClient, monkeypatch) -> None:
    """超时未批准即作废；客户端收到 400 而不是含糊的「挑战不存在」。"""
    grant = _authorize(client)
    real_monotonic = time.monotonic
    monkeypatch.setattr(
        auth_service.time,
        "monotonic",
        lambda: real_monotonic() + auth_service.DEVICE_CODE_TTL_SECONDS + 1,
    )
    assert _redeem(client, grant["device_code"]).status_code == 400
    assert client.get(f"{_AUTH}/devices/requests/{grant['user_code']}").status_code == 400


def test_unknown_device_code_is_indistinguishable_from_expired(client: TestClient) -> None:
    """乱猜 device_code 与「已过期」返回同一结论，不给探测者留判据。"""
    assert _redeem(client, "definitely-not-a-real-device-code").status_code == 400


def test_unknown_user_code_is_not_found(client: TestClient) -> None:
    assert client.get(f"{_AUTH}/devices/requests/MCLW-ZZZZ").status_code == 404


def test_pending_requests_are_capped_per_source(lan_client: TestClient) -> None:
    """来源可辨时，单来源未决请求有上限，防止刷屏。"""
    for _ in range(auth_service._DEVICE_MAX_PENDING_PER_IP):
        _authorize(lan_client)
    overflow = lan_client.post(
        f"{_AUTH}/device/authorize",
        json={"client_type": "cli", "client_name": "flood"},
    )
    assert overflow.status_code == 400
    assert "同一来源" in overflow.json()["message"]


def test_records_the_real_source_when_it_identifies_a_machine(lan_client: TestClient) -> None:
    grant = _authorize(lan_client)
    request = lan_client.get(f"{_AUTH}/devices/requests/{grant['user_code']}").json()["data"]
    assert request["source_ip"] == "192.168.1.42"


def test_unidentifiable_source_is_reported_empty_not_faked(client: TestClient) -> None:
    """取不到可辨地址时如实返回空串，不编一个占位地址。

    审批卡让用户照着「来源」判断这是不是自己那台机器；桥接网络里所有设备的
    源地址都会被 NAT 成同一个网关地址，摆出来只会误导。
    """
    grant = _authorize(client)
    request = client.get(f"{_AUTH}/devices/requests/{grant['user_code']}").json()["data"]
    assert request["source_ip"] == ""


def test_unidentifiable_sources_do_not_share_one_rate_limit_bucket(client: TestClient) -> None:
    """来源认不出来时不按来源分桶，否则一台机器刷屏就锁住整个局域网。

    容器桥接网络下每台设备的源地址都是同一个网关地址。如果照旧按地址计数，
    第 6 台机器根本配不上对——而它和前 5 台毫无关系。
    """
    for _ in range(auth_service._DEVICE_MAX_PENDING_PER_IP + 1):
        _authorize(client)

    # 但总数上限仍然兜着
    accepted = auth_service._DEVICE_MAX_PENDING_PER_IP + 1
    while True:
        resp = client.post(
            f"{_AUTH}/device/authorize",
            json={"client_type": "cli", "client_name": "flood"},
        )
        if resp.status_code != 200:
            break
        accepted += 1
    assert resp.status_code == 400
    assert "过多" in resp.json()["message"]
    assert accepted == auth_service._DEVICE_MAX_PENDING_TOTAL


def test_authorize_rejects_unknown_client_type(client: TestClient) -> None:
    resp = client.post(
        f"{_AUTH}/device/authorize",
        json={"client_type": "toaster", "client_name": "x"},
    )
    assert resp.status_code == 400


def test_approving_twice_is_rejected(client: TestClient) -> None:
    """重复批准同一条请求不会再签发一枚令牌。"""
    grant = _authorize(client)
    assert client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve").status_code == 200
    assert client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve").status_code == 400
    assert len(_paired_devices(client)) == 1


def test_device_approval_requires_login(client: TestClient) -> None:
    """批准是防钓鱼的唯一人工闸，必须有人登录着——匿名一律 401。"""
    grant = _authorize(client)
    anon = TestClient(client.app)
    code = grant["user_code"]
    assert anon.get(f"{_AUTH}/devices/requests/{code}").status_code == 401
    assert anon.post(f"{_AUTH}/devices/requests/{code}/approve").status_code == 401
    assert anon.post(f"{_AUTH}/devices/requests/{code}/deny").status_code == 401


# ---------------------------------------------------------------------------
# 谁批准，令牌就是谁的
# ---------------------------------------------------------------------------


def _create_member_and_login(client: TestClient) -> None:
    """建一个默认成员并以他的身份登录（调用后 client 处于成员身份）。"""
    created = client.post("/api/v1/members", json=_MEMBER)
    assert created.status_code == 200, created.text
    client.cookies.clear()
    assert client.post(f"{_AUTH}/login", json=_MEMBER).status_code == 200


def test_member_can_pair_a_cli_that_acts_as_the_member(client: TestClient) -> None:
    """成员批准自己的命令行：令牌的身份与权限就是这个成员，碰不到管理面。"""
    _create_member_and_login(client)
    grant = _authorize(client)
    request = client.get(f"{_AUTH}/devices/requests/{grant['user_code']}").json()["data"]
    assert request["requires_admin"] is False
    assert client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve").status_code == 200
    data = _redeem(client, grant["device_code"]).json()["data"]
    assert data["granted_by"] == "family"

    holder = TestClient(client.app)
    me = holder.get(f"{_AUTH}/me", headers=_bearer(data["token"])).json()["data"]
    assert (me["username"], me["role"]) == ("family", "member")
    # 成员没有管理权：管理区一律 403，与他在网页上的权限完全一致
    assert holder.get("/api/v1/members", headers=_bearer(data["token"])).status_code == 403
    # 设备记在成员名下
    assert [d["owner_username"] for d in _paired_devices(client)] == ["family"]


def test_member_cannot_approve_a_transcoder(client: TestClient) -> None:
    """转码是整台服务器的资源：转码器只能由超管批准。"""
    _create_member_and_login(client)
    grant = _authorize(client, client_type="worker", name="Yi的Mac-mini")
    request = client.get(f"{_AUTH}/devices/requests/{grant['user_code']}").json()["data"]
    assert request["requires_admin"] is True
    resp = client.post(f"{_AUTH}/devices/requests/{grant['user_code']}/approve")
    assert resp.status_code == 403
    # 请求没被消耗，管理员还能批
    assert client.get(f"{_AUTH}/devices/requests/{grant['user_code']}").status_code == 200


# ---------------------------------------------------------------------------
# 形态上限：转码器凭证只能转码
# ---------------------------------------------------------------------------


def test_transcoder_token_is_rejected_by_every_business_route(client: TestClient) -> None:
    """遍历全路由：转码器凭证在 require_login 处被默认拒绝。

    这条守护的价值在于「新增业务路由不需要记得标注什么」——只要照常挂
    require_login，转码器就自动进不来。放行它的只有转码控制面与「注销自己」。
    """
    from tests.api.test_auth import _PUBLIC_ALLOWLIST, fill_path_params

    token = _pair(client, client_type="worker", name="Yi的Mac-mini")
    worker = TestClient(client.app)
    allowed = _PUBLIC_ALLOWLIST | {
        ("GET", "/api/v1/auth/devices/current"),
        ("DELETE", "/api/v1/auth/devices/current"),
    }
    # 同 test_auth.py：spec 直接取自应用，不依赖 /openapi.json 是否对外开放（生产默认关闭）
    openapi = client.app.openapi()
    checked = 0
    for path, methods in openapi["paths"].items():
        url = fill_path_params(path)
        for method in methods:
            if (method.upper(), path) in allowed:
                continue
            resp = worker.request(method.upper(), url, headers=_bearer(token))
            assert resp.status_code in (401, 403), (
                f"{method.upper()} {path} 竟然放行了转码器凭证：{resp.status_code}"
            )
            checked += 1
    assert checked > 100


def test_cli_token_is_not_restricted_by_client_type(client: TestClient) -> None:
    """对照组：同一批准者签发的命令行令牌不受形态上限影响。"""
    token = _pair(client)
    cli = TestClient(client.app)
    resp = cli.get("/api/v1/subscriptions", headers=_bearer(token))
    assert resp.status_code == 200, resp.text


def test_worker_token_is_accepted_by_the_transcode_control_plane(client: TestClient) -> None:
    """形态上限的另一半：转码器凭证进不了业务接口，但必须进得了转码控制面。"""
    from movieclaw_api.api.deps import resolve_worker_principal

    token = _pair(client, client_type="worker", name="Yi的Mac-mini")

    async def resolve(header: str | None):
        return await resolve_worker_principal(header)

    principal = asyncio.run(resolve(f"Bearer {token}"))
    assert principal is not None
    assert principal.device is not None and principal.device.scope == "transcode"

    # 命令行令牌不能冒充转码器去连转码控制面
    cli_token = _pair(client)
    assert asyncio.run(resolve(f"Bearer {cli_token}")) is None
    assert asyncio.run(resolve(None)) is None
    assert asyncio.run(resolve("Bearer 乱写的")) is None


def test_revoking_a_transcoder_drops_its_live_connection(client: TestClient) -> None:
    """注销转码器要当场断开它的连接，而不是等它下次重连才发现被踢了。"""
    from movieclaw_api.services.playback.remote_worker import get_remote_worker_registry

    _pair(client, client_type="worker", name="Yi的Mac-mini")
    device = _paired_devices(client)[0]
    device_row_id = int(device["id"].removeprefix("ld-"))

    closed: list[tuple[int, str]] = []

    class FakeSocket:
        async def close(self, code: int = 1000, reason: str = "") -> None:
            closed.append((code, reason))

    registry = get_remote_worker_registry()
    connection = client.portal.call(
        lambda: registry.register(
            FakeSocket(),  # type: ignore[arg-type]
            {"worker_id": "mac-mini", "capabilities": {}},
            login_device_id=device_row_id,
        )
    )
    try:
        assert client.delete(f"{_AUTH}/devices/{device['id']}").status_code == 200
        assert closed and closed[0][0] == 1008
        assert "注销" in closed[0][1]
    finally:
        client.portal.call(registry.unregister, connection)


# ---------------------------------------------------------------------------
# 签发权：程序类凭证造不出新凭证、注销不了别人，只能注销自己
# ---------------------------------------------------------------------------


def test_tokens_cannot_mint_or_revoke_other_credentials(client: TestClient) -> None:
    """凭证的签发与管理只能由人在网页或 App 里完成。

    这是「注销是唯一止损手段」这句话成立的前提：命令行令牌若能签发新令牌，
    就能给自己造一枚备份，注销原来那枚也止不住损；若能注销别的设备，一枚泄露的
    令牌就能把主人的手机踢下线。
    """
    token = _pair(client)
    own_id = _paired_devices(client)[0]["id"]
    other_token = _pair(client, name="another-box")
    other_id = next(d["id"] for d in _paired_devices(client) if d["name"] == "another-box")

    holder = TestClient(client.app)
    headers = _bearer(token)
    # 令牌可用（业务接口通），但碰不到凭证管理面
    assert holder.get("/api/v1/subscriptions", headers=headers).status_code == 200
    assert (
        holder.post(f"{_AUTH}/tokens", json={"name": "spare"}, headers=headers).status_code == 403
    )
    assert holder.get(f"{_AUTH}/devices", headers=headers).status_code == 403
    assert holder.delete(f"{_AUTH}/devices/{other_id}", headers=headers).status_code == 403
    assert (
        holder.patch(
            f"{_AUTH}/devices/{own_id}", json={"name": "renamed"}, headers=headers
        ).status_code
        == 403
    )

    # 也不能自我扩张：批准别的设备把更多机器拉进来
    other = _authorize(client, name="attacker-box")
    assert (
        holder.post(
            f"{_AUTH}/devices/requests/{other['user_code']}/approve", headers=headers
        ).status_code
        == 403
    )
    assert client.get(f"{_AUTH}/devices/requests/{other['user_code']}").status_code == 200

    # 但能看自己、注销自己（mclaw logout），注销后立即失效，别的设备不受影响
    current = holder.get(f"{_AUTH}/devices/current", headers=headers)
    assert current.status_code == 200 and current.json()["data"]["current"] is True
    assert holder.delete(f"{_AUTH}/devices/current", headers=headers).status_code == 200
    assert holder.get("/api/v1/subscriptions", headers=headers).status_code == 401
    assert holder.get("/api/v1/subscriptions", headers=_bearer(other_token)).status_code == 200


def test_transcoder_can_sign_itself_out(client: TestClient) -> None:
    """转码器「断开并重新配置」要能在服务端把自己作废，而不是只删本地文件。"""
    token = _pair(client, client_type="worker", name="Yi的Mac-mini")
    worker = TestClient(client.app)
    assert worker.delete(f"{_AUTH}/devices/current", headers=_bearer(token)).status_code == 200
    assert _paired_devices(client) == []


def test_concurrent_approvals_mint_at_most_one_token(client: TestClient) -> None:
    """并发批准同一条请求只签出一枚令牌。

    签发要 await（写库），若状态变更放在 await 之后，两个并发请求会双双通过
    「仍待批准」的检查，多签的那枚永远没人兑换、也不会有人知道它存在。
    """
    from concurrent.futures import ThreadPoolExecutor

    grant = _authorize(client)
    url = f"{_AUTH}/devices/requests/{grant['user_code']}/approve"
    with ThreadPoolExecutor(max_workers=4) as pool:
        codes = [f.result().status_code for f in [pool.submit(client.post, url) for _ in range(4)]]

    assert codes.count(200) == 1, f"批准被重复受理：{codes}"
    assert len(_paired_devices(client)) == 1


# ---------------------------------------------------------------------------
# 手工令牌：给没人能按批准的环境（docs/design/device-auth.md §6.2.1、§7）
# ---------------------------------------------------------------------------


def test_manual_token_is_usable_and_listed_alongside_paired_devices(client: TestClient) -> None:
    """手工创建的令牌与配对出来的令牌同权、同列表、同一个注销入口。

    这是「签发的入口有多个，管理的入口只有一个」这句话的检验：网页上多开一个
    创建入口，不能在设备列表之外再长出一套平行的管理面——否则用户改密后去清点
    设备时，会漏掉整整一类凭证。
    """
    created = client.post(f"{_AUTH}/tokens", json={"name": "nas-cron"})
    assert created.status_code == 200, created.text
    payload = created.json()["data"]

    # 明文只在这一次响应里出现，且形态与配对签出来的令牌一致
    assert payload["token"].startswith("mclaw_")
    assert payload["scope"] == "full"
    assert payload["name"] == "nas-cron"

    # 与超管同权：业务接口直接可用
    holder = TestClient(client.app)
    headers = _bearer(payload["token"])
    assert holder.get("/api/v1/subscriptions", headers=headers).status_code == 200

    # 落在同一张设备列表里，注销后立刻失效
    listed = _paired_devices(client)
    assert [(d["id"], d["kind"]) for d in listed] == [(payload["id"], "manual")]
    assert client.delete(f"{_AUTH}/devices/{payload['id']}").status_code == 200
    assert holder.get("/api/v1/subscriptions", headers=headers).status_code == 401


def test_transcode_scoped_manual_token_serves_a_headless_worker(client: TestClient) -> None:
    """命令行模式的转码器用手工令牌：scope=transcode 时能连转码控制面、进不了业务接口。

    改造前手工令牌的类型是 manual，转码控制面只认 worker，照文档操作的用户
    根本连不上。
    """
    from movieclaw_api.api.deps import resolve_worker_principal

    token = client.post(
        f"{_AUTH}/tokens", json={"name": "headless-worker", "scope": "transcode"}
    ).json()["data"]["token"]
    principal = asyncio.run(resolve_worker_principal(f"Bearer {token}"))
    assert principal is not None
    holder = TestClient(client.app)
    assert holder.get("/api/v1/subscriptions", headers=_bearer(token)).status_code == 403


def test_manual_token_plaintext_is_never_readable_again(client: TestClient) -> None:
    """明文只发这一次——所以网页那张卡必须让用户当场存走。"""
    plaintext = client.post(f"{_AUTH}/tokens", json={"name": "ci"}).json()["data"]["token"]

    listed = client.get(f"{_AUTH}/devices").json()["data"]
    assert plaintext not in str(listed)
    for record in listed:
        assert "token" not in record


def test_manual_token_creation_requires_a_person(client: TestClient) -> None:
    """手工入口不放宽签发面：令牌仍然造不出令牌。"""
    plaintext = client.post(f"{_AUTH}/tokens", json={"name": "seed"}).json()["data"]["token"]

    holder = TestClient(client.app)
    assert (
        holder.post(
            f"{_AUTH}/tokens", json={"name": "spare"}, headers=_bearer(plaintext)
        ).status_code
        == 403
    )


def test_transcoder_shows_connected_while_its_control_link_is_up(client: TestClient) -> None:
    """转码器只在握手时验一次凭证、之后靠长连接心跳在线：设备列表的「已连接」以连接为准，
    不能按最近验签时间判断——否则连着的转码器 5 分钟后就显示成离线。"""
    from movieclaw_api.services.playback.remote_worker import REMOTE_WORKER_PROTOCOL_VERSION

    token = _pair(client, client_type="worker", name="Yi的Mac-mini")
    assert client.put("/api/v1/transcode-worker/config", json={"enabled": True}).status_code == 200
    assert _paired_devices(client)[0]["connected"] is False

    with client.websocket_connect("/api/v1/transcode-worker/ws", headers=_bearer(token)) as ws:
        ws.send_json(
            {
                "type": "worker.hello",
                "protocol_version": REMOTE_WORKER_PROTOCOL_VERSION,
                "worker_id": "yi-mac-mini",
                "capabilities": {"platform": "macOS", "backends": ["videotoolbox"], "max_jobs": 1},
            }
        )
        assert ws.receive_json()["type"] == "worker.accepted"
        device = _paired_devices(client)[0]
        assert device["connected"] is True
        # 其他设备不受影响
        assert all(
            not d["connected"]
            for d in client.get(f"{_AUTH}/devices").json()["data"]
            if d["kind"] != "worker"
        )

    # 连接断开后回到「未连接」（服务端注销连接在断开处理里，稍等片刻）
    for _ in range(50):
        if _paired_devices(client)[0]["connected"] is False:
            break
        time.sleep(0.1)
    assert _paired_devices(client)[0]["connected"] is False


@pytest.mark.parametrize("paired", [True, False])
def test_worker_rename_updates_only_its_paired_device(client: TestClient, paired: bool) -> None:
    """同一凭证改名重连后仍是原设备；手工令牌的管理名称保留。"""
    from movieclaw_api.services.playback.remote_worker import REMOTE_WORKER_PROTOCOL_VERSION

    token = (
        _pair(client, client_type="worker", name="old-mac")
        if paired
        else client.post(f"{_AUTH}/tokens", json={"name": "manual", "scope": "transcode"})
        .json()["data"]["token"]
    )
    assert client.put("/api/v1/transcode-worker/config", json={"enabled": True}).status_code == 200
    listed = client.get(f"{_AUTH}/devices").json()["data"]
    original = next(d for d in listed if d["name"] == ("old-mac" if paired else "manual"))
    for name in ["new-mac", "final-mac"]:
        with client.websocket_connect("/api/v1/transcode-worker/ws", headers=_bearer(token)) as ws:
            ws.send_json(
                {
                    "type": "worker.hello",
                    "protocol_version": REMOTE_WORKER_PROTOCOL_VERSION,
                    "worker_id": name,
                    "capabilities": {"platform": "macOS", "backends": ["videotoolbox"]},
                }
            )
            assert ws.receive_json()["type"] == "worker.accepted"
            devices = client.get(f"{_AUTH}/devices").json()["data"]
            device = next(d for d in devices if d["id"] == original["id"])
            assert device["name"] == (name if paired else "manual")
            assert len(devices) == len(listed)
            assert {d["id"]: d["name"] for d in devices if d["id"] != original["id"]} == {
                d["id"]: d["name"] for d in listed if d["id"] != original["id"]
            }


def test_worker_messages_refresh_last_seen(client: TestClient) -> None:
    """心跳也算活跃：「最近活跃」跟得上转码器真实的在线时间，而不是停在握手那一刻。"""
    from datetime import timedelta

    from movieclaw_api.services import login_devices
    from movieclaw_db.engine import get_database
    from movieclaw_db.models.base import utcnow
    from movieclaw_db.models.login_device import LoginDevice

    _pair(client, client_type="worker", name="Yi的Mac-mini")
    row_id = int(_paired_devices(client)[0]["id"].removeprefix("ld-"))
    stale = utcnow() - timedelta(hours=3)

    async def age_and_touch() -> None:
        async with get_database().session() as session:
            row = await session.get(LoginDevice, row_id)
            row.last_seen_at = stale
            await session.commit()
        login_devices.reset_state()  # 清掉进程内的节流，模拟一分钟以后的下一条心跳
        await login_devices.touch_id(
            row_id, ip="192.168.1.60", user_agent="MovieClawTranscoder/1.0"
        )

    client.portal.call(age_and_touch)
    device = _paired_devices(client)[0]
    assert device["last_seen_ip"] == "192.168.1.60"
    assert not device["last_seen_at"].startswith(stale.isoformat()[:16])
