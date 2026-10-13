"""LLM 供应商实例接口的端到端测试。

覆盖：多实例增删改查、默认实例不变量、保存后异步验证的状态流转、API Key
脱敏与落库加密、预设列表、base_url 必填校验，以及对话框模型清单的重复 id
策略。真实协议实现被替换为假协议，不发真实请求，使状态流转可确定性断言。
"""

from __future__ import annotations

import json
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.settings import reset_setting_store
from movieclaw_llm import ChatResponse, LlmConnectError, ProviderInfo
from movieclaw_llm.base import BaseLlmProtocol
from movieclaw_llm.models import LlmProviderConfig
from movieclaw_llm.protocols import PROTOCOLS

# 假协议行为开关：key 含 "bad" 时模拟连不上；含 "nolist" 时模拟无 /models 接口
_BAD_KEY_MARK = "bad"
_NO_LIST_MARK = "nolist"

# 每次验证收到的领域配置，供断言"传给协议层的 key 已解密"
_captured_configs: list[LlmProviderConfig] = []
# 每次验证实际走的协议实现（假协议类名），供断言实例协议选择生效
_captured_protocols: list[str] = []


class _FakeProtocol(BaseLlmProtocol):
    """假协议：跳过真实网络，按 api_key 决定测试结果。"""

    async def chat(self, request, model_id):
        _captured_configs.append(self.config)
        _captured_protocols.append(type(self).__name__)
        if _BAD_KEY_MARK in self.config.api_key:
            raise LlmConnectError("连接模型服务失败，请检查网络与 base_url 配置")
        return ChatResponse(content="pong", finish_reason="stop")

    async def chat_stream(self, request, model_id):  # pragma: no cover
        yield None

    async def test_connection(self) -> ProviderInfo:
        if _NO_LIST_MARK in self.config.api_key:
            raise LlmConnectError("该端点不提供模型列表接口")
        return ProviderInfo(models=["qwen-plus", "qwen-max"])

    async def close(self) -> None:
        pass


class _FakeResponsesProtocol(_FakeProtocol):
    """Responses 协议的替身：行为同 _FakeProtocol，只靠类名区分走了哪套协议。"""


@pytest.fixture
def client(tmp_path, monkeypatch):
    # 每个测试用独立临时 SQLite 库与密钥文件，保证隔离
    db_file = tmp_path / "test.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_file}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()

    # 用假协议替换 openai_chat 协议实现
    # 配置存储是进程级单例且带缓存，用例间必须重置，否则上一个用例的 AI 设定会串进来
    reset_setting_store()
    _captured_configs.clear()
    _captured_protocols.clear()
    monkeypatch.setitem(PROTOCOLS, "openai_chat", _FakeProtocol)
    monkeypatch.setitem(PROTOCOLS, "openai_responses", _FakeResponsesProtocol)

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    # 本文件只测 LLM 配置业务，登录鉴权用依赖覆盖绕过（鉴权本身在 test_auth 覆盖）
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app) as c:  # with 块内触发 lifespan：建库、迁移、初始化加密器
        yield c, db_file
    get_settings.cache_clear()


_PAYLOAD = {
    "name": "百炼",
    "provider_type": "bailian",
    "api_key": "sk-live-123456",
    "default_model": "qwen3.7-max",
}


def _list(c) -> list[dict]:
    r = c.get("/api/v1/llm/providers")
    assert r.status_code == 200, r.text
    return r.json()["data"]


def _first(c) -> dict | None:
    """默认实例（列表首项）；一个都没有时 None。"""
    rows = _list(c)
    return rows[0] if rows else None


def test_list_before_configured_returns_empty(client) -> None:
    c, _ = client
    assert _list(c) == []
    assert c.get("/api/v1/llm/models").json()["data"] == []


def test_save_then_async_verify_active_and_desensitized(client) -> None:
    c, _ = client
    r = c.post("/api/v1/llm/providers", json=_PAYLOAD)
    assert r.status_code == 200
    data = r.json()["data"]
    # 接口立即返回 verifying（同步占位），绝不回传 API Key
    assert data["status"] == "verifying"
    assert "api_key" not in data

    # TestClient 的 BackgroundTasks 在响应后同步执行完毕 → 再查已是终态
    detail = _first(c)
    assert detail["status"] == "active"
    assert detail["usable"] is True
    assert detail["last_error"] is None
    assert detail["last_checked_at"] is not None
    assert detail["available_models"] == ["qwen-max", "qwen-plus"]

    # 传给协议层的 key 是解密后的明文（证明加密→解密链路正确）
    assert _captured_configs[-1].api_key == "sk-live-123456"
    # base_url 留空 → 领域配置也留空（由预设提供百炼默认端点）
    assert _captured_configs[-1].base_url is None
    assert _captured_configs[-1].default_model == "qwen3.7-max"


def test_api_key_encrypted_at_rest(client) -> None:
    c, db_file = client
    c.post("/api/v1/llm/providers", json=_PAYLOAD)

    # 直接读 SQLite 文件核实落库形态：密文带 enc:: 前缀，不含明文
    row = sqlite3.connect(db_file).execute("SELECT api_key FROM llm_provider").fetchone()
    assert row[0].startswith("enc::")
    assert "sk-live-123456" not in row[0]


def test_bad_key_marked_failed_with_chinese_error(client) -> None:
    c, _ = client
    c.post("/api/v1/llm/providers", json={**_PAYLOAD, "api_key": "sk-bad-key"})
    detail = _first(c)
    assert detail["status"] == "failed"
    assert detail["usable"] is False
    assert "连接模型服务失败" in detail["last_error"]


def test_model_list_failure_does_not_affect_verdict(client) -> None:
    c, _ = client
    c.post("/api/v1/llm/providers", json={**_PAYLOAD, "api_key": "sk-nolist-key"})
    detail = _first(c)
    # 对话验证通过即 active；模型列表拉不到只是没有提示数据
    assert detail["status"] == "active"
    assert detail["available_models"] is None


# 自定义端点的完整请求体：default_model 带齐参数配置
_COMPAT_PAYLOAD = {
    "name": "家里的 vLLM",
    "provider_type": "openai_compat",
    "base_url": "http://192.168.1.5:8000/v1",
    "api_key": "sk-vllm",
    "default_model": "my-local-model",
    "extra_models": [
        {
            "id": "my-local-model",
            "context_window": 131072,
            "max_output_tokens": 8192,
            "supports_tools": True,
        }
    ],
}


def test_multiple_instances(client) -> None:
    """可同时接入多家，按添加顺序列出。"""
    c, db_file = client
    c.post("/api/v1/llm/providers", json=_PAYLOAD)
    c.post("/api/v1/llm/providers", json=_COMPAT_PAYLOAD)
    rows = sqlite3.connect(db_file).execute("SELECT COUNT(*) FROM llm_provider").fetchone()
    assert rows[0] == 2
    assert [r["name"] for r in _list(c)] == ["百炼", "家里的 vLLM"]
    detail = _list(c)[1]
    assert detail["provider_type"] == "openai_compat"
    assert detail["base_url"] == "http://192.168.1.5:8000/v1"
    # 自定义模型目录随配置持久化，参数完整回传（设置页的数据源）
    assert detail["extra_models"][0]["id"] == "my-local-model"
    assert detail["extra_models"][0]["context_window"] == 131072


def test_test_model_defaults_to_first_catalog_entry(client) -> None:
    """接入时不选模型：连接测试模型自动取目录第一个（预设目录 / 自定义目录）。"""
    c, _ = client
    payload = {k: v for k, v in _PAYLOAD.items() if k != "default_model"}
    created = c.post("/api/v1/llm/providers", json=payload).json()["data"]
    presets = {p["id"]: p for p in c.get("/api/v1/llm/presets").json()["data"]}
    assert created["default_model"] == presets["bailian"]["models"][0]["id"]
    assert _captured_configs[-1].default_model == created["default_model"]
    compat = {k: v for k, v in _COMPAT_PAYLOAD.items() if k != "default_model"}
    created = c.post("/api/v1/llm/providers", json=compat).json()["data"]
    assert created["default_model"] == "my-local-model"


def test_ai_defaults_auto_set_on_first_provider_then_configured(client) -> None:
    """AI 设定的不变量：一个实例都没有时为空；首次接入自动把两个默认设为该实例
    目录第一个模型（显式写入设定，不是隐式兜底）；之后用户各用途独立改；
    被引用的实例删除时自动改指最早剩下的实例；全部删除时清空。"""
    c, _ = client
    assert c.get("/api/v1/llm/defaults").json()["data"] == {
        "agent_model": None,
        "subtitle_model": None,
        "effective_agent_model": None,
        "effective_subtitle_model": None,
    }
    # 首次接入（不指定测试模型）：默认 = 预设目录第一个模型，且是显式存下来的值
    first_payload = {k: v for k, v in _PAYLOAD.items() if k != "default_model"}
    bailian = c.post("/api/v1/llm/providers", json=first_payload).json()["data"]
    presets = {p["id"]: p for p in c.get("/api/v1/llm/presets").json()["data"]}
    flagship = presets["bailian"]["models"][0]["id"]
    defaults = c.get("/api/v1/llm/defaults").json()["data"]
    assert defaults == {
        "agent_model": flagship,
        "subtitle_model": flagship,
        "effective_agent_model": flagship,
        "effective_subtitle_model": flagship,
    }
    # 再接一家不改动已有设定
    compat = c.post("/api/v1/llm/providers", json=_COMPAT_PAYLOAD).json()["data"]
    assert c.get("/api/v1/llm/defaults").json()["data"]["agent_model"] == flagship

    r = c.put(
        "/api/v1/llm/defaults",
        json={"agent_model": "my-local-model", "subtitle_model": "qwen3.7-max"},
    )
    assert r.status_code == 200, r.text
    data = r.json()["data"]
    assert data["agent_model"] == "my-local-model"
    assert data["effective_agent_model"] == "my-local-model"
    assert data["effective_subtitle_model"] == "qwen3.7-max"
    # 模型清单里的 is_default 跟随智能体默认模型
    options = {o["ref"]: o for o in c.get("/api/v1/llm/models").json()["data"]}
    assert options["my-local-model"]["is_default"] is True
    assert options["qwen3.7-max"]["is_default"] is False

    # 引用不在清单里 → 400
    r = c.put("/api/v1/llm/defaults", json={"agent_model": "nope"})
    assert r.status_code == 400
    assert "不在已接入供应商的模型清单中" in r.json()["message"]
    # 传 null = 回到自动推荐（最早实例的第一个模型），不会清空
    r = c.put("/api/v1/llm/defaults", json={"agent_model": None, "subtitle_model": "qwen3.7-max"})
    assert r.json()["data"]["agent_model"] == flagship

    # 删除被引用的实例：改指最早剩下实例的第一个模型（显式改写，不是隐式兜底）
    c.put(
        "/api/v1/llm/defaults",
        json={"agent_model": "my-local-model", "subtitle_model": "qwen3.7-max"},
    )
    assert c.delete(f"/api/v1/llm/providers/{bailian['id']}").status_code == 200
    data = c.get("/api/v1/llm/defaults").json()["data"]
    assert data["agent_model"] == "my-local-model"  # 仍有效，不动
    assert data["subtitle_model"] == "my-local-model"  # 原指百炼，改指剩下的兼容端点
    # 全部删除 → 清空
    assert c.delete(f"/api/v1/llm/providers/{compat['id']}").status_code == 200
    assert c.get("/api/v1/llm/defaults").json()["data"]["agent_model"] is None


def test_duplicate_name_rejected(client) -> None:
    c, _ = client
    assert c.post("/api/v1/llm/providers", json=_PAYLOAD).status_code == 200
    r = c.post("/api/v1/llm/providers", json={**_COMPAT_PAYLOAD, "name": "百炼"})
    assert r.status_code == 409
    assert "已被使用" in r.json()["message"]


def test_name_with_slash_rejected(client) -> None:
    """实例名是「实例名/模型id」路由引用的前半段，含斜杠会破坏解析。"""
    c, _ = client
    r = c.post("/api/v1/llm/providers", json={**_PAYLOAD, "name": "a/b"})
    assert r.status_code == 422


def test_update_instance_reverifies(client) -> None:
    c, _ = client
    created = c.post("/api/v1/llm/providers", json=_PAYLOAD).json()["data"]
    r = c.put(
        f"/api/v1/llm/providers/{created['id']}",
        json={**_PAYLOAD, "name": "百炼-改名", "api_key": "sk-updated"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["data"]["status"] == "verifying"
    detail = c.get(f"/api/v1/llm/providers/{created['id']}").json()["data"]
    assert detail["name"] == "百炼-改名"
    assert detail["status"] == "active"
    assert _captured_configs[-1].api_key == "sk-updated"
    assert _captured_configs[-1].name == "百炼-改名"


def test_create_requires_api_key(client) -> None:
    c, _ = client
    payload = {k: v for k, v in _PAYLOAD.items() if k != "api_key"}
    for body in (payload, {**payload, "api_key": "  "}):
        r = c.post("/api/v1/llm/providers", json=body)
        assert r.status_code == 400, r.text
        assert "API Key" in r.json()["message"]
    assert _list(c) == []


def test_update_blank_api_key_keeps_existing(client) -> None:
    """编辑只改名/模型时 API Key 留空（不传或空串）沿用原 Key。"""
    c, db_file = client
    created = c.post("/api/v1/llm/providers", json=_PAYLOAD).json()["data"]
    stored = sqlite3.connect(db_file).execute("SELECT api_key FROM llm_provider").fetchone()[0]
    payload = {k: v for k, v in _PAYLOAD.items() if k != "api_key"}
    for i, body in enumerate(
        ({**payload, "name": "百炼-a"}, {**payload, "name": "百炼-b", "api_key": ""})
    ):
        r = c.put(f"/api/v1/llm/providers/{created['id']}", json=body)
        assert r.status_code == 200, (i, r.text)
        assert _first(c)["status"] == "active"
        assert _captured_configs[-1].api_key == "sk-live-123456"
    # 密文原样未动（没有被重新加密成别的值）
    row = sqlite3.connect(db_file).execute("SELECT name, api_key FROM llm_provider").fetchone()
    assert row == ("百炼-b", stored)


def test_update_endpoint_change_requires_api_key(client) -> None:
    """改了端点或类型却不重填 Key → 400，防止已存的 Key 被发往新地址。"""
    c, _ = client
    created = c.post("/api/v1/llm/providers", json=_PAYLOAD).json()["data"]
    payload = {k: v for k, v in _PAYLOAD.items() if k != "api_key"}
    for body in (
        {**payload, "base_url": "https://evil.example.com/v1"},
        {**payload, "provider_type": "openai", "default_model": None},
    ):
        r = c.put(f"/api/v1/llm/providers/{created['id']}", json=body)
        assert r.status_code == 400, r.text
        assert "重新填写 API Key" in r.json()["message"]
    assert _first(c)["base_url"] is None
    # 端点、类型都没变 → 留空照常保存
    r = c.put(f"/api/v1/llm/providers/{created['id']}", json=payload)
    assert r.status_code == 200, r.text
    # 重填了 Key 就允许换端点
    r = c.put(
        f"/api/v1/llm/providers/{created['id']}",
        json={**payload, "base_url": "https://new.example.com/v1", "api_key": "sk-new"},
    )
    assert r.status_code == 200, r.text
    assert _captured_configs[-1].api_key == "sk-new"
    assert _captured_configs[-1].base_url == "https://new.example.com/v1"


def test_model_options_bare_ids_when_unique(client) -> None:
    """只有一家时清单里全是裸 id；智能体默认模型（未设定时兜底到测试模型）带 is_default。"""
    c, _ = client
    c.post("/api/v1/llm/providers", json=_PAYLOAD)
    options = c.get("/api/v1/llm/models").json()["data"]
    by_id = {o["model_id"]: o for o in options}
    assert "qwen3.7-max" in by_id
    assert by_id["qwen3.7-max"]["ref"] == "qwen3.7-max"
    assert by_id["qwen3.7-max"]["label"] == "qwen3.7-max"
    assert by_id["qwen3.7-max"]["is_default"] is True
    assert by_id["qwen3.7-max"]["provider_name"] == "百炼"
    assert sum(o["is_default"] for o in options) == 1
    # 目录里的其它模型也都可选（接入一家即可用它全部模型）
    assert len(options) > 1
    assert all(
        o["ref"] == (f"百炼/{o['model_id']}" if "/" in o["model_id"] else o["model_id"])
        for o in options
    )


def test_model_options_qualify_conflicting_ids(client) -> None:
    """同一模型 id 出现在两个实例：引用改为「实例名/模型id」、展示加括号；
    其它不冲突的 id 保持裸 id。"""
    c, _ = client
    c.post("/api/v1/llm/providers", json=_PAYLOAD)
    # 兼容端点借用百炼目录里的 qwen3.7-max（同 id）
    r = c.post(
        "/api/v1/llm/providers",
        json={
            **_COMPAT_PAYLOAD,
            "name": "中转",
            "default_model": "qwen3.7-max",
            "extra_models": [{"id": "qwen3.7-max", "context_window": 131072}],
        },
    )
    assert r.status_code == 200, r.text
    options = c.get("/api/v1/llm/models").json()["data"]
    conflicted = [o for o in options if o["model_id"] == "qwen3.7-max"]
    assert [(o["ref"], o["label"]) for o in conflicted] == [
        ("百炼/qwen3.7-max", "qwen3.7-max（百炼）"),
        ("中转/qwen3.7-max", "qwen3.7-max（中转）"),
    ]
    # 按添加顺序；未设定时兜底到第一个实例的测试模型，只有它标 is_default
    assert conflicted[0]["is_default"] is True
    assert conflicted[1]["is_default"] is False
    others = [o for o in options if o["model_id"] != "qwen3.7-max"]
    assert others and all(
        o["ref"]
        == (f"{o['provider_name']}/{o['model_id']}" if "/" in o["model_id"] else o["model_id"])
        and "（" not in o["label"]
        for o in others
    )


def test_cataloged_provider_rejects_model_outside_catalog(client) -> None:
    """严格规则：官方渠道只认预设目录，自定义模型即使带全参数也不行。"""
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={
            **_PAYLOAD,
            "default_model": "my-private-qwen",
            "extra_models": [
                {"id": "my-private-qwen", "context_window": 131072, "max_output_tokens": 8192}
            ],
        },
    )
    assert r.status_code == 400
    assert "不在「阿里云百炼」的模型目录中" in r.json()["message"]


def test_borrowed_catalog_model_exempt_from_manual_param_rules(client) -> None:
    """兼容端点借用目录模型（如 kimi 共享窗口、无独立输出上限）→ 豁免手填规则，可保存。"""
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={
            **_COMPAT_PAYLOAD,
            "default_model": "kimi-k2.5",
            "extra_models": [
                {
                    "id": "kimi-k2.5",
                    "context_window": 262144,
                    "supports_thinking": True,
                    "max_thinking_tokens": 81920,
                }
            ],
        },
    )
    assert r.status_code == 200
    detail = _first(c)
    assert detail["status"] == "active"
    assert detail["default_model"] == "kimi-k2.5"


def test_custom_endpoint_requires_at_least_one_model(client) -> None:
    """自定义端点一个模型都没补录 → 400（没有目录的实例接入了也无模型可用）。"""
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={**_COMPAT_PAYLOAD, "extra_models": []},
    )
    assert r.status_code == 400
    assert "至少要补录一个模型" in r.json()["message"]


def test_custom_test_model_must_be_in_catalog(client) -> None:
    """指定的连接测试模型不在自定义目录里 → 400，提示先补全参数。"""
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={**_COMPAT_PAYLOAD, "default_model": "ghost-model"},
    )
    assert r.status_code == 400
    assert "补全它的参数配置" in r.json()["message"]


def test_custom_model_missing_required_params_rejected(client) -> None:
    """自定义模型缺上下文/最大输出 → 400。"""
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={
            **_COMPAT_PAYLOAD,
            "extra_models": [{"id": "my-local-model", "context_window": 131072}],
        },
    )
    assert r.status_code == 400
    assert "上下文长度与最大输出为必填" in r.json()["message"]


def test_custom_budget_control_requires_budget(client) -> None:
    """预算分段控制没填思考预算 → 400；输出思考内容本身不要求预算参数。"""
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={
            **_COMPAT_PAYLOAD,
            "extra_models": [
                {
                    "id": "my-local-model",
                    "context_window": 131072,
                    "max_output_tokens": 8192,
                    "supports_thinking": True,
                    "thinking_control": {"kind": "budget", "supports_off": True},
                }
            ],
        },
    )
    assert r.status_code == 400
    assert "思考预算上限" in r.json()["message"]


def test_user_agent_defaults_to_sdk(client) -> None:
    """不填 User-Agent → 落库与领域配置都是 None，协议层保持 SDK 默认 UA。"""
    c, _ = client
    c.post("/api/v1/llm/providers", json=_COMPAT_PAYLOAD)
    assert _first(c)["user_agent"] is None
    assert _captured_configs[-1].user_agent is None


def test_custom_user_agent_persisted_and_passed_down(client) -> None:
    """填了 User-Agent → 回显在配置视图里，并原样传到协议层。"""
    c, _ = client
    ua = "movieclaw/1.0 (gateway-allowlist)"
    r = c.post("/api/v1/llm/providers", json={**_COMPAT_PAYLOAD, "user_agent": ua})
    assert r.status_code == 200
    assert _first(c)["user_agent"] == ua
    assert _captured_configs[-1].user_agent == ua


def test_blank_user_agent_normalized_to_null(client) -> None:
    """空串（用户清空输入框）归一为 None，等同「用 SDK 默认」。"""
    c, _ = client
    c.post("/api/v1/llm/providers", json={**_COMPAT_PAYLOAD, "user_agent": "   "})
    assert _first(c)["user_agent"] is None


def test_user_agent_rejects_header_injection(client) -> None:
    """换行等控制字符会造成请求头注入，入口即拦。"""
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={**_COMPAT_PAYLOAD, "user_agent": "ua\r\nX-Admin: 1"},
    )
    assert r.status_code == 422
    assert any("ASCII" in d["message"] for d in r.json()["details"])


_OPENAI_PAYLOAD = {"name": "官方", "provider_type": "openai", "api_key": "sk-openai"}


def test_openai_defaults_to_responses_protocol(client) -> None:
    """issue #768：OpenAI 预设不选协议即走 Responses API（带工具也能调思考强度）。"""
    c, _ = client
    r = c.post("/api/v1/llm/providers", json=_OPENAI_PAYLOAD)
    assert r.status_code == 200, r.text
    assert _first(c)["api_protocol"] is None
    assert _captured_protocols[-1] == "_FakeResponsesProtocol"


def test_compat_endpoint_can_switch_to_responses(client) -> None:
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers", json={**_COMPAT_PAYLOAD, "api_protocol": "openai_responses"}
    )
    assert r.status_code == 200, r.text
    assert _first(c)["api_protocol"] == "openai_responses"
    assert _captured_configs[-1].api_protocol == "openai_responses"
    assert _captured_protocols[-1] == "_FakeResponsesProtocol"


def test_protocol_not_selectable_for_fixed_presets(client) -> None:
    """百炼等国内端点只有 Chat Completions：不开放切换，传了就 400。"""
    c, _ = client
    r = c.post("/api/v1/llm/providers", json={**_PAYLOAD, "api_protocol": "openai_responses"})
    assert r.status_code == 400
    assert "不支持协议" in r.json()["message"]
    assert _list(c) == []


def test_update_without_protocol_field_keeps_stored_value(client) -> None:
    """不认识该字段的老客户端编辑实例：不传即沿用原值，显式 null 才回到预设默认。"""
    c, _ = client
    created = c.post(
        "/api/v1/llm/providers", json={**_OPENAI_PAYLOAD, "api_protocol": "openai_chat"}
    ).json()["data"]
    assert _captured_protocols[-1] == "_FakeProtocol"
    legacy = {k: v for k, v in _OPENAI_PAYLOAD.items() if k != "api_key"}
    r = c.put(f"/api/v1/llm/providers/{created['id']}", json={**legacy, "name": "官方-改名"})
    assert r.status_code == 200, r.text
    assert _first(c)["api_protocol"] == "openai_chat"
    assert _captured_protocols[-1] == "_FakeProtocol"
    r = c.put(f"/api/v1/llm/providers/{created['id']}", json={**legacy, "api_protocol": None})
    assert r.status_code == 200, r.text
    assert _first(c)["api_protocol"] is None
    assert _captured_protocols[-1] == "_FakeResponsesProtocol"


def test_openai_compat_requires_base_url(client) -> None:
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={"name": "x", "provider_type": "openai_compat", "api_key": "k", "default_model": "m"},
    )
    assert r.status_code == 400
    assert "必须填写 API 端点地址" in r.json()["message"]


def test_unknown_provider_type_rejected(client) -> None:
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={**_PAYLOAD, "provider_type": "gemini"},
    )
    assert r.status_code == 400
    assert "未知的供应商类型" in r.json()["message"]


def test_reverify_unknown_instance_404(client) -> None:
    c, _ = client
    r = c.post("/api/v1/llm/providers/999/verify")
    assert r.status_code == 404


def test_delete_then_list_empty(client) -> None:
    c, _ = client
    created = c.post("/api/v1/llm/providers", json=_PAYLOAD).json()["data"]
    r = c.delete(f"/api/v1/llm/providers/{created['id']}")
    assert r.status_code == 200
    assert _first(c) is None
    assert c.delete(f"/api/v1/llm/providers/{created['id']}").status_code == 404


def test_presets_endpoint(client) -> None:
    c, _ = client
    presets = {p["id"]: p for p in c.get("/api/v1/llm/presets").json()["data"]}
    assert {"openai", "bailian", "openai_compat"} <= set(presets)
    assert presets["bailian"]["base_url"] == "https://dashscope.aliyuncs.com/compatible-mode/v1"
    assert presets["openai_compat"]["requires_base_url"] is True
    # 协议选择器的数据源：默认协议 + 可切换列表（空 = 隐藏选择器）
    assert presets["openai"]["protocol"] == "openai_responses"
    assert presets["openai"]["selectable_protocols"] == ["openai_responses", "openai_chat"]
    assert presets["openai_compat"]["protocol"] == "openai_chat"
    assert presets["bailian"]["selectable_protocols"] == []
    assert any(m["id"] == "qwen3.7-max" for m in presets["bailian"]["models"])
    # SDK 自带 UA 按内部公式现算（AsyncOpenAI/Python x.y.z），设置页占位提示用
    import openai

    assert presets["openai"]["default_user_agent"] == f"AsyncOpenAI/Python {openai.__version__}"


def test_slash_model_id_is_always_qualified(client) -> None:
    """模型 id 本身含斜杠（org/model 风格）：不冲突也要用「实例名/模型id」引用，
    否则路由层会把 org 当实例名；展示仍是裸 id。"""
    c, _ = client
    r = c.post(
        "/api/v1/llm/providers",
        json={
            **_COMPAT_PAYLOAD,
            "name": "硅基",
            "default_model": None,
            "extra_models": [
                {
                    "id": "deepseek-ai/DeepSeek-V3",
                    "context_window": 131072,
                    "max_output_tokens": 8192,
                }
            ],
        },
    )
    assert r.status_code == 200, r.text
    options = {o["model_id"]: o for o in c.get("/api/v1/llm/models").json()["data"]}
    assert options["deepseek-ai/DeepSeek-V3"]["ref"] == "硅基/deepseek-ai/DeepSeek-V3"
    assert options["deepseek-ai/DeepSeek-V3"]["label"] == "deepseek-ai/DeepSeek-V3"
    # 首次接入自动设定的默认就是这个限定引用，且能解析
    defaults = c.get("/api/v1/llm/defaults").json()["data"]
    assert defaults["agent_model"] == "硅基/deepseek-ai/DeepSeek-V3"
    assert defaults["effective_agent_model"] == "硅基/deepseek-ai/DeepSeek-V3"


def test_defaults_follow_ref_respelling(client) -> None:
    """引用拼写随实例集合变化时，用户的设定按稳定身份改写而不是被重置：
    第二家借用同 id → 裸 id 变限定形式；实例改名 → 前半段跟着改；
    第二家删除 → 降回裸 id。"""
    c, _ = client
    bailian = c.post("/api/v1/llm/providers", json=_PAYLOAD).json()["data"]
    r = c.put("/api/v1/llm/defaults", json={"agent_model": "qwen3.7-plus"})
    assert r.status_code == 200, r.text
    # 中转也借用 qwen3.7-plus：设定应改写成「百炼/qwen3.7-plus」，而不是回到推荐默认
    relay = c.post(
        "/api/v1/llm/providers",
        json={
            **_COMPAT_PAYLOAD,
            "name": "中转",
            "default_model": None,
            "extra_models": [{"id": "qwen3.7-plus", "context_window": 131072}],
        },
    ).json()["data"]
    defaults = c.get("/api/v1/llm/defaults").json()["data"]
    assert defaults["agent_model"] == "百炼/qwen3.7-plus"
    # 百炼改名 → 引用前半段跟着改
    r = c.put(
        f"/api/v1/llm/providers/{bailian['id']}",
        json={**_PAYLOAD, "name": "百炼-主", "api_key": "sk-renamed"},
    )
    assert r.status_code == 200, r.text
    assert c.get("/api/v1/llm/defaults").json()["data"]["agent_model"] == "百炼-主/qwen3.7-plus"
    # 删除中转 → 不再冲突，降回裸 id
    assert c.delete(f"/api/v1/llm/providers/{relay['id']}").status_code == 200
    assert c.get("/api/v1/llm/defaults").json()["data"]["agent_model"] == "qwen3.7-plus"


def test_discover_draft_does_not_save_provider(client) -> None:
    c, _ = client
    response = c.post("/api/v1/llm/models/discover", json=_OPENAI_PAYLOAD)
    assert response.status_code == 200, response.text
    assert response.json()["data"] == ["qwen-max", "qwen-plus"]
    assert _list(c) == []
    assert "sk-openai" not in response.text


def test_discover_stored_key_cannot_be_forwarded_to_changed_endpoint(client) -> None:
    c, _ = client
    created = c.post("/api/v1/llm/providers", json=_OPENAI_PAYLOAD).json()["data"]
    draft = {**_OPENAI_PAYLOAD, "api_key": None, "provider_id": created["id"]}
    assert c.post("/api/v1/llm/models/discover", json=draft).status_code == 200
    response = c.post(
        "/api/v1/llm/models/discover", json={**draft, "base_url": "http://other.local/v1"}
    )
    assert response.status_code == 400
    assert "重新填写 API Key" in response.json()["message"]


def test_discover_unsupported_endpoint_keeps_manual_configuration(client) -> None:
    c, _ = client
    response = c.post(
        "/api/v1/llm/models/discover", json={**_OPENAI_PAYLOAD, "api_key": "sk-nolist"}
    )
    assert response.status_code == 400
    assert "手动添加" in response.json()["message"]
    assert _list(c) == []


def test_openai_custom_effort_model_does_not_require_thinking_output_or_budget(client) -> None:
    c, _ = client
    response = c.post(
        "/api/v1/llm/providers",
        json={
            **_OPENAI_PAYLOAD,
            "default_model": "my-finetuned-model",
            "extra_models": [
                {
                    "id": "my-finetuned-model",
                    "context_window": 131072,
                    "max_output_tokens": 8192,
                    "supports_thinking": False,
                    "thinking_control": {"kind": "effort", "levels": ["low", "high"]},
                }
            ],
        },
    )
    assert response.status_code == 200, response.text
    options = {o["model_id"]: o for o in c.get("/api/v1/llm/models").json()["data"]}
    assert options["my-finetuned-model"]["thinking_levels"] == ["low", "high"]
    assert c.get("/api/v1/llm/defaults").json()["data"]["agent_model"] == "my-finetuned-model"


def test_chat_configuration_excludes_responses_only_tools_and_limits_effort_menu(client) -> None:
    c, _ = client
    draft = {**_OPENAI_PAYLOAD, "api_protocol": "openai_chat"}
    rejected = c.post("/api/v1/llm/providers", json={**draft, "default_model": "gpt-6.1-sol"})
    assert rejected.status_code == 400
    created = c.post("/api/v1/llm/providers", json=draft)
    assert created.status_code == 200, created.text
    assert _first(c)["default_model"] == "gpt-6-sol"
    options = {o["model_id"]: o for o in c.get("/api/v1/llm/models").json()["data"]}
    assert "gpt-6-astra" not in options
    assert "gpt-6.1-sol" not in options
    assert options["gpt-6-luna"]["thinking_levels"] == ["off"]


@pytest.mark.parametrize("field", ["context_window", "max_output_tokens", "max_input_tokens"])
def test_custom_model_token_limits_must_be_positive(client, field) -> None:
    c, _ = client
    response = c.post(
        "/api/v1/llm/providers",
        json={
            **_COMPAT_PAYLOAD,
            "extra_models": [
                {
                    "id": "my-local-model",
                    "context_window": 131072,
                    "max_output_tokens": 8192,
                    field: -1,
                }
            ],
        },
    )
    assert response.status_code == 422


@pytest.fixture
def model_gateway():
    """本机上游：实际经过 HTTP 与 OpenAI SDK，不替换协议实现。"""
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, data, status=200):
            body = json.dumps(data).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            requests.append((self.path, None, self.headers.get("Authorization")))
            self.reply(
                {
                    "object": "list",
                    "data": [
                        {"id": "gpt-6-luna", "object": "model", "created": 0, "owned_by": "test"},
                        {
                            "id": "my-local-model",
                            "object": "model",
                            "created": 0,
                            "owned_by": "test",
                        },
                    ],
                }
            )

        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append((self.path, payload, self.headers.get("Authorization")))
            if self.path.endswith("/chat/completions"):
                assistants = [m for m in payload["messages"] if m["role"] == "assistant"]
                if (
                    payload["model"].startswith("deepseek")
                    and payload.get("tools")
                    and any(not m.get("reasoning_content") for m in assistants)
                ):
                    self.reply({"error": {"message": "reasoning_content required"}}, status=400)
                    return
                tool_turn = payload.get("tools") and not assistants
                message = {
                    "role": "assistant",
                    "content": "已连接",
                    "reasoning_content": "已检查用户提供的海报",
                }
                if tool_turn:
                    message["tool_calls"] = [
                        {
                            "id": "call_search",
                            "type": "function",
                            "function": {"name": "search", "arguments": '{"q":"沙丘"}'},
                        }
                    ]
                self.reply(
                    {
                        "id": "chat_test",
                        "object": "chat.completion",
                        "created": 0,
                        "model": payload["model"],
                        "choices": [
                            {
                                "index": 0,
                                "message": message,
                                "finish_reason": "tool_calls" if tool_turn else "stop",
                            }
                        ],
                        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
                    }
                )
                return
            self.reply(
                {
                    "id": "resp_test",
                    "object": "response",
                    "created_at": 0,
                    "status": "completed",
                    "model": payload["model"],
                    "output": [
                        {
                            "id": "msg_test",
                            "type": "message",
                            "role": "assistant",
                            "status": "completed",
                            "content": [
                                {"type": "output_text", "text": "已连接", "annotations": []}
                            ],
                        }
                    ],
                    "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
                }
            )

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/v1", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def test_discover_save_verify_and_edit_through_real_sdk(client, model_gateway, monkeypatch):
    """用户查询→选择→保存→测试→编辑沿用密钥，经过真实数据库与 HTTP 上游。"""
    from movieclaw_llm.protocols.openai_responses import OpenAIResponsesProtocol

    c, _ = client
    base_url, requests = model_gateway
    monkeypatch.setitem(PROTOCOLS, "openai_responses", OpenAIResponsesProtocol)
    draft = {**_OPENAI_PAYLOAD, "base_url": base_url}
    response = c.post("/api/v1/llm/models/discover", json=draft)
    assert response.status_code == 200, response.text
    assert response.json()["data"] == ["gpt-6-luna", "my-local-model"]
    assert _list(c) == []
    created = c.post("/api/v1/llm/providers", json={**draft, "default_model": "gpt-6-luna"})
    assert created.status_code == 200, created.text
    assert _first(c)["status"] == "active"
    assert c.get("/api/v1/llm/defaults").json()["data"]["agent_model"] == "gpt-6-luna"
    assert [r[0] for r in requests] == ["/v1/models", "/v1/responses", "/v1/models"]
    assert requests[1][1]["model"] == "gpt-6-luna"
    assert requests[1][1]["max_output_tokens"] == 16
    assert requests[1][1]["store"] is False
    assert all(r[2] == "Bearer sk-openai" for r in requests)
    provider_id = created.json()["data"]["id"]
    response = c.post(
        "/api/v1/llm/models/discover",
        json={
            **draft,
            "api_key": None,
            "provider_id": provider_id,
        },
    )
    assert response.status_code == 200, response.text
    updated = c.put(
        f"/api/v1/llm/providers/{provider_id}",
        json={
            **draft,
            "api_key": None,
            "default_model": "gpt-6-luna",
        },
    )
    assert updated.status_code == 200, updated.text
    assert _first(c)["default_model"] == "gpt-6-luna"
    from movieclaw_api.services.llm_config import LlmConfigService, to_domain_config
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository
    from movieclaw_llm import ChatMessage, ChatRequest, LlmRouter, ModelSettings, ToolDefinition

    async def call_configured_model():
        async with get_database().session() as session:
            row = await LlmConfigService(session).get(provider_id)
            key = LlmProviderRepository(session).decrypted_api_key(row)
            router = LlmRouter([to_domain_config(row, key)])
            try:
                return await router.chat(
                    ChatRequest(
                        model="官方/gpt-6.1-sol",
                        messages=[ChatMessage(role="user", content="查询电影")],
                        tools=[ToolDefinition(name="search", description="搜索", parameters={})],
                        settings=ModelSettings(thinking_level="high", temperature=0.5),
                    )
                )
            finally:
                await router.aclose()

    result = c.portal.call(call_configured_model)
    assert result.content == "已连接"
    assert requests[-1][0] == "/v1/responses"
    payload = requests[-1][1]
    assert payload["model"] == "gpt-6.1-sol"
    assert payload["tools"][0]["name"] == "search"
    assert payload["reasoning"]["effort"] == "high"
    assert "temperature" not in payload


@pytest.mark.parametrize(
    "provider,model_id,level,vision,reasoning",
    [
        ("bailian", "qwen3.8-omni-flash", "off", True, {"reasoning_effort": "none"}),
        ("deepseek", "deepseek-flash", "high", True, {"reasoning_effort": "high"}),
        ("deepseek", "deepseek-v4-pro", "off", False, {"thinking": {"type": "disabled"}}),
        ("kimi", "kimi-k3", "max", True, {"reasoning_effort": "max"}),
        ("kimi", "kimi-k2.7-code-highspeed", None, True, {}),
        ("glm", "glm-5.3-flashx", "high", True, {"reasoning_effort": "high"}),
        ("bailian", "MiniMax/MiniMax-M3", None, True, {}),
    ],
)
def test_provider_vision_and_tool_history_through_real_sdk(
    client,
    model_gateway,
    monkeypatch,
    tmp_path,
    provider,
    model_id,
    level,
    vision,
    reasoning,
):
    """配置→图片水合门控→真实 SDK→工具回放→答复，模型规格取实际保存的目录。"""
    from tests.api.test_agent_hydration import png_bytes

    from movieclaw_api.services.agent_attachments import AgentAttachmentStore, hydrate_images
    from movieclaw_api.services.llm_config import LlmConfigService, to_domain_config
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository
    from movieclaw_llm import (
        ChatMessage,
        ChatRequest,
        ImagePart,
        LlmRouter,
        ModelSettings,
        TextPart,
        ToolDefinition,
    )
    from movieclaw_llm.protocols.openai_chat import OpenAIChatProtocol

    c, _ = client
    gateway_url, upstream = model_gateway
    monkeypatch.setitem(PROTOCOLS, "openai_chat", OpenAIChatProtocol)
    created = c.post(
        "/api/v1/llm/providers",
        json={
            "name": "验证",
            "provider_type": provider,
            "api_key": "sk-local-test",
            "base_url": gateway_url,
            "default_model": model_id,
        },
    )
    assert created.status_code == 200, created.text
    assert _first(c)["status"] == "active"
    selected = next(
        o for o in c.get("/api/v1/llm/models").json()["data"] if o["model_id"] == model_id
    )

    async def run_scenario():
        async with get_database().session() as session:
            row = await LlmConfigService(session).get(created.json()["data"]["id"])
            key = LlmProviderRepository(session).decrypted_api_key(row)
            router = LlmRouter([to_domain_config(row, key)])
            store = AgentAttachmentStore(tmp_path / "attachments")
            meta = store.save_staging(png_bytes(), "海报.png")
            [bound] = store.bind("scene", [meta.attachment_id])
            try:
                info = router.get_model_info(selected["ref"])
                assert info.context_window and info.context_window >= 262144
                messages = await hydrate_images(
                    [
                        ChatMessage(
                            role="user",
                            content=[
                                TextPart(text="查询这张海报的电影"),
                                ImagePart(attachment_id=bound.attachment_id, name="海报.png"),
                            ],
                        ),
                    ],
                    session_id="scene",
                    model_info=info,
                    store=store,
                )
                request = ChatRequest(
                    model=selected["ref"],
                    messages=messages,
                    tools=[ToolDefinition(name="search", description="搜索影片", parameters={})],
                    settings=ModelSettings(max_tokens=64, thinking_level=level, temperature=0.5),
                )
                first = await router.chat(request)
                assert first.tool_calls and first.tool_calls[0].name == "search"
                request.messages.extend(
                    [
                        first.to_message(),
                        ChatMessage(
                            role="tool",
                            tool_call_id=first.tool_calls[0].id,
                            content="电影是沙丘",
                        ),
                    ]
                )
                return await router.chat(request)
            finally:
                await router.aclose()

    assert c.portal.call(run_scenario).content == "已连接"
    payload = upstream[-2][1]
    assert payload["model"] == model_id
    if vision:
        assert any(p.get("type") == "image_url" for p in payload["messages"][0]["content"])
    else:
        assert "不支持图片输入" in payload["messages"][0]["content"]
    for field, value in reasoning.items():
        assert payload[field] == value
    if provider == "kimi":
        assert "temperature" not in payload and "top_p" not in payload
    if model_id == "kimi-k3":
        assert payload["max_completion_tokens"] == 64 and "max_tokens" not in payload
    if provider in {"deepseek", "kimi"}:
        assistant = next(m for m in upstream[-1][1]["messages"] if m["role"] == "assistant")
        assert assistant["reasoning_content"] == "已检查用户提供的海报"
