"""模型目录接口的端到端测试（docs/design/llm-model-catalog.md）。

真实数据库、真实接口与服务层；供应商协议换成可编排列表的假协议，公共目录用
用例内构造的固定快照（不随每周同步的随包快照漂移），上游 models.dev 用替身。
覆盖：兼容端点免手填参数接入、列表合并与默认显示、显示/隐藏、手动刷新与失败
退路、升级前裸 id 设定的改写、公共目录 ETag 刷新与坏数据作废、隐藏模型照常路由。
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import llm_catalog
from movieclaw_api.settings import reset_setting_store
from movieclaw_llm import ChatResponse, LlmRequestError, ProviderInfo
from movieclaw_llm.base import BaseLlmProtocol
from movieclaw_llm.protocols import PROTOCOLS

#: 假协议 /models 的行为：条目列表，或要抛出的异常
_listing: dict = {"entries": [], "error": None}
_chats: list[tuple[str, str]] = []


class _FakeProtocol(BaseLlmProtocol):
    async def chat(self, request, model_id):
        _chats.append((self.config.name, model_id))
        return ChatResponse(content="pong", finish_reason="stop")

    async def chat_stream(self, request, model_id):  # pragma: no cover
        yield None

    async def test_connection(self) -> ProviderInfo:
        if _listing["error"] is not None:
            raise _listing["error"]
        entries = _listing["entries"]
        return ProviderInfo(models=[e["id"] for e in entries], entries=entries)

    async def close(self) -> None:
        pass


def _raw(date: str, **over) -> dict:
    return {
        "name": over.pop("name", "M"),
        "tool_call": True,
        "reasoning": False,
        "release_date": date,
        "modalities": {"input": ["text"], "output": ["text"]},
        "limit": {"context": 131072, "output": 8192},
        **over,
    }


_PUBLIC = {
    "relay-cn": {
        "name": "某中转",
        "api": "https://relay.example.cn/v1",
        "fetched_at": "2026-10-01T00:00:00Z",
        "models": {
            "org/new-chat": _raw("2026-10-20", name="New Chat"),
            "org/old-chat": _raw("2025-01-01"),
            "org/retired": _raw("2026-09-01", status="deprecated"),
            "org/embed": _raw("2026-10-21", type="embedding"),
            "org/thinker": _raw(
                "2026-10-10",
                reasoning=True,
                reasoning_options=[{"type": "effort", "values": ["low", "high"]}],
            ),
        },
    },
}


@pytest.fixture
def catalog_dirs(tmp_path):
    bundled = tmp_path / "bundled"
    bundled.mkdir()
    for cid, data in _PUBLIC.items():
        (bundled / f"{cid}.json").write_text(json.dumps(data), encoding="utf-8")
    index = [{"id": cid, "name": d["name"], "api": d["api"]} for cid, d in _PUBLIC.items()]
    (bundled / "_index.json").write_text(json.dumps(index), encoding="utf-8")
    cache = tmp_path / "cache"
    llm_catalog.set_public_catalog(llm_catalog.PublicCatalog(bundled, cache))
    return bundled, cache


@pytest.fixture
def client(tmp_path, monkeypatch, catalog_dirs):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    reset_setting_store()
    _listing.update(entries=[], error=None)
    _chats.clear()
    monkeypatch.setitem(PROTOCOLS, "openai_chat", _FakeProtocol)
    monkeypatch.setitem(PROTOCOLS, "openai_responses", _FakeProtocol)

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app, headers={"Accept-Language": "zh-Hans"}) as c:
        yield c
    get_settings.cache_clear()


_RELAY = {
    "name": "中转",
    "provider_type": "openai_compat",
    "base_url": "https://relay.example.cn/v1",
    "api_key": "sk-relay",
    "default_model": "org/new-chat",
}


def _ids(entries: list[str]) -> list[dict]:
    return [{"id": e} for e in entries]


def _connect(c, **over) -> dict:
    r = c.post("/api/v1/llm/providers", json={**_RELAY, **over})
    assert r.status_code == 200, r.text
    return r.json()["data"]


def _menu(c, **params) -> dict[str, dict]:
    r = c.get("/api/v1/llm/models", params=params)
    assert r.status_code == 200, r.text
    return {o["model_id"]: o for o in r.json()["data"]}


def test_compat_endpoint_connects_without_manual_params_and_lists_menu(client):
    """填一个公共目录查得到的测试模型即可接入；菜单只有参数已知、合格、未停用的模型。"""
    _listing["entries"] = _ids(
        ["org/new-chat", "org/old-chat", "org/retired", "org/embed", "org/thinker", "local/x"]
    )
    created = _connect(client)
    assert created["default_model"] == "org/new-chat"

    menu = _menu(client)
    assert list(menu) == ["org/new-chat", "org/thinker", "org/old-chat"]
    new = menu["org/new-chat"]
    assert new["ref"] == "中转/org/new-chat"
    assert new["display_name"] == "New Chat" and new["context_window"] == 131072
    assert menu["org/thinker"]["thinking_levels"] == ["low", "high"]
    # 全部已知模型：停用的也在（照常可选），只是不显示；嵌入模型与参数未知的都不在
    everything = _menu(client, all="true")
    assert everything["org/retired"]["shown"] is False
    assert everything["org/retired"]["deprecated"] is True
    assert "org/embed" not in everything and "local/x" not in everything

    (provider,) = client.get("/api/v1/llm/providers").json()["data"]
    listing = provider["listing"]
    assert listing["source"] == "provider" and listing["error"] is None
    assert listing["catalog_id"] == "relay-cn"  # 按端点地址自动识别
    assert (listing["total"], listing["shown"]) == (4, 3)
    assert "org/new-chat" in provider["available_models"]  # 旧客户端仍读它

    detail = client.get(f"/api/v1/llm/providers/{created['id']}/models").json()["data"]
    unknown = next(m for m in detail if m["model"]["id"] == "local/x")
    assert unknown["known"] is False and unknown["shown"] is False
    assert next(m for m in detail if m["model"]["id"] == "org/new-chat")["model"]["sources"] == [
        "public"
    ]


def test_unknown_test_model_still_requires_params_and_catalog_can_be_disabled(client):
    r = client.post("/api/v1/llm/providers", json={**_RELAY, "default_model": "local/x"})
    assert r.status_code == 400
    assert "至少要补录一个模型" in r.json()["message"]
    # 明确「不使用」公共目录：连查得到的模型也要手填
    r = client.post("/api/v1/llm/providers", json={**_RELAY, "catalog_id": "none"})
    assert r.status_code == 400
    r = client.post("/api/v1/llm/providers", json={**_RELAY, "catalog_id": "nope"})
    assert r.status_code == 400
    assert "不在公共模型目录里" in r.json()["message"]


def test_visibility_show_hide_unknown_and_pinned_default(client):
    _listing["entries"] = _ids(["org/new-chat", "org/old-chat", "org/retired", "local/x"])
    created = _connect(client)
    pid = created["id"]

    def toggle(model_id, shown):
        return client.post(
            f"/api/v1/llm/providers/{pid}/models/visibility",
            json={"model_id": model_id, "shown": shown},
        )

    assert toggle("org/retired", True).status_code == 200
    assert toggle("org/old-chat", False).status_code == 200
    menu = _menu(client)
    assert "org/retired" in menu and "org/old-chat" not in menu
    r = toggle("local/x", True)
    assert r.status_code == 400 and "参数未知" in r.json()["message"]
    assert toggle("ghost", True).status_code == 404
    # AI 设定引用的模型隐藏了也照样在菜单里
    assert toggle("org/new-chat", False).status_code == 200
    assert "org/new-chat" in _menu(client)
    # 改回与默认规则一致时不再存这一项
    assert toggle("org/old-chat", True).status_code == 200
    toggle("org/retired", False)
    (provider,) = client.get("/api/v1/llm/providers").json()["data"]
    assert provider["listing"]["shown"] == 2


def test_refresh_picks_up_new_models_and_failure_keeps_old_list(client):
    _listing["entries"] = _ids(["org/new-chat"])
    created = _connect(client)
    pid = created["id"]
    assert list(_menu(client)) == ["org/new-chat"]

    _listing["entries"] = _ids(["org/new-chat", "org/thinker"])
    r = client.post(f"/api/v1/llm/providers/{pid}/models/refresh")
    assert r.status_code == 200, r.text
    assert r.json()["data"]["listing"]["total"] == 2
    assert "org/thinker" in _menu(client)

    _listing["error"] = LlmRequestError(
        "模型服务返回错误（HTTP 500）",
        message_key="errors.llm.connection.http",
        params={"status": 500, "detail": "boom"},
    )
    listing = client.post(f"/api/v1/llm/providers/{pid}/models/refresh").json()["data"]["listing"]
    assert listing["source"] == "provider" and listing["error"]
    assert "org/thinker" in _menu(client)  # 失败保留旧列表

    _listing["error"] = LlmRequestError(
        "模型服务返回错误（HTTP 404）",
        message_key="errors.llm.connection.http",
        params={"status": 404, "detail": "no route"},
    )
    listing = client.post(f"/api/v1/llm/providers/{pid}/models/refresh").json()["data"]["listing"]
    assert listing["source"] == "unsupported"
    # 端点不提供列表：退回补录 + 预设 + 连接测试模型，AI 设定引用的模型仍在
    assert list(_menu(client)) == ["org/new-chat"]
    defaults = client.get("/api/v1/llm/defaults").json()["data"]
    assert defaults["agent_model"] == "中转/org/new-chat"


def test_legacy_bare_default_is_rewritten_to_qualified_ref(client):
    """升级前存的裸 id 设定：读取时改写成「实例名/模型id」并落库，不被重置成别的模型。"""
    _listing["entries"] = _ids(["org/new-chat", "org/old-chat"])
    _connect(client)
    import asyncio

    from movieclaw_api.settings import LlmDefaultsSetting, get_setting_store

    asyncio.run(
        get_setting_store().set(
            LlmDefaultsSetting(agent_model="org/old-chat", subtitle_model="org/new-chat")
        )
    )
    data = client.get("/api/v1/llm/defaults").json()["data"]
    assert data["agent_model"] == "中转/org/old-chat"
    assert data["subtitle_model"] == "中转/org/new-chat"


def test_hidden_model_still_routes(client):
    """菜单只管显示：隐藏的模型显式选用照常调用。"""
    _listing["entries"] = _ids(["org/new-chat", "org/old-chat"])
    created = _connect(client)
    client.post(
        f"/api/v1/llm/providers/{created['id']}/models/visibility",
        json={"model_id": "org/old-chat", "shown": False},
    )
    import asyncio

    from movieclaw_api.services.llm_config import acquire_llm_router
    from movieclaw_db.engine import get_database
    from movieclaw_llm import ChatMessage, ChatRequest

    async def call() -> None:
        async with get_database().session() as session:
            router = await acquire_llm_router(session)
        await router.chat(
            ChatRequest(
                model="中转/org/old-chat", messages=[ChatMessage(role="user", content="hi")]
            )
        )

    asyncio.run(call())
    assert _chats[-1] == ("中转", "org/old-chat")


def test_public_catalog_refresh_etag_and_corrupt_upstream(client, catalog_dirs, monkeypatch):
    _, cache = catalog_dirs
    _listing["entries"] = _ids(["org/new-chat", "org/brand-new"])
    _connect(client)
    assert "org/brand-new" not in _menu(client, all="true")  # 快照里还没有

    upstream = {
        "relay-cn": {
            "name": "某中转",
            "api": "https://relay.example.cn/v1",
            "models": {**_PUBLIC["relay-cn"]["models"], "org/brand-new": _raw("2026-10-29")},
        }
    }
    calls: list[dict] = []

    async def fake_fetch(url, headers):
        calls.append(headers)
        if headers.get("If-None-Match") == '"v1"':
            return 304, None, b""
        return 200, '"v1"', json.dumps(upstream).encode()

    monkeypatch.setattr(llm_catalog, "_fetch", fake_fetch)
    import asyncio

    asyncio.run(llm_catalog.refresh_all(force=True))
    assert "org/brand-new" in _menu(client)
    assert (cache / "relay-cn.json").exists()
    version = llm_catalog.get_public_catalog().version
    asyncio.run(llm_catalog.refresh_all(force=True))
    assert calls[-1] == {"If-None-Match": '"v1"'}
    assert llm_catalog.get_public_catalog().version == version  # 304：没有变化

    async def corrupt(url, headers):
        return 200, '"v2"', json.dumps({"relay-cn": {"models": []}}).encode()

    monkeypatch.setattr(llm_catalog, "_fetch", corrupt)
    asyncio.run(llm_catalog.refresh_all(force=True))
    assert "org/brand-new" in _menu(client)  # 坏数据整次作废，保留原缓存


def test_catalog_providers_index(client):
    data = client.get("/api/v1/llm/catalog/providers").json()["data"]
    assert data == [{"id": "relay-cn", "name": "某中转", "api": "https://relay.example.cn/v1"}]
