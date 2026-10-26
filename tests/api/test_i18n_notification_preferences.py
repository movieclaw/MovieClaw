"""Stable notification groups and per-reader delivery receipts preserve source facts."""

import copy
from datetime import timedelta
from types import SimpleNamespace

from sqlalchemy import text

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import reference, render_value
from movieclaw_api.services.push import channels, dispatcher, me, preferences, rules
from movieclaw_db.engine import get_database
from movieclaw_db.models import utcnow

from . import test_cloud_push as cloud_fixture

client = cloud_fixture.client
world = cloud_fixture.world
_data = cloud_fixture._data


def test_group_ids_are_stable_and_reading_does_not_write_preferences(client, world):
    originals = [
        (entry.pref_key, entry.title, entry.description, entry.group) for entry in rules.entries()
    ]
    key = preferences.push_events()[0].key
    _data(client.put("/api/v1/push/me/preferences", json={"events": {key: False}}))

    async def stored():
        async with get_database().session() as session:
            return (
                await session.execute(
                    text(
                        "SELECT events,library_ids,muted_item_ids "
                        "FROM push_preference WHERE member_id=0"
                    )
                )
            ).one()

    before = client.portal.call(stored)
    english, chinese, again = [
        _data(client.get("/api/v1/push/me", headers={"Accept-Language": language}))
        for language in ("en", "zh-Hans", "en")
    ]
    assert english == again
    assert [(row["key"], row["group_id"], row["enabled"]) for row in english["events"]] == [
        (row["key"], row["group_id"], row["enabled"]) for row in chinese["events"]
    ]
    source = {entry.pref_key: entry.group for entry in rules.entries()}
    assert all(row["group_id"] == source[row["key"]] for row in english["events"])
    assert any(
        en["group"] != zh["group"]
        for en, zh in zip(english["events"], chinese["events"], strict=True)
    )
    assert client.portal.call(stored) == before
    assert [
        (entry.pref_key, entry.title, entry.description, entry.group) for entry in rules.entries()
    ] == originals


def test_equal_translated_group_titles_do_not_replace_original_group_ids(monkeypatch):
    import movieclaw_api.i18n as i18n

    original = i18n.messages
    groups = list(dict.fromkeys(entry.group for entry in rules.entries()))[:2]
    english = {**original("en"), **dict.fromkeys(groups, "Same translated group")}
    monkeypatch.setattr(
        i18n, "messages", lambda language: english if language == "en" else original(language)
    )
    with use_locale("en"):
        projected = [event for event in preferences.push_events() if event.group_id in groups]
    assert {event.group for event in projected} == {"Same translated group"}
    assert {event.group_id for event in projected} == set(groups)
    assert (
        preferences.PushEvent("legacy", "Title", "Description", "Raw group", True).group_id is None
    )


def test_cached_delivery_receipts_render_per_reader_without_changing_outcomes(
    client, world, monkeypatch
):
    outcomes = [
        dispatcher.Outcome(
            1,
            "Fixture phone",
            "queued",
            "通道暂时不可用，稍后自动重试",
            message_ref=reference("push.outcome.queued"),
        ),
        dispatcher.Outcome(2, "Fixture raw", "failed", "第三方原因"),
        dispatcher.Outcome(3, "Fixture delivered", "ok"),
    ]
    before = copy.deepcopy(outcomes)

    async def send(owner):
        return outcomes

    monkeypatch.setattr(me, "send_test", send)
    monkeypatch.setattr(me, "_TEST_INTERVAL_S", 0)
    responses = [
        _data(client.post("/api/v1/push/me/test", headers={"Accept-Language": language}))
        for language in ("en", "zh-Hans", "en")
    ]
    assert responses[0] == responses[2]
    assert responses[0]["sent"] == responses[1]["sent"] == 2
    assert (
        responses[0]["results"][0]["message"]
        == "Channel is temporarily unavailable. It will retry automatically"
    )
    assert responses[1]["results"][0]["message"] == outcomes[0].message
    assert (
        responses[0]["results"][1]["message"]
        == responses[1]["results"][1]["message"]
        == "第三方原因"
    )
    assert responses[0]["results"][2]["message"] == "Delivered to Apple Push Notification service"
    assert outcomes == before
    assert all("message_ref" not in result for result in responses[0]["results"])


def test_device_limit_references_expire_and_channel_names_are_reader_projections(client, world):
    channel = channels.Channel("fixture", "custom", "作者中继", True, [], None, None, True, True)
    item = dispatcher.Outgoing(
        7, "Fixture", "io.fixture.app", {"token": "fixture-token"}, 9999999999
    )
    client.portal.call(
        dispatcher._handle_result,
        channel,
        item,
        {"result": "rate_limited", "reason": "device_day", "retry_after": 60},
    )
    state = channels.runtime(channel.id)
    before = copy.deepcopy(state)
    with use_locale("en"):
        assert (
            render_value(state.device_block_refs[item.token])
            == "This device has reached today’s push limit"
        )
    assert state.device_block(item.token) == "这台设备今天的推送已达上限"
    assert state == before
    state.device_blocks[item.token] = (
        utcnow() - timedelta(seconds=1),
        state.device_block(item.token),
    )
    assert state.device_block(item.token) is None
    assert item.token not in state.device_block_refs
    client.portal.call(
        dispatcher._handle_result,
        channel,
        item,
        {
            "result": "rate_limited",
            "reason": "device_day",
            "message": "原始上游限制",
            "retry_after": 60,
        },
    )
    assert item.token not in state.device_block_refs
    assert state.device_block(item.token) == "原始上游限制"
    state.clear_blocks()
    assert not state.device_block_refs
    device = SimpleNamespace(
        push_token="fixture",
        push_problem=None,
        push_permission="authorized",
        push_stream=False,
        push_topic=channels.OFFICIAL_TOPIC,
    )
    official = channels.Channel(
        "official", "official", channels.OFFICIAL_NAME, True, [], None, None, True, True
    )
    with use_locale("en"):
        assert me.device_status(device, [official])[2] == "MovieClaw official push"
    assert official.name == channels.OFFICIAL_NAME
