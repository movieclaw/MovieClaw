"""规则组「DV P5」在真实匹配链路里的行为：被动匹配 → 规则判定 → 投递。

发布名与站点标记取自真实 M-Team 种子（docs/design/avoid-dv-p5.md）：WEB 源只标 DV 的是
Profile 5，DV + HDR 的是 Profile 8。链路是真的（真库、真迁移、真匹配与选优），只有下载器
是 dry-run。
"""

# ruff: noqa: F811
from __future__ import annotations

from datetime import timedelta

from sqlmodel import select
from tests.api.smart_memory_fixture import ROUTES
from tests.api.test_subscription_pipeline import (  # noqa: F401
    _activities,
    _fake_tmdb,
    _insert_torrent,
    _wanted_map,
    db,
)

from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.rule_sets import RuleSetService
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.services.torrent_sync import _to_observation
from movieclaw_db.models import SiteTorrent, WantedStatus
from movieclaw_db.models.base import utcnow
from movieclaw_media.models import MediaKind
from movieclaw_tracker.models import TorrentListItem


def _service(session) -> SubscriptionService:
    return SubscriptionService(session, MediaLibraryService(session, _fake_tmdb(ROUTES)))


async def _movie_with_rule(session, *, hdr_block: list[str]):
    """用一个 2160p 规则组订阅一部英语片（701）；``hdr_block`` 是 HDR 黑名单。"""
    rule = await RuleSetService(session).create(
        "不要 DV P5" if hdr_block else "只要 2160p",
        {"resolutions": ["2160p"], "hdr_block": hdr_block},
    )
    return await _service(session).create(MediaKind.MOVIE, 701, rule_set_id=rule.id)


async def _release(session, group, tags, *, seeders, labels=()):
    """一条 2160p WEB-DL；``tags`` 是标题里写的 HDR 记号，``labels`` 是站点标记。"""
    hdr = [t for t in tags if t in {"DV", "HDR10", "HDR10+", "HLG"}]
    attrs = {
        "media_type": "movie",
        "year": 2023,
        "resolution": "2160p",
        "media_source": "WEB-DL",
        "release_group": group,
        "hdr": hdr,
        "subtitle_languages": ["zh-Hans"],  # 英语片要字幕，别让语言要求干扰本测试
    }
    if labels:
        attrs["site_labels"] = list(labels)
    title = f"Oppenheimer 2023 2160p WEB-DL {' '.join(tags)} H.265-{group}".replace("  ", " ")
    return await _insert_torrent(
        session, group, title, attrs, seeders=seeders, publish_time=utcnow() - timedelta(hours=3)
    )


async def test_rule_group_skips_p5_even_with_the_most_seeders_and_takes_the_p8(db):
    async with db.session() as session:
        sub = await _movie_with_rule(session, hdr_block=["DV P5"])
        p5 = await _release(session, "FLUXP5", ["DV"], seeders=500)
        p8 = await _release(session, "BYNDRP8", ["DV", "HDR10"], seeders=5)
        result = await evaluate_and_dispatch(session, [p5, p8], source="被动匹配")
        assert result.dispatched_units == 1
        assert [t for t in result.dispatched_torrents if "BYNDRP8" in t]
        assert not [t for t in result.dispatched_torrents if "FLUXP5" in t]
        # 为什么没下 P5：活动流水里有一条说得明白的拒绝（每个候选只记一次）
        rejected = [a for a in await _activities(session, sub.id) if a.type == "match_rejected"]
        assert len(rejected) == 1
        assert rejected[0].payload["reason_code"] == "hdr_blocked"
        assert "DV P5" in rejected[0].message and "Profile 5" in rejected[0].message


async def test_rule_group_without_the_chip_still_takes_the_p5_when_it_has_the_most_seeders(db):
    """对照组：黑名单里没有「DV P5」，行为与以前完全一样——能原样播 P5 的人不受影响。"""
    async with db.session() as session:
        await _movie_with_rule(session, hdr_block=[])
        p5 = await _release(session, "FLUXP5", ["DV"], seeders=500)
        p8 = await _release(session, "BYNDRP8", ["DV", "HDR10"], seeders=5)
        result = await evaluate_and_dispatch(session, [p5, p8], source="被动匹配")
        assert [t for t in result.dispatched_torrents if "FLUXP5" in t]


async def test_rule_group_with_only_p5_waits_and_a_p8_arriving_later_is_taken(db):
    async with db.session() as session:
        sub = await _movie_with_rule(session, hdr_block=["DV P5"])
        p5 = await _release(session, "FLUXP5", ["DV"], seeders=500)
        result = await evaluate_and_dispatch(session, [p5], source="被动匹配")
        assert result.dispatched_units == 0
        wanted = (await _wanted_map(session, sub.id))[(0, 0)]
        assert wanted.status == WantedStatus.WANTED
        rejected = [a for a in await _activities(session, sub.id) if a.type == "match_rejected"]
        assert [a.payload["reason_code"] for a in rejected] == ["hdr_blocked"]
        p8 = await _release(session, "BYNDRP8", ["DV", "HDR10"], seeders=5)
        later = await evaluate_and_dispatch(session, [p8], source="被动匹配")
        assert [t for t in later.dispatched_torrents if "BYNDRP8" in t]


async def test_site_labels_decide_when_the_title_alone_would_mislead(db):
    async with db.session() as session:
        await _movie_with_rule(session, hdr_block=["DV P5"])
        # 标题只写 DV，站点却标了 hdr10：其实带 HDR10 兼容层，不该被拦
        looks_like_p5 = await _release(
            session, "MISLABELED", ["DV"], seeders=50, labels=["中字", "4k", "hdr10", "DoVi"]
        )
        result = await evaluate_and_dispatch(session, [looks_like_p5], source="被动匹配")
        assert [t for t in result.dispatched_torrents if "MISLABELED" in t]


async def test_site_labels_catch_a_p5_the_title_never_mentions(db):
    async with db.session() as session:
        await _movie_with_rule(session, hdr_block=["DV P5"])
        silent = await _release(session, "SILENT", [], seeders=50, labels=["中字", "4k", "DoVi"])
        plain = await _release(session, "PLAIN", [], seeders=1)
        result = await evaluate_and_dispatch(session, [silent, plain], source="被动匹配")
        assert [t for t in result.dispatched_torrents if "PLAIN" in t]
        assert not [t for t in result.dispatched_torrents if "SILENT" in t]


async def test_site_labels_survive_the_sync_pipeline_into_the_index(db):
    """M-Team 列表里的 labelsNew 经同步管线落进 site_torrent.attrs.site_labels，且参与判定。"""
    from movieclaw_db.repositories.torrent_repo import TorrentRepository
    from movieclaw_matcher.formats import is_dv_p5

    item = TorrentListItem(
        torrent_id="1251530",
        title="Mayday 2026 2160p ATVP WEB-DL DDP 5.1 Atmos DV H.265-FLUX",
        subtitle="求救信号 / 求救暗号",
        size_bytes=21474836480,
        seeders=50,
        labels=["中字", "4k", "DoVi"],
    )
    observation = _to_observation("mteam", item, trust_volatile=True)
    assert observation.attrs["site_labels"] == ["中字", "4k", "DoVi"]
    async with db.session() as session:
        await TorrentRepository(session).upsert(observation)
        row = (
            await session.execute(select(SiteTorrent).where(SiteTorrent.torrent_id == "1251530"))
        ).scalar_one()
        from movieclaw_enrich import TorrentAttrs

        assert row.attrs["site_labels"] == ["中字", "4k", "DoVi"]
        assert is_dv_p5(TorrentAttrs(**row.attrs)) is True
    # 站点没给标记（如 NexusPHP 系）的行，attrs 里不会多出空键
    plain = _to_observation(
        "mteam",
        TorrentListItem(torrent_id="2", title="Dune 2021 1080p BluRay x265-WiKi"),
        trust_volatile=True,
    )
    assert "site_labels" not in plain.attrs
