"""site.proxy.request（站点代请求）的测试。

覆盖三块：
1. 纯函数校验（路径 / 头黑名单 / 正文截断）——直接调用 schemas 里的函数；
2. 路由层行为——monkeypatch ``get_site_access`` 返回假 BaseSite（客户端 mock 掉网络），
   断言 409/404/400 语义、认证头剥除、响应脱敏；
3. 真实网络一律不出（假客户端只回内存构造的 httpx.Response）。
"""

from __future__ import annotations

import json as jsonlib
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

import movieclaw_api.api.routes.sites as sites_routes
from movieclaw_api.core.config import get_settings
from movieclaw_api.schemas.site import (
    PROXY_FORBIDDEN_REQUEST_HEADERS,
    join_proxy_url,
    proxy_base_url,
    proxy_path_error,
    proxy_response_text,
    sanitize_proxy_headers,
    sanitize_proxy_response_headers,
)
from movieclaw_tracker import load_all_sites
from movieclaw_tracker.registry import get_site_config

load_all_sites()  # 纯函数部分要用注册表里的真实站点配置（mteam/hdsky）


# ---------------------------------------------------------------------------
# 1. 纯函数
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "path",
    [
        "attendance.php",
        "/attendance.php",
        "/api/member/updateLastBrowse",
        "index.php?cool=1",
        "/foo.php?a=1&b=2",
        "a/b/c.php",
        "./relative.php",
    ],
)
def test_proxy_path_error_accepts_site_relative(path: str) -> None:
    assert proxy_path_error(path) is None


@pytest.mark.parametrize(
    "path",
    [
        "//evil.com/x",  # 协议相对
        "https://evil.com/x",  # 带协议
        "http://169.254.169.254/latest/meta-data",  # 内网元数据地址
        "",  # 空
        "  ",  # 空白
        "a\\b.php",  # 反斜杠
        "a\r\nb.php",  # CRLF 注入
        "a\tb.php",
    ],
)
def test_proxy_path_error_rejects(path: str) -> None:
    assert proxy_path_error(path) is not None


def test_proxy_same_origin_guards_host() -> None:
    from movieclaw_api.schemas.site import join_proxy_url as join
    from movieclaw_api.schemas.site import proxy_same_origin

    base = "https://hdsky.me"
    assert proxy_same_origin(base, join(base, "attendance.php")) is True
    assert proxy_same_origin(base, join(base, "/a/b.php?x=1")) is True
    # 拼接后的路径被按站内路径处理（host 不变），但独立传入的换 host URL 必须拦下
    assert proxy_same_origin(base, "https://evil.com/x") is False
    assert proxy_same_origin(base, "http://hdsky.me/x") is False  # 协议降级也拦
    assert proxy_same_origin(base, "https://EVIL.example/x") is False


def test_sanitize_proxy_headers_strips_auth() -> None:
    headers = {
        "Cookie": "uid=1; pass=secret",
        "cookie": "again",
        "Authorization": "Bearer x",
        "X-API-Key": "k",
        "x-api-key": "k2",
        "Host": "evil.com",
        "Referer": "https://kp.m-team.cc/",
        "Content-Type": "application/json",
    }
    kept = sanitize_proxy_headers(headers)
    assert kept == {"Referer": "https://kp.m-team.cc/", "Content-Type": "application/json"}
    assert set(kept).isdisjoint({h.capitalize() for h in PROXY_FORBIDDEN_REQUEST_HEADERS})


def test_sanitize_proxy_response_headers_strips_session_headers() -> None:
    resp_headers = httpx.Headers(
        {
            "Content-Type": "text/html",
            "Set-Cookie": "c_secure_uid=1",
            "set-cookie": "c_secure_pass=2",
            "WWW-Authenticate": "Basic",
            "Location": "/index.php",
        }
    )
    kept = sanitize_proxy_response_headers(resp_headers)
    assert "content-type" in {k.lower() for k in kept}
    assert "location" in {k.lower() for k in kept}
    assert all(k.lower() != "set-cookie" for k in kept)
    assert all(k.lower() != "www-authenticate" for k in kept)
    assert all("secret" not in v and "pass" not in v.lower() for v in kept.values())


def test_proxy_response_text_truncates_large_text() -> None:
    big = "x" * (512 * 1024 + 100)
    text, truncated = proxy_response_text(big.encode(), "text/html; charset=utf-8")
    assert truncated is True
    assert text is not None and len(text) == 512 * 1024


def test_proxy_response_text_binary_returns_none() -> None:
    assert proxy_response_text(b"\x00\x01", "image/png") == (None, False)
    assert proxy_response_text(b"d5:f", "application/x-bittorrent") == (None, False)
    assert proxy_response_text(b"raw", "application/octet-stream") == (None, False)


def test_proxy_base_url_web_vs_api() -> None:
    mteam = get_site_config("mteam")  # web=tp.m-team.cc, api=api.m-team.cc
    hdsky = get_site_config("hdsky")  # 未配置 web_base_url，两者相同
    assert mteam is not None and hdsky is not None
    assert proxy_base_url(mteam, "web") == "https://tp.m-team.cc"
    assert proxy_base_url(mteam, "api") == "https://api.m-team.cc"
    assert proxy_base_url(hdsky, "web") == proxy_base_url(hdsky, "api")
    assert join_proxy_url("https://hdsky.me", "/attendance.php") == "https://hdsky.me/attendance.php"


# ---------------------------------------------------------------------------
# 2. 路由层（假站点会话）
# ---------------------------------------------------------------------------


class _FakeClient:
    """假 HttpClient：记录收到的请求并回放预设响应，绝不联网。"""

    def __init__(self, response: httpx.Response) -> None:
        self.response = response
        self.calls: list[dict[str, Any]] = []

    async def raw_request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        self.calls.append({"method": method, "url": url, **kwargs})
        return self.response


class _FakeSite:
    """假 BaseSite：只有 client 一个会被路由用到的属性。"""

    def __init__(self, client: _FakeClient) -> None:
        self.client = client


class _FakeAccess:
    def __init__(self, site: Any) -> None:
        self._site = site

    async def get(self, site_id: str) -> Any:
        return self._site


def _html_response(body: str, status: int = 200) -> httpx.Response:
    return httpx.Response(
        status,
        headers={"Content-Type": "text/html; charset=utf-8", "Set-Cookie": "c_secure_pass=leak"},
        content=body.encode(),
        request=httpx.Request("GET", "https://site.example/"),
    )


@pytest.fixture
def client(tmp_path, monkeypatch):
    db_file = tmp_path / "test.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_file}")
    get_settings.cache_clear()

    async def _fake_verify(site_id: str) -> None:  # 不触发真实网络验证
        return None

    monkeypatch.setattr(sites_routes, "verify_site", _fake_verify)

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app) as c:
        yield c
    get_settings.cache_clear()


def _install_fake_access(monkeypatch, response: httpx.Response) -> _FakeClient:
    fake_client = _FakeClient(response)
    fake_access = _FakeAccess(_FakeSite(fake_client))
    monkeypatch.setattr(sites_routes, "get_site_access", lambda: fake_access)
    return fake_client


def test_proxy_request_strips_auth_headers_and_cookies_in_response(client, monkeypatch) -> None:
    fake = _install_fake_access(monkeypatch, _html_response("<html>ok</html>"))
    r = client.post(
        "/api/v1/sites/hdsky/proxy",
        json={
            "method": "GET",
            "path": "attendance.php",
            "headers": {"Cookie": "x=1", "Authorization": "Bearer y", "Referer": "https://hdsky.me/"},
        },
    )
    assert r.status_code == 200, r.text
    data = r.json()["data"]
    assert data["status_code"] == 200
    assert data["text"] == "<html>ok</html>"
    # 请求侧：认证头被剥掉，非敏感头保留
    sent = fake.calls[0]
    assert sent["url"] == "https://hdsky.me/attendance.php"  # hdsky 未配 web 域名，web=api
    sent_headers = sent.get("headers") or {}
    assert "Cookie" not in sent_headers and "Authorization" not in sent_headers
    # 响应侧：set-cookie 不回传
    assert all(k.lower() != "set-cookie" for k in data["headers"])
    assert data["truncated"] is False


def test_proxy_request_api_base_uses_request_domain(client, monkeypatch) -> None:
    fake = _install_fake_access(
        monkeypatch,
        httpx.Response(
            200,
            headers={"Content-Type": "application/json"},
            content=jsonlib.dumps({"code": "1", "message": "FAIL", "data": None}).encode(),
            request=httpx.Request("POST", "https://api.m-team.cc/"),
        ),
    )
    r = client.post(
        "/api/v1/sites/mteam/proxy",
        json={
            "method": "POST",
            "path": "/api/member/updateLastBrowse",
            "base": "api",
            "body": {"_timestamp": 1, "_sgin": "sig"},
            "headers": {"x-api-key": "stolen"},
        },
    )
    assert r.status_code == 200, r.text
    data = r.json()["data"]
    assert data["json_body"] == {"code": "1", "message": "FAIL", "data": None}
    # x-api-key 被剥除；URL 用 api 域名
    sent = fake.calls[0]
    assert sent["url"] == "https://api.m-team.cc/api/member/updateLastBrowse"
    sent_headers = sent.get("headers") or {}
    assert all(k.lower() != "x-api-key" for k in sent_headers)
    # 字典体按 JSON 发
    assert sent.get("json") == {"_timestamp": 1, "_sgin": "sig"}


def test_proxy_request_passes_timeout_seconds_through(client, monkeypatch) -> None:
    # 字段不叫 timeout：它与 CLI 内置的 --timeout 重名，会让这条命令失去该标志
    fake = _install_fake_access(monkeypatch, _html_response("ok"))
    r = client.post(
        "/api/v1/sites/hdsky/proxy",
        json={"method": "GET", "path": "a.php", "timeout_seconds": 5},
    )
    assert r.status_code == 200, r.text
    assert fake.calls[0]["timeout"] == 5.0


def test_proxy_request_does_not_follow_redirects(client, monkeypatch) -> None:
    """站点回 3xx 时不跟随，原样返回：认证头只发给校验过的那一个 URL。

    站点客户端默认跟随跳转，x-api-key 又挂在客户端的默认头上；站点若有开放重定向，
    跟到外站就会把 key 带出去（httpx 跨域跳转只剥 Authorization / Cookie）。
    这里用真的站点客户端（只把传输层换成内存桩）验证，而不是只看传参。"""
    from movieclaw_tracker.http import HttpClient

    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if request.url.host == "hdsky.me":
            return httpx.Response(302, headers={"Location": "https://evil.example/collect"})
        return httpx.Response(200, text="不该被请求到")

    site_client = HttpClient(
        headers={"x-api-key": "site-secret"}, transport=httpx.MockTransport(handler)
    )
    monkeypatch.setattr(
        sites_routes, "get_site_access", lambda: _FakeAccess(_FakeSite(site_client))
    )

    r = client.post("/api/v1/sites/hdsky/proxy", json={"method": "GET", "path": "out.php?to=1"})

    assert r.status_code == 200, r.text
    data = r.json()["data"]
    assert data["status_code"] == 302
    headers = {k.lower(): v for k, v in data["headers"].items()}
    assert headers["location"] == "https://evil.example/collect"
    assert [req.url.host for req in seen] == ["hdsky.me"], "不能向跳转目标发出任何请求"
    assert seen[0].headers["x-api-key"] == "site-secret"  # 宿主会话的认证头照常附加


def test_proxy_request_is_marked_dangerous(client) -> None:
    """能以用户的站点身份发任意 POST：CLI 要 --yes，插件要逐个声明（通配不覆盖）。"""
    spec = client.app.openapi()
    operation = spec["paths"]["/api/v1/sites/{site_id}/proxy"]["post"]
    assert operation["x-cli-dangerous"] == "confirm"


def test_proxy_request_rejects_bad_path_and_unknown_site(client) -> None:
    r1 = client.post(
        "/api/v1/sites/hdsky/proxy", json={"method": "GET", "path": "//evil.com/x"}
    )
    assert r1.status_code == 400
    r2 = client.post(
        "/api/v1/sites/hdsky/proxy", json={"method": "GET", "path": "https://evil.com/x"}
    )
    assert r2.status_code == 400
    r3 = client.post(
        "/api/v1/sites/hdsky/proxy", json={"method": "GET", "path": "a\\b.php"}
    )
    assert r3.status_code == 400
    r4 = client.post(
        "/api/v1/sites/nope-site/proxy", json={"method": "GET", "path": "a.php"}
    )
    assert r4.status_code == 404


def test_proxy_request_site_unavailable_conflict(client, monkeypatch) -> None:
    from movieclaw_api.services.site_access import SiteUnavailableError

    class _NoAccess:
        async def get(self, site_id: str) -> Any:
            raise SiteUnavailableError(f"站点尚未验证通过（当前状态 failed）：{site_id}")

    monkeypatch.setattr(sites_routes, "get_site_access", lambda: _NoAccess())
    r = client.post("/api/v1/sites/hdsky/proxy", json={"method": "GET", "path": "a.php"})
    assert r.status_code == 409
    assert "尚未验证通过" in r.json()["message"]


def test_proxy_request_network_error_503(client, monkeypatch) -> None:
    class _BoomClient:
        async def raw_request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
            raise httpx.ConnectError("no route")

    class _BoomAccess:
        async def get(self, site_id: str) -> Any:
            return _FakeSite(_BoomClient())  # type: ignore[arg-type]

    monkeypatch.setattr(sites_routes, "get_site_access", lambda: _BoomAccess())
    r = client.post("/api/v1/sites/hdsky/proxy", json={"method": "GET", "path": "a.php"})
    assert r.status_code == 503
