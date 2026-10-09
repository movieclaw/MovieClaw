"""公开演示站的订阅与观看数据（services/demo_activity.py）的不变量。

造出来的数据给访客看，所以守的是「看起来合理」：不出现未来时刻、没入库就看过、
超管看过的片却挂在他的「刚刚入库」里；每天重启重建时不能越堆越多；
「正在播放」同一时刻算出来的结果一致、进度落在片长之内。
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest_asyncio
from sqlalchemy import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import demo_activity
from movieclaw_api.services.rule_sets import RuleSetService
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaItem,
    PlaybackLog,
    PlaybackState,
    Subscription,
    SubscriptionFollower,
    WantedItem,
)
from movieclaw_db.models.member import Member
from movieclaw_db.repositories.library_repo import LibraryRepository

NOW = datetime(2026, 9, 28, 12, 0)


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'demo.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    async with get_database().session() as session:
        movies = await LibraryRepository(session).create(
            name="电影", kind="movie", root_paths=["/m"]
        )
        await LibraryRepository(session).create(name="图片", kind="photo", root_paths=["/p"])
        items = [
            MediaItem(kind="movie", tmdb_id=100 + i, title=f"影片{i}", original_title=f"F{i}")
            for i in range(6)
        ]
        session.add_all(items)
        session.add(Member(username="family", password_hash="x", nickname="家人"))
        await session.flush()
        session.add_all(
            LibraryFile(
                library_id=movies.id,
                media_item_id=item.id,
                file_path=f"/m/{item.id}.mp4",
                size_bytes=500_000_000,
                source=FileSource.SCANNED,
                duration_seconds=600,
                state=FileState.IN_PLACE,
            )
            for item in items
        )
        await session.commit()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


async def test_seeded_data_is_plausible_and_idempotent(db) -> None:
    await demo_activity.seed_demo_data(NOW)
    await demo_activity.seed_demo_data(NOW)  # 当天重启：结果不翻倍

    async with db.session() as session:
        subs = (await session.execute(select(Subscription))).scalars().all()
        wanted = {w.media_item_id: w for w in (await session.execute(select(WantedItem))).scalars()}
        logs = (await session.execute(select(PlaybackLog))).scalars().all()
        states = (await session.execute(select(PlaybackState))).scalars().all()
        followers = (await session.execute(select(SubscriptionFollower))).scalars().all()
        family_id = (await session.execute(select(Member.id))).scalar_one()

    assert len(subs) == 6 and all(s.status == "completed" for s in subs)
    assert any(s.created_by_member_id == family_id for s in subs) or followers
    recent = {i for i, w in wanted.items() if NOW - w.imported_at < timedelta(days=7)}
    assert len(recent) == 3

    assert logs, "应该造出播放记录"
    for log in logs:
        assert demo_activity.is_seeded_device(log.device_id)
        assert log.ended_at is not None and log.ended_at < NOW
        assert log.started_at >= wanted[log.media_item_id].imported_at
        if log.member_id == 0:
            assert log.media_item_id not in recent, "超管看过的片不该挂在他的「刚刚入库」里"

    admin_played = {s.media_item_id for s in states if s.member_id == 0 and s.played}
    assert not admin_played & recent
    assert any(s.is_favorite for s in states)
    assert any(s.position_ms > 0 and not s.played for s in states), "「继续观看」需要续播点"



async def test_reseeding_keeps_real_subscriptions(db) -> None:
    """审核账号建的真订阅（demo-site.md §9）：当天重启重建演示数据时原样保留，
    那部片也不再另造一条假订阅。"""
    async with db.session() as session:
        first_item = (await session.execute(select(MediaItem.id).order_by(MediaItem.id))).scalar()
        rule_set = await RuleSetService(session).ensure_default()
        real = Subscription(
            media_item_id=first_item,
            kind="movie",
            selected_seasons=[],
            follow_future=False,
            rule_set_id=rule_set.id,
        )
        session.add(real)
        await session.commit()
        real_id = real.id

    await demo_activity.seed_demo_data(NOW)
    await demo_activity.seed_demo_data(NOW)

    async with db.session() as session:
        subs = (await session.execute(select(Subscription))).scalars().all()
    assert real_id in {s.id for s in subs}
    assert [s.media_item_id for s in subs].count(first_item) == 1
    assert len(subs) == 6

async def test_live_sessions_are_deterministic_and_within_runtime(db) -> None:
    await demo_activity.seed_demo_data(NOW)
    epoch = NOW.timestamp()
    first = demo_activity.live_sessions(epoch)
    again = demo_activity.live_sessions(epoch)
    assert [(s.device_id, s.unit, s.position_ms) for s in first] == [
        (s.device_id, s.unit, s.position_ms) for s in again
    ]
    later = {s.device_id: s for s in demo_activity.live_sessions(epoch + 30)}
    for session in first:
        assert demo_activity.is_seeded_device(session.device_id)
        assert 0 <= (session.position_ms or 0) < 600_000
        follow = later.get(session.device_id)
        if follow is not None and follow.unit == session.unit:
            assert follow.position_ms == (session.position_ms or 0) + 30_000


def test_live_sessions_rarely_all_idle(monkeypatch) -> None:
    """按演示站的真实片长（多是两三分钟的短片）算一整天：「正在播放」一路都没有
    的时候要少见——访客打开活动页，多数时候应当看得到有人在看。"""
    films = [11, 10, 15, 12, 8, 4, 3]  # 分钟：电影库
    shorts = [4, 1.5, 2.5, 2.5, 3, 2]  # 分钟：动画短片库

    def units(minutes: list[float]) -> tuple:
        return tuple(
            demo_activity._Unit(i, "movie", f"片{i}", 1, i, int(m * 60_000), 10**8)
            for i, m in enumerate(minutes, start=1)
        )

    devices = {d.device_id: d for v in demo_activity._VIEWERS for d in v.devices}
    channels = (
        demo_activity._LiveChannel(0, devices["demo-admin-mac"], units(films + shorts), 0.5),
        demo_activity._LiveChannel(1, devices["demo-family-atv"], units(films + shorts), 0.85),
        demo_activity._LiveChannel(2, devices["demo-kids-ipad"], units(shorts), 0.85),
        demo_activity._LiveChannel(3, devices["demo-guest-pc"], units(films), 0.3),
    )
    monkeypatch.setattr(demo_activity, "_live_channels", channels)
    epoch = NOW.timestamp()
    counts = [len(demo_activity.live_sessions(epoch + minute * 60)) for minute in range(1440)]
    assert counts.count(0) / len(counts) < 0.12
    assert max(counts) >= 3, "路数要有起有落，高峰时能看到好几路"


async def test_demo_history_shows_preset_names_and_hides_visitor_text(db, monkeypatch) -> None:
    """演示模式下的「最近播放」：演示数据显示预设文案；访客的第三方播放器（包括
    冒用演示设备标识的）自报的文字不原样出现。曾因把查询结果直接交给 dict() 而 500。"""
    from movieclaw_api.api.routes.playback import list_playback_history
    from movieclaw_api.services.auth import Principal
    from movieclaw_api.settings.store import init_setting_store, reset_setting_store

    await demo_activity.seed_demo_data(NOW)
    async with get_database().session() as session:
        seeded = (await session.execute(select(PlaybackLog).limit(1))).scalars().one()
        fields = seeded.model_dump(exclude={"id", "device_id", "client", "device_name"})
        started = datetime.now(UTC).replace(tzinfo=None) - timedelta(minutes=5)
        fields.update(started_at=started, ended_at=started + timedelta(minutes=1))
        for device_id in ("demo-family-atv", "visitor-1"):
            bad = {"client": "不当文字", "device_name": "不当文字"}
            session.add(PlaybackLog(**fields, **bad, device_id=device_id))
        await session.commit()

    monkeypatch.setenv("MOVIECLAW_DEMO_MODE", "true")
    get_settings.cache_clear()
    init_setting_store(database=get_database())
    async with get_database().session() as session:
        resp = await list_playback_history(
            limit=200,
            before=None,
            days=None,
            member_id=None,
            scope="all",
            principal=Principal(kind="admin", name="admin"),
            session=session,
        )
    reset_setting_store()
    entries = resp.data.entries
    assert entries
    assert all("不当文字" not in (e.client, e.device_name) for e in entries)
    assert {"Infuse", "第三方播放器"} <= {e.client for e in entries}
