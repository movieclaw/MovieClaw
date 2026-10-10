"""来源快照里属于获取领域的部分（docs/design/library-boundary.md §10）。

订阅投递 / 手动下载入库时的来源文案，以及给旧行（``origin`` 为空）读时推导来源文案——
这些要读订阅下载记录、手动下载意图、种子表与站点配置，归获取领域。媒体库自己的文案
（监听入库、扫描发现）与展示取值规则在 ``services/library/origin.py``。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.library.origin import (
    _STRATEGY_LABELS,
    KIND_MANUAL_DOWNLOAD,
    KIND_SCAN,
    KIND_SUBSCRIPTION,
    KIND_WATCH_IMPORT,
    _join,
    _snapshot,
)
from movieclaw_db.models import FileSource, LibraryFile, MediaItem
from movieclaw_db.models.downloader_client import DownloaderClient
from movieclaw_db.models.manual_download_intent import ManualDownloadIntent
from movieclaw_db.models.site_torrent import SiteTorrent
from movieclaw_db.models.subscription import Subscription, SubscriptionDownloadAttempt

logger = logging.getLogger("movieclaw_api.acquisition_origin")


def site_display_name(site_id: str | None) -> str | None:
    """站点 ID → 用户可读的站点名；站点配置已被移除时回落原 ID。"""
    if not site_id:
        return None
    from movieclaw_tracker.exceptions import SiteNotFoundError
    from movieclaw_tracker.registry import get_site_config

    try:
        return get_site_config(site_id).display_name
    except SiteNotFoundError:
        return site_id


def subscription_origin(
    attempt: SubscriptionDownloadAttempt,
    *,
    item_title: str,
    downloader_name: str | None,
    strategy: str | None,
) -> dict[str, Any]:
    """订阅投递入库：投递记录里有站点、种子标题、目的（首次 / 洗版）与是否人工选种。"""
    verb = "洗版投递" if attempt.purpose == "upgrade" else "自动投递"
    label = f"订阅《{item_title}》{verb}" + ("（人工选种）" if attempt.manual else "")
    detail = _join(
        site_display_name(attempt.site_id),
        attempt.torrent_title or attempt.download_name,
        downloader_name,
        _STRATEGY_LABELS.get(strategy or ""),
    )
    return _snapshot(KIND_SUBSCRIPTION, label, detail)


def manual_download_origin(
    intent: ManualDownloadIntent,
    *,
    torrent_title: str | None,
    downloader_name: str | None,
    strategy: str | None,
) -> dict[str, Any]:
    """手动下载入库：身份锚入库成功即删除，快照是它留下的唯一人话。"""
    detail = _join(
        site_display_name(intent.site_id),
        torrent_title or intent.download_name,
        downloader_name,
        _STRATEGY_LABELS.get(strategy or ""),
    )
    return _snapshot(KIND_MANUAL_DOWNLOAD, "手动下载", detail)


@dataclass
class OriginContext:
    """一次入库作业内构造快照所需的旁路数据：下载器名与手动下载的种子标题。

    投递记录只有 ``downloader_id``，手动下载意图只有 (site, torrent)；两者都
    要多查一次表才能拼出人话，这里按作业一次查好，逐文件构造时纯内存取值。
    """

    downloader_names: dict[int, str] = field(default_factory=dict)
    manual_torrent_title: str | None = None

    def downloader(self, downloader_id: int | None) -> str | None:
        return self.downloader_names.get(downloader_id) if downloader_id is not None else None


async def load_origin_context(
    session: AsyncSession,
    attempts: tuple[SubscriptionDownloadAttempt, ...] | list[SubscriptionDownloadAttempt],
    manual_intent: ManualDownloadIntent | None,
) -> OriginContext:
    ids = {a.downloader_id for a in attempts if a.downloader_id is not None}
    if manual_intent is not None and manual_intent.downloader_id is not None:
        ids.add(manual_intent.downloader_id)
    ctx = OriginContext()
    try:
        if ids:
            rows = (
                await session.execute(
                    select(DownloaderClient.id, DownloaderClient.name).where(
                        DownloaderClient.id.in_(ids)  # type: ignore[union-attr]
                    )
                )
            ).all()
            ctx.downloader_names = {int(i): str(n) for i, n in rows}
        if manual_intent is not None and manual_intent.site_id and manual_intent.torrent_id:
            ctx.manual_torrent_title = await session.scalar(
                select(SiteTorrent.title).where(
                    SiteTorrent.site_id == manual_intent.site_id,
                    SiteTorrent.torrent_id == manual_intent.torrent_id,
                )
            )
    except Exception:  # noqa: BLE001 -- 来源快照是附加信息，查不到也不能拖垮入库
        logger.warning("读取来源快照的旁路数据失败，文案将省略下载器 / 种子标题", exc_info=True)
    return ctx


def _legacy_fallback(row: LibraryFile) -> dict[str, Any]:
    if row.source == FileSource.SCANNED:
        return _snapshot(KIND_SCAN, "存量扫描发现（非本系统入库）", None)
    if row.site_id or row.torrent_id:
        return _snapshot(KIND_WATCH_IMPORT, "手动或监听导入", _join(site_display_name(row.site_id)))
    return _snapshot(KIND_WATCH_IMPORT, "监听目录导入", "来源种子未记录")


async def derive_origins(
    session: AsyncSession, rows: list[LibraryFile]
) -> dict[int, dict[str, Any]]:
    """给 ``origin IS NULL`` 的旧行推导等价快照：{file_id: snapshot}。

    只对带 (site, torrent) 来源戳的入库行多查两张表——同戳的投递记录（拼
    订阅名 / 目的 / 人工选种）、查不到投递时的种子标题；其余按 ``source``
    直接给文案。结果不写回台账。
    """
    legacy = [r for r in rows if r.origin is None and r.id is not None]
    if not legacy:
        return {}
    result: dict[int, dict[str, Any]] = {}
    stamped = [r for r in legacy if r.source == FileSource.IMPORTED and r.site_id and r.torrent_id]
    attempts: dict[tuple[str, str], SubscriptionDownloadAttempt] = {}
    titles: dict[tuple[str, str], str] = {}
    item_titles: dict[int, str] = {}
    downloaders: dict[int, str] = {}
    if stamped:
        sites = {r.site_id for r in stamped}
        torrents = {r.torrent_id for r in stamped}
        pairs = {(r.site_id, r.torrent_id) for r in stamped}
        try:
            rows_ = (
                await session.execute(
                    select(SubscriptionDownloadAttempt, MediaItem.title, DownloaderClient.name)
                    .join(
                        Subscription,
                        Subscription.id == SubscriptionDownloadAttempt.subscription_id,  # type: ignore[arg-type]
                    )
                    .join(MediaItem, MediaItem.id == Subscription.media_item_id)  # type: ignore[arg-type]
                    .outerjoin(
                        DownloaderClient,
                        DownloaderClient.id == SubscriptionDownloadAttempt.downloader_id,  # type: ignore[arg-type]
                    )
                    .where(
                        SubscriptionDownloadAttempt.site_id.in_(sites),  # type: ignore[union-attr]
                        SubscriptionDownloadAttempt.torrent_id.in_(torrents),  # type: ignore[union-attr]
                    )
                    .order_by(SubscriptionDownloadAttempt.id)
                )
            ).all()
            for attempt, title, downloader in rows_:
                key = (attempt.site_id, attempt.torrent_id)
                if key in pairs:
                    attempts[key] = attempt  # 按 id 升序遍历，留下的是最新一次
                    item_titles[attempt.id] = title
                    if downloader and attempt.downloader_id is not None:
                        downloaders[attempt.downloader_id] = downloader
            missing = pairs - set(attempts)
            if missing:
                trows = (
                    await session.execute(
                        select(
                            SiteTorrent.site_id, SiteTorrent.torrent_id, SiteTorrent.title
                        ).where(
                            SiteTorrent.site_id.in_({s for s, _ in missing}),  # type: ignore[union-attr]
                            SiteTorrent.torrent_id.in_({t for _, t in missing}),  # type: ignore[union-attr]
                        )
                    )
                ).all()
                titles = {(s, t): title for s, t, title in trows if (s, t) in missing}
        except Exception:  # noqa: BLE001 -- 推导失败退回按 source 的粗文案
            logger.warning("读时推导来源快照失败，退回粗文案", exc_info=True)
    for row in legacy:
        assert row.id is not None
        key = (row.site_id or "", row.torrent_id or "")
        attempt = attempts.get(key)
        if attempt is not None:
            result[row.id] = subscription_origin(
                attempt,
                item_title=item_titles.get(attempt.id or -1, ""),
                downloader_name=downloaders.get(attempt.downloader_id or -1),
                strategy=None,
            )
        elif key in titles:
            result[row.id] = _snapshot(
                KIND_WATCH_IMPORT,
                "手动或监听导入",
                _join(site_display_name(row.site_id), titles[key]),
            )
        else:
            result[row.id] = _legacy_fallback(row)
    return result
