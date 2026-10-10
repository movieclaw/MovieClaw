"""第一批领域事件（docs/design/plugin-phase2a.md §4）：写入点、快照内容、零开销。

业务侧只管写（``domain_event`` 行随记录事实的那次提交成立），投递在 test_durable_events.py。
这里用「登记一个消费者行」模拟有插件订阅，然后走真实的路由 / 服务函数，检查写下来的事件。
最后一条走完整链路：真实应用 + 运行中挂载的订阅插件，删条目 → 插件收到快照。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
import pytest_asyncio
from fastapi import BackgroundTasks
from fastapi.testclient import TestClient
from sqlmodel import select

from movieclaw_api import domain_events as de
from movieclaw_api.api.routes.libraries import (
    delete_library_file,
    delete_library_item,
    purge_library_file,
    restore_library_file,
)
from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events
from movieclaw_api.services.library.recycle import recycle_file
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    DomainEvent,
    DownloaderClient,
    EventConsumer,
    FileSource,
    LibraryFile,
    MediaItem,
    RuleSet,
    Subscription,
    SubscriptionDownloadAttempt,
    utcnow,
)
from movieclaw_db.repositories.library_repo import LibraryRepository


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'domain.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    durable_events.reset_state()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    durable_events.reset_state()
    await dispose_db()
    get_settings.cache_clear()


async def subscribe(db, *events) -> None:
    """模拟有插件订阅：登记消费者行（真实订阅时由投递插件写入）。"""
    async with db.session() as session:
        for event in events:
            session.add(EventConsumer(consumer_id=f"test:{event.name}", event_name=event.name))
        await session.commit()
    durable_events.reset_subscribed()


async def recorded(db, name: str | None = None) -> list[dict]:
    async with db.session() as session:
        query = select(DomainEvent).order_by(DomainEvent.seq)
        if name is not None:
            query = query.where(DomainEvent.name == name)
        return [
            {"name": row.name, **row.payload} for row in (await session.execute(query)).scalars()
        ]


async def record_sources(session, rows: list[LibraryFile]) -> None:
    """像入库桥一样把来源记到下载领域（library-boundary.md §5）。"""
    from movieclaw_api.services.download_sources import record_source

    await session.flush()
    for row in rows:
        await record_source(
            session,
            row.id,
            info_hash=row.info_hash,
            downloader_id=row.downloader_id,
            site_id=row.site_id,
            torrent_id=row.torrent_id,
        )


async def seed_show(db, tmp_path: Path, *, info_hash: str = "packhash") -> dict:
    """一部剧两集，季包由订阅投递（自有、非 H&R）；第二集的文件另记着一个来源种子。"""
    root = tmp_path / "media" / "tv"
    show = root / "测试剧集 (2024)" / "Season 01"
    show.mkdir(parents=True)
    e1 = show / "测试剧集 - S01E01.mkv"
    e2 = show / "测试剧集 - S01E02.mkv"
    e1.write_bytes(b"e1")
    e2.write_bytes(b"e2")
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=[str(root)]
        )
        downloader = DownloaderClient(name="qb", client_type="qbittorrent", url="http://qb")
        item = MediaItem(
            kind="tv", tmdb_id=1, title="测试剧集", original_title="Test Show", year=2024
        )
        rules = RuleSet(name="默认", spec={})
        session.add_all([downloader, item, rules])
        await session.flush()
        sub = Subscription(media_item_id=item.id, kind="tv", rule_set_id=rules.id)
        session.add(sub)
        await session.flush()
        session.add(
            SubscriptionDownloadAttempt(
                subscription_id=sub.id,
                downloader_id=downloader.id,
                info_hash=info_hash.upper(),
                torrent_title="Test.Show.S01.1080p",
                units=[[1, 1], [1, 2]],
                owned_by_movieclaw=True,
                hit_and_run=False,
                last_progress_at=utcnow(),
            )
        )
        rows = []
        for ep, path in ((1, e1), (2, e2)):
            row = LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                season_number=1,
                episode_number=ep,
                file_path=str(path),
                size_bytes=2,
                source=FileSource.IMPORTED,
                info_hash=info_hash.lower(),
                downloader_id=downloader.id,
            )
            session.add(row)
            rows.append(row)
        await record_sources(session, rows)
        await session.commit()
        return {
            "library_id": library.id,
            "item_id": item.id,
            "sub_id": sub.id,
            "downloader_id": downloader.id,
            "file_ids": [r.id for r in rows],
            "paths": [e1, e2],
        }


# ---------------------------------------------------------------------- 删除
async def test_no_subscriber_means_no_snapshot_and_no_rows(db, tmp_path) -> None:
    seeded = await seed_show(db, tmp_path)
    async with db.session() as session:
        item = await session.get(MediaItem, seeded["item_id"])
        assert await de.deletion_recorder(session, seeded["library_id"], item, []) is None
        await delete_library_item(
            seeded["library_id"], seeded["item_id"], BackgroundTasks(), session
        )
    assert await recorded(db) == []


async def test_deleting_one_episode_records_file_deleted_with_shared_pack(db, tmp_path) -> None:
    seeded = await seed_show(db, tmp_path)
    await subscribe(db, de.LIBRARY_FILE_DELETED, de.LIBRARY_ITEM_DELETED)
    async with db.session() as session:
        await delete_library_file(
            seeded["library_id"],
            seeded["item_id"],
            seeded["file_ids"][0],
            BackgroundTasks(),
            session,
        )
    [event] = await recorded(db)
    assert event["name"] == "library.file.deleted"
    assert event["whole_item"] is False
    assert event["media"]["title"] == "测试剧集" and event["media"]["tmdb_id"] == 1
    assert [(f["season"], f["episode"]) for f in event["files"]] == [(1, 1)]
    assert event["files"][0]["info_hash"] == "packhash"
    assert event["links"]["subscription_id"] == seeded["sub_id"]
    [torrent] = event["links"]["torrents"]
    # 季包还供着第二集：插件据此知道不能顺手删种
    assert torrent == {
        "info_hash": "packhash",
        "downloader_id": seeded["downloader_id"],
        "title": "Test.Show.S01.1080p",
        "source": "subscription",
        "site_id": None,
        "torrent_id": None,
        "owned_by_movieclaw": True,
        "hit_and_run": False,
        "shared": True,
    }


async def test_deleting_whole_item_records_item_deleted(db, tmp_path) -> None:
    seeded = await seed_show(db, tmp_path)
    await subscribe(db, de.LIBRARY_ITEM_DELETED)
    async with db.session() as session:
        await delete_library_item(
            seeded["library_id"], seeded["item_id"], BackgroundTasks(), session
        )
    [event] = await recorded(db)
    assert event["name"] == "library.item.deleted" and event["whole_item"] is True
    assert sorted(f["id"] for f in event["files"]) == sorted(seeded["file_ids"])
    [torrent] = event["links"]["torrents"]
    assert torrent["shared"] is False
    assert not seeded["paths"][0].exists()


async def seed_shared_pack(
    db, tmp_path: Path, *, other_identified: bool, info_hash: str = "d" * 40
) -> dict:
    """一个合集种子拆进了两行：本条目一部电影 + 另一行（另一部电影，或没识别的文件）。"""
    root = tmp_path / "media" / "movies"
    root.mkdir(parents=True)
    mine = root / "电影甲 (2001).mkv"
    other = root / "电影乙 (2003).mkv"
    mine.write_bytes(b"a")
    other.write_bytes(b"b")
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=[str(root)]
        )
        downloader = DownloaderClient(name="qb", client_type="qbittorrent", url="http://qb")
        first = MediaItem(
            kind="movie", tmdb_id=11, title="电影甲", original_title="Movie A", year=2001
        )
        second = MediaItem(
            kind="movie", tmdb_id=12, title="电影乙", original_title="Movie B", year=2003
        )
        session.add_all([downloader, first, second])
        await session.flush()
        rows = []
        for item_id, path in ((first.id, mine), (second.id if other_identified else None, other)):
            row = LibraryFile(
                library_id=library.id,
                media_item_id=item_id,
                file_path=str(path),
                size_bytes=1,
                source=FileSource.IMPORTED,
                info_hash=info_hash,
                downloader_id=downloader.id,
            )
            session.add(row)
            rows.append(row)
        await record_sources(session, rows)
        await session.commit()
        return {
            "library_id": library.id,
            "item_id": first.id,
            "other_file_id": rows[1].id,
        }


@pytest.mark.parametrize("other_identified", [True, False])
async def test_torrent_shared_with_other_items_is_marked_shared(
    db, tmp_path, other_identified
) -> None:
    """合集种子还供着别的条目（或没识别的文件）：删了种子会毁掉它们，必须标 shared。"""
    seeded = await seed_shared_pack(db, tmp_path, other_identified=other_identified)
    await subscribe(db, de.LIBRARY_ITEM_DELETED)
    async with db.session() as session:
        await delete_library_item(
            seeded["library_id"], seeded["item_id"], BackgroundTasks(), session
        )
    [event] = await recorded(db)
    assert event["whole_item"] is True
    [torrent] = event["links"]["torrents"]
    assert torrent["info_hash"] == "d" * 40
    assert torrent["shared"] is True


async def test_relations_list_files_of_other_items_on_the_same_torrent(db, tmp_path) -> None:
    from movieclaw_api.api.routes.download_sources import get_item_relations
    from movieclaw_api.services.download_sources import item_relations

    seeded = await seed_shared_pack(db, tmp_path, other_identified=True)
    async with db.session() as session:
        relations = await item_relations(session, seeded["item_id"])
        reply = await get_item_relations(seeded["library_id"], seeded["item_id"], session)
    [torrent] = relations.torrents
    assert torrent.other_file_ids == (seeded["other_file_id"],)
    # 插件经「查条目关联」接口自己判断时看得到同样的信息
    [view] = reply.data.torrents
    assert view.other_file_ids == [seeded["other_file_id"]]


async def test_failed_disk_delete_records_nothing(db, tmp_path, monkeypatch) -> None:
    # 磁盘删除失败的行保留台账：事件只描述真正删掉的，什么都没删就不发
    import movieclaw_api.services.library.items as items_mod

    seeded = await seed_show(db, tmp_path)
    await subscribe(db, de.LIBRARY_FILE_DELETED, de.LIBRARY_ITEM_DELETED)
    monkeypatch.setattr(items_mod, "_discard_file_with_sidecars", lambda *a, **k: False)
    async with db.session() as session:
        await delete_library_file(
            seeded["library_id"],
            seeded["item_id"],
            seeded["file_ids"][0],
            BackgroundTasks(),
            session,
        )
    assert await recorded(db) == []


# ---------------------------------------------------------------------- 回收站
async def test_recycle_restore_and_purge_record_events(db, tmp_path) -> None:
    seeded = await seed_show(db, tmp_path)
    await subscribe(db, de.LIBRARY_FILE_TRASHED, de.LIBRARY_FILE_RESTORED, de.LIBRARY_FILE_PURGED)
    file_id = seeded["file_ids"][1]
    trigger = {"kind": "subscription", "id": seeded["sub_id"], "label": "洗版"}
    async with db.session() as session:
        row = await session.get(LibraryFile, file_id)
        await recycle_file(session, row, reason="upgrade_replaced", trigger=trigger, note="")
        await session.commit()
    async with db.session() as session:
        await restore_library_file(seeded["library_id"], seeded["item_id"], file_id, session)
    async with db.session() as session:
        row = await session.get(LibraryFile, file_id)
        await recycle_file(session, row, reason="duplicate_cleanup", trigger={}, note="")
        await session.commit()
    async with db.session() as session:
        await purge_library_file(seeded["library_id"], seeded["item_id"], file_id, session)

    events = await recorded(db)
    assert [(e["name"], e["reason"]) for e in events] == [
        ("library.file.trashed", "upgrade_replaced"),
        ("library.file.restored", "upgrade_replaced"),
        ("library.file.trashed", "duplicate_cleanup"),
        ("library.file.purged", "manual"),
    ]
    assert events[0]["trigger_kind"] == "subscription"
    assert events[0]["trigger_id"] == str(seeded["sub_id"])
    assert events[0]["file"]["original_path"] == str(seeded["paths"][1])
    assert events[0]["media"]["title"] == "测试剧集"


async def test_rolled_back_recycle_leaves_no_event(db, tmp_path) -> None:
    seeded = await seed_show(db, tmp_path)
    await subscribe(db, de.LIBRARY_FILE_TRASHED)
    async with db.session() as session:
        row = await session.get(LibraryFile, seeded["file_ids"][0])
        await recycle_file(session, row, reason="manual", trigger={}, note="")
        await session.rollback()
    assert await recorded(db) == []


# ---------------------------------------------------------------------- 订阅
async def test_subscription_status_and_delete_events(db, tmp_path) -> None:
    from movieclaw_api.services.subscription import SubscriptionService

    seeded = await seed_show(db, tmp_path)
    await subscribe(db, de.SUBSCRIPTION_STATUS_CHANGED, de.SUBSCRIPTION_DELETED)
    async with db.session() as session:
        service = SubscriptionService(session, None)  # type: ignore[arg-type]
        await service.set_paused(seeded["sub_id"], True)
        await service.set_paused(seeded["sub_id"], True)  # 已暂停再暂停：没有变化，不发
        await service.delete_permanently(seeded["sub_id"])
    events = await recorded(db)
    assert [(e["name"], e["previous_status"], e["status"], e["reason"]) for e in events] == [
        ("subscription.status-changed", "active", "paused", "paused"),
        ("subscription.deleted", None, "paused", "deleted"),
    ]
    assert events[1]["media"]["title"] == "测试剧集"


# ---------------------------------------------------------------------- 完整链路
def test_plugin_receives_deletion_snapshot_end_to_end(tmp_path, monkeypatch) -> None:
    """真实应用：运行中挂载一个订阅删除事件的插件 → 调删除接口 → 插件拿到删除前的快照。"""
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal
    from movieclaw_kernel import DURABLE_EVENTS, Entry, plugin

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'e2e.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()

    received: list[de.LibraryDeleted] = []

    @plugin("test.cascade", title="删片联动（测试）", inject=(DURABLE_EVENTS,))
    async def cascade(ctx) -> None:
        def on_deleted(event: de.LibraryDeleted) -> None:
            received.append(event)

        ctx.on(de.LIBRARY_ITEM_DELETED, on_deleted, id="cascade")

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    with TestClient(app) as client:
        kernel = app.state.kernel
        fiber = client.portal.call(kernel.mount, Entry("test.cascade", cascade))
        assert fiber.state.value == "active"

        async def ready() -> None:
            async with asyncio.timeout(5):
                while True:
                    async with get_database().session() as session:
                        if await session.get(EventConsumer, "test.cascade:cascade"):
                            return
                    await asyncio.sleep(0.02)

        client.portal.call(ready)
        seeded = client.portal.call(seed_show, get_database(), tmp_path)
        resp = client.delete(f"/api/v1/libraries/{seeded['library_id']}/items/{seeded['item_id']}")
        assert resp.status_code == 200, resp.text

        async def delivered() -> None:
            async with asyncio.timeout(5):
                while not received:
                    await asyncio.sleep(0.02)

        client.portal.call(delivered)
        client.portal.call(kernel.unmount, "test.cascade")
    get_settings.cache_clear()
    durable_events.reset_state()

    [event] = received
    assert event.whole_item and event.media is not None and event.media.title == "测试剧集"
    assert event.links.subscription_id == seeded["sub_id"]
    assert [t.info_hash for t in event.links.torrents] == ["packhash"]


@pytest.mark.parametrize(
    "event", [e for e in vars(de).values() if isinstance(e, type(de.DOWNLOAD_COMPLETED))]
)
def test_domain_events_are_open_to_third_party_plugins(event) -> None:
    # 本地受信插件要能订阅它们：实验级、可靠投递
    assert event.stability.value == "experimental"
    assert event.delivery.value == "durable"


# ---------------------------------------------------------------------- 下载、入库、订阅
async def test_download_completed_is_recorded_once(db, tmp_path, monkeypatch) -> None:
    import movieclaw_api.services.download_progress as progress
    from movieclaw_db.models import WantedItem, WantedStatus
    from movieclaw_downloader import TorrentStatus

    seeded = await seed_show(db, tmp_path)
    await subscribe(db, de.DOWNLOAD_COMPLETED)
    async with db.session() as session:
        # 心跳只照看名下还有在途工单的投递
        for ep in (1, 2):
            session.add(
                WantedItem(
                    subscription_id=seeded["sub_id"],
                    media_item_id=seeded["item_id"],
                    season_number=1,
                    episode_number=ep,
                    status=WantedStatus.GRABBED,
                    info_hash="PACKHASH",
                )
            )
        await session.commit()
        attempt_id = (await session.execute(select(SubscriptionDownloadAttempt.id))).scalar_one()
        downloader = await session.get(DownloaderClient, seeded["downloader_id"])
    status = TorrentStatus(
        info_hash="packhash",
        name="Test.Show.S01.1080p",
        progress=1.0,
        completed=True,
        save_path="/downloads",
        files=[],
    )

    async def lookup(info_hash, downloaders, *, preferred_downloader_id=None):
        return progress._TorrentLookup((downloader, status), 1)

    monkeypatch.setattr(progress, "_lookup_torrent", lookup)
    # 已完成的记录每轮心跳都会再走一遍完成分支：只在第一次转为完成时发
    await progress._observe_attempt(attempt_id, downloaders=[])
    await progress._observe_attempt(attempt_id, downloaders=[])
    [event] = await recorded(db)
    assert event["name"] == "download.completed"
    assert event["subscription_id"] == seeded["sub_id"]
    assert event["info_hash"] == "packhash" and event["downloader_id"] == seeded["downloader_id"]
    assert [tuple(u) for u in event["units"]] == [(1, 1), (1, 2)]
    assert event["media"]["title"] == "测试剧集" and event["purpose"] == "download"


async def test_fulfilled_units_are_recorded(db, tmp_path) -> None:
    from movieclaw_api.services.subscription import close_fulfilled_wanted
    from movieclaw_db.models import WantedItem, WantedStatus

    seeded = await seed_show(db, tmp_path)
    await subscribe(db, de.SUBSCRIPTION_FULFILLED)
    async with db.session() as session:
        for ep in (1, 2):
            session.add(
                WantedItem(
                    subscription_id=seeded["sub_id"],
                    media_item_id=seeded["item_id"],
                    season_number=1,
                    episode_number=ep,
                    status=WantedStatus.DOWNLOADED,
                    info_hash="packhash",
                )
            )
        await session.commit()
        assert await close_fulfilled_wanted(session, seeded["item_id"]) == 2
    [event] = await recorded(db)
    assert event["name"] == "subscription.fulfilled"
    assert event["subscription_id"] == seeded["sub_id"]
    assert sorted(tuple(u) for u in event["units"]) == [(1, 1), (1, 2)]


async def test_subscription_created_event(db, monkeypatch) -> None:
    import httpx

    from movieclaw_api.services.media_library import MediaLibraryService
    from movieclaw_api.services.subscription import SubscriptionService
    from movieclaw_media.models import MediaKind
    from movieclaw_media.tmdb import TmdbClient

    movie = {
        "id": 100,
        "title": "测试电影",
        "original_title": "Test Movie",
        "release_date": "2024-01-01",
        "status": "Released",
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
    }

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/3/movie/100":
            return httpx.Response(200, json=movie)
        return httpx.Response(404, json={})

    tmdb = TmdbClient("0" * 32, transport=httpx.MockTransport(handler))
    await subscribe(db, de.SUBSCRIPTION_CREATED)
    async with db.session() as session:
        service = SubscriptionService(session, MediaLibraryService(session, tmdb))
        created = await service.create(MediaKind.MOVIE, 100)
        # 同一作品再订一次是幂等的（返回已有订阅），不是新建
        again = await service.create(MediaKind.MOVIE, 100)
        assert again.id == created.id
    [event] = await recorded(db)
    assert event["name"] == "subscription.created"
    assert event["subscription_id"] == created.id
    assert event["media"]["title"] == "测试电影" and event["member_id"] is None
