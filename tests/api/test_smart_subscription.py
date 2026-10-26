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


async def test_subscriptions_follow_own_kind_profile_and_create_is_idempotent(db):
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
        assert again.id == sub.id
        # 跟随剧集设置的修改（2160p → 1080p），不受电影设置影响
        assert original["resolution"] == "2160p"
        assert again.smart_policy["resolution"] == "1080p"
        assert again.smart_policy["source"] == original["source"]
        assert again.smart_policy["profile_revision"] == 2
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


async def test_same_name_pack_with_far_fewer_episodes_never_enters_smart_pool(db):
    """智能模式同样拦：声明「全1集」而本季 2 集都已播出，不进候选池、不投递。"""
    async with db.session() as session:
        sub = await smart_sub(session, wait_seconds=0)
        pack = await _insert_torrent(
            session,
            "pack1",
            "Test Show S01 1080p WEB-DL-A",
            {
                "media_type": "tv",
                "seasons": [1],
                "complete": True,
                "episodes_total": 1,
                "resolution": "1080p",
                "media_source": "WEB-DL",
                "release_group": "A",
            },
        )
        result = await evaluate_and_dispatch(session, [pack], source="被动匹配")
        assert result.dispatched_units == 0
        assert all(w.status == "wanted" for w in (await _wanted_map(session, sub.id)).values())
        assert (
            await session.execute(select(SubscriptionDownloadAttempt))
        ).scalars().first() is None


async def test_switching_profile_to_no_wait_dispatches_waiting_episode(db, monkeypatch):
    """复现 NAS《Doctor X》E4：剧集设置 6 小时、只有 1080p 候选时在等；把剧集设置改成
    不等待后，已有订阅立即跟随，下一轮到期扫描就投递，并留下调整动态与决策输入。"""
    from movieclaw_db.models import ActivityType, SmartDecisionRecord, SubscriptionActivity

    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        sub = await smart_sub(session, wait_seconds=21600)
        torrent = await resource(session)  # 1080p，不满足默认 2160p 目标
        first = await evaluate_and_dispatch(session, [torrent], source="发现")
        assert first.dispatched_units == 0
        wanted = (await _wanted_map(session, sub.id))[(1, 1)]
        assert wanted.selection_state["reason"] in {"observing", "waiting_series"}
        assert wanted.next_selection_at > clock

        clock += timedelta(minutes=5)
        await save_profile(session, "tv", SmartPreferences(wait_seconds=0), 1)
        await session.refresh(sub)
        await session.refresh(wanted)
        assert sub.smart_policy["wait_seconds"] == 0
        assert wanted.next_selection_at <= utcnow()
        activity = (
            await session.execute(
                select(SubscriptionActivity).where(
                    SubscriptionActivity.subscription_id == sub.id,
                    SubscriptionActivity.type == ActivityType.ADJUSTED,
                )
            )
        ).scalar_one()
        assert "不等待" in activity.message

        result = await run_due(session, now=clock)
        assert result is not None and result.dispatched_units == 1
        attempt = (await session.execute(select(SubscriptionDownloadAttempt))).scalar_one()
        assert attempt.torrent_id == "a"
        record = (
            (await session.execute(select(SmartDecisionRecord))).scalars().all()[-1]
        )
        assert record.inputs["policy"]["wait_seconds"] == 0  # 审计记录当时实际生效的设置


async def test_manual_extension_survives_profile_switch(db, monkeypatch):
    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        sub = await smart_sub(session, wait_seconds=7200)
        torrent = await resource(session)
        await evaluate_and_dispatch(session, [torrent], source="发现")
        wanted = (await _wanted_map(session, sub.id))[(1, 1)]
        await change_wait(session, wanted.id, wanted.selection_version, extend_seconds=3600 * 3)
        await session.refresh(wanted)
        extended_deadline = wanted.selection_state["deadline"]

        await save_profile(session, "tv", SmartPreferences(wait_seconds=0), 1)
        clock += timedelta(minutes=1)
        result = await run_due(session, now=clock)
        assert result is None or result.dispatched_units == 0
        await session.refresh(wanted)
        assert wanted.selection_state["deadline"] == extended_deadline
        assert not (await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()
