"""Localize saved smart explanations at read time without changing any decision facts."""

import json
import re
from dataclasses import replace
from datetime import timedelta

from sqlmodel import select
from tests.matcher.test_smart import NOW, candidate
from tests.matcher.test_smart_waiting import POLICY, history

from movieclaw_api.i18n import use_locale
from movieclaw_api.services.subscription.smart_presentation import selection_presentation
from movieclaw_matcher.smart import SelectionState, decide

from . import test_subscription_pipeline as pipeline
from . import test_subscription_routes as subscriptions

client = subscriptions.client
db = pipeline.db


def test_all_wait_explanation_branches_preserve_chinese_and_decision_state():
    low = replace(candidate(group="LOW"), publish_time=NOW)
    initial = decide(POLICY, [low], now=NOW)
    subtitle_policy = POLICY.model_copy(update={"watchable_languages": ["zh"]})
    subtitle_wait = decide(subtitle_policy, [low], now=NOW)
    cases = [
        (decide(POLICY, [candidate()], now=NOW), "unknownPublication"),
        (initial, "publishedAnchor"),
        (
            decide(
                POLICY,
                [low],
                now=NOW,
                state=initial.state.model_copy(update={"manual_extended": True}),
            ),
            "manualWait",
        ),
        (
            decide(POLICY, [low], now=NOW, episode=6, release_history=history()),
            "predictionSupported",
        ),
        (
            decide(
                POLICY, [low], now=NOW + timedelta(hours=2), episode=6, release_history=history()
            ),
            "predictionElapsed",
        ),
        (
            decide(
                POLICY.model_copy(update={"wait_seconds": 1800}),
                [low],
                now=NOW,
                episode=6,
                release_history=history(),
            ),
            "predictionBeyondBudget",
        ),
        (subtitle_wait, "subtitlesWaiting"),
        (
            decide(
                subtitle_policy,
                [low],
                now=NOW + timedelta(days=1),
                state=subtitle_wait.state,
            ),
            "subtitlesExpired",
        ),
    ]
    for decision, key in cases:
        state = decision.state.model_dump(mode="json")
        before = json.dumps(decision.model_dump(mode="json"), sort_keys=True)
        assert (
            decision.state.messages["wait_explanation"]["message_key"]
            == f"subscription.selection.{key}"
        )
        for locale in ("en", "zh-Hans", "en"):
            with use_locale(locale):
                view = selection_presentation(state, decision.state.messages)
            assert view["deadline"] == state["deadline"]
            assert view["observation_end"] == state["observation_end"]
            assert view["candidate_key"] == state["candidate_key"]
            if locale == "zh-Hans":
                assert view["wait_explanation"] == state["wait_explanation"]
            else:
                assert not re.search(r"[\u3400-\u9fff]", view["wait_explanation"])
        assert json.dumps(decision.model_dump(mode="json"), sort_keys=True) == before


def test_choice_explanation_preserves_counts_and_handles_unknown_or_zero_seeders():
    for seeders in (None, 0, 12):
        for verified in (0, 2):
            release = replace(candidate(), seeders=seeders)
            from movieclaw_matcher.smart import series_key

            decision = decide(
                POLICY.model_copy(update={"wait_seconds": 0}),
                [release],
                now=NOW,
                coverage={"test/a": [3, 1]},
                reliability={series_key(release): verified},
            )
            if seeders == 0:
                assert decision.action == "no_candidate"
                continue
            assert decision.action == "download"
            state = decision.state.model_dump(mode="json")
            with use_locale("zh-Hans"):
                assert (
                    selection_presentation(state, decision.state.messages)["choice_explanation"]
                    == state["choice_explanation"]
                )
            with use_locale("en"):
                text = selection_presentation(state, decision.state.messages)["choice_explanation"]
            assert "This series covers 3 episodes and this release would cover 1 episode." in text
            assert text.endswith(f"Seeders: {seeders if seeders is not None else 'unknown'}.")
            assert not re.search(r"[\u3400-\u9fff]", text)


def test_legacy_explanations_are_not_inferred_and_cleared_explanations_stay_empty():
    legacy = SelectionState(
        anchor=NOW,
        deadline=NOW,
        observation_end=NOW,
        wait_explanation="未标记的旧解释",
    ).model_dump(mode="json")
    assert "messages" not in legacy
    with use_locale("en"):
        assert selection_presentation(legacy)["wait_explanation"] == "未标记的旧解释"
        assert selection_presentation(None) is None
        decision = decide(POLICY, [candidate()], now=NOW)
        state = decision.state.model_dump(mode="json")
        state["wait_explanation"] = None
        assert selection_presentation(state, decision.state.messages)["wait_explanation"] is None


def test_real_detail_and_manual_wait_response_follow_reader_without_rewriting_saved_state(
    client, monkeypatch
):
    from movieclaw_api.services import media_discover
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import SubscriptionActivity, WantedItem, utcnow

    monkeypatch.setattr(media_discover, "get_tmdb_client", subscriptions._fake_tmdb)
    profile = client.put(
        "/api/v1/subscriptions/smart-profiles/movie",
        json={
            "revision": 0,
            "preferences": {"resolution": "2160p", "source": "web-dl", "wait_seconds": 10800},
        },
    )
    assert profile.status_code == 200, profile.text
    response = client.post(
        "/api/v1/subscriptions",
        json={
            "title_ref": "tmdb:movie:100",
            "selection_mode": "smart",
            "smart_profile_revision": 1,
        },
    )
    assert response.status_code == 200, response.text
    sub_id = response.json()["data"]["subscription"]["id"]
    path = f"/api/v1/subscriptions/{sub_id}"

    async def save_state():
        async with get_database().session() as session:
            wanted = (
                await session.execute(
                    select(WantedItem).where(WantedItem.subscription_id == sub_id)
                )
            ).scalar_one()
            state = decide(POLICY, [candidate()], now=utcnow().replace(tzinfo=None)).state
            wanted.selection_state = state.model_dump(mode="json")
            wanted.selection_messages = state.messages
            wanted.selection_version = 4
            session.add(wanted)
            await session.commit()
            return wanted.id, wanted.selection_state

    wanted_id, saved = client.portal.call(save_state)
    for locale in ("en", "zh-Hans", "en"):
        detail = client.get(path, headers={"Accept-Language": locale}).json()["data"]
        state = detail["wanted"][0]["selection_state"]
        assert state["deadline"] == saved["deadline"]
        assert (state["wait_explanation"] == saved["wait_explanation"]) == (locale == "zh-Hans")
        assert detail["wanted"][0]["selection_version"] == 4
    extended = client.post(
        f"{path}/wanted/{wanted_id}/smart-wait",
        json={"version": 4, "extend_seconds": 7200},
        headers={"Accept-Language": "en"},
    )
    assert extended.status_code == 200, extended.text
    assert not re.search(
        r"[\u3400-\u9fff]", extended.json()["data"]["selection_state"]["wait_explanation"]
    )
    assert extended.json()["data"]["selection_version"] == 5

    async def stored():
        async with get_database().session() as session:
            wanted = await session.get(WantedItem, wanted_id)
            event = (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == sub_id,
                        SubscriptionActivity.message_key
                        == "activity.subscription.smartWaitExtended",
                    )
                )
            ).scalar_one()
            return wanted.selection_state, event.message

    persisted, message = client.portal.call(stored)
    assert "messages" not in persisted
    assert persisted["wait_explanation"] == saved["wait_explanation"]
    assert message == "用户延长了等待时间"


async def test_backfilling_only_presentation_references_keeps_the_selection_version(
    db, monkeypatch
):
    from tests.api.test_smart_subscription import resource, smart_sub
    from tests.api.test_subscription_pipeline import _wanted_map

    from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
    from movieclaw_db.models import utcnow

    clock = utcnow()
    monkeypatch.setattr("movieclaw_api.services.subscription.smart_selection.utcnow", lambda: clock)
    async with db.session() as session:
        sub = await smart_sub(session)
        release = await resource(session)
        assert (
            await evaluate_and_dispatch(session, [release], source="fixture")
        ).dispatched_units == 0
        wanted = (await _wanted_map(session, sub.id))[(1, 1)]
        raw, version = dict(wanted.selection_state), wanted.selection_version
        assert "messages" not in raw
        assert wanted.selection_messages
        wanted.selection_messages = None
        session.add(wanted)
        await session.commit()
        assert (
            await evaluate_and_dispatch(session, [release], source="fixture")
        ).dispatched_units == 0
        await session.refresh(wanted)
        assert wanted.selection_state == raw
        assert wanted.selection_version == version
        assert wanted.selection_messages
