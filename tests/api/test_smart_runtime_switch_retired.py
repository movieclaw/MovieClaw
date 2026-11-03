# ruff: noqa: F811
"""#1093：退役隐藏的智能订阅运行开关 subscription.smart。

这个开关没有任何界面或接口能写，库里一旦留下 enabled=false，智能订阅就会
创建成功、提示排入搜索队列，却永远不搜。现在代码不再读它，迁移顺手删掉遗留行。
"""

from __future__ import annotations

import sqlite3

from alembic import command
from sqlalchemy import text
from sqlmodel import select
from tests.api.test_smart_subscription import smart_sub
from tests.api.test_subscription_pipeline import db  # noqa: F401

from movieclaw_api.core.config import get_settings
from movieclaw_api.schemas.search import SearchResponse, SiteSearchStatus
from movieclaw_api.services import site_search
from movieclaw_api.services.subscription.wanted_search import search_wanted
from movieclaw_db.migrations import _build_config
from movieclaw_db.models import WantedItem

_BEFORE = "d7a25e81c4f0"
_REVISION = "b4e8d2f61a37"
_LEGACY = '{"enabled": false, "prediction_enabled": false, "shadow_only": false}'


def test_migration_drops_legacy_switch(tmp_path, monkeypatch) -> None:
    database = tmp_path / "smart-switch.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, _BEFORE)
    with sqlite3.connect(database) as connection:
        for namespace in ("subscription.smart", "subscription.smart_other"):
            connection.execute(
                "INSERT INTO app_setting (created_at, updated_at, namespace, value_json) "
                "VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?)",
                (namespace, _LEGACY),
            )
        connection.commit()

    command.upgrade(config, _REVISION)

    with sqlite3.connect(database) as connection:
        left = [row[0] for row in connection.execute("SELECT namespace FROM app_setting")]
    assert left == ["subscription.smart_other"]
    get_settings.cache_clear()


async def test_smart_subscription_searches_even_with_legacy_switch_row(db, monkeypatch):
    calls = []

    async def search(keyword, **kwargs):
        calls.append(keyword)
        return SearchResponse(
            keyword=keyword,
            label=None,
            categories=[],
            total=0,
            items=[],
            sites=[SiteSearchStatus(site_id="fixture", site_name="站点", count=0)],
        )

    monkeypatch.setattr(site_search, "search_all_sites", search)
    async with db.session() as session:
        # 迁移之后又被旧版本或手工写回的遗留行，也不能再挡住智能订阅
        await session.execute(
            text(
                "INSERT INTO app_setting (created_at, updated_at, namespace, value_json) "
                "VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 'subscription.smart', :value)"
            ),
            {"value": _LEGACY},
        )
        await session.commit()
        sub = await smart_sub(session)
    await search_wanted()
    assert calls
    async with db.session() as session:
        wanted = (
            (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub.id)))
            .scalars()
            .all()
        )
    assert wanted and all(w.search_attempts == 1 for w in wanted)
