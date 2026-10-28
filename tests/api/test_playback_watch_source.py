"""真实 HTTP/SQLite：完成事件、续播分组与历史目录使用同一观看 ID。"""

from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from movieclaw_api.services import durable_events
from movieclaw_db.engine import get_database
from movieclaw_db.models import DomainEvent, EventConsumer, LibraryFile, MediaItem
from movieclaw_sdk.events import PLAYBACK_COMPLETED, PLAYBACK_STOPPED, PlaybackCompleted

from .test_playback_sync import client as client
from .test_playback_sync import snapshot


@pytest.mark.parametrize("kind", ["movie", "tv"])
def test_event_source_matches_catalog_after_resume_and_later_stop(client, monkeypatch, kind):
    c, _, ids = client
    item_id = ids[0]
    clock = [datetime(2020, 1, 1, 12, 20)]
    for module in (
        "movieclaw_api.services.playback.watch",
        "movieclaw_playback.state",
        "movieclaw_api.services.playback_sync",
        "movieclaw_db.models",
    ):
        monkeypatch.setattr(module + ".utcnow", lambda: clock[0])
    season, episode = (1, 2) if kind == "tv" else (0, 0)

    async def prepare():
        async with get_database().session() as s:
            media = await s.get(MediaItem, item_id)
            media.kind = kind
            file = (
                await s.execute(select(LibraryFile).where(LibraryFile.media_item_id == item_id))
            ).scalar_one()
            file.season_number, file.episode_number = season, episode
            s.add_all(
                EventConsumer(consumer_id=f"source:{name}", event_name=name, event_names=[name])
                for name in ("playback.completed", "playback.stopped")
            )
            await s.commit()

    c.portal.call(prepare)
    durable_events.reset_subscribed()

    def report(event, position=0, device="a"):
        response = c.post(
            "/api/v1/playback/progress",
            json={
                "media_item_id": item_id,
                "season_number": season,
                "episode_number": episode,
                "event": event,
                "position_ms": position,
                "device_id": device,
            },
        )
        assert response.status_code == 200, response.text

    async def recorded(name):
        async with get_database().session() as s:
            return [
                r.payload
                for r in (
                    await s.execute(
                        select(DomainEvent)
                        .where(DomainEvent.name == name)
                        .order_by(DomainEvent.seq)
                    )
                ).scalars()
            ]

    report("start")
    clock[0] = datetime(2020, 1, 1, 12, 25)
    report("stop", 300_000)
    first = c.portal.call(recorded, "playback.stopped")[0]["watch_source_ids"][0]
    assert first.startswith("playback:")
    clock[0] = datetime(2020, 1, 1, 12, 26)
    report("start", device="b")
    clock[0] = datetime(2020, 1, 1, 12, 34, 59)
    report("progress", 570_000, device="b")
    completed = c.portal.call(recorded, "playback.completed")[-1]
    assert completed["watch_source_ids"][0] == first
    assert len(completed["watch_source_ids"]) == 2
    clock[0] = datetime(2020, 1, 1, 12, 45)
    report("stop", 600_000, device="b")
    stopped = c.portal.call(recorded, "playback.stopped")[-1]
    assert stopped["watch_source_ids"] == completed["watch_source_ids"]
    unit = next(u for u in snapshot(c)["items"] if u["media"]["id"] == item_id)
    assert len(unit["watches"]) == 1
    assert unit["watches"][0]["id"] == first
    assert unit["watches"][0]["source_ids"] == stopped["watch_source_ids"]
    assert unit["watches"][0]["watched_at"].startswith("2020-01-01T12:45:00")
    # A rewatch is a different fact, even though the item remains marked played.
    clock[0] = datetime(2020, 1, 1, 12, 50)
    report("start")
    clock[0] = datetime(2020, 1, 1, 13, 5)
    report("stop", 570_000)
    second = c.portal.call(recorded, "playback.stopped")[-1]["watch_source_ids"][0]
    assert second != first
    unit = next(u for u in snapshot(c)["items"] if u["media"]["id"] == item_id)
    assert {w["id"] for w in unit["watches"]} == {first, second}
    durable_events.reset_subscribed()


def test_source_id_is_an_optional_minor_contract_extension():
    assert str(PLAYBACK_COMPLETED.version) == "1.1"
    assert str(PLAYBACK_STOPPED.version) == "1.1"
    assert not PlaybackCompleted.model_fields["watch_source_ids"].is_required()


def test_offline_completion_uses_the_same_source_ids_as_catalog(client):
    c, _, ids = client

    async def prepare():
        async with get_database().session() as s:
            s.add(
                EventConsumer(
                    consumer_id="offline-source",
                    event_name="playback.completed",
                    event_names=["playback.completed"],
                )
            )
            await s.commit()

    c.portal.call(prepare)
    durable_events.reset_subscribed()
    now = datetime.now(UTC)
    response = c.post(
        "/api/v1/playback/viewings",
        json={
            "sent_at": now.isoformat(),
            "records": [
                {
                    "viewing_id": "source-offline-0001",
                    "media_item_id": ids[0],
                    "started_at": (now - timedelta(minutes=10)).isoformat(),
                    "updated_at": now.isoformat(),
                    "position_ms": 570_000,
                    "watched_ms": 570_000,
                    "completed": True,
                    "ended": True,
                }
            ],
        },
    )
    assert response.status_code == 200, response.text

    async def event_source():
        async with get_database().session() as s:
            event = (
                await s.execute(select(DomainEvent).where(DomainEvent.name == "playback.completed"))
            ).scalar_one()
            return event.payload["watch_source_ids"]

    event_ids = c.portal.call(event_source)
    unit = next(u for u in snapshot(c)["items"] if u["media"]["id"] == ids[0])
    assert event_ids == unit["watches"][0]["source_ids"]
    durable_events.reset_subscribed()
