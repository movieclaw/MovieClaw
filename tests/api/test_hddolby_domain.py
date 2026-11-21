"""高清杜比（HDDolby）域名迁移端到端回归测试（issue #1304）。

构造真实用户场景：旧域名 www.hddolby.com 不可达（ConnectTimeout），新域名
www.uhddolby.com 可达。端到端验证：
1. 站点目录返回新域名；
2. 设置页连通性测试（POST /api/v1/network/test, service=site:hddolby）探测新域名并通过；
3. 手动添加站点（POST /api/v1/sites）走真实 verify_site 访问新域名并验证为 active；
4. 浏览器扩展列表与 Cookie 推送（/api/v1/extension/*）按 uhddolby.com 匹配并验证通过。
"""

from __future__ import annotations

import httpx
import pytest
from fastapi.testclient import TestClient

import movieclaw_api.services.network_config as network_config
import movieclaw_tracker.http as tracker_http
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import Principal, reset_auth_state
from movieclaw_api.services.network_egress import reset_network_egress
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_tracker.ratelimit import reset_limiters

_HDDOLBY_PROFILE_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>UHDDolby :: userdetails</title></head>
<body>
  <table id="info_block">
    <tr>
      <td>
        <a href="userdetails.php?id=9527" class="PowerUser_Name"><b>dolby_user</b></a>
        <font class="color_ratio">分享率:</font> 3.50
        <font class="color_uploaded">上传量:</font> 2.50 TB
        <font class="color_downloaded">下载量:</font> 730.00 GB
        <font class="color_bonus">鲸币:</font> 12,345.6
        <img class="arrowup" alt="seeding" /> 18
        <img class="arrowdown" alt="leeching" /> 1
      </td>
    </tr>
  </table>
</body>
</html>
"""


@pytest.fixture
def e2e_env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'hddolby.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    reset_network_egress()
    reset_limiters()

    recorded: list[tuple[str, httpx.Request]] = []

    def make_transport(service: str, **kwargs) -> httpx.MockTransport:
        def handler(request: httpx.Request) -> httpx.Response:
            recorded.append((service, request))
            if request.url.host == "www.hddolby.com":
                raise httpx.ConnectTimeout("old domain unreachable", request=request)
            if request.url.host == "www.uhddolby.com":
                if request.url.path == "/userdetails.php":
                    return httpx.Response(200, text=_HDDOLBY_PROFILE_HTML)
                if request.url.path == "/login.php":
                    return httpx.Response(
                        200, text="<title>UHDDolby :: 登录 - Powered by NexusPHP</title>"
                    )
                return httpx.Response(
                    302, headers={"location": "https://www.uhddolby.com/login.php"}
                )
            return httpx.Response(404)

        return httpx.MockTransport(handler)

    monkeypatch.setattr(network_config, "egress_transport", make_transport)
    monkeypatch.setattr(tracker_http, "egress_transport", make_transport)

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app, headers={"Accept-Language": "zh-Hans"}) as client:
        yield client, recorded

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    reset_network_egress()
    reset_limiters()
    get_settings.cache_clear()


def test_hddolby_ping_add_and_extension_sync_e2e(e2e_env) -> None:
    client, recorded = e2e_env

    # 1. 目录暴露新域名
    catalog = client.get("/api/v1/sites/catalog").json()["data"]
    hddolby = next(item for item in catalog if item["site_id"] == "hddolby")
    assert hddolby["base_url"] == "https://www.uhddolby.com"

    # 2. 网络连通性测试（ping site:hddolby）探测新域名并成功
    ping_resp = client.post("/api/v1/network/test", json={"service": "site:hddolby"})
    assert ping_resp.status_code == 200, ping_resp.text
    assert ping_resp.json()["data"]["ok"] is True
    assert recorded[0][0] == "site:hddolby"
    assert str(recorded[0][1].url) == "https://www.uhddolby.com"
    assert str(recorded[-1][1].url) == "https://www.uhddolby.com/login.php"

    # 3. 手动添加站点并跑真实 verify_site：请求新域名 userdetails.php 并转为 active
    add_resp = client.post(
        "/api/v1/sites",
        json={
            "site_id": "hddolby",
            "auth_type": "cookie",
            "cookie": "c_secure_uid=9527; c_secure_pass=ok",
        },
    )
    assert add_resp.status_code == 200, add_resp.text
    site_detail = client.get("/api/v1/sites/hddolby").json()["data"]
    assert site_detail["status"] == "active", site_detail
    assert site_detail["profile"]["username"] == "dolby_user"
    assert any(
        service == "site:hddolby"
        and str(req.url) == "https://www.uhddolby.com/userdetails.php"
        for service, req in recorded
    )

    # 4. 浏览器扩展站点列表与 Cookie 推送均命中 uhddolby.com
    token = client.post("/api/v1/extension/token").json()["data"]["token"]
    headers = {"Authorization": f"Bearer {token}"}

    ext_sites = client.get("/api/v1/extension/sites", headers=headers).json()["data"]
    ext_hddolby = next(item for item in ext_sites if item["site_id"] == "hddolby")
    assert ext_hddolby["domain"] == "uhddolby.com"
    assert ext_hddolby["usable"] is True

    # 避免两次真实请求间触发 5s 站级限流等待
    reset_limiters()

    push_resp = client.post(
        "/api/v1/extension/cookies",
        headers=headers,
        json={
            "domain": "www.uhddolby.com",
            "cookie": "c_secure_uid=9527; c_secure_pass=refreshed",
        },
    )
    assert push_resp.status_code == 200, push_resp.text
    assert push_resp.json()["data"]["site_id"] == "hddolby"
    refreshed = client.get("/api/v1/sites/hddolby").json()["data"]
    assert refreshed["status"] == "active", refreshed
