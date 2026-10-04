"""mclaw 工具在 API 层的装配测试：服务目录同步、描述快照、递归服务端硬闸。"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_agent.tools.mclaw import build_description
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.mclaw_tool import (
    _DOMAIN_LINES,
    render_service_map,
    spec_domains,
)
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box

_SNAPSHOT = Path(__file__).parent / "mclaw_tool_description_snapshot.txt"


def test_service_map_covers_every_spec_domain() -> None:
    """目录同步守护：spec 的每个开放域都必须有人工润色并出现在目录里。

    运行期保留 DOMAIN_HELP 回落是为了部署韧性，但仓库内不接受只有技术短标签
    的新域：能力地图是 Agent 选择工具的依据，必须显式评审用户语义。
    """
    missing = spec_domains() - set(_DOMAIN_LINES)
    assert not missing, f"以下开放域缺少人工功能介绍：{missing}"

    rendered = render_service_map()
    for domain in spec_domains():
        assert any(line.lstrip("- ").startswith(domain) for line in rendered.splitlines()), (
            f"服务目录缺少域：{domain}"
        )


def test_curated_lines_have_no_orphans() -> None:
    """润色行不能指向不存在的域（防止改版后目录里残留幽灵条目）。"""
    orphans = set(_DOMAIN_LINES) - spec_domains()
    assert not orphans, f"_DOMAIN_LINES 含 spec 中不存在（或已被排除）的域：{orphans}"


def test_service_map_distinguishes_browsing_from_unified_search() -> None:
    """关键语义守卫：discover 负责浏览，search 统一承接三类搜索目标。"""
    lines = render_service_map().splitlines()
    discover = next(line for line in lines if line.startswith("- discover "))
    search = next(line for line in lines if line.startswith("- search "))

    for keyword in ("电影", "剧集", "TMDB", "豆瓣", "热门", "高分"):
        assert keyword in discover
    for keyword in ("titles", "torrents", "library 按片名", "PT", "种子", "download"):
        assert keyword in search


def test_service_map_reflects_frontend_product_language() -> None:
    """前端核心承诺必须进入能力地图，避免 Agent 只看到后台技术对象名。"""
    lines = {
        line.lstrip("- ").split(maxsplit=1)[0]: line
        for line in render_service_map().splitlines()
        if line.startswith("- ")
    }

    for keyword in ("实时热点", "热映", "在播", "热门", "高分", "口碑"):
        assert keyword in lines["discover"]
    for keyword in ("持续追踪", "自动搜索", "下载", "整理入库"):
        assert keyword in lines["subscriptions"]
    assert "AI 对话入口" in lines["channels"] and "搜片、订阅、查进度" in lines["channels"]
    assert "qBittorrent/Transmission" in lines["dl"]
    assert "首页背景" in lines["appearance"] and "界面质感" in lines["ui"]
    assert "播放、收藏" in lines["webhook"] and "HMAC" in lines["webhook"]


def test_session_domain_is_exposed_without_agent_domain() -> None:
    """Agent 分类已移除；模型直接看到一级 session 会话管理能力。"""
    rendered = render_service_map()
    assert not any(line.lstrip("- ").startswith("agent ") for line in rendered.splitlines()), (
        "目录不应残留旧 agent 域"
    )
    session = next(line for line in rendered.splitlines() if line.startswith("- session "))
    for keyword in (
        "用户与智能体",
        "发起新对话",
        "继续已有对话",
        "指定用户消息",
        "读取并分析",
        "message/compaction",
        "压缩上下文",
        "跟随或停止",
        "删除会话",
    ):
        assert keyword in session
    for protocol_word in ("先 list", "禁用", "可能很大", "不分页、不截断"):
        assert protocol_word not in session


def test_full_description_matches_snapshot() -> None:
    """工具描述是模型行为的一部分：任何改动必须显式过快照评审。"""
    actual = build_description(render_service_map())
    if not _SNAPSHOT.exists():
        _SNAPSHOT.write_text(actual, encoding="utf-8")
    # 快照文件按仓库文本规范保留末尾换行；工具 description 本身不需要该换行。
    # 只规范化一个 EOF 换行，其余字符仍逐字比较。
    expected = _SNAPSHOT.read_text(encoding="utf-8").removesuffix("\n")
    assert actual == expected, (
        f"mclaw 工具描述与快照不一致。确认属预期变更后删除快照文件重新生成：\n  rm {_SNAPSHOT}"
    )


# ---------------------------------------------------------------------------
# 服务端递归硬闸
# ---------------------------------------------------------------------------

_ADMIN = {"username": "admin", "password": "s3cret-pass"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()

    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        c.post("/api/v1/auth/bootstrap", json=_ADMIN)
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def test_agent_token_cannot_start_or_send_session_message(client: TestClient) -> None:
    """Agent 令牌不能开始会话或发送消息，且硬闸先于资源/模型校验。"""
    import asyncio

    from movieclaw_api.services import auth as auth_service

    token = asyncio.run(auth_service.issue_agent_token("sess-x"))

    # 必须用不带 Cookie 的干净客户端——服务端鉴权 Cookie 优先，带着
    # bootstrap 的管理员 Cookie 会把身份判成 admin。真实 Agent 工作区
    # 也只有 Bearer 令牌，这正是它的调用形态。
    fresh = TestClient(client.app)
    for body in (
        {"content": "递归测试"},
        {"content": "递归测试", "session_id": "missing"},
    ):
        resp = fresh.post(
            "/api/v1/sessions",
            json=body,
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 400
        assert "禁止递归" in resp.json()["message"]
    retry = fresh.post(
        "/api/v1/sessions/missing/retry",
        json={"message_id": "m1"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert retry.status_code == 400
    assert "禁止递归" in retry.json()["message"]


def test_agent_token_cannot_stop_its_own_session(client: TestClient) -> None:
    """即使绕过 mclaw 工具直调 API，当前 Agent 也不能自我终止。"""
    import asyncio

    from movieclaw_api.services import auth as auth_service

    token = asyncio.run(auth_service.issue_agent_token("sess-x"))
    fresh = TestClient(client.app)
    resp = fresh.post(
        "/api/v1/sessions/sess-x/stop",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 400
    assert "不能停止承载自己的会话" in resp.json()["message"]
