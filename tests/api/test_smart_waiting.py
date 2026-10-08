# ruff: noqa: F811
from datetime import datetime

from sqlmodel import select
from tests.api.smart_waiting_fixture import seed_old_release
from tests.api.test_subscription_pipeline import db  # noqa: F401

from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_db.models import SmartDecisionRecord, SubscriptionDownloadAttempt, WantedItem


async def test_nas_old_episode_real_pipeline_selects_once_without_new_wait(db, monkeypatch):
    clock = datetime(2026, 10, 7, 4, 32)
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        _, candidates = await seed_old_release(session)
        real = await evaluate_and_dispatch(session, candidates, source="真实链路隔离回放")
        assert real.dispatched_units == 2
        assert real.dispatched_torrents == ["mteam/1266198"]
        decisions = list((await session.execute(select(SmartDecisionRecord))).scalars())
        assert len(decisions) == 2
        assert all(
            d.outcome["action"] == "download"
            and d.outcome["candidate_key"] == "mteam/1266198"
            and d.outcome["state"]["anchor_source"] == "published_at"
            for d in decisions
        )
        attempts = list((await session.execute(select(SubscriptionDownloadAttempt))).scalars())
        assert len(attempts) == 1 and attempts[0].torrent_id == "1266198"
        rows = list((await session.execute(select(WantedItem))).scalars())
        assert all(w.status == "grabbed" for w in rows)
        assert (
            await evaluate_and_dispatch(session, candidates, source="重复回放")
        ).dispatched_units == 0


async def test_default_prediction_is_enabled_without_runtime_override():
    from movieclaw_api.settings.smart_subscription import SmartAutomationSettings

    assert SmartAutomationSettings().prediction_enabled
