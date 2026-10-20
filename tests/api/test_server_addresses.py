"""内外双地址（docs/design/server-addresses.md）：访问地址簿、主机签名、内外网判定。

重点场景是 #947：外层反代把外网请求的对端地址抹成自己的私网地址，服务端不能再靠对端 IP 判
「在家」。这里按真实的请求头组合（Host / X-Forwarded-Host / X-Forwarded-For / X-MovieClaw-Route）
走一遍完整的 ASGI 栈。
"""

from __future__ import annotations

import base64
import time

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from fastapi.testclient import TestClient
from starlette.requests import HTTPConnection

from movieclaw_api import middleware
from movieclaw_api.core.config import get_settings
from movieclaw_api.services import host_key, lan_discovery, network_side
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.server_addresses import (
    address_book,
    host_kind,
    lan_subnets,
    normalize_url,
)
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box

_AUTH = "/api/v1/auth"
_ADDRESSES = "/api/v1/server/addresses"
_ADMIN = {"username": "admin", "password": "s3cret-pass"}
_MEMBER = {"username": "family", "password": "family-pass-1"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    address_book.reset_state()
    host_key.reset_state()
    # 局域网发现记下的地址也是进程级状态（地址簿会并进来），每个用例从空开始
    fresh = lan_discovery._LanOrigins()
    monkeypatch.setattr(lan_discovery, "lan_origins", fresh)
    monkeypatch.setattr(middleware, "lan_origins", fresh)

    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        assert c.post(f"{_AUTH}/bootstrap", json=_ADMIN).status_code == 200
        yield c

    address_book.reset_state()
    host_key.reset_state()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def _addresses(client: TestClient) -> dict:
    resp = client.get(_ADDRESSES)
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def _wait_for(client: TestClient, predicate) -> dict:
    """学习在后台任务里落库：轮询到出现为止。"""
    deadline = time.monotonic() + 3
    while True:
        data = _addresses(client)
        if predicate(data) or time.monotonic() > deadline:
            return data
        time.sleep(0.05)


def _urls(data: dict) -> dict[str, tuple[str, str]]:
    return {a["url"]: (a["kind"], a["source"]) for a in data["addresses"]}


# ---------------------------------------------------------------------------
# 地址本身判内外网
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("host", "kind"),
    [
        ("192.168.1.10", "lan"),
        ("10.10.10.2", "lan"),
        ("172.20.0.3", "lan"),
        ("127.0.0.1", "lan"),
        ("fd00::1", "lan"),
        ("nas.local", "lan"),
        ("nas", "lan"),
        ("router.home.arpa", "lan"),
        ("movie.example.com", "wan"),
        ("8.8.8.8", "wan"),
        ("100.80.1.2", "wan"),  # Tailscale 一类的共享地址：人在外面
        ("2408:8207::1", "wan"),
    ],
)
def test_host_kind(host, kind):
    assert host_kind(host) == kind


def test_normalize_url():
    assert normalize_url("HTTPS://Movie.Example.com:443/login?x=1") == "https://movie.example.com"
    assert normalize_url("http://192.168.1.10:3300/") == "http://192.168.1.10:3300"
    for bad in ("192.168.1.10:3000", "ftp://nas", "http://user:pw@nas", "http://nas:99999"):
        with pytest.raises(ValueError):
            normalize_url(bad)


# ---------------------------------------------------------------------------
# 请求方在家还是在外面
# ---------------------------------------------------------------------------


def _conn(headers: dict[str, str], client: tuple[str, int] | None = ("10.10.10.2", 5000)):
    scope = {
        "type": "http",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
        "client": client,
    }
    return HTTPConnection(scope)


@pytest.mark.parametrize(
    ("headers", "side"),
    [
        # #947：外网经外层反代进来，对端是反代的私网地址，但入口是外网域名
        ({"Host": "192.168.1.10:3000", "X-Forwarded-Host": "movie.example.com:8888"}, "outside"),
        # 外层反代改写了 Host、也没传 X-Forwarded-Host，但转发链里有外面那台的公网地址
        ({"Host": "192.168.1.10:3000", "X-Forwarded-For": "1.2.3.4, 10.10.10.2"}, "outside"),
        # 家里直接用局域网地址
        ({"Host": "192.168.1.10:3300", "X-Forwarded-For": "192.168.1.23"}, "home"),
        # 家里用外网域名（NAT 回环）：按在外面，代价是多让一次上传
        ({"Host": "movie.example.com"}, "outside"),
        # 自家 App 的声明优先：经 VPN 连着内网地址，其实在外面
        ({"Host": "192.168.1.10:3300", "X-MovieClaw-Route": "vpn"}, "outside"),
        ({"Host": "movie.example.com", "X-MovieClaw-Route": "lan"}, "home"),
        ({"Host": "movie.example.com", "X-MovieClaw-Route": "bogus"}, "outside"),
        # 没有任何入口信息
        ({}, "unknown"),
    ],
)
def test_request_side(headers, side):
    assert network_side.request_side(_conn(headers)) == side


def test_route_in_stream_token_wins_when_the_engine_cannot_send_headers():
    lan_entry = _conn({"Host": "192.168.1.10:3300"})
    assert network_side.request_side(lan_entry, route="vpn") == "outside"
    assert network_side.request_side(lan_entry, route=None) == "home"


async def test_stream_token_carries_the_declared_route(client):
    from movieclaw_api.services.playback.signing import issue_stream_token, verify_stream_token

    reset = network_side.current_route.set("vpn")
    try:
        token = await issue_stream_token(member_id=0, file_id=7)
    finally:
        network_side.current_route.reset(reset)
    plain = await issue_stream_token(member_id=0, file_id=7)
    assert (await verify_stream_token(token, file_id=7)).route == "vpn"
    assert (await verify_stream_token(plain, file_id=7)).route is None


def test_route_header_reaches_tokens_issued_in_the_request(client):
    """中间件把请求头里的路线放进上下文（签发取流 token 时读它），请求结束后复原。"""
    seen: list[str | None] = []

    @client.app.get("/__route_probe")
    async def probe():
        seen.append(network_side.current_route.get())
        return {}

    client.get("/__route_probe", headers={"X-MovieClaw-Route": "wan"})
    client.get("/__route_probe")
    assert seen == ["wan", None]
    assert network_side.current_route.get() is None


# ---------------------------------------------------------------------------
# 地址簿
# ---------------------------------------------------------------------------


def test_addresses_are_learned_from_logged_in_requests_only(client):
    # 匿名请求带着陌生的 Host：不学；局域网发现从匿名请求记下的私网地址也不进地址簿
    anonymous = TestClient(client.app)
    anonymous.get("/api/v1/health", headers={"Host": "evil.example.net"})
    anonymous.get("/api/v1/health", headers={"Host": "192.168.1.77:3000"})
    # 已登录：一次走局域网地址，一次经外层反代的外网域名
    client.get(f"{_AUTH}/me", headers={"Host": "192.168.1.10:3300"})
    client.get(
        f"{_AUTH}/me",
        headers={
            "Host": "192.168.1.10:3300",
            "X-Forwarded-Host": "movie.example.com:8888",
            "X-Forwarded-Proto": "https",
        },
    )
    # 容器名、环回、失败的请求都不学
    client.get(f"{_AUTH}/me", headers={"Host": "movieclaw:3000"})
    client.get(f"{_AUTH}/me", headers={"Host": "127.0.0.1:8000"})
    client.get("/api/v1/libraries/999999", headers={"Host": "failed.example.org"})

    data = _wait_for(client, lambda d: len(d["addresses"]) >= 2)
    urls = _urls(data)
    assert urls == {
        "http://192.168.1.10:3300": ("lan", "learned"),
        "https://movie.example.com:8888": ("wan", "learned"),
    }
    assert data["addresses"][0]["url"] == "http://192.168.1.10:3300", "内网在前"
    assert data["addresses"][0]["last_seen"].endswith("+00:00")
    assert data["lan_subnets"] == ["192.168.1.0/24"]
    assert data["instance_id"] and data["host_key"]


def test_configured_external_url_is_listed(client):
    resp = client.put("/api/v1/app/config", json={"external_url": "https://media.example.org"})
    assert resp.status_code == 200, resp.text
    assert _urls(_addresses(client)) == {"https://media.example.org": ("wan", "configured")}


def test_admin_adds_and_removes_addresses_and_overrides_the_kind(client):
    # 家里 DNS 把这个域名解析到内网：手动标成内网
    added = client.post(_ADDRESSES, json={"url": "https://nas.home.example.com/", "kind": "lan"})
    assert added.status_code == 200, added.text
    guessed = client.post(_ADDRESSES, json={"url": "http://192.168.50.2:3000"})
    assert guessed.status_code == 200
    urls = _urls(guessed.json()["data"])
    assert urls["https://nas.home.example.com"] == ("lan", "manual")
    assert urls["http://192.168.50.2:3000"] == ("lan", "manual"), "不填类型按地址判"
    assert "192.168.50.0/24" in guessed.json()["data"]["lan_subnets"]

    # 手动标成内网的域名：在家用它访问算在家；外面的人经反代用同一个域名进来，转发链里有公网地址，
    # 照样算在外面
    home = _conn({"Host": "nas.home.example.com"})
    assert network_side.request_side(home) == "home"
    away = _conn({"Host": "nas.home.example.com", "X-Forwarded-For": "1.2.3.4"})
    assert network_side.request_side(away) == "outside"

    bad = client.post(_ADDRESSES, json={"url": "nas.home.example.com"})
    assert bad.status_code == 400 and "http://" in bad.json()["message"]

    removed = client.post(f"{_ADDRESSES}/remove", json={"url": "https://nas.home.example.com"})
    assert removed.status_code == 200
    assert "https://nas.home.example.com" not in _urls(removed.json()["data"])
    missing = client.post(f"{_ADDRESSES}/remove", json={"url": "https://nope.example.com"})
    assert missing.status_code == 404


def test_members_can_read_but_not_change_addresses(client):
    created = client.post("/api/v1/members", json=_MEMBER)
    assert created.status_code == 200, created.text
    client.cookies.clear()
    assert client.post(f"{_AUTH}/login", json=_MEMBER).status_code == 200
    # 成员的请求不教地址簿：学到的地址会发给全家的 App 去连，成员能自己写 X-Forwarded-Host
    client.get(f"{_AUTH}/me", headers={"X-Forwarded-Host": "relay.attacker.example"})
    client.get(f"{_AUTH}/me", headers={"Host": "192.168.1.66:3000"})
    time.sleep(0.3)
    learned = _urls(_addresses(client))
    assert not any("attacker" in url or "192.168.1.66" in url for url in learned), learned
    assert client.post(_ADDRESSES, json={"url": "http://192.168.1.9"}).status_code == 403
    removed = client.post(f"{_ADDRESSES}/remove", json={"url": "http://192.168.1.9"})
    assert removed.status_code == 403
    client.cookies.clear()
    assert client.get(_ADDRESSES).status_code == 401


def test_lan_subnets_skip_non_ipv4_lan_addresses():
    from movieclaw_api.services.server_addresses import AddressView

    views = [
        AddressView(url="http://192.168.1.10:3300", kind="lan", source="learned"),
        AddressView(url="http://192.168.1.11", kind="lan", source="manual"),
        AddressView(url="https://nas.home.example.com", kind="lan", source="manual"),
        AddressView(url="https://movie.example.com", kind="wan", source="configured"),
    ]
    assert lan_subnets(views) == ["192.168.1.0/24"]


# ---------------------------------------------------------------------------
# 主机签名
# ---------------------------------------------------------------------------


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def test_health_proof_verifies_with_the_published_host_key(client):
    data = _addresses(client)
    public = Ed25519PublicKey.from_public_bytes(_unb64(data["host_key"]))
    nonce = "n0nce-AbCdEf_1234567"
    anonymous = TestClient(client.app)
    health = anonymous.get("/api/v1/health", params={"nonce": nonce}).json()
    assert health["instance_id"] == data["instance_id"]
    public.verify(_unb64(health["proof"]), host_key.proof_message(health["instance_id"], nonce))

    # 同一把密钥：重启后（缓存清掉、从库里读回）签名照样验得过
    host_key.reset_state()
    again = anonymous.get("/api/v1/health", params={"nonce": nonce}).json()
    public.verify(_unb64(again["proof"]), host_key.proof_message(again["instance_id"], nonce))

    assert anonymous.get("/api/v1/health").json().get("proof") is None
    bad = anonymous.get("/api/v1/health", params={"nonce": "short"}).json()
    assert bad.get("proof") is None, "不合格的随机串不签"
