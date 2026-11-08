"""跨季绝对集号剧的文件清单复核（issue #1224）。

标题只有 ``S01`` 时，既可能是整季包，也可能是发布组固定写 S01 的绝对号单集。
标题和体积都不能告诉我们具体是哪一集；详情页已有的 ``file_list`` 才是确定证据。
本模块只对已证实使用跨季绝对号、且标题未声明 Complete/总集数的候选多读一次
详情页，普通剧与明确整季包完全不进入这条路径。
"""

from __future__ import annotations

import logging
from dataclasses import replace
from pathlib import Path

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.library.layout import VIDEO_EXTS, explicit_unit
from movieclaw_db.models import SiteTorrent
from movieclaw_matcher import IdentityMatch, MediaIdentity, TorrentCandidate
from movieclaw_matcher.seasons import (
    EpisodeRange,
    SeasonMapping,
    normalize_unit,
)

logger = logging.getLogger("movieclaw_api.subscription_unit_recheck")

FILE_LIST_UNAVAILABLE = "episode_file_list_unavailable"


def needs_file_list_recheck(candidate: TorrentCandidate, media: MediaIdentity) -> bool:
    """固定 S01 + 无集号的绝对号剧候选必须先看文件清单，不能冒充整季包。"""
    attrs = candidate.attrs
    if not media.episode_ranges or attrs.episodes or attrs.complete is True:
        return False
    if attrs.episodes_total is not None or len(attrs.seasons) != 1:
        return False
    first_season = min(season for season, _start, _end in media.episode_ranges)
    return attrs.seasons[0] == first_season


def _rejected(match: IdentityMatch, reason: str, site_season: int) -> IdentityMatch:
    return replace(
        match,
        episodes=frozenset(),
        pack_seasons=frozenset(),
        is_pack=False,
        site_seasons=frozenset({site_season}),
        unit_rejection=reason,
    )


async def recheck_file_units(
    session: AsyncSession,
    candidate: TorrentCandidate,
    media: MediaIdentity,
    match: IdentityMatch,
) -> IdentityMatch:
    """用详情页文件名把标题层的假整季包收窄为真实单元；拿不准就拒绝。"""
    if not needs_file_list_recheck(candidate, media):
        return match
    site_season = candidate.attrs.seasons[0]
    row = (
        await session.execute(
            select(SiteTorrent).where(
                SiteTorrent.site_id == candidate.site_id,
                SiteTorrent.torrent_id == candidate.torrent_id,
            )
        )
    ).scalar_one_or_none()
    target = (row.detail_url if row is not None else None) or candidate.torrent_id
    try:
        from movieclaw_api.services.site_access import get_site_access

        site = await get_site_access().get(candidate.site_id)
        detail = await site.get_torrent_detail(target)
    except Exception as exc:  # noqa: BLE001 -- 证据取不到就拒绝认领，不让网络故障冒充结论
        logger.warning(
            "绝对集号候选 %s/%s 无法读取详情文件清单：%s",
            candidate.site_id,
            candidate.torrent_id,
            exc,
        )
        return _rejected(match, FILE_LIST_UNAVAILABLE, site_season)

    mapping = SeasonMapping(
        episode_ranges=tuple(
            EpisodeRange(season, start, end) for season, start, end in media.episode_ranges
        )
    )
    translated = []
    for raw in detail.file_list or []:
        path = Path(raw)
        if path.suffix.lower() not in VIDEO_EXTS:
            continue
        # 与影视库扫描共用 sample / extras 判定；这些文件不构成正片证据。
        # 除此之外每个视频都必须能唯一落到一个单元，不能只挑认得出的文件。
        from movieclaw_api.services.library.scan import classify_cloud_path

        classified = classify_cloud_path(str(raw).replace("\\", "/"))
        if classified is not None and classified[0] == "extra":
            continue
        unit = explicit_unit(path.stem)
        if unit is None:
            return _rejected(match, FILE_LIST_UNAVAILABLE, site_season)
        translated.append(normalize_unit(mapping, *unit))
    if not translated:
        return _rejected(match, FILE_LIST_UNAVAILABLE, site_season)

    reasons = {item.reason for item in translated if item.reason}
    if reasons:
        return _rejected(match, sorted(reasons)[0], site_season)

    resolved = [item.unit for item in translated if item.unit is not None]
    if len(set(resolved)) != len(resolved):
        return _rejected(match, FILE_LIST_UNAVAILABLE, site_season)
    units = frozenset(resolved)
    normalized = any(item.mode != "literal" for item in translated)
    return replace(
        match,
        episodes=units,
        pack_seasons=frozenset(),
        is_pack=len(units) > 1,
        season_normalized=normalized,
        site_seasons=frozenset({site_season}) if normalized else frozenset(),
        unit_rejection=None,
    )
