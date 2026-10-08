# ruff: noqa: F811
from datetime import timedelta

import pytest
from sqlmodel import select
from tests.api.test_subscription_pipeline import (
    _TWIN,
    _fake_detail,
    _fake_twin_probe,
    _insert_torrent,
    _movie_sub_with_imdb,
    _wanted_map,  # noqa: F401
    db,  # noqa: F401
)

from movieclaw_api.exceptions import AppException
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.services.subscription.smart_selection import change_wait
from movieclaw_db.models import SubscriptionStatus, SystemNotice, utcnow
from movieclaw_matcher.smart import SmartPolicy


async def movie(session):
    sub = await _movie_sub_with_imdb(session, "tt32138219")
    sub.selection_mode = "smart"
    sub.rule_set_id = None
    sub.smart_policy = SmartPolicy(kind="movie", profile_revision=1, wait_seconds=10800).model_dump(
        mode="json"
    )
    await session.commit()
    return sub


async def resource(session, name, resolution="2160p", **kwargs):
    return await _insert_torrent(
        session,
        name,
        f"Upcoming Movie 2026 {resolution} WEB-DL-Kitsune",
        {"media_type": "movie", "year": 2026, "resolution": resolution, "media_source": "WEB-DL"},
        **kwargs,
    )


async def test_ambiguous_candidate_has_no_actions_and_recovers_with_id(db, monkeypatch):
    _fake_detail(monkeypatch, imdb_id=None)
    _fake_twin_probe(monkeypatch, [_TWIN])
    pushes = []
    monkeypatch.setattr(
        "movieclaw_api.services.push.events.identity_skipped", lambda **kw: pushes.append(kw)
    )
    async with db.session() as session:
        sub = await movie(session)
        row = await resource(session, "uncertain", publish_time=utcnow() - timedelta(days=80))
        for _ in range(2):
            assert (
                await evaluate_and_dispatch(session, [row], source="test")
            ).dispatched_units == 0
        wanted = (await _wanted_map(session, sub.id))[(0, 0)]
        assert sub.status == SubscriptionStatus.ACTIVE
        assert wanted.selection_state["reason"] == "identity_unconfirmed"
        assert wanted.selection_state["candidate_key"] is None
        assert wanted.next_selection_at is None
        assert len(pushes) == 1 and "无需你处理" in pushes[0]["message"]
        assert (
            not (await session.execute(select(SystemNotice).where(SystemNotice.status == "active")))
            .scalars()
            .all()
        )
        for kw in ({"immediate_candidate": "testsite/uncertain"}, {"extend_seconds": 86400}):
            with pytest.raises(AppException):
                await change_wait(session, wanted.id, wanted.selection_version, **kw)
        row.imdb_id = "tt32138219"
        session.add(row)
        await session.commit()
        assert (
            await evaluate_and_dispatch(session, [row], source="new identity")
        ).dispatched_units == 1
        assert len(pushes) == 1


async def test_ambiguous_best_does_not_block_or_age_verified_candidate(db, monkeypatch):
    _fake_detail(monkeypatch, imdb_id=None)
    _fake_twin_probe(monkeypatch, [_TWIN])
    async with db.session() as session:
        sub = await movie(session)
        now = utcnow()
        wrong = await resource(session, "old-4k", publish_time=now - timedelta(days=80))
        right = await resource(
            session, "fresh-1080", "1080p", imdb_id="tt32138219", publish_time=now
        )
        assert (
            await evaluate_and_dispatch(session, [wrong, right], source="test")
        ).dispatched_units == 0
        wanted = (await _wanted_map(session, sub.id))[(0, 0)]
        assert wanted.selection_state["candidate_key"] == "testsite/fresh-1080"
        assert wanted.selection_state["anchor"] == now.isoformat()
        assert wanted.selection_state["reason"] == "observing"
        sub.smart_policy = SmartPolicy(kind="movie", profile_revision=1, wait_seconds=0).model_dump(
            mode="json"
        )
        # Use a fresh subscription policy state to exercise immediate same-round fallback.
        wanted.selection_state = None
        session.add(sub)
        session.add(wanted)
        await session.commit()
        result = await evaluate_and_dispatch(session, [wrong, right], source="immediate")
        assert result.dispatched_units == 1
        assert result.dispatched_torrents == ["testsite/fresh-1080"]
