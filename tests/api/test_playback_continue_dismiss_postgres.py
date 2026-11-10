"""真实 Postgres（``READ COMMITTED``）：「接下来继续」隐藏与并发播放的两事务交错。

SQLite 全库串行写，抓不到这类窗口；这里用两条真实连接、在关键点停住一方，让另一方
在中间跑完（或证明它被作品级锁挡住），再看最终结果：

- 隐藏先过锚点校验、未提交时另一台设备播了下一集 → 最终没有标记（较新的播放赢）；
- 播放先写、未提交时来了隐藏 → 隐藏等它提交后按新锚点判冲突，不留标记。

需要 ``MOVIECLAW_TEST_POSTGRES_URL``（如 ``postgresql+asyncpg://postgres@/postgres?host=/tmp/pg``）
与 asyncpg；没配就跳过（同 .env 里其它外部依赖的约定）。每个用例建一个临时库，结束即删。
"""

from __future__ import annotations

import asyncio
import os
import uuid
from datetime import UTC

import pytest
from sqlalchemy import select, text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from movieclaw_api.schemas.playback_sync import SyncChangeIn, SyncStateIn
from movieclaw_api.services import playback_sync
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.playback_up_next import continue_anchor
from movieclaw_db.models import (
    FileSource,
    FileState,
    Library,
    LibraryFile,
    MediaItem,
    PlaybackState,
)
from movieclaw_playback import state as playback_state

PG_URL = os.environ.get("MOVIECLAW_TEST_POSTGRES_URL")
pytestmark = pytest.mark.skipif(not PG_URL, reason="MOVIECLAW_TEST_POSTGRES_URL 未配置")
ADMIN = Principal(kind="admin", name="admin")
MEMBER = 0  # 超管哨兵：可见性最简单，锁与校验路径与普通成员相同
#: 被锁挡住的一方至少要等这么久仍没完成，才算"确实被挡住"
BLOCKED_FOR = 1.0


@pytest.fixture
def pg(tmp_path):
    pytest.importorskip("asyncpg")
    assert PG_URL is not None
    name = f"mc_dismiss_{uuid.uuid4().hex[:12]}"
    admin_url = make_url(PG_URL)
    url = admin_url.set(database=name)

    async def admin(sql: str) -> None:
        engine = create_async_engine(admin_url, isolation_level="AUTOCOMMIT")
        async with engine.connect() as conn:
            await conn.execute(text(sql))
        await engine.dispose()

    async def setup():
        await admin(f'CREATE DATABASE "{name}"')
        engine = create_async_engine(url)
        async with engine.begin() as conn:
            await conn.run_sync(SQLModel.metadata.create_all)
        sessions = async_sessionmaker(
            bind=engine, class_=AsyncSession, expire_on_commit=False, autoflush=False
        )
        async with sessions() as s:
            library = Library(name="库", kind="tv", root_paths=[str(tmp_path)])
            show = MediaItem(kind="tv", title="剧", original_title="T", tmdb_id=200)
            s.add_all([library, show])
            await s.flush()
            for episode in (1, 2):
                s.add(
                    LibraryFile(
                        library_id=library.id,
                        media_item_id=show.id,
                        season_number=1,
                        episode_number=episode,
                        file_path=str(tmp_path / f"e{episode}.mkv"),
                        size_bytes=1,
                        source=FileSource.SCANNED,
                        state=FileState.IN_PLACE,
                        duration_seconds=600,
                    )
                )
            await s.commit()
            return engine, sessions, show.id

    loop = asyncio.new_event_loop()
    engine, sessions, show = loop.run_until_complete(setup())
    try:
        yield loop, sessions, show
    finally:
        loop.run_until_complete(engine.dispose())
        loop.run_until_complete(admin(f'DROP DATABASE "{name}" WITH (FORCE)'))
        loop.close()


async def _play(sessions, show: int, episode: int) -> None:
    """一次真实进度上报（同 /playback/progress 的领域服务），自己的事务。"""
    async with sessions() as s:
        await playback_state.record_playback_start(s, (show, 1, episode), member_id=MEMBER)
        await playback_state.record_playback_progress(
            s, (show, 1, episode), member_id=MEMBER, position_ms=100_000, runtime_ms=600_000
        )
        await s.commit()


async def _dismiss(sessions, show: int, episode: int) -> str:
    """按刚读到的版本对某一集发 dismiss_continue=true（同 /playback/sync/state）。"""
    async with sessions() as s:
        row = (
            await s.execute(
                select(PlaybackState).where(
                    PlaybackState.member_id == MEMBER,
                    PlaybackState.media_item_id == show,
                    PlaybackState.episode_number == episode,
                )
            )
        ).scalar_one()
        version = row.updated_at.replace(tzinfo=UTC)
    payload = SyncStateIn(
        member_id=MEMBER,
        changes=[
            SyncChangeIn(
                media_item_id=show,
                kind="tv",
                tmdb_id=200,
                season=1,
                episode=episode,
                expected_updated_at=version,
                dismiss_continue=True,
            )
        ],
    )
    async with sessions() as s:
        outcomes = await playback_sync.apply_state(s, ADMIN, payload)
    return outcomes[0].status


async def _flags(sessions, show: int) -> dict[int, bool]:
    async with sessions() as s:
        rows = (
            await s.execute(
                select(PlaybackState.episode_number, PlaybackState.continue_dismissed).where(
                    PlaybackState.member_id == MEMBER, PlaybackState.media_item_id == show
                )
            )
        ).all()
        return {int(e): bool(f) for e, f in rows}


async def _anchor(sessions, show: int):
    async with sessions() as s:
        return await continue_anchor(s, MEMBER, show)


async def _blocked(task: asyncio.Task) -> bool:
    """给 task 一段时间：期间没完成即视为被锁挡住。"""
    done, _ = await asyncio.wait({task}, timeout=BLOCKED_FOR)
    return not done


def test_concurrent_next_episode_play_clears_a_dismiss_that_passed_the_anchor_check(
    pg, monkeypatch
):
    """T1 隐藏 E1 已过锚点校验未提交 → T2 播 E2 → T1 提交：标记不能留在 E1 上。"""
    loop, sessions, show = pg
    loop.run_until_complete(_play(sessions, show, 1))
    checked, release = asyncio.Event(), asyncio.Event()
    original = playback_sync.continue_anchor

    async def paused_anchor(session, member_id, media_item_id):
        anchor = await original(session, member_id, media_item_id)
        checked.set()
        await release.wait()  # T1 停在"校验已过、尚未提交"
        return anchor

    monkeypatch.setattr(playback_sync, "continue_anchor", paused_anchor)

    async def scenario():
        t1 = asyncio.create_task(_dismiss(sessions, show, 1))
        await asyncio.wait_for(checked.wait(), 10)
        assert await _anchor(sessions, show) == (1, 1)
        t2 = asyncio.create_task(_play(sessions, show, 2))
        # 作品级锁：T2 的清标记必须排在 T1 之后，不能在 T1 未提交时"无物可清"地先提交
        blocked = await _blocked(t2)
        release.set()
        status = await asyncio.wait_for(t1, 10)
        await asyncio.wait_for(t2, 10)
        return blocked, status

    blocked, status = loop.run_until_complete(scenario())
    assert blocked, "T2 没被作品级锁挡住：并发窗口仍在"
    assert status == "applied"  # 隐藏在 T1 当时确实落在锚点上
    assert loop.run_until_complete(_anchor(sessions, show)) == (1, 2)
    # E2 是隐藏之后更新的播放：整部作品不能还带标记（首页"任一行带标记就整部隐藏"）
    assert loop.run_until_complete(_flags(sessions, show)) == {1: False, 2: False}


def test_dismiss_waits_for_a_concurrent_uncommitted_play_and_then_conflicts(pg, monkeypatch):
    """T2 播 E2 已写未提交 → T1 隐藏 E1 → T2 提交：T1 看到新锚点 E2，冲突且不留标记。"""
    loop, sessions, show = pg
    loop.run_until_complete(_play(sessions, show, 1))
    wrote, release = asyncio.Event(), asyncio.Event()
    original = playback_state.note_playback
    pause = {"armed": True}

    async def paused_note(session, **kw):
        await original(session, **kw)
        if pause["armed"]:
            pause["armed"] = False
            wrote.set()
            await release.wait()  # T2 停在"播放已写、尚未提交"

    monkeypatch.setattr(playback_state, "note_playback", paused_note)

    async def scenario():
        t2 = asyncio.create_task(_play(sessions, show, 2))
        await asyncio.wait_for(wrote.wait(), 10)
        t1 = asyncio.create_task(_dismiss(sessions, show, 1))
        blocked = await _blocked(t1)
        release.set()
        await asyncio.wait_for(t2, 10)
        return blocked, await asyncio.wait_for(t1, 10)

    blocked, status = loop.run_until_complete(scenario())
    assert blocked, "T1 没等 T2 提交就做了锚点校验"
    assert status == "conflict"
    assert loop.run_until_complete(_anchor(sessions, show)) == (1, 2)
    assert loop.run_until_complete(_flags(sessions, show)) == {1: False, 2: False}
