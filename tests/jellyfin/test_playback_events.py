"""播放 / 收藏 HTTP 流程产生的系统事件（docs/design/domain-events.md §8）。

在唯一入口 ``events.publish`` 处捕获（投递由 tests/api/test_webhook_delivery.py 等覆盖），验证：
事件与 handler 的映射、stopped/completed 双发、级联标记合成一个事件、收藏层级翻译（哨兵不外泄）、
client 信息透传、失败上报不产生事件。
"""

from __future__ import annotations

import inspect

import pytest
from fastapi.testclient import TestClient

from jellyfin.helpers import jf_login
from movieclaw_api import events
from movieclaw_api.services.playback import watch
from movieclaw_jellyfin.ids import episode_guid, item_guid, season_guid

TICKS_PER_MS = 10_000
RUNTIME_MS = 47 * 60 * 1000  # 播种剧集单集时长


class Published:
    def __init__(self, name: str, payload) -> None:  # type: ignore[no-untyped-def]
        self.event = name
        self.data = payload


@pytest.fixture
def emitted(monkeypatch) -> list:
    """捕获产生的播放、标记、收藏事件（替换 events.publish，不走总线）。"""
    watch._progress_last_emit.clear()  # progress 节流状态在用例间隔离
    captured: list = []

    async def publish(session, event, build):  # type: ignore[no-untyped-def]
        if not event.name.startswith(("playback.", "library.item.fav", "library.item.unfav")):
            return
        payload = build()
        if inspect.isawaitable(payload):
            payload = await payload
        if payload is not None:
            captured.append(Published(event.name, payload))

    monkeypatch.setattr(events, "publish", publish)
    return captured


def _auth(client: TestClient) -> dict:
    return {"ApiKey": jf_login(client)}


def test_started_event_with_client_info(client, seeded, emitted):
    auth = _auth(client)
    ep = episode_guid(seeded["show"], 1, 1)
    assert client.post("/Sessions/Playing", params=auth, json={"ItemId": ep}).status_code == 204
    assert [e.event for e in emitted] == ["playback.started"]
    payload = emitted[0].data
    assert payload.media.kind == "tv" and payload.media.tmdb_id == 1396
    assert (payload.unit.season, payload.unit.episode) == (1, 1)
    assert payload.play_count == 1
    # client 信息来自登录时注册的设备（helpers.AUTH_HEADER）
    assert payload.client.name == "Infuse"
    assert payload.client.device_name == "Apple TV"


def test_progress_events_and_throttle(client, seeded, emitted):
    auth = _auth(client)
    ep = episode_guid(seeded["show"], 1, 1)
    # 40%：普通进度 → 发一条 progress
    client.post(
        "/Sessions/Playing/Progress",
        params=auth,
        json={"ItemId": ep, "PositionTicks": int(RUNTIME_MS * 0.4) * TICKS_PER_MS},
    )
    assert [e.event for e in emitted] == ["playback.progress"]
    assert emitted[0].data.position_ms == int(RUNTIME_MS * 0.4)
    # 30 秒内再报进度：被节流，不产生事件
    emitted.clear()
    client.post(
        "/Sessions/Playing/Progress",
        params=auth,
        json={"ItemId": ep, "PositionTicks": RUNTIME_MS // 2 * TICKS_PER_MS},
    )
    assert emitted == []
    # 95%：仅靠 Progress 翻转已看 → 只发 completed（progress 被 completed 抑制）
    client.post(
        "/Sessions/Playing/Progress",
        params=auth,
        json={"ItemId": ep, "PositionTicks": int(RUNTIME_MS * 0.95) * TICKS_PER_MS},
    )
    assert [e.event for e in emitted] == ["playback.completed"]
    assert emitted[0].data.played is True
    assert emitted[0].data.duration_ms == RUNTIME_MS


def test_stopped_at_end_emits_stopped_and_completed(client, seeded, emitted):
    auth = _auth(client)
    ep = episode_guid(seeded["show"], 2, 1)
    client.post(
        "/Sessions/Playing/Stopped",
        params=auth,
        json={"ItemId": ep, "PositionTicks": int(RUNTIME_MS * 0.95) * TICKS_PER_MS},
    )
    assert [e.event for e in emitted] == ["playback.stopped", "playback.completed"]
    assert emitted[0].data.completed is True  # 停止时刚好看完
    # 已看状态下再次停止：只发 stopped，不重复 completed
    emitted.clear()
    client.post(
        "/Sessions/Playing/Stopped",
        params=auth,
        json={"ItemId": ep, "PositionTicks": int(RUNTIME_MS * 0.95) * TICKS_PER_MS},
    )
    assert [e.event for e in emitted] == ["playback.stopped"]
    assert emitted[0].data.completed is False


def test_stopped_failed_emits_nothing(client, seeded, emitted):
    auth = _auth(client)
    movie = item_guid(seeded["movie"])
    client.post(
        "/Sessions/Playing/Stopped",
        params=auth,
        json={"ItemId": movie, "PositionTicks": 999 * TICKS_PER_MS, "Failed": True},
    )
    assert emitted == []


def test_legacy_start_route_emits(client, seeded, emitted):
    auth = _auth(client)
    movie = item_guid(seeded["movie"])
    assert client.post(f"/PlayingItems/{movie}", params=auth).status_code == 204
    assert [e.event for e in emitted] == ["playback.started"]
    payload = emitted[0].data
    assert payload.media.kind == "movie"
    assert payload.unit is None  # 电影的内部单元 (0,0) 不外泄


def test_mark_played_cascade_is_one_event(client, seeded, emitted):
    auth = _auth(client)
    show = item_guid(seeded["show"])
    assert client.post(f"/UserPlayedItems/{show}", params=auth).status_code == 200
    # 播种了 3 集 → 一个事件，带受影响的 3 集
    assert [e.event for e in emitted] == ["playback.marked_played"]
    assert len(emitted[0].data.units) == 3

    emitted.clear()
    client.request("DELETE", f"/UserPlayedItems/{show}", params=auth)
    assert [e.event for e in emitted] == ["playback.marked_unplayed"]
    assert len(emitted[0].data.units) == 3


def test_favorite_levels_no_sentinel_leak(client, seeded, emitted):
    auth = _auth(client)
    season = season_guid(seeded["show"], 2)
    show = item_guid(seeded["show"])

    client.post(f"/UserFavoriteItems/{season}", params=auth)
    client.post(f"/UserFavoriteItems/{show}", params=auth)
    assert [e.event for e in emitted] == ["library.item.favorited"] * 2
    on_season = emitted[0].data
    assert (on_season.level, on_season.season, on_season.episode) == ("season", 2, None)
    on_series = emitted[1].data
    assert (on_series.level, on_series.season) == ("series", None)  # 哨兵 -1 不外泄

    emitted.clear()
    client.request("DELETE", f"/UserFavoriteItems/{show}", params=auth)
    assert [e.event for e in emitted] == ["library.item.unfavorited"]
