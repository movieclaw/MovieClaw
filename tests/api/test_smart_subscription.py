# ruff: noqa: F811
from datetime import timedelta

import pytest
from sqlalchemy import delete
from sqlmodel import select
from tests.api.test_subscription_pipeline import (
    _insert_torrent,
    _service,
    _wanted_map,
    db,  # noqa: F401
)

from movieclaw_api.exceptions import AppException
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.services.subscription.smart_profiles import save_profile
from movieclaw_api.services.subscription.smart_scheduler import run_due
from movieclaw_api.services.subscription.smart_selection import change_wait
from movieclaw_db.models import SiteTorrent, SmartProfile, Subscription, SubscriptionDownloadAttempt
from movieclaw_db.models.base import utcnow
from movieclaw_matcher.smart import SmartPreferences
from movieclaw_media.models import MediaKind


async def smart_sub(session, **preferences):
    await save_profile(session, "tv", SmartPreferences(**preferences), 0)
    return await _service(session).create(
        MediaKind.TV, 200, selected_seasons=[1], selection_mode="smart", smart_profile_revision=1
    )


async def resource(session, name="a", resolution="1080p", episode=1, group="A"):
    return await _insert_torrent(
        session,
        name,
        f"Test Show S01E{episode:02d} {resolution} WEB-DL-{group}",
        {
            "media_type": "tv",
            "year": 2024,
            "seasons": [1],
            "episodes": [episode],
            "resolution": resolution,
            "media_source": "WEB-DL",
            "release_group": group,
        },
    )


async def test_profiles_frozen_independent_and_shared_subscription_idempotent(db):
    async with db.session() as session:
        sub = await smart_sub(session)
        assert sub.rule_set_id is None
        original = dict(sub.smart_policy)
        sub_id = sub.id
        await save_profile(
            session, "movie", SmartPreferences(wait_seconds=86400, source="remux"), 0
        )
        await save_profile(session, "tv", SmartPreferences(resolution="1080p"), 1)
        with pytest.raises(AppException) as exc:
            await save_profile(session, "tv", SmartPreferences(), 1)
        assert exc.value.status_code == 409
        sub = await session.get(Subscription, sub_id)
        again = await _service(session).create(MediaKind.TV, 200, selected_seasons=[1])
        assert again.id == sub.id and again.smart_policy == original
        assert (await session.get(SmartProfile, "movie")).preferences["source"] == "remux"


async def test_wait_survives_index_cleanup_and_new_session_then_timer_dispatches(db, monkeypatch):
    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        sub = await smart_sub(session)
        torrent = await resource(session)
        result = await evaluate_and_dispatch(session, [torrent], source="test")
        assert result.dispatched_units == 0
        wanted = (await _wanted_map(session, sub.id))[(1, 1)]
        deadline = wanted.selection_state["deadline"]
        await session.execute(delete(SiteTorrent))
        await session.commit()
    clock += timedelta(hours=3)
    async with db.session() as session:
        result = await run_due(session, now=clock)
        assert result.dispatched_units == 1
        wanted = (await _wanted_map(session, sub.id))[(1, 1)]
        assert wanted.status == "grabbed"
        assert wanted.selection_state["deadline"] == deadline
        assert (await evaluate_and_dispatch(session, [], source="duplicate")).dispatched_units == 0


async def test_manual_extension_version_prevents_stale_request(db):
    async with db.session() as session:
        sub = await smart_sub(session)
        await evaluate_and_dispatch(session, [await resource(session)], source="test")
        row = (await _wanted_map(session, sub.id))[(1, 1)]
        version = row.selection_version
        await change_wait(session, row.id, version, extend_seconds=7200)
        with pytest.raises(AppException) as exc:
            await change_wait(session, row.id, version, immediate_candidate="test/a")
        assert exc.value.status_code == 409


async def test_target_available_dispatches_once_and_rule_mode_still_works(db):
    async with db.session() as session:
        sub = await smart_sub(session)
        row = await resource(session, resolution="2160p")
        first = await evaluate_and_dispatch(session, [row], source="test")
        assert first.dispatched_units == 1
        assert (await evaluate_and_dispatch(session, [row], source="repeat")).dispatched_units == 0
        attempts = (
            (
                await session.execute(
                    select(SubscriptionDownloadAttempt).where(
                        SubscriptionDownloadAttempt.subscription_id == sub.id
                    )
                )
            )
            .scalars()
            .all()
        )
        assert len(attempts) == 1


@pytest.mark.parametrize("reverse", [False, True])
async def test_complete_pack_beats_popular_partial_and_singles(db, reverse):
    async with db.session() as session:
        await smart_sub(session)
        one = await resource(session, "popular", resolution="2160p", group="UBWEB")
        one.seeders = 165
        pack = await _insert_torrent(
            session,
            "complete",
            "Test Show S01 Complete 2160p WEB-DL-UBWEB",
            {
                "media_type": "tv",
                "year": 2024,
                "seasons": [1],
                "episodes_total": 2,
                "complete": True,
                "resolution": "2160p",
                "media_source": "WEB-DL",
                "release_group": "UBWEB",
            },
            seeders=70,
        )
        await session.commit()
        candidates = [one, pack]
        result = await evaluate_and_dispatch(
            session, candidates[::-1] if reverse else candidates, source="完整方案"
        )
        assert result.dispatched_units == 2
        attempts = list((await session.execute(select(SubscriptionDownloadAttempt))).scalars())
        assert len(attempts) == 1 and attempts[0].torrent_id == "complete"
        assert sorted(attempts[0].units) == [[1, 1], [1, 2]]


async def test_pack_can_fill_gap_without_claiming_inflight_episode(db):
    async with db.session() as session:
        sub = await smart_sub(session)
        first = await resource(session, "first", resolution="2160p", group="A")
        await evaluate_and_dispatch(session, [first], source="首集")
        pack = await _insert_torrent(
            session,
            "complete",
            "Test Show S01 Complete 2160p WEB-DL-A",
            {
                "media_type": "tv",
                "year": 2024,
                "seasons": [1],
                "complete": True,
                "resolution": "2160p",
                "media_source": "WEB-DL",
                "release_group": "A",
            },
        )
        result = await evaluate_and_dispatch(session, [pack], source="只发布完结包")
        assert result.dispatched_units == 1
        attempts = list(
            (
                await session.execute(
                    select(SubscriptionDownloadAttempt).order_by(SubscriptionDownloadAttempt.id)
                )
            ).scalars()
        )
        assert len(attempts) == 2 and attempts[-1].units == [[1, 2]]
        assert (await _wanted_map(session, sub.id))[(1, 1)].grab_title.endswith(first.title)
