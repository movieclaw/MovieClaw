"""Webhook 管理 API 测试：secret 一次性明文/打码/密文落库、目录下发、测试发送。"""

from __future__ import annotations

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.webhook import deliveries, delivery
from movieclaw_db.engine import get_database

BASE = "/api/v1/webhook"


@pytest.fixture
def client(tmp_path, monkeypatch):
    db_file = tmp_path / "test.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_file}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    deliveries.clear_deliveries()

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app) as c:
        yield c
    deliveries.clear_deliveries()
    get_settings.cache_clear()


def _create_endpoint(client: TestClient, **overrides) -> dict:
    endpoint = {
        "name": "Yamtrack",
        "url": "http://yamtrack.lan/hook",
        "format": "movieclaw",
        "enabled": True,
        "events": ["playback.started", "playback.completed"],
    }
    endpoint.update(overrides)
    resp = client.put(BASE, json={"enabled": True, "endpoints": [endpoint]})
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


async def test_create_reveals_secret_once_and_encrypts_at_rest(client: TestClient):
    data = _create_endpoint(client)
    created = data["endpoints"][0]
    secret = created["secret"]
    assert secret and secret.startswith("mcwh_")
    assert created["secret_masked"].endswith("****")

    # 再读：只有打码值，没有明文
    shown = client.get(BASE).json()["data"]["endpoints"][0]
    assert shown["secret"] is None
    assert shown["secret_masked"] == created["secret_masked"]

    # 落库为密文：value_json 里不出现明文 secret
    async with get_database().session() as session:
        row = (
            await session.execute(
                text("SELECT value_json FROM app_setting WHERE namespace = 'webhook'")
            )
        ).scalar_one()
    assert secret not in row
    assert "enc::" in row


def test_catalog_delivered_with_config(client: TestClient):
    catalog = client.get(BASE).json()["data"]["catalog"]
    events = {entry["event"] for entry in catalog}
    assert {"playback.started", "library.item.favorited"} <= events
    groups = {entry["group"] for entry in catalog}
    assert {"播放", "收藏"} <= groups


def test_unknown_event_rejected(client: TestClient):
    resp = client.put(
        BASE,
        json={
            "enabled": True,
            "endpoints": [{"name": "x", "url": "http://a", "events": ["no.such"]}],
        },
    )
    assert resp.status_code == 400
    assert "未知的订阅事件" in resp.json()["message"]


def test_edit_preserves_secret(client: TestClient):
    created = _create_endpoint(client)["endpoints"][0]
    resp = client.put(
        BASE,
        json={
            "enabled": True,
            "endpoints": [
                {
                    "id": created["id"],
                    "name": "更名后",
                    "url": created["url"],
                    "format": "movieclaw",
                    "events": ["playback.started"],
                }
            ],
        },
    )
    updated = resp.json()["data"]["endpoints"][0]
    assert updated["id"] == created["id"]
    assert updated["secret"] is None  # 编辑不再返回明文
    assert updated["secret_masked"] == created["secret_masked"]  # 密钥未变


def test_format_switch_to_movieclaw_generates_secret(client: TestClient):
    """jellyfin endpoint 切换为 movieclaw 时必须补发签名密钥（一次性明文返回），
    否则会静默发出无签名报文。"""
    created = _create_endpoint(
        client, format="jellyfin", events=["playback.started"], template="{{NotificationType}}"
    )["endpoints"][0]
    assert created["secret"] is None and created["secret_masked"] == ""

    resp = client.put(
        BASE,
        json={
            "enabled": True,
            "endpoints": [
                {
                    "id": created["id"],
                    "name": created["name"],
                    "url": created["url"],
                    "format": "movieclaw",
                    "events": ["playback.started"],
                }
            ],
        },
    )
    switched = resp.json()["data"]["endpoints"][0]
    assert switched["id"] == created["id"]
    assert switched["secret"] and switched["secret"].startswith("mcwh_")
    assert switched["secret_masked"].endswith("****")


def test_jellyfin_endpoint_rejects_unmappable_events(client: TestClient):
    """订阅域事件没有 Jellyfin 对应物，jellyfin 格式 endpoint 保存时即拒绝。"""
    resp = client.put(
        BASE,
        json={
            "enabled": True,
            "endpoints": [
                {
                    "name": "y",
                    "url": "http://a",
                    "format": "jellyfin",
                    "events": ["playback.started", "subscription.fulfilled"],
                }
            ],
        },
    )
    assert resp.status_code == 400
    assert "没有 Jellyfin 对应物" in resp.json()["message"]


def test_rotate_secret(client: TestClient):
    created = _create_endpoint(client)["endpoints"][0]
    resp = client.post(f"{BASE}/endpoints/{created['id']}/rotate-secret")
    assert resp.status_code == 200
    rotated = resp.json()["data"]
    assert rotated["secret"] and rotated["secret"] != created["secret"]
    assert rotated["secret_masked"] != created["secret_masked"]


def test_endpoint_not_found_is_404(client: TestClient):
    resp = client.post(f"{BASE}/endpoints/nonexistent/test")
    assert resp.status_code == 404


def test_send_test_and_deliveries(client: TestClient, monkeypatch):
    created = _create_endpoint(client)["endpoints"][0]

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["X-MovieClaw-Event"] == "webhook.test"
        return httpx.Response(200)

    monkeypatch.setattr(
        delivery,
        "egress_transport",
        lambda service, **kwargs: httpx.MockTransport(handler),
    )
    result = client.post(f"{BASE}/endpoints/{created['id']}/test").json()["data"]
    assert result["ok"] is True and result["event"] == "webhook.test"

    records = client.get(f"{BASE}/endpoints/{created['id']}/deliveries").json()["data"]
    assert len(records) == 1 and records[0]["ok"] is True

    # 列表页的最近投递状态也随之出现
    shown = client.get(BASE).json()["data"]["endpoints"][0]
    assert shown["last_delivery"]["ok"] is True
