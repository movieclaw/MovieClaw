"""获取领域给入库用的下载器信息（docs/design/library-boundary.md §10，入库桥块 A、B）。

入库要知道「这个条目是不是还在下载、哪些文件已经写完、是不是 MovieClaw 投递的还没到」；
这些都是下载器与投递台账的事，媒体库经 ``services/library/acquisition.py`` 的接口来问，
答案只用媒体库的概念（条目路径、本机文件路径、写完没有）。
"""

from __future__ import annotations

import logging
import os
import re
import time
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path, PurePosixPath

from sqlalchemy import or_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.library.acquisition import TaskFile, TaskFiles
from movieclaw_db.engine import get_database
from movieclaw_db.models import DownloaderClient, ManualDownloadIntent, utcnow
from movieclaw_db.models.manual_download_intent import MANUAL_DOWNLOAD_INTENT_TTL

logger = logging.getLogger("movieclaw_api.library_ingest")

# 下载器种子概览的缓存：一轮事件风暴中的多个目录巡检共享一次 API 调用
_BRIEFS_TTL_SECONDS = 15.0
# 下载器种子概览缓存：(取样时刻, 概览列表或 None=不可用)
_briefs_cache: tuple[float, list | None] = (float("-inf"), None)


async def downloader_briefs() -> list | None:
    """全部可用下载器的种子概览（带短缓存）。

    ``[]`` 表示没有配置下载器或可达下载器确实没有任务；``None`` 只表示
    配置过下载器但本轮全部不可达。后者必须 fail closed，不能拿静默窗口
    猜完成——API 短暂失联正是未完成文件被提前入库的根因。
    """
    global _briefs_cache
    now = time.monotonic()
    cached_at, cached = _briefs_cache
    if now - cached_at < _BRIEFS_TTL_SECONDS:
        return cached
    # 局部导入：复用订阅管线的"可用下载器"口径，避免模块加载期的重依赖
    from movieclaw_api.services.download_progress import _usable_downloaders
    from movieclaw_downloader import create_downloader

    db = get_database()
    async with db.session() as session:
        enabled_exists = (
            await session.execute(
                select(DownloaderClient.id).where(DownloaderClient.enabled.is_(True))  # type: ignore[union-attr]
            )
        ).first() is not None
        downloaders = await _usable_downloaders(session)
    if not downloaders:
        # 没有启用任何下载器才表示“确实没有权威状态源”。启用中的配置若仍在
        # pending/verifying/failed，则只是当前不可用，必须和连接异常一样
        # fail closed；否则服务启动的验证窗口会把预分配文件误当成已完成。
        result = None if enabled_exists else []
        _briefs_cache = (now, result)
        return result
    briefs: list = []
    all_ok = True
    for row, config in downloaders:
        adapter = create_downloader(config)
        try:
            briefs.extend(await adapter.list_torrents())
        except Exception as exc:  # noqa: BLE001 -- 继续关闭/检查其余连接后整体降级
            all_ok = False
            logger.warning("列出下载器「%s」的种子失败：%s", row.name, exc)
        finally:
            await adapter.close()
    # 任一台缺席时，这份列表都不能证明“某目录不属于下载任务”。宁可让所有
    # 未决条目暂等，也不能用另一台的成功响应替失联下载器作否定判断。
    result = briefs if all_ok else None
    _briefs_cache = (now, result)
    return result


def _claim_path_matches(entry: Path, save_path: str | None) -> bool:
    """持久化投递路径是否覆盖当前监听条目；旧行无路径时按真实名称认领。"""
    if not save_path:
        return True
    expected = Path(os.path.normpath(save_path))
    actual = Path(os.path.normpath(str(entry)))
    return expected in {actual, actual.parent}


def download_name_matches(entry_name: str, recorded_name: str | None) -> bool:
    """兼容站点标题与下载器内容名的轻微差异，不做宽松片名猜测。"""
    if not recorded_name:
        return False
    if entry_name == recorded_name:
        return True
    compact_entry = re.sub(r"[^a-z0-9]+", "", entry_name.lower())
    compact_recorded = re.sub(r"[^a-z0-9]+", "", recorded_name.lower())
    if compact_entry == compact_recorded:
        return True
    if min(len(compact_entry), len(compact_recorded)) < 20:
        return False
    years_entry = set(re.findall(r"(?:19|20)\d{2}", compact_entry))
    years_recorded = set(re.findall(r"(?:19|20)\d{2}", compact_recorded))
    if years_entry and years_recorded and not years_entry.intersection(years_recorded):
        return False
    return SequenceMatcher(None, compact_entry, compact_recorded).ratio() >= 0.90


async def has_managed_download_claim(session, entry: Path) -> bool:
    """条目是否仍由 MovieClaw 投递台账管理，即使下载器概览暂时漏掉它。"""
    from movieclaw_db.models import (
        DownloadAttemptStatus,
        SiteTorrent,
        SubscriptionDownloadAttempt,
    )

    manual = list(
        (
            await session.execute(
                select(ManualDownloadIntent, SiteTorrent.title)
                .outerjoin(
                    SiteTorrent,
                    (SiteTorrent.site_id == ManualDownloadIntent.site_id)
                    & (SiteTorrent.torrent_id == ManualDownloadIntent.torrent_id),
                )
                .where(
                    ManualDownloadIntent.created_at >= utcnow() - MANUAL_DOWNLOAD_INTENT_TTL,  # type: ignore[arg-type]
                    or_(
                        ManualDownloadIntent.download_name == entry.name,
                        ManualDownloadIntent.download_name.is_(None),  # type: ignore[union-attr]
                        ManualDownloadIntent.download_name == "",
                    ),
                )
            )
        ).all()
    )
    if any(
        _claim_path_matches(entry, intent.save_path)
        and (
            download_name_matches(entry.name, intent.download_name)
            or download_name_matches(entry.name, site_title)
        )
        for intent, site_title in manual
    ):
        return True

    active = (
        DownloadAttemptStatus.ACTIVE,
        DownloadAttemptStatus.REPLACEMENT_PENDING,
        DownloadAttemptStatus.TRIAL,
        DownloadAttemptStatus.CLEANUP_PENDING,
        DownloadAttemptStatus.COMPLETED,
    )
    attempts = list(
        (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.status.in_(active),  # type: ignore[union-attr]
                    or_(
                        SubscriptionDownloadAttempt.download_name == entry.name,
                        SubscriptionDownloadAttempt.download_name.is_(None),  # type: ignore[union-attr]
                        SubscriptionDownloadAttempt.download_name == "",
                    ),
                )
            )
        )
        .scalars()
        .all()
    )
    return any(
        _claim_path_matches(entry, row.save_path)
        and (
            download_name_matches(entry.name, row.download_name)
            or download_name_matches(entry.name, row.torrent_title)
        )
        for row in attempts
    )


async def redelivered_since(
    session: AsyncSession, entry_name: str, since: datetime, info_hashes: list[str]
) -> bool:
    """台账下结论之后，订阅又把同一颗种子重新投递、且投递仍在途：旧结论已过时。

    台账按「条目路径 + 指纹」幂等：已入库/已跳过且指纹没变就不再处理。但结论所
    依据的现实会变——用户把入库的文件删了、作品随之被清掉，之后重新订阅，仍在
    下载器里做种的同一颗种子被原样再投递一次。指纹没变，旧台账于是永远短路，新
    工单停在「已投递」、投递停在「已完成」，谁也不报警（NAS 实测《恶人传》）。

    判据刻意只认「晚于台账结论的在途投递」：重跑会刷新 ``attempted_at``，同一次
    投递不会反复触发；正常流程里投递总是先于入库结论，也不会误触发。
    """
    from movieclaw_db.models import DownloadAttemptStatus, SubscriptionDownloadAttempt

    if not info_hashes:
        return False
    hashes = sorted({h for value in info_hashes if value for h in (value, value.lower())})
    attempt_id = (
        await session.execute(
            select(SubscriptionDownloadAttempt.id)
            .where(
                SubscriptionDownloadAttempt.info_hash.in_(hashes),  # type: ignore[union-attr]
                SubscriptionDownloadAttempt.status.in_(  # type: ignore[attr-defined]
                    (
                        DownloadAttemptStatus.ACTIVE,
                        DownloadAttemptStatus.REPLACEMENT_PENDING,
                        DownloadAttemptStatus.TRIAL,
                        DownloadAttemptStatus.COMPLETED,
                    )
                ),
                SubscriptionDownloadAttempt.created_at > since,  # type: ignore[operator]
            )
            .limit(1)
        )
    ).scalar_one_or_none()
    if attempt_id is None:
        return False
    logger.info(
        "「%s」在上次入库结论之后又被订阅投递（投递 #%s），旧结论已过时，重新入库",
        entry_name,
        attempt_id,
    )
    return True


async def _matched_torrent_statuses(matches: list) -> list[tuple[object, object]] | None:
    """补查同名种子的文件状态；任一详情缺失时返回 None，调用方保守等待。"""
    from movieclaw_api.services.download_progress import _query_torrent, _usable_downloaders

    if any(not brief.info_hash for brief in matches):
        return None  # 没有 hash 的轻量记录无法形成可复核的文件证据
    hashes = sorted({str(brief.info_hash).lower() for brief in matches if brief.info_hash})
    if len(hashes) != len(matches):
        return None  # 重复 hash 的概览不应产生互相矛盾的文件写入证据
    db = get_database()
    async with db.session() as session:
        downloaders = await _usable_downloaders(session)
    if not downloaders:
        return None
    details: list[tuple[object, object]] = []
    for info_hash in hashes:
        found = await _query_torrent(info_hash, downloaders)
        if found is None:
            return None
        details.append(found)
    return details


def _torrent_file_source(downloader, status, torrent_file) -> Path | None:  # noqa: ANN001
    """把下载器文件路径翻译到 MovieClaw 视角；异常相对路径直接拒绝。"""
    from movieclaw_api.services.torrent_submit import translate_to_local

    local_dir = translate_to_local(status.save_path, downloader.path_mappings)
    if not local_dir:
        return None
    relative = PurePosixPath(str(torrent_file.path).replace("\\", "/"))
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        return None
    return Path(local_dir).joinpath(*relative.parts)


def _torrent_file_completed(status, torrent_file) -> bool:  # noqa: ANN001
    """只认下载器完成字节；旧适配器缺字段时仅整种完成可兜底。"""
    if status.completed:
        return True
    completed_bytes = torrent_file.completed_bytes
    return completed_bytes is not None and completed_bytes >= torrent_file.size_bytes


async def task_files(matches: list) -> list[TaskFiles] | None:
    """同名下载任务的文件清单（路径已翻译到本机）；任一详情缺失时返回 None，调用方保守等待。"""
    details = await _matched_torrent_statuses(matches)
    if details is None:
        return None
    out: list[TaskFiles] = []
    for downloader, status in details:
        out.append(
            TaskFiles(
                info_hash=str(status.info_hash).lower(),
                completed=bool(status.completed),
                files=tuple(
                    TaskFile(
                        source=_torrent_file_source(downloader, status, torrent_file),
                        selected=bool(torrent_file.selected),
                        size_bytes=int(torrent_file.size_bytes),
                        completed=_torrent_file_completed(status, torrent_file),
                    )
                    for torrent_file in status.files or ()
                ),
            )
        )
    return out
