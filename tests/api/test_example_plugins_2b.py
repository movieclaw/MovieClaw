"""二 B 的验收插件端到端（docs/design/plugin-phase2b.md §10 B8）。

把示例插件 ``keyword_rules.py`` 当本地受信插件装进临时数据目录，真实应用 + 真实匹配流水线
（dry-run 投递）：关键字规则淘汰候选、写进订阅动态，订阅删除时插件清掉自己的扩展字段。
"""

from __future__ import annotations

import asyncio
import shutil
import sys
import textwrap
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select
from tests.api.test_subscription_pipeline import (
    _S1_PACK_ATTRS,
    _activities,
    _insert_torrent,
    _service,
)

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events
from movieclaw_db.engine import get_database
from movieclaw_db.models import PluginData
from movieclaw_media.models import MediaKind

EXAMPLES = (
    Path(__file__).resolve().parents[2]
    / "src"
    / "movieclaw_agent"
    / "builtin-skills"
    / "movieclaw-plugin-dev"
    / "references"
    / "examples"
)


@pytest.fixture(params=["inline", "process"])
def app_client(request, tmp_path, monkeypatch):
    """主进程里跑一遍、独立进程里再跑一遍（plugin-phase3.md §0：运行位置对插件透明）。"""
    from movieclaw_api.settings.store import reset_setting_store

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'kw.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "true")
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    shutil.copy(EXAMPLES / "keyword_rules.py", tmp_path / "plugins" / "keyword_rules.py")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: keyword-rules
              local: true
              runtime: {runtime}
              config:
                rules:
                  1: { require_any: [国语], exclude: [抢先版] }
            """
        ).replace("{runtime}", request.param),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as client:
        yield app, client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    durable_events.reset_state()
    get_settings.cache_clear()


def test_keyword_rules_reject_candidates_and_clean_up_with_the_subscription(app_client) -> None:
    from movieclaw_api.services.subscription.matching import evaluate_and_dispatch

    app, client = app_client
    fiber = app.state.kernel.fiber("keyword-rules")
    assert fiber.state.value == "active", fiber.error

    async def scenario() -> tuple[list[str], list[dict]]:
        async with get_database().session() as session:
            sub = await _service(session).create(MediaKind.TV, 200, selected_seasons=[1])
            assert sub.id == 1
            early = await _insert_torrent(
                session, "early", "Test Show S01 2160p WEB-DL 抢先版", _S1_PACK_ATTRS, seeders=50
            )
            mandarin = await _insert_torrent(
                session,
                "mandarin",
                "Test Show S01 2160p WEB-DL",
                _S1_PACK_ATTRS,
                subtitle="国语中字",
                seeders=3,
            )
            plain = await _insert_torrent(
                session, "plain", "Test Show S01 1080p WEB-DL", _S1_PACK_ATTRS, seeders=80
            )
            await evaluate_and_dispatch(session, [early, mandarin, plain], source="被动匹配")
            activities = await _activities(session, sub.id)
        grabbed = [a.payload["torrent_id"] for a in activities if a.type == "grabbed"]
        rejected = [
            {
                "torrent": a.payload["torrent_id"],
                "code": a.payload["reason_code"],
                "text": a.message,
            }
            for a in activities
            if a.type == "match_rejected"
        ]
        return grabbed, rejected

    grabbed, rejected = client.portal.call(scenario)
    # 做种最多的两个都被关键字规则淘汰，留下带「国语」的那个
    assert grabbed == ["mandarin"]
    assert sorted(r["torrent"] for r in rejected) == ["early", "plain"]
    assert {r["code"] for r in rejected} == {"plugin:keyword"}
    assert any("排除词「抢先版」" in r["text"] for r in rejected)

    async def rules_rows() -> int:
        async with get_database().session() as session:
            return len(
                (
                    await session.execute(
                        select(PluginData).where(PluginData.scope == "subscription:1")
                    )
                )
                .scalars()
                .all()
            )

    assert client.portal.call(rules_rows) == 1

    async def delete_and_wait() -> None:
        from movieclaw_api.services.subscription import SubscriptionService

        async with get_database().session() as session:
            await SubscriptionService(session, None).delete_permanently(1)  # type: ignore[arg-type]
        # 可靠事件至少投递一次：满载时一次投递失败要等 5 秒重试，给足余量
        async with asyncio.timeout(30):
            while await rules_rows():
                await asyncio.sleep(0.05)

    client.portal.call(delete_and_wait)
