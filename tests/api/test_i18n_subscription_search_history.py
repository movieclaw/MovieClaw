"""Real search ticks save canonical Chinese and reader-neutral nested diagnostics."""

import re

import pytest
from sqlmodel import select

from movieclaw_api.i18n import use_locale
from movieclaw_api.schemas.search import SearchResponse, SiteSearchStatus
from movieclaw_api.schemas.subscription import ActivityView
from movieclaw_api.services import site_search
from movieclaw_api.services.subscription.wanted_search import search_wanted
from movieclaw_db.models import SubscriptionActivity, WantedItem, utcnow
from movieclaw_media.models import MediaKind

from . import test_subscription_pipeline as pipeline

db = pipeline.db


@pytest.mark.parametrize("shape", ["no_sites", "known_error", "success"])
async def test_search_tick_history_follows_the_reader_and_preserves_retry_semantics(
    db, monkeypatch, shape
):
    calls = []

    async def search(keyword, **kwargs):
        calls.append(keyword)
        sites = []
        if shape != "no_sites":
            sites = [
                SiteSearchStatus(
                    site_id="fixture",
                    site_name="我的站点",
                    count=0,
                    **(
                        {
                            "error": "原始诊断",
                            "error_key": "errors.siteDiagnostic.loginRedirect",
                            "error_params": {},
                        }
                        if shape == "known_error"
                        else {}
                    ),
                )
            ]
        return SearchResponse(
            keyword=keyword, label=None, categories=[], total=0, items=[], sites=sites
        )

    monkeypatch.setattr(site_search, "search_all_sites", search)
    async with db.session() as session:
        sub = await pipeline._service(session).create(MediaKind.TV, 200, selected_seasons=[1])
    await search_wanted()
    async with db.session() as session:
        event = (
            await session.execute(
                select(SubscriptionActivity).where(
                    SubscriptionActivity.subscription_id == sub.id,
                    SubscriptionActivity.type == "searched",
                )
            )
        ).scalar_one()
        raw, params = event.message, event.message_params.copy()
        with use_locale("zh-Hans"):
            assert ActivityView.from_model(event).message == raw
        with use_locale("en"):
            english = ActivityView.from_model(event).message
        assert not re.search(
            r"[\u3400-\u9fff]", english.replace("测试剧集", "").replace("我的站点", "")
        )
        assert event.message == raw and event.message_params == params
        if shape == "no_sites":
            assert "当前没有可用的已验证站点" in raw
            assert "No verified sites are currently available" in english
        elif shape == "known_error":
            assert "我的站点：登录已失效" in raw
            assert "我的站点: The site redirected" in english
            # Multiple recall keywords do not repeat the same site's diagnostic.
            assert english.count("The site redirected") == 1
        else:
            assert raw.startswith("搜索《测试剧集》（关键词")
            assert "1 个站点返回 0 个结果，身份命中 0，规则拒绝 0，投递覆盖 0 个单元" in raw
            assert "1 site returned 0 results" in english
        wanted = (
            (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub.id)))
            .scalars()
            .all()
        )
        assert all(w.search_attempts == (1 if shape == "success" else 0) for w in wanted)
        assert all(w.next_search_at > utcnow() for w in wanted)
    assert calls
