"""同一成员在两台设备上同时首次开播同一单元：不报错，状态只有一行。

两个请求都先查到「还没有这一行」，再各自插入，后到的撞 ``uq_playback_state_unit``。
曾经直接 500（2026-10 观看统计端到端模拟时并发开播撞出来的）。
"""

from __future__ import annotations

import asyncio
import sqlite3

from sqlalchemy import event, select

from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import get_database
from movieclaw_db.models import PlaybackState
from movieclaw_playback import state as playback_state


async def _state_rows(unit) -> list[PlaybackState]:
    async with get_database().session() as session:
        return list(
            (
                await session.execute(
                    select(PlaybackState).where(
                        PlaybackState.member_id == 1,
                        PlaybackState.media_item_id == unit[0],
                    )
                )
            ).scalars()
        )


async def test_concurrent_first_start_on_two_devices(seeded_db) -> None:
    unit = (seeded_db["movie"], 0, 0)
    db = get_database()
    async with db.session() as first, db.session() as second:
        await playback_state.record_playback_start(first, unit, member_id=1)

        async def second_device() -> None:
            await playback_state.record_playback_start(second, unit, member_id=1)
            await second.commit()

        task = asyncio.create_task(second_device())
        await asyncio.sleep(0.3)
        await first.commit()
        await task  # 曾经在这里（或上一行）撞唯一约束

    assert len(await _state_rows(unit)) == 1


async def test_insert_that_loses_the_race_uses_the_winners_row(seeded_db) -> None:
    """确定性地复现「查到没有 → 别人抢先写入 → 自己插入撞键」：在本会话发出 INSERT
    之前，另一条连接把同一单元写进去并提交。"""
    unit = (seeded_db["movie"], 0, 0)
    db_path = get_settings().database_url.removeprefix("sqlite+aiosqlite:///")

    fired: list[bool] = []

    def other_device_wins(conn, cursor, statement, *_):
        if statement.startswith("INSERT INTO playback_state") and not fired:
            fired.append(True)
            other = sqlite3.connect(db_path)
            other.execute(
                "INSERT INTO playback_state (created_at, updated_at, member_id, media_item_id,"
                " season_number, episode_number, position_ms, played, play_count, is_favorite)"
                " VALUES (datetime('now'), datetime('now'), 1, ?, 0, 0, 0, 0, 1, 0)",
                (unit[0],),
            )
            other.commit()
            other.close()

    db = get_database()
    event.listen(db.engine.sync_engine, "before_cursor_execute", other_device_wins)
    try:
        async with db.session() as session:
            row = await playback_state.record_playback_start(session, unit, member_id=1)
            await session.commit()
    finally:
        event.remove(db.engine.sync_engine, "before_cursor_execute", other_device_wins)

    assert fired  # 确实走到了撞键那条路
    assert row.play_count == 2  # 用的是抢先写入的那一行（已计 1 次），再加上本次
    rows = await _state_rows(unit)
    assert len(rows) == 1 and rows[0].play_count == 2
