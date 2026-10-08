# ruff: noqa: F811
"""需求 AT01–16、模式隔离与故障场景：真实数据库、策略、调度和投递服务。"""

import asyncio
from datetime import datetime, timedelta
from types import SimpleNamespace

import pytest
from sqlalchemy import text
from sqlmodel import select
from tests.api.test_smart_subscription import resource, smart_sub
from tests.api.test_subscription_pipeline import _insert_torrent, _wanted_map, db  # noqa: F401

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.services.subscription.smart_runtime import SmartAutomationSettings
from movieclaw_api.services.subscription.smart_scheduler import recover_submissions, run_due
from movieclaw_api.services.subscription.smart_selection import change_wait, confirm_import
from movieclaw_api.settings.store import get_setting_store
from movieclaw_db.models import (
    SmartCandidate,
    SmartDecisionRecord,
    SmartSeason,
    SubscriptionDownloadAttempt,
    WantedItem,
)
from movieclaw_db.models.base import utcnow
from movieclaw_downloader.models import SubmitResult
from movieclaw_matcher import QualitySnapshot
from movieclaw_matcher.smart import SelectionState


@pytest.mark.parametrize(
    "case,window_hours,deadline_hours", [("arrival", 2, 6), ("window", 2, 6), ("deadline", 3, 2)]
)
async def test_at01_03_forecast_window_and_hard_deadline(
    db, monkeypatch, case, window_hours, deadline_hours
):
    clock = datetime(2026, 10, 7, 20)
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        sub = await smart_sub(session, wait_seconds=deadline_hours * 3600)
        rows = await _wanted_map(session, sub.id)
        snapshot = QualitySnapshot(
            resolution="2160p",
            media_source="WEB-DL",
            resolution_verified=True,
            source_evidence="consistent_declaration",
        ).model_dump(mode="json")
        for row in rows.values():
            row.status, row.quality = "imported", snapshot
        row = WantedItem(
            subscription_id=sub.id,
            media_item_id=sub.media_item_id,
            season_number=1,
            episode_number=4,
            air_date=clock.date(),
        )
        session.add(row)
        session.add(
            SmartSeason(
                subscription_id=sub.id, season_number=1, series_key="a|2160p|3", confirmed=True
            )
        )
        candidates = []
        # 三集真实候选记录支持窗口，不能直接写一个没有证据的 prediction 状态。
        for episode in (1, 2, 3):
            for suffix, resolution, delay in [
                ("low", "1080p", 0),
                ("high", "2160p", window_hours - 0.5),
            ]:
                torrent = await resource(
                    session,
                    f"{suffix}-{episode}",
                    resolution,
                    episode,
                    "B" if suffix == "low" else "A",
                )
                torrent.publish_time = clock - timedelta(days=4 - episode) + timedelta(hours=delay)
                candidates.append(torrent)
        current = await resource(session, "a", "1080p", 4, "B")
        current.publish_time = clock
        candidates.append(current)
        await session.commit()
        first = await evaluate_and_dispatch(session, candidates, source="发现")
        deadline = row.selection_state["deadline"]
        if case == "deadline":
            # 到达窗口超出预算时立即选择，不为注定等不到的目标耗尽预算。
            assert first.dispatched_units == 1
            expected = "a"
        else:
            assert first.dispatched_units == 0
            assert row.selection_state["prediction"]["episodes"] == [1, 2, 3]
            clock += timedelta(hours=1, minutes=29)
            assert (await evaluate_and_dispatch(session, [], source="刷新")).dispatched_units == 0
            if case == "arrival":
                clock += timedelta(minutes=1)
                result = await evaluate_and_dispatch(
                    session, [await resource(session, "high", "2160p", 4)], source="到达"
                )
                expected = "high"
            else:
                clock = datetime.fromisoformat(row.selection_state["observation_end"])
                result = await run_due(session, now=clock)
                expected = "a"
            assert result.dispatched_units == 1
        attempt = (await session.execute(select(SubscriptionDownloadAttempt))).scalar_one()
        assert attempt.torrent_id == expected
        assert (await evaluate_and_dispatch(session, [], source="重复事件")).dispatched_units == 0
        assert row.selection_state["deadline"] == deadline


async def test_at06_pause_resume_at09_no_candidate_does_not_restart_budget(db, monkeypatch):
    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        sub = await smart_sub(session)
        candidate = await resource(session)
        await evaluate_and_dispatch(session, [candidate], source="发现")
        row = (await _wanted_map(session, sub.id))[(1, 1)]
        deadline = row.selection_state["deadline"]
        sub.status = "paused"
        await session.commit()
        clock += timedelta(hours=4)
        assert await run_due(session, now=clock) is None
        sub.status = "active"
        candidate.seeders = 0
        await session.commit()
        assert (
            await evaluate_and_dispatch(session, [candidate], source="恢复")
        ).dispatched_units == 0
        assert row.selection_state["reason"] == "deadline_no_candidate"
        candidate.seeders = 3
        await session.commit()
        assert (
            await evaluate_and_dispatch(session, [candidate], source="重新可用")
        ).dispatched_units == 1
        assert row.selection_state["deadline"] == deadline


async def test_at07_08_episode_fallback_keeps_season_follow(db, monkeypatch):
    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        sub = await smart_sub(session)
        session.add(
            SmartSeason(
                subscription_id=sub.id, season_number=1, series_key="a|1080p|3", confirmed=True
            )
        )
        await session.commit()
        await evaluate_and_dispatch(session, [await resource(session, group="B")], source="迟到")
        clock += timedelta(hours=3)
        assert (await run_due(session, now=clock)).dispatched_units == 1
        follow = (await session.execute(select(SmartSeason))).scalar_one()
        assert follow.series_key == "a|1080p|3"
        rows = [
            await resource(session, "next-b", "2160p", 2, "B"),
            await resource(session, "next-a", "1080p", 2, "A"),
        ]
        assert (await evaluate_and_dispatch(session, rows, source="下一集")).dispatched_units == 1
        attempts = (
            (
                await session.execute(
                    select(SubscriptionDownloadAttempt).order_by(SubscriptionDownloadAttempt.id)
                )
            )
            .scalars()
            .all()
        )
        assert [a.torrent_id for a in attempts] == ["a", "next-b"]
        assert follow.series_key == "a|1080p|3"  # 单集目标品质优先，保留整季跟随记录。


async def test_at10_concurrent_discovery_and_timer_only_one_intent(db):
    async with db.session() as session:
        await smart_sub(session, wait_seconds=0)
        row = await resource(session)

    async def run():
        async with db.session() as session:
            return await evaluate_and_dispatch(session, [row], source="并发")

    await asyncio.gather(run(), run(), run())
    async with db.session() as session:
        assert (
            len((await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()) == 1
        )


async def test_at12_pack_selects_ready_episode_without_bypassing_other_wait(db, monkeypatch):
    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        sub = await smart_sub(session)
        session.add(
            SmartSeason(
                subscription_id=sub.id, season_number=1, series_key="a|2160p|3", confirmed=True
            )
        )
        await session.commit()
        one = await resource(session, "one", group="B")
        await evaluate_and_dispatch(session, [one], source="首集")
        clock += timedelta(minutes=20)
        await evaluate_and_dispatch(
            session, [await resource(session, "two", episode=2, group="B")], source="次集"
        )
        pack = await _insert_torrent(
            session,
            "pack",
            "Test Show S01 1080p WEB-DL-A",
            {
                "media_type": "tv",
                "year": 2024,
                "seasons": [1],
                "resolution": "1080p",
                "media_source": "WEB-DL",
                "release_group": "A",
            },
            seeders=1000,
        )
        clock += timedelta(minutes=10)
        result = await evaluate_and_dispatch(session, [pack], source="整季包")
        assert result.dispatched_units == 1
        rows = await _wanted_map(session, sub.id)
        assert rows[(1, 1)].status == "grabbed" and rows[(1, 2)].status == "wanted"
        assert (
            await session.execute(select(SubscriptionDownloadAttempt))
        ).scalar_one().torrent_id == "pack"


async def test_shadow_disabled_corrupt_policy_never_falls_back(db):
    async with db.session() as session:
        sub = await smart_sub(session, wait_seconds=0)
        candidate = await resource(session)
        store = get_setting_store()
        await store.set(SmartAutomationSettings(shadow_only=True))
        assert (
            await evaluate_and_dispatch(session, [candidate], source="影子")
        ).dispatched_units == 0
        wanted = (await _wanted_map(session, sub.id))[(1, 1)]
        assert (
            wanted.selection_state is None
            and wanted.selection_version == 0
            and wanted.status == "wanted"
        )
        assert (await session.execute(select(SmartDecisionRecord))).scalars().first() is not None
        assert (
            await session.execute(select(SubscriptionDownloadAttempt))
        ).scalars().first() is None
        await store.set(SmartAutomationSettings(enabled=False))
        assert (
            await evaluate_and_dispatch(session, [candidate], source="关闭")
        ).dispatched_units == 0
        await store.set(SmartAutomationSettings())
        sub.smart_policy = {**sub.smart_policy, "algorithm_version": 999}
        await session.commit()
        assert (
            await evaluate_and_dispatch(session, [candidate], source="版本损坏")
        ).dispatched_units == 0


async def test_at16_crash_after_claim_replays_same_intent_and_deadline(db, monkeypatch):
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "false")
    get_settings.cache_clear()
    from importlib import import_module

    module = import_module("movieclaw_api.services.subscription.dispatch")

    async def fail(*args, **kwargs):
        raise TimeoutError("模拟认领后退出")

    monkeypatch.setattr(module, "_submit_real", fail)
    async with db.session() as session:
        sub = await smart_sub(session, wait_seconds=0)
        await evaluate_and_dispatch(session, [await resource(session)], source="认领")
        row = (await _wanted_map(session, sub.id))[(1, 1)]
        deadline, sub_id = row.selection_state["deadline"], sub.id
        assert row.status == "grabbed"
        assert (
            await session.execute(select(SubscriptionDownloadAttempt))
        ).scalar_one().status == "submitting"

    async def accepted(*args, **kwargs):
        await kwargs["before_submit"]("a" * 40, None)
        return SubmitResult(info_hash="a" * 40, name="Test Show"), SimpleNamespace(id=None)

    monkeypatch.setattr(module, "_submit_real", accepted)
    async with db.session() as session:
        await recover_submissions(session, now=utcnow() + timedelta(minutes=2))
        attempts = (await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()
        assert len(attempts) == 1 and attempts[0].status == "active"
        row = (await _wanted_map(session, sub_id))[(1, 1)]
        assert row.info_hash == "a" * 40 and row.selection_state["deadline"] == deadline


async def test_at23_25_stop_requires_both_axes_and_verified_import(db):
    async with db.session() as session:
        sub = await smart_sub(session, source="blu-ray")
        row = (await _wanted_map(session, sub.id))[(1, 1)]
        await confirm_import(
            session,
            sub,
            row,
            QualitySnapshot(
                resolution="2160p",
                media_source="WEB-DL",
                resolution_verified=True,
                source_evidence="consistent_declaration",
            ),
        )
        assert not row.selection_state["target_reached"]
        await confirm_import(
            session, sub, row, QualitySnapshot(resolution="2160p", media_source="Blu-ray")
        )
        assert not row.selection_state["target_reached"]
        await confirm_import(
            session,
            sub,
            row,
            QualitySnapshot(
                resolution="2160p",
                media_source="Blu-ray",
                resolution_verified=True,
                source_evidence="consistent_declaration",
            ),
        )
        assert row.selection_state["target_reached"]
        row.status = "imported"
        row.quality = QualitySnapshot(
            resolution="2160p",
            media_source="Blu-ray",
            resolution_verified=True,
            source_evidence="consistent_declaration",
        ).model_dump(mode="json")
        await session.commit()
        assert (
            await evaluate_and_dispatch(
                session, [await resource(session, "new", "2160p", group="B")], source="新资源"
            )
        ).dispatched_units == 0


async def test_at13_attribute_revisions_do_not_rewrite_observation_history(db, monkeypatch):
    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        await smart_sub(session)
        candidate = await resource(session)
        await evaluate_and_dispatch(session, [candidate], source="初见")
        first = clock
        clock += timedelta(minutes=1)
        candidate.attrs = {**candidate.attrs, "release_group": "B"}
        await session.commit()
        await evaluate_and_dispatch(session, [candidate], source="属性修正")
        cached = (await session.execute(select(SmartCandidate))).scalar_one()
        assert [(o["series"], o["at"]) for o in cached.observations] == [
            ("a|1080p|3", first.isoformat()),
            ("b|1080p|3", clock.isoformat()),
        ]


async def test_due_query_uses_index(db):
    async with db.session() as session:
        plan = (
            await session.execute(
                text(
                    "EXPLAIN QUERY PLAN SELECT subscription_id FROM wanted_item WHERE "
                    "status='wanted' AND in_scope=1 AND next_selection_at <= '2026-10-07' ORDER "
                    "BY next_selection_at LIMIT 100"
                )
            )
        ).all()
        assert any("ix_wanted_smart_due" in str(row) for row in plan)


async def test_manual_extension_and_dispatch_claim_are_mutually_exclusive(db):
    from movieclaw_api.exceptions import AppException
    from movieclaw_api.services.subscription.matching import to_candidate
    from movieclaw_api.services.subscription.smart_submission import claim_intent

    async with db.session() as one:
        sub = await smart_sub(one)
        torrent = await resource(one)
        await evaluate_and_dispatch(one, [torrent], source="发现")
        row = (await _wanted_map(one, sub.id))[(1, 1)]
        version = row.selection_version
        async with db.session() as two:
            await change_wait(two, row.id, version, extend_seconds=7200)
        assert (
            await claim_intent(one, sub, [row], [], to_candidate(torrent), {row.id: version})
            is None
        )
        # 失败认领不能使同一批已经加载的上下文过期（否则异步属性访问会崩溃）。
        assert sub.kind == "tv" and torrent.torrent_id == "a"
        await one.refresh(row)
        version = row.selection_version
        assert (
            await claim_intent(one, sub, [row], [], to_candidate(torrent), {row.id: version})
            is not None
        )
        async with db.session() as two:
            with pytest.raises(AppException) as error:
                await change_wait(two, row.id, version, extend_seconds=7200)
            assert error.value.status_code == 409


async def test_season_switch_requires_verified_failures_and_three_successful_episodes(db):
    from movieclaw_api.services.subscription.smart_selection import maybe_switch_series

    async with db.session() as session:
        sub = await smart_sub(session)
        rows = await _wanted_map(session, sub.id)
        for ep in range(3, 5):
            row = WantedItem(
                subscription_id=sub.id,
                media_item_id=sub.media_item_id,
                season_number=1,
                episode_number=ep,
            )
            session.add(row)
            rows[(1, ep)] = row
        quality = QualitySnapshot(
            resolution="1080p",
            media_source="WEB-DL",
            release_group="B",
            resolution_verified=True,
            source_evidence="consistent_declaration",
        )
        for row in rows.values():
            row.status = "imported"
            row.quality = quality.model_dump(mode="json")
        follow = SmartSeason(
            subscription_id=sub.id, season_number=1, series_key="a|1080p|3", confirmed=True
        )
        session.add(follow)
        await session.commit()
        imported = rows[(1, 4)]
        await maybe_switch_series(session, sub, follow, imported)
        assert follow.series_key == "a|1080p|3"  # B 的成功和 A 未出现不能证明 A 失约。
        follow.evidence = {"quality_failure_episodes": [1, 2, 3]}
        await maybe_switch_series(session, sub, follow, imported)
        assert follow.series_key == "b|1080p|3"
        assert follow.evidence["reason"] == "verified_quality_failures"
        assert follow.evidence["switched_at_episode"] == 4


async def test_smart_replacement_uses_recoverable_trial_without_repointing_primary(db):
    from movieclaw_api.services.subscription.dispatch import dispatch
    from movieclaw_api.services.subscription.matching import to_candidate
    from movieclaw_db.models import MediaItem
    from movieclaw_matcher import RuleVerdict

    async with db.session() as session:
        sub = await smart_sub(session, wait_seconds=0)
        await evaluate_and_dispatch(session, [await resource(session)], source="主源")
        row = (await _wanted_map(session, sub.id))[(1, 1)]
        row.info_hash = "a" * 40
        parent = (await session.execute(select(SubscriptionDownloadAttempt))).scalar_one()
        parent.status = "replacement_pending"
        parent.info_hash = row.info_hash
        await session.commit()
        replacement = to_candidate(await resource(session, "replacement", group="B"))
        assert await dispatch(
            session,
            subscription=sub,
            item=await session.get(MediaItem, sub.media_item_id),
            wanted_rows=[row],
            candidate=replacement,
            verdict=RuleVerdict(accepted=True),
            source="换源",
            selection_versions={row.id: row.selection_version},
            replacing_attempt=parent,
        )
        assert row.info_hash == "a" * 40
        attempts = (
            (
                await session.execute(
                    select(SubscriptionDownloadAttempt).order_by(SubscriptionDownloadAttempt.id)
                )
            )
            .scalars()
            .all()
        )
        assert [a.status for a in attempts] == ["replacement_pending", "trial"]
        assert attempts[1].replaces_attempt_id == parent.id


@pytest.mark.parametrize("with_candidates", [False, True])
async def test_due_load_10000_units_100_expired_within_scan_budget(
    db, monkeypatch, with_candidates
):
    """参考开发机负载门槛：预留 30 秒调度周期，处理必须小于剩余 30 秒。"""
    import time

    from sqlalchemy import insert

    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        sub = await smart_sub(session)
        state = SelectionState(
            anchor=clock - timedelta(hours=3),
            deadline=clock - timedelta(hours=1),
            observation_end=clock - timedelta(hours=2),
        )
        await session.execute(
            insert(WantedItem),
            [
                dict(
                    subscription_id=sub.id,
                    media_item_id=sub.media_item_id,
                    season_number=1,
                    episode_number=ep,
                    status="wanted",
                    in_scope=True,
                    selection_version=0,
                    selection_state=state.model_dump(mode="json") if ep < 103 else None,
                    next_selection_at=clock - timedelta(hours=1) if ep < 103 else None,
                    created_at=clock,
                    updated_at=clock,
                    search_attempts=0,
                    priority=0,
                    upgrade_verify_failures=0,
                )
                for ep in range(3, 10001)
            ],
        )
        await session.commit()
        if with_candidates:
            from movieclaw_api.services.subscription.matching import to_candidate
            from movieclaw_matcher.smart import series_key

            for ep in range(3, 103):
                torrent = await resource(session, f"load-{ep}", episode=ep)
                session.add(
                    SmartCandidate(
                        subscription_id=sub.id,
                        site_id=torrent.site_id,
                        torrent_id=torrent.torrent_id,
                        snapshot=torrent.model_dump(mode="json"),
                        observations=[
                            {
                                "series": series_key(to_candidate(torrent)),
                                "eligible": True,
                                "episodes": [[1, ep]],
                                "pack": False,
                                "at": (clock - timedelta(hours=3)).isoformat(),
                            }
                        ],
                    )
                )
            await session.commit()
        started = time.perf_counter()
        result = await run_due(session, now=clock)
        if with_candidates:
            assert result.dispatched_units == 100
        elapsed = time.perf_counter() - started
        assert elapsed < 30
        expired = (
            await session.execute(
                select(WantedItem.id).where(WantedItem.next_selection_at <= clock)
            )
        ).all()
        assert not expired
        print(
            f"智能到期负载：10000 单元 / 100 到期，候选 {100 if with_candidates else 0}，"
            f"处理 {elapsed:.3f}s"
        )


async def test_movie_observation_target_and_profile_isolation(db, monkeypatch):
    from tests.api.test_subscription_pipeline import _fake_twin_probe, _service

    from movieclaw_api.services.subscription.smart_profiles import save_profile
    from movieclaw_matcher.smart import SmartPreferences
    from movieclaw_media.models import MediaKind

    _fake_twin_probe(monkeypatch, [])
    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        await save_profile(session, "movie", SmartPreferences(wait_seconds=86400), 0)
        sub = await _service(session).create(
            MediaKind.MOVIE, 105, selection_mode="smart", smart_profile_revision=1
        )
        row = (await _wanted_map(session, sub.id))[(0, 0)]
        assert row.selection_state is None
        candidate = await _insert_torrent(
            session,
            "movie-low",
            "Dune Part Two 1080p WEB-DL",
            {
                "media_type": "movie",
                "resolution": "1080p",
                "media_source": "WEB-DL",
                "year": clock.year,
                "release_group": "A",
            },
        )
        assert (
            await evaluate_and_dispatch(session, [candidate], source="电影首见")
        ).dispatched_units == 0
        state = SelectionState.model_validate(row.selection_state)
        assert state.observation_end - state.anchor == timedelta(hours=6)
        assert state.deadline - state.anchor == timedelta(days=1)
        await save_profile(
            session, "movie", SmartPreferences(wait_seconds=259200, source="remux"), 1
        )
        clock += timedelta(minutes=5)
        target = await _insert_torrent(
            session,
            "movie-target",
            "Dune Part Two 2160p WEB-DL",
            {
                "media_type": "movie",
                "resolution": "2160p",
                "media_source": "WEB-DL",
                "year": clock.year,
                "release_group": "B",
            },
        )
        assert (
            await evaluate_and_dispatch(session, [target], source="电影目标到达")
        ).dispatched_units == 1
        assert sub.smart_policy["source"] == "web-dl" and sub.smart_policy["wait_seconds"] == 86400
        assert not (await session.execute(select(SmartSeason))).scalars().all()
        await confirm_import(
            session,
            sub,
            row,
            QualitySnapshot(
                resolution="2160p",
                media_source="WEB-DL",
                resolution_verified=True,
                source_evidence="consistent_declaration",
            ),
        )
        assert row.selection_state["target_reached"]


async def test_at22_same_batch_rules_dispatch_while_smart_waits(db, monkeypatch):
    from tests.api.test_subscription_pipeline import _fake_twin_probe, _service

    from movieclaw_media.models import MediaKind

    _fake_twin_probe(monkeypatch, [])
    async with db.session() as session:
        smart = await smart_sub(session)
        legacy = await _service(session).create(MediaKind.MOVIE, 105)
        batch = [
            await resource(session),
            await _insert_torrent(
                session,
                "legacy",
                "Dune Part Two 1080p WEB-DL",
                {
                    "media_type": "movie",
                    "year": utcnow().year,
                    "resolution": "1080p",
                    "media_source": "WEB-DL",
                },
            ),
        ]
        result = await evaluate_and_dispatch(session, batch, source="共享批次")
        assert result.dispatched_units == 1
        assert (await _wanted_map(session, smart.id))[(1, 1)].status == "wanted"
        assert (await _wanted_map(session, legacy.id))[(0, 0)].status == "grabbed"


async def test_failed_database_write_does_not_publish_extension(db, monkeypatch):
    async with db.session() as session:
        sub = await smart_sub(session)
        await evaluate_and_dispatch(session, [await resource(session)], source="发现")
        row = (await _wanted_map(session, sub.id))[(1, 1)]
        wanted_id, version, deadline = (
            row.id,
            row.selection_version,
            row.selection_state["deadline"],
        )

        async def unavailable():
            raise OSError("injected database write failure")

        monkeypatch.setattr(session, "commit", unavailable)
        with pytest.raises(OSError):
            await change_wait(session, wanted_id, version, extend_seconds=7200)
        await session.rollback()
    async with db.session() as session:
        row = await session.get(WantedItem, wanted_id)
        assert row.selection_version == version and row.selection_state["deadline"] == deadline
        assert not (await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()


async def test_immediate_request_rechecks_current_candidate(db):
    from movieclaw_api.exceptions import AppException

    async with db.session() as session:
        sub = await smart_sub(session)
        torrent = await resource(session)
        await evaluate_and_dispatch(session, [torrent], source="发现")
        row = (await _wanted_map(session, sub.id))[(1, 1)]
        torrent.seeders = 0
        await session.commit()
        with pytest.raises(AppException) as error:
            await change_wait(
                session,
                row.id,
                row.selection_version,
                immediate_candidate=row.selection_state["candidate_key"],
            )
        assert error.value.status_code == 409
        assert not (await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()


@pytest.mark.parametrize("change", ["paused", "out_of_scope"])
async def test_stale_decision_cannot_claim_after_pause_or_scope_change(db, change):
    from movieclaw_api.services.subscription.matching import to_candidate
    from movieclaw_api.services.subscription.smart_submission import claim_intent

    async with db.session() as session:
        sub = await smart_sub(session)
        torrent = await resource(session)
        await evaluate_and_dispatch(session, [torrent], source="发现")
        row = (await _wanted_map(session, sub.id))[(1, 1)]
        if change == "paused":
            sub.status = "paused"
        else:
            row.in_scope = False
        await session.commit()
        assert (
            await claim_intent(
                session, sub, [row], [], to_candidate(torrent), {row.id: row.selection_version}
            )
            is None
        )
    async with db.session() as session:
        assert not (await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()


async def test_duplicate_remote_hash_rejects_before_network_and_releases_claim(db, monkeypatch):
    from movieclaw_api.services.subscription.dispatch import dispatch
    from movieclaw_api.services.subscription.matching import to_candidate
    from movieclaw_db.models import MediaItem
    from movieclaw_matcher import RuleVerdict

    async with db.session() as session:
        sub = await smart_sub(session, wait_seconds=0)
        torrent = await resource(session)
        row = (await _wanted_map(session, sub.id))[(1, 1)]
        old = SubscriptionDownloadAttempt(
            subscription_id=sub.id,
            info_hash="a" * 40,
            status="failed",
            units=[[1, 1]],
            last_progress_at=utcnow(),
        )
        session.add(old)
        await session.commit()
        monkeypatch.setattr(get_settings(), "subscription_dispatch_dry_run", False)

        async def submit(*args, **kwargs):
            await kwargs["before_submit"]("a" * 40, 1)
            pytest.fail("重复指纹不应提交网络")

        import importlib

        monkeypatch.setattr(
            importlib.import_module("movieclaw_api.services.subscription.dispatch"),
            "_submit_real",
            submit,
        )
        assert not await dispatch(
            session,
            subscription=sub,
            item=await session.get(MediaItem, sub.media_item_id),
            wanted_rows=[row],
            candidate=to_candidate(torrent),
            verdict=RuleVerdict(accepted=True),
            source="测试",
            selection_versions={row.id: row.selection_version},
        )
        assert row.status == "wanted"
        attempts = (await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()
        assert len(attempts) == 2 and all(a.status == "failed" for a in attempts)
        assert attempts[1].submission["stage"] == "rejected"
        assert (
            await evaluate_and_dispatch(session, [torrent], source="恢复")
        ).dispatched_units == 0
