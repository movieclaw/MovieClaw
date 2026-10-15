"""网页搜索设置：验证通过才落库、脱敏、测试连接，以及配好之后才装配工具。"""

from __future__ import annotations

import logging
import sqlite3

import httpx
import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.settings import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import dispose_db, init_db
from movieclaw_db.migrations import run_migrations

_KEY = "tvly-test-key-1234"


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("AGENT_WORKSPACE_DIR", str(tmp_path / "ws"))
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    monkeypatch.setattr("movieclaw_agent.web_search.http.RETRY_DELAY_SECONDS", 0)
    _install(monkeypatch, _ok)

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app) as test_client:
        yield test_client, tmp_path / "test.db"
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()


def _ok(_request: httpx.Request) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "results": [
                {"title": "Inception", "url": "https://example.com/inception", "content": "2010"}
            ],
            "web": {
                "results": [
                    {
                        "title": "Inception",
                        "url": "https://example.com/inception",
                        "description": "2010",
                    }
                ]
            },
        },
    )


def _install(monkeypatch, handler):
    monkeypatch.setattr(
        "movieclaw_api.services.web_search_config.search_transport",
        lambda **_kwargs: httpx.MockTransport(handler),
    )


def _stored(db_file) -> str:
    row = (
        sqlite3.connect(db_file)
        .execute(
            "SELECT value_json FROM app_setting WHERE namespace = ?",
            ("agent.web_search",),
        )
        .fetchone()
    )
    assert row is not None
    return row[0]


def test_unconfigured_view_lists_providers_and_has_no_key(client):
    http, _db = client
    data = http.get("/api/v1/llm/web-search").json()["data"]
    assert data["configured"] is False
    assert data["provider"] is None
    assert data["key_hint"] == ""
    assert [item["id"] for item in data["providers"]] == ["tavily", "exa", "brave"]
    assert "api_key" not in data


def test_save_encrypts_the_key_and_responses_only_show_the_hint(client, caplog):
    http, db_file = client
    with caplog.at_level(logging.INFO):
        response = http.put(
            "/api/v1/llm/web-search",
            json={"provider": "tavily", "api_key": _KEY},
        )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["configured"] is True
    assert data["provider"] == "tavily"
    assert data["key_hint"] == "1234"
    assert _KEY not in response.text
    stored = _stored(db_file)
    assert _KEY not in stored
    assert "enc::" in stored
    assert _KEY not in caplog.text

    again = http.get("/api/v1/llm/web-search")
    assert _KEY not in again.text
    assert again.json()["data"]["key_hint"] == "1234"


def test_blank_key_keeps_the_saved_secret_and_switching_provider_requires_a_new_one(
    client, monkeypatch
):
    http, db_file = client
    http.put("/api/v1/llm/web-search", json={"provider": "tavily", "api_key": _KEY})
    kept = http.put("/api/v1/llm/web-search", json={"provider": "tavily", "api_key": ""})
    assert kept.status_code == 200, kept.text
    assert kept.json()["data"]["key_hint"] == "1234"
    assert _KEY not in kept.text

    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.headers["authorization"])
        return httpx.Response(200, json={"results": []})

    _install(monkeypatch, handler)
    tested = http.post("/api/v1/llm/web-search/test", json={"provider": "tavily"})
    assert tested.status_code == 200, tested.text
    assert seen == [f"Bearer {_KEY}"]

    stored = _stored(db_file)
    rejected = http.put("/api/v1/llm/web-search", json={"provider": "exa"})
    assert rejected.status_code == 400
    assert "新的密钥" in rejected.json()["message"]
    assert _stored(db_file) == stored


def test_clear_removes_the_key_and_disables_the_tool_flag(client):
    http, db_file = client
    http.put("/api/v1/llm/web-search", json={"provider": "brave", "api_key": _KEY})
    response = http.delete("/api/v1/llm/web-search")
    assert response.status_code == 200
    assert response.json()["data"]["configured"] is False
    assert _KEY not in _stored(db_file)


def test_connection_test_does_not_save_and_reports_a_sample(client, monkeypatch):
    http, _db = client

    def handler(request: httpx.Request) -> httpx.Response:
        assert _KEY not in str(request.url)
        assert request.headers["authorization"] == f"Bearer {_KEY}"
        return httpx.Response(
            200,
            json={
                "results": [
                    {
                        "title": "Inception",
                        "url": "https://example.com/inception",
                        "content": "2010",
                    }
                ]
            },
        )

    _install(monkeypatch, handler)
    response = http.post(
        "/api/v1/llm/web-search/test",
        json={"provider": "tavily", "api_key": _KEY},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["data"]["sample_title"] == "Inception"
    assert "连接成功" in body["data"]["message"]
    assert _KEY not in response.text
    assert http.get("/api/v1/llm/web-search").json()["data"]["configured"] is False


def test_rejected_key_is_explained_without_saving(client, monkeypatch):
    http, _db = client

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"error": f"nope {_KEY}"})

    _install(monkeypatch, handler)
    response = http.post(
        "/api/v1/llm/web-search/test",
        json={"provider": "tavily", "api_key": _KEY},
    )
    assert response.status_code == 400
    assert "API Key 无效" in response.json()["message"]
    # 人就在设置页上，不再叫人「到设置 → AI 设定里核对」
    assert "设置 →" not in response.json()["message"]
    assert _KEY not in response.text
    assert http.get("/api/v1/llm/web-search").json()["data"]["configured"] is False


def test_save_rejects_a_bad_key_and_keeps_the_previous_one(client, monkeypatch):
    http, db_file = client
    saved = http.put("/api/v1/llm/web-search", json={"provider": "tavily", "api_key": _KEY})
    assert saved.status_code == 200, saved.text
    stored = _stored(db_file)

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(401)

    _install(monkeypatch, handler)
    bad_key = "tvly-wrong-key-9999"
    response = http.put("/api/v1/llm/web-search", json={"provider": "tavily", "api_key": bad_key})
    assert response.status_code == 400
    assert "API Key 无效" in response.json()["message"]
    assert bad_key not in response.text
    assert _stored(db_file) == stored
    assert http.get("/api/v1/llm/web-search").json()["data"]["key_hint"] == "1234"


def test_save_network_failure_does_not_create_a_config(client, monkeypatch):
    http, _db = client

    def handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    _install(monkeypatch, handler)
    response = http.put("/api/v1/llm/web-search", json={"provider": "tavily", "api_key": _KEY})
    assert response.status_code == 502
    assert response.json()["code"] == "UPSTREAM_UNREACHABLE"
    assert "网页搜索" in response.json()["message"]
    assert http.get("/api/v1/llm/web-search").json()["data"]["configured"] is False


def test_network_failure_points_at_the_proxy_setting(client, monkeypatch):
    http, _db = client

    def handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    _install(monkeypatch, handler)
    response = http.post(
        "/api/v1/llm/web-search/test",
        json={"provider": "exa", "api_key": _KEY},
    )
    assert response.status_code == 502
    assert response.json()["code"] == "UPSTREAM_UNREACHABLE"
    assert "网页搜索" in response.json()["message"]


@pytest.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'tool.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("AGENT_WORKSPACE_DIR", str(tmp_path / "ws"))
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    from movieclaw_api.settings.store import init_setting_store
    from movieclaw_db.crypto import init_secret_box

    init_secret_box(None, tmp_path / ".secret_key")
    init_setting_store()
    yield
    await dispose_db()
    reset_setting_store()
    reset_secret_box()
    get_settings.cache_clear()


async def test_tool_is_registered_only_after_the_provider_is_saved(db, monkeypatch):
    from movieclaw_api.api.routes.agent import _profile_tools, get_agent_tools
    from movieclaw_api.services.web_search_config import (
        clear_web_search,
        load_web_search_provider,
        save_web_search,
    )

    monkeypatch.setattr(
        "movieclaw_api.services.web_search_config.search_transport",
        lambda **_kwargs: httpx.MockTransport(_ok),
    )
    assert await load_web_search_provider() is None
    bare = get_agent_tools({})
    assert "web_search" not in {tool.name for tool in bare}
    none_tools = await _profile_tools("none", "s", None)
    assert none_tools == []

    await save_web_search(provider="tavily", api_key=_KEY)
    provider = await load_web_search_provider()
    assert provider is not None and provider.id == "tavily"
    web_tools = await _profile_tools("web", "s", None)
    names = {tool.name for tool in web_tools}
    assert "web_search" in names
    from movieclaw_agent.tools.media_ui import TOOL_NAME as media_ui_tool

    assert media_ui_tool in names

    from movieclaw_api.services.channel_agent import _restricted_tools

    restricted = await _restricted_tools("s", "telegram")
    names = {tool.name for tool in restricted}
    assert "web_search" in names
    assert "bash" not in names
    assert media_ui_tool not in names

    await clear_web_search()
    assert await load_web_search_provider() is None
    cleared = await _profile_tools("full", "s", None)
    assert "web_search" not in {tool.name for tool in cleared}


async def test_unreadable_config_drops_the_tool_without_breaking_the_turn(
    db, tmp_path, monkeypatch
):
    """存的供应商后来不支持了：本轮只是没有搜索，其他工具照常装配。"""
    from movieclaw_api.api.routes.agent import _profile_tools
    from movieclaw_api.services.web_search_config import load_web_search_provider, save_web_search
    from movieclaw_api.settings.store import init_setting_store

    monkeypatch.setattr(
        "movieclaw_api.services.web_search_config.search_transport",
        lambda **_kwargs: httpx.MockTransport(_ok),
    )
    await save_web_search(provider="tavily", api_key=_KEY)
    with sqlite3.connect(tmp_path / "tool.db") as conn:
        conn.execute(
            "UPDATE app_setting SET value_json = json_set(value_json, '$.provider', 'retired')"
            " WHERE namespace = ?",
            ("agent.web_search",),
        )
    reset_setting_store()
    init_setting_store()

    assert await load_web_search_provider() is None
    names = {tool.name for tool in await _profile_tools("web", "s", None)}
    assert "web_search" not in names
    assert "bash" in names
