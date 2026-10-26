"""扩充属性落库与存量重算的集成测试（真实 SQLite 临时库）。

覆盖三件事：
1. 观测带 attrs/enrich_version/hit_and_run 时，upsert 正确写入与刷新；
2. ``reenrich_stale_torrents`` 只重算版本过期的行，且按当前提取器补齐 attrs；
3. attrs 的 JSON 往返（写库→读回→重建 TorrentAttrs）无损。
"""

from __future__ import annotations

import pytest
from sqlmodel import SQLModel, select

from movieclaw_api.services.enrich_backfill import reenrich_stale_torrents
from movieclaw_db.engine import dispose_db, init_db
from movieclaw_db.models.site_torrent import SiteTorrent, TorrentSource
from movieclaw_db.repositories.torrent_repo import TorrentObservation, TorrentRepository
from movieclaw_enrich import ENRICH_VERSION, TorrentAttrs, enrich


@pytest.fixture
async def db(tmp_path):
    """临时 SQLite 库：直接用模型元数据建表（迁移链另有专项验证）。"""
    database = init_db(f"sqlite+aiosqlite:///{tmp_path}/test.db")
    async with database.engine.begin() as conn:
        await conn.run_sync(SQLModel.metadata.create_all)
    yield database
    await dispose_db()


def _observation(title: str, subtitle: str = "", **overrides) -> TorrentObservation:
    fields = dict(
        site_id="demo",
        torrent_id="t1",
        source=TorrentSource.LIST,
        title=title,
        subtitle=subtitle,
        attrs=enrich(title, subtitle).model_dump(mode="json", exclude_defaults=True),
        enrich_version=ENRICH_VERSION,
    )
    fields.update(overrides)
    return TorrentObservation(**fields)


async def test_upsert_writes_attrs_and_hr(db):
    title = "Limbo.2021.1080p.BluRay.x265-WiKi"
    async with db.session() as session:
        await TorrentRepository(session).upsert(_observation(title, hit_and_run=True))
    async with db.session() as session:
        row = await TorrentRepository(session).get("demo", "t1")
        assert row is not None
        assert row.enrich_version == ENRICH_VERSION
        assert row.hit_and_run is True
        # JSON 往返无损：读回的 attrs 能重建出与现算一致的 TorrentAttrs
        assert TorrentAttrs(**row.attrs) == enrich(title)


async def test_refresh_without_enrich_keeps_old_attrs(db):
    title = "Limbo.2021.1080p.BluRay.x265-WiKi"
    async with db.session() as session:
        repo = TorrentRepository(session)
        await repo.upsert(_observation(title))
        # 第二次观测不带扩充层（attrs=None，模拟未来可能的轻量刷新路径）
        await repo.upsert(
            _observation(title, attrs=None, enrich_version=None, seeders=42)
        )
    async with db.session() as session:
        row = await TorrentRepository(session).get("demo", "t1")
        assert row.seeders == 42
        assert row.enrich_version == ENRICH_VERSION  # 旧 attrs 未被 None 冲掉
        assert row.attrs.get("year") == 2021


async def test_backfill_reenriches_stale_rows(db):
    async with db.session() as session:
        # 一行"从未扩充"（老数据），一行"旧版本"，一行已是当前版本
        session.add(SiteTorrent(
            site_id="demo", torrent_id="old1", source=TorrentSource.LIST,
            title="Oppenheimer.2023.2160p.UHD.BluRay.REMUX.HEVC-FGT",
        ))
        session.add(SiteTorrent(
            site_id="demo", torrent_id="old2", source=TorrentSource.LIST,
            title="The.Last.of.Us.S02E03.2160p.WEB-DL.DDP5.1-FLUX",
            attrs={"year": 1999}, enrich_version=ENRICH_VERSION - 1,
        ))
        session.add(SiteTorrent(
            site_id="demo", torrent_id="new1", source=TorrentSource.LIST,
            title="whatever", attrs={}, enrich_version=ENRICH_VERSION,
        ))
        await session.commit()

    assert await reenrich_stale_torrents() == 2

    async with db.session() as session:
        rows = {
            r.torrent_id: r
            for r in (await session.execute(select(SiteTorrent))).scalars().all()
        }
    assert rows["old1"].enrich_version == ENRICH_VERSION
    assert rows["old1"].attrs["remux"] is True
    assert rows["old1"].attrs["resolution"] == "2160p"
    # 旧版本的错误产出被当前提取器纠正
    assert rows["old2"].attrs.get("year") is None
    assert rows["old2"].attrs["seasons"] == [2]
    # 已是当前版本的行不动
    assert rows["new1"].attrs == {}

    # 幂等：再跑一遍没有可重算的行
    assert await reenrich_stale_torrents() == 0


async def test_backfill_offloads_enrich_to_worker_thread(db, monkeypatch):
    """重算的模型推理必须在工作线程执行——enrich 含同步 NER 推理，大库重算
    在事件循环里跑会长时间卡住健康检查（重算已改为启动后的后台任务）。"""
    import threading

    import movieclaw_api.services.enrich_backfill as backfill

    caller_thread = threading.get_ident()
    worker_threads: list[int] = []
    real_enrich = backfill.enrich

    def spy_enrich(title, subtitle="", category=None, site_labels=None):
        worker_threads.append(threading.get_ident())
        return real_enrich(title, subtitle, category, site_labels)

    monkeypatch.setattr(backfill, "enrich", spy_enrich)

    async with db.session() as session:
        session.add(SiteTorrent(
            site_id="demo", torrent_id="stale1", source=TorrentSource.LIST,
            title="Dune.2021.1080p.BluRay.x265-WiKi",
        ))
        await session.commit()

    assert await reenrich_stale_torrents() == 1
    assert worker_threads
    assert all(thread_id != caller_thread for thread_id in worker_threads)


async def test_backfill_carries_site_labels_over(db):
    """站点标记不是从标题推出来的：存量重算时要从旧 attrs 带回去，不然版本一 bump 就被抹掉。"""
    async with db.session() as session:
        session.add(SiteTorrent(
            site_id="demo", torrent_id="m1", source=TorrentSource.LIST,
            title="Mayday 2026 2160p ATVP WEB-DL DDP 5.1 Atmos DV H.265-FLUX",
            attrs={"site_labels": ["中字", "4k", "DoVi"]}, enrich_version=ENRICH_VERSION - 1,
        ))
        session.add(SiteTorrent(
            site_id="demo", torrent_id="m2", source=TorrentSource.LIST,
            title="Dune.2021.1080p.BluRay.x265-WiKi",
            attrs={"year": 1999}, enrich_version=ENRICH_VERSION - 1,
        ))
        await session.commit()

    assert await reenrich_stale_torrents() == 2

    async with db.session() as session:
        rows = {
            r.torrent_id: r
            for r in (await session.execute(select(SiteTorrent))).scalars().all()
        }
    assert rows["m1"].attrs["site_labels"] == ["中字", "4k", "DoVi"]
    assert rows["m1"].attrs["hdr"] == ["DV"]  # 标题推出来的部分照常重算
    assert "site_labels" not in rows["m2"].attrs  # 没有标记的行不会凭空多出这个键
