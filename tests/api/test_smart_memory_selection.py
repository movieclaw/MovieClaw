"""字幕要求在真实匹配链路里的行为：等字幕、到期知会一次、这次先下原版、字幕版到达。"""

# ruff: noqa: F811
import inspect
from datetime import timedelta

import pytest
from sqlmodel import select
from tests.api.smart_memory_fixture import ROUTES
from tests.api.test_subscription_pipeline import (  # noqa: F401
    _fake_tmdb,
    _insert_torrent,
    _wanted_map,
    db,
)

from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.services.subscription.smart_profiles import save_defaults
from movieclaw_api.services.subscription.smart_selection import change_wait
from movieclaw_db.models import SubscriptionDownloadAttempt
from movieclaw_db.models.base import utcnow
from movieclaw_matcher.smart import SmartPreferences
from movieclaw_media.models import MediaKind


def _service(session) -> SubscriptionService:
    return SubscriptionService(session, MediaLibraryService(session, _fake_tmdb(ROUTES)))


async def _english_movie(session):
    await save_defaults(
        session,
        SmartPreferences(),
        movie_wait_seconds=86400,
        tv_wait_seconds=10800,
        movie_revision=0,
        tv_revision=0,
    )
    return await _service(session).create(
        MediaKind.MOVIE, 701, selection_mode="smart", smart_profile_revision=1
    )


async def _release(session, name, *, subs=(), published=None):
    return await _insert_torrent(
        session,
        name,
        f"Oppenheimer 2023 2160p WEB-DL-{name}",
        {
            "media_type": "movie",
            "title": "Oppenheimer",
            "year": 2023,
            "resolution": "2160p",
            "media_source": "WEB-DL",
            "release_group": name,
            "subtitle_languages": list(subs),
        },
        publish_time=published,
    )


@pytest.fixture
def published(monkeypatch):
    calls = []

    async def fake_publish(session, event, build, **_kw):
        if event.name != "subscription.awaiting_subtitles":
            return
        payload = build()
        if inspect.isawaitable(payload):
            payload = await payload
        if payload is not None:
            calls.append((event.name, payload))

    monkeypatch.setattr("movieclaw_api.events.publish", fake_publish)
    return calls


async def test_raw_only_waits_then_notifies_once_and_never_downloads(db, published):
    async with db.session() as session:
        sub = await _english_movie(session)
        assert sub.smart_policy["watchable_languages"] == ["zh"]
        raw = await _release(session, "RAW", published=utcnow() - timedelta(hours=2))
        result = await evaluate_and_dispatch(session, [raw], source="test")
        assert result.dispatched_units == 0
        wanted = (await _wanted_map(session, sub.id))[(0, 0)]
        assert wanted.selection_state["reason"] == "awaiting_subtitles"
        assert wanted.selection_state["subtitle_blocked"] == 1
        assert published == []

        stale = await _release(session, "OLD", published=utcnow() - timedelta(days=3))
        result = await evaluate_and_dispatch(session, [stale], source="test")
        assert result.dispatched_units == 0
        await session.refresh(wanted)
        assert wanted.selection_state["reason"] == "deadline_awaiting_subtitles"
        assert [name for name, _ in published] == ["subscription.awaiting_subtitles"]
        payload = published[0][1]
        assert (payload.language, payload.acceptable, payload.originals) == ("英语", "中文", 2)
        assert payload.waited_hours >= 72

        # 再评估不重复知会，也不下原版
        await evaluate_and_dispatch(session, [raw, stale], source="test")
        assert len(published) == 1
        attempts = (await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()
        assert attempts == []


async def test_download_original_this_time_then_subbed_version_never_needed(db, published):
    async with db.session() as session:
        sub = await _english_movie(session)
        raw = await _release(session, "RAW", published=utcnow())
        await evaluate_and_dispatch(session, [raw], source="test")
        wanted = (await _wanted_map(session, sub.id))[(0, 0)]
        state = wanted.selection_state
        assert state["candidate_key"] == "testsite/RAW"
        await change_wait(
            session, wanted.id, wanted.selection_version, immediate_candidate="testsite/RAW"
        )
        result = await evaluate_and_dispatch(session, [], source="test", subscription_ids={sub.id})
        assert result.dispatched_units == 1


async def test_subbed_version_is_chosen_over_better_raw(db, published):
    async with db.session() as session:
        await _english_movie(session)
        raw = await _release(session, "RAW", published=utcnow() - timedelta(days=3))
        subbed = await _release(
            session, "SUB", subs=["zh-Hans"], published=utcnow() - timedelta(days=3)
        )
        result = await evaluate_and_dispatch(session, [raw, subbed], source="test")
        assert result.dispatched_units == 1
        assert any("SUB" in t for t in result.dispatched_torrents)
        assert published == []
