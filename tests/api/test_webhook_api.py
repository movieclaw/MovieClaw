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
    with TestClient(app, headers={"Accept-Language": "zh-Hans"}) as c:
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


def test_catalog_languages_preserve_event_facts_and_plugin_titles(client, monkeypatch):
    from types import SimpleNamespace

    from movieclaw_api.services.webhook import catalog
    from movieclaw_sdk.events import core_events

    builtins = list(core_events())
    facts = [(e.name, e.title, e.group, e.high_frequency) for e in builtins]
    plugin = SimpleNamespace(name="acme.custom", title="播放", group="播放", high_frequency=False)
    monkeypatch.setattr(catalog, "event_types", lambda: {e.name: e for e in [*builtins, plugin]})
    assert {e.name for e in builtins} == catalog._BUILTIN_TEXT.keys()
    snapshots = []
    for language in ("en", "zh-Hans", "en"):
        rows = client.get(BASE, headers={"Accept-Language": language}).json()["data"]["catalog"]
        assert rows[-1]["label"] == rows[-1]["group"] == "播放"
        snapshots.append(rows)
    assert snapshots[0] == snapshots[2]
    assert snapshots[0][0]["label"] == "Device signed in"
    assert [(r["event"], r["label"], r["group"]) for r in snapshots[1][:-1]] == [
        fact[:3] for fact in facts
    ]
    for english, chinese in zip(snapshots[0], snapshots[1], strict=True):
        assert {k: v for k, v in english.items() if k not in {"label", "group"}} == {
            k: v for k, v in chinese.items() if k not in {"label", "group"}
        }
    assert facts == [(e.name, e.title, e.group, e.high_frequency) for e in builtins]


def test_delivery_reasons_render_at_read_without_rewriting_records(client):
    endpoint = _create_endpoint(client)["endpoints"][0]
    record = deliveries.DeliveryRecord(
        event_id="raw-event",
        event="playback.started",
        status_code=503,
        error="目标返回 HTTP 503",
        error_key="settings.webhook.errors.http",
        error_params={"status": 503},
    )
    deliveries.record_delivery(endpoint["id"], record)
    for language, expected in (
        ("en", "Destination returned HTTP 503"),
        ("zh-Hans", "目标返回 HTTP 503"),
        ("en", "Destination returned HTTP 503"),
    ):
        headers = {"Accept-Language": language}
        rows = client.get(f"{BASE}/endpoints/{endpoint['id']}/deliveries", headers=headers).json()[
            "data"
        ]
        view = client.get(BASE, headers=headers).json()["data"]["endpoints"][0]
        assert rows[0]["error"] == view["last_delivery"]["error"] == expected
        assert rows[0]["event_id"] == "raw-event" and rows[0]["status_code"] == 503
    assert record.error == "目标返回 HTTP 503"
    assert record.error_params == {"status": 503}
    legacy = deliveries.DeliveryRecord(
        event_id="legacy", event="acme.custom", error="目标返回 HTTP 503"
    )
    deliveries.record_delivery(endpoint["id"], legacy)
    rows = client.get(
        f"{BASE}/endpoints/{endpoint['id']}/deliveries", headers={"Accept-Language": "en"}
    ).json()["data"]
    assert rows[0]["error"] == legacy.error


def test_test_delivery_creates_localizable_failure_and_keeps_raw_exception(client, monkeypatch):
    endpoint = _create_endpoint(client)["endpoints"][0]

    def refused(request):
        raise httpx.ConnectError("Raw failure 原始错误", request=request)

    monkeypatch.setattr(
        delivery, "egress_transport", lambda *args, **kwargs: httpx.MockTransport(refused)
    )
    response = client.post(
        f"{BASE}/endpoints/{endpoint['id']}/test", headers={"Accept-Language": "en"}
    )
    assert response.status_code == 200
    row = response.json()["data"]
    assert row["error"] == "Request failed: Raw failure 原始错误"
    assert row["status_code"] is None and not row["ok"]
    chinese = client.get(f"{BASE}/endpoints/{endpoint['id']}/deliveries").json()["data"][0]
    assert chinese["error"] == "请求失败：Raw failure 原始错误"


@pytest.mark.parametrize(
    ("template", "english", "chinese"),
    [
        (
            "{{unknown Name}}",
            "Unsupported template helper: unknown",
            "模板使用了不支持的助手：unknown",
        ),
        (
            "{{#unknown Name}}x{{/unknown}}",
            "Unsupported block helper: unknown",
            "模板使用了不支持的块助手：unknown",
        ),
        (
            "{{/if_exist}}",
            "Closing tag {{/if_exist}} does not match",
            "模板的闭合标签 {{/if_exist}} 与当前打开的块不匹配",
        ),
        ("{{else}}", "Template tag {{else}} is outside", "模板的 {{else}} 不在任何块助手内"),
        (
            "{{#if_exist Name}}x{{else}}y{{else}}z{{/if_exist}}",
            "Duplicate {{else}}",
            "同一个块助手里出现了重复的 {{else}}",
        ),
        ("{{#if_exist Name}}x", "Unclosed template block helper", "模板存在未闭合的块助手"),
    ],
)
def test_template_errors_keep_references_through_formatter(client, template, english, chinese):
    endpoint = _create_endpoint(
        client, format="jellyfin", events=["playback.stopped"], template=template
    )["endpoints"][0]
    path = f"{BASE}/endpoints/{endpoint['id']}"
    response = client.post(path + "/test", headers={"Accept-Language": "en"})
    assert response.status_code == 200
    error = response.json()["data"]["error"]
    assert error.startswith("Template rendering failed: ") and english in error
    raw = client.get(path + "/deliveries").json()["data"][0]
    assert raw["error"].startswith("模板渲染失败：") and chinese in raw["error"]
    reread = client.get(path + "/deliveries", headers={"Accept-Language": "en"}).json()["data"][0]
    assert reread["error"] == error and reread["event_id"] == raw["event_id"]
