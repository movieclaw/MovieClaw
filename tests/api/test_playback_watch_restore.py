"""取流只能恢复近期、已上报过播放的会话（issue #624）。"""

from __future__ import annotations

from datetime import timedelta
from unittest.mock import AsyncMock

import pytest

from movieclaw_api.services.playback import watch
from movieclaw_db.models import PlaybackLog, PlaybackState
from movieclaw_db.models.base import utcnow
from movieclaw_playback import activity
from movieclaw_playback.events import ClientInfo

CLIENT = ClientInfo(name="Infuse", device_id="dev-1")
UNIT = (1, 0, 0)


@pytest.fixture(autouse=True)
def clean_registry():
    activity.reset()
    yield
    activity.reset()


@pytest.mark.parametrize("has_resume_point", [False, True])
async def test_stream_without_open_log_does_not_create_session(monkeypatch, has_resume_point):
    monkeypatch.setattr(watch, "_open_log", AsyncMock(return_value=None))
    states = {UNIT: PlaybackState(media_item_id=UNIT[0], position_ms=60_000)}
    monkeypatch.setattr(
        watch.playback_state,
        "get_states",
        AsyncMock(return_value=states if has_resume_point else {}),
    )

    await watch.restore_session_from_stream(AsyncMock(), UNIT, member_id=0, client=CLIENT)

    assert activity.snapshot()[0] == []


@pytest.mark.parametrize("age_seconds", [0, activity.SESSION_TTL_SECONDS - 1])
async def test_stream_restores_recent_open_log(monkeypatch, age_seconds):
    now = utcnow()
    row = PlaybackLog(
        media_item_id=UNIT[0],
        device_id=CLIENT.device_id,
        started_at=now - timedelta(seconds=age_seconds + 60),
        last_seen_at=now - timedelta(seconds=age_seconds),
        end_position_ms=90_000,
    )
    monkeypatch.setattr(watch, "_open_log", AsyncMock(return_value=row))

    await watch.restore_session_from_stream(AsyncMock(), UNIT, member_id=0, client=CLIENT)

    restored = activity.snapshot()[0][0]
    assert restored.unit == UNIT
    assert restored.position_ms == 90_000
    assert restored.started_at == row.started_at
    assert restored.local_streamed is True


@pytest.mark.parametrize(
    "age_seconds", [activity.SESSION_TTL_SECONDS, activity.SESSION_TTL_SECONDS + 1]
)
async def test_stream_does_not_revive_stale_unclosed_log(monkeypatch, age_seconds):
    row = PlaybackLog(
        media_item_id=UNIT[0],
        device_id=CLIENT.device_id,
        last_seen_at=utcnow() - timedelta(seconds=age_seconds),
    )
    monkeypatch.setattr(watch, "_open_log", AsyncMock(return_value=row))

    await watch.restore_session_from_stream(AsyncMock(), UNIT, member_id=0, client=CLIENT)

    assert activity.snapshot()[0] == []
