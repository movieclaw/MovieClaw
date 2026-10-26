"""手动选种承接洗版测试（quality-upgrade.md §13.8）：无缺口时投递已入库
单元、manual 标记、验证的"共存保留"裁决、常驻 indeterminate 派生。"""

from __future__ import annotations

import os

import pytest
import pytest_asyncio
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import stored_message
from movieclaw_api.services.subscription.manual_grab import grab_manual
from movieclaw_api.services.subscription.upgrade import verify_upgrades
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    ActivityType,
    DownloadAttemptStatus,
    FileSource,
    LibraryFile,
    MediaItem,
    RuleSet,
    Subscription,
    SubscriptionActivity,
    SubscriptionDownloadAttempt,
    WantedItem,
    WantedStatus,
    utcnow,
)
from movieclaw_db.repositories.library_repo import LibraryRepository


def _write_seeded(path, data: bytes) -> None:
    """写测试文件并挂一个硬链接副本，模拟推荐的硬链入库形态（st_nlink ≥ 2）。

    做种保护上线后（§7.1：唯一硬链接绝不改名），回收站相关断言都以
    硬链形态为前提；单链接（原地下载/复制导入）的行为由专门用例覆盖。
    """
    path.write_bytes(data)
    seed_dir = path.parent / ".seed-copies"
    seed_dir.mkdir(exist_ok=True)
    os.link(path, seed_dir / f"{len(list(seed_dir.iterdir()))}-{path.name}")


_WEBDL = {"resolution": "1080p", "media_source": "WEB-DL"}
_REMUX_ATTRS = {
    "resolution": "1080p",
    "media_source": "Blu-ray",
    "remux": True,
    "seasons": [1],
    "episodes": [1],
}


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'manual.db'}")
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "true")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


async def _seed(db, tmp_path, *, spec=None, quality=_WEBDL, old_hash="old1"):
    """库(真实 tmp 根)/条目/订阅/imported 工单 + 旧版本物理文件，无缺口。"""
    root = tmp_path / "tv"
    root.mkdir(exist_ok=True)
    old_file = root / "Testshow.S01E01.1080p.WEB-DL.mkv"
    _write_seeded(old_file, b"old")
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=[str(root)]
        )
        item = MediaItem(
            kind="tv",
            tmdb_id=210,
            title="测试剧集",
            original_title="Testshow",
            year=2024,
            aliases=["Testshow", "测试剧集"],
        )
        rule_set = RuleSet(
            name="洗版组", spec={"upgrade_source": "remux"} if spec is None else spec
        )
        session.add_all([item, rule_set])
        await session.commit()
        await session.refresh(item)
        await session.refresh(rule_set)
        sub = Subscription(
            media_item_id=item.id, kind="tv", rule_set_id=rule_set.id, library_id=library.id
        )
        session.add(sub)
        await session.commit()
        await session.refresh(sub)
        wanted = WantedItem(
            subscription_id=sub.id,
            media_item_id=item.id,
            season_number=1,
            episode_number=1,
            status=WantedStatus.IMPORTED,
            quality=quality,
            info_hash=old_hash,
            imported_at=utcnow(),
        )
        session.add(wanted)
        session.add(
            LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                season_number=1,
                episode_number=1,
                file_path=str(old_file),
                size_bytes=3,
                source=FileSource.IMPORTED,
                resolution="1080p",
                media_source="WEB-DL",
                bit_rate=5_000_000,
            )
        )
        await session.commit()
        await session.refresh(wanted)
        return library, item.id, sub.id, wanted.id, root, old_file


@pytest.mark.asyncio
async def test_manual_grab_upgrades_imported_unit(db, tmp_path):
    """无缺口 + 规则组带洗版目标：手选投递已入库单元——attempt 记
    purpose=upgrade + manual=True，工单保持 imported、info_hash 不动。"""
    _library, _item_id, sub_id, wanted_id, _root, _old = await _seed(db, tmp_path)
    async with db.session() as session:
        covered = await grab_manual(
            session,
            sub_id,
            site_id="site-a",
            torrent_id="m1",
            title="Testshow 2024 S01E01 1080p Blu-ray REMUX",
            attrs=_REMUX_ATTRS,
        )
        assert [(w.season_number, w.episode_number) for w in covered] == [(1, 1)]
        wanted = await session.get(WantedItem, wanted_id)
        assert wanted.status == WantedStatus.IMPORTED  # 不重开工单
        assert wanted.info_hash == "old1"  # 指向旧版本，直到验证确认
        # dry-run 不落 attempt 行（真实投递才有 infohash）；投递语义看活动分流
        activities = list(
            (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == sub_id
                    )
                )
            ).scalars()
        )
        grabbed = next(a for a in activities if a.type == ActivityType.UPGRADE_GRABBED)
        # 中文原文照旧落库；读者按自己的语言看到同一句话
        assert grabbed.message.startswith("S01E01发现更高版本，已提交洗版下载：来自 site-a 的")
        assert grabbed.message.endswith("——模拟投递，未真实提交下载器")
        with use_locale("en"):
            english = stored_message(
                grabbed.message, grabbed.message_key, grabbed.message_params
            )
        assert english.startswith("S01E01: found a better version and submitted an upgrade")
        assert english.endswith("(simulated; nothing was sent to the downloader)")


@pytest.mark.asyncio
async def test_manual_grab_no_gap_without_target_gives_guidance(db, tmp_path):
    """无缺口且规则组没配洗版目标：可读中文错误引导先配置洗版目标。"""
    _library, _item_id, sub_id, _wid, _root, _old = await _seed(db, tmp_path, spec={})
    async with db.session() as session:
        with pytest.raises(BadRequestException, match="洗版目标"):
            await grab_manual(
                session,
                sub_id,
                site_id="site-a",
                torrent_id="m1",
                title="Testshow 2024 S01E01 1080p Blu-ray REMUX",
                attrs=_REMUX_ATTRS,
            )


async def _add_manual_delivery(db, sub_id, item_id, library_id, root, *, claimed, probed):
    """模拟手选洗版 attempt + 其下载文件已入库。"""
    new_file = root / "Testshow.S01E01.manual.mkv"
    _write_seeded(new_file, b"new-version")
    async with db.session() as session:
        session.add(
            SubscriptionDownloadAttempt(
                subscription_id=sub_id,
                info_hash="manual1",
                site_id="site-a",
                torrent_id="m1",
                units=[[1, 1]],
                quality=claimed,
                purpose="upgrade",
                manual=True,
                status=DownloadAttemptStatus.COMPLETED,
                last_progress_at=utcnow(),
            )
        )
        session.add(
            LibraryFile(
                library_id=library_id,
                media_item_id=item_id,
                season_number=1,
                episode_number=1,
                file_path=str(new_file),
                size_bytes=11,
                source=FileSource.IMPORTED,
                site_id="site-a",
                torrent_id="m1",
                **probed,
            )
        )
        await session.commit()
    return new_file


@pytest.mark.asyncio
async def test_manual_verify_retains_coexisting_when_not_better(db, tmp_path):
    """手选版本实测未能证明更优：共存保留——文件不动、不熔断、不进排除，
    attempt 置 RETAINED，基线刷新为实测最优。"""
    library, item_id, sub_id, wanted_id, root, old_file = await _seed(db, tmp_path)
    new_file = await _add_manual_delivery(
        db,
        sub_id,
        item_id,
        library.id,
        root,
        claimed=_WEBDL,  # 同档：证明不了更优
        probed={"resolution": "1080p", "bit_rate": 6_000_000},
    )
    async with db.session() as session:
        await verify_upgrades(session, item_id)
        attempt = (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.info_hash == "manual1"
                )
            )
        ).scalar_one()
        assert attempt.status == DownloadAttemptStatus.RETAINED
        wanted = await session.get(WantedItem, wanted_id)
        assert wanted.upgrade_verify_failures == 0  # 用户的选择不受证伪惩罚
        assert wanted.info_hash == "old1"  # 未替换
        assert wanted.quality["media_source"] == "WEB-DL"  # 基线仍可判定
        files = list(
            (
                await session.execute(
                    select(LibraryFile).where(LibraryFile.media_item_id == item_id)
                )
            ).scalars()
        )
        assert len(files) == 2  # 两个版本共存，一个都不删
        activity = list(
            (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == sub_id
                    )
                )
            ).scalars()
        )
        assert any(a.payload.get("reason") == "manual_retained" for a in activity)
    assert old_file.exists() and new_file.exists()  # 磁盘上也都在


@pytest.mark.asyncio
async def test_manual_verify_confirms_when_provably_better(db, tmp_path):
    """手选版本实测确认更优：照常替换（与自动洗版同一确认路径）。"""
    library, item_id, sub_id, wanted_id, root, old_file = await _seed(db, tmp_path)
    await _add_manual_delivery(
        db,
        sub_id,
        item_id,
        library.id,
        root,
        claimed={"resolution": "1080p", "media_source": "Blu-ray", "remux": True},
        probed={"resolution": "1080p", "bit_rate": 30_000_000},
    )
    async with db.session() as session:
        await verify_upgrades(session, item_id)
        wanted = await session.get(WantedItem, wanted_id)
        assert wanted.info_hash == "manual1"  # 关联切到新版本
        assert wanted.quality["remux"] is True
        attempt = (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.info_hash == "manual1"
                )
            )
        ).scalar_one()
        assert attempt.status == DownloadAttemptStatus.IMPORTED
    assert not old_file.exists()  # 旧版本进回收站


def test_wanted_upgrades_marks_indeterminate_units():
    """常驻感知（§13.8）：{} 哨兵不再隐形（版本未识别），部分快照标
    indeterminate；可判定单元不受影响。"""
    from movieclaw_api.schemas.subscription import _wanted_upgrades
    from movieclaw_matcher import RuleSetSpec

    def _row(episode, quality):
        return WantedItem(
            subscription_id=1,
            media_item_id=1,
            season_number=1,
            episode_number=episode,
            status=WantedStatus.IMPORTED,
            quality=quality,
            imported_at=utcnow(),
        )

    spec = RuleSetSpec.model_validate({"upgrade_source": "remux"})
    views = _wanted_upgrades(
        [
            _row(1, {}),  # 哨兵：完全无法识别
            _row(2, {"resolution": "1080p"}),  # 部分快照：片源未知
            _row(3, _WEBDL),  # 可判定：低于目标
            _row(4, None),  # 未回填：转瞬态，不展示
        ],
        spec,
    )
    assert views[(1, 1)].indeterminate and views[(1, 1)].current_label == "版本未识别"
    assert not views[(1, 1)].active
    assert views[(1, 2)].indeterminate and views[(1, 2)].current_label == "1080p 片源未知"
    assert not views[(1, 3)].indeterminate and views[(1, 3)].active
    assert (1, 4) not in views
