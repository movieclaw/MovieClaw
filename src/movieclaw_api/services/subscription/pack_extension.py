"""「继续订阅」落到整包上：把新入域的集并进已在下载器里的包。

设计见 docs/design/subscription-episode-cap.md §4。整季包、全集包是一个原子种子。
订阅上限下第一批只勾了窗口里的文件；用户调大上限后，新工单搜到的往往还是
**同一个包**。投递层对同一 infohash 原本只合并台账、不碰下载器里
的文件选中集合（已存在的任务可能是用户自己的在途任务，见 ``torrent_submit``），于是
新认领的集永远下不到：工单挂在 GRABBED 上，库存对账既不退回也不关单。

这里在**投递前**识别「这个候选就是本订阅自己投递、还在下载器里的包」，把新单元的文件
并进它的选中集合并恢复下载；返回值与 ``_submit_real`` 同形，台账（工单 info_hash、尝试
单元并集、活动）继续走投递层原有的合并路径。所有权只认我们自己的台账
（``owned_by_movieclaw``）——用户自己的任务照旧一指头不碰。
"""

from __future__ import annotations

import logging

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.i18n.stored import keyed_error
from movieclaw_api.services.subscription.file_selection import plan_strict_file_selection
from movieclaw_api.services.subscription.smart_submission import SubmissionRejected
from movieclaw_db.models import (
    DownloadAttemptStatus,
    DownloaderClient,
    Subscription,
    SubscriptionDownloadAttempt,
)
from movieclaw_db.repositories.downloader_repo import DownloaderRepository
from movieclaw_downloader.factory import create_downloader
from movieclaw_downloader.models import DownloaderConfig, SubmitResult
from movieclaw_matcher import TorrentCandidate

logger = logging.getLogger("movieclaw_api.pack_extension")

# 还能「继续」的尝试状态：下载中、刚下完、已入库（做种中）。换源/失败/取消的不算
_EXTENDABLE = (
    DownloadAttemptStatus.ACTIVE,
    DownloadAttemptStatus.COMPLETED,
    DownloadAttemptStatus.IMPORTED,
)


class ExtensionRefused(SubmissionRejected):
    """这个包补选不了这批集（文件清单对不上）。不是网络问题，重试无益。

    继承 ``SubmissionRejected``：智能订阅据此直接结束本次意图、工单退回等待，
    不会把意图留在「待对账」里被恢复任务无限重放。
    """


async def find_owned_attempt(
    session: AsyncSession, subscription_id: int, candidate: TorrentCandidate
) -> SubscriptionDownloadAttempt | None:
    """本订阅自己投递过、还能继续的同一个种子（按站点 + 种子 ID 认）。"""
    return (
        (
            await session.execute(
                select(SubscriptionDownloadAttempt)
                .where(
                    SubscriptionDownloadAttempt.subscription_id == subscription_id,
                    SubscriptionDownloadAttempt.site_id == candidate.site_id,
                    SubscriptionDownloadAttempt.torrent_id == candidate.torrent_id,
                    SubscriptionDownloadAttempt.owned_by_movieclaw.is_(True),  # type: ignore[attr-defined]
                    SubscriptionDownloadAttempt.purpose == "download",
                    SubscriptionDownloadAttempt.status.in_(_EXTENDABLE),  # type: ignore[attr-defined]
                    SubscriptionDownloadAttempt.downloader_id.is_not(None),  # type: ignore[union-attr]
                )
                .order_by(SubscriptionDownloadAttempt.id.desc())  # type: ignore[attr-defined]
                .limit(1)
            )
        )
        .scalars()
        .first()
    )


async def extend_owned_pack(
    session: AsyncSession,
    *,
    subscription: Subscription,
    candidate: TorrentCandidate,
    targets: set[tuple[int, int]],
    before_resume=None,
) -> tuple[SubmitResult, DownloaderClient] | None:
    """把 ``targets`` 并进已有整包的文件选中集合，返回与 ``_submit_real`` 同形的结果。

    ``None`` = 不适用（没有这样的尝试、下载器停用、任务已不在下载器里），调用方走原来的
    投递路径。文件清单对不上抛 ``ExtensionRefused``；下载器不可达等瞬时错误原样抛出。

    选中集合 = 该包此前认领过的全部单元 ∪ 本次新单元：只增不减，已下载、已入库的文件
    保持选中。结果标 ``already_exists=False``：这是同一份内容又一个下载阶段，台账按
    「全新下载」重置心跳基线（投递层对同一 hash 再投递的既有语义）。
    """
    attempt = await find_owned_attempt(session, subscription.id, candidate)  # type: ignore[arg-type]
    if attempt is None or attempt.downloader_id is None:
        return None
    row = await session.get(DownloaderClient, attempt.downloader_id)
    if row is None or not row.enabled:
        return None

    adapter = create_downloader(
        DownloaderConfig(
            type=row.client_type,
            url=row.url,
            username=row.username,
            password=DownloaderRepository.decrypted_password(row),
        )
    )
    try:
        status = await adapter.get_torrent(attempt.info_hash, include_files=True)
        if status is None or not status.files:
            return None
        previous = {(int(season), int(episode)) for season, episode in attempt.units}
        needed = previous | targets
        try:
            plan = plan_strict_file_selection(
                [f.path for f in status.files],
                needed,
                known_seasons=subscription.selected_seasons or None,
            )
        except ValueError as exc:
            raise ExtensionRefused(
                "subscription.smart.extensionRefused", error=getattr(exc, "ref", None) or str(exc)
            ) from exc
        expected = set(plan.keep_indices)
        if {i for i, f in enumerate(status.files) if f.selected} != expected:
            await adapter.set_file_selection(
                attempt.info_hash,
                [
                    status.files[i].index if status.files[i].index is not None else i
                    for i in plan.keep_indices
                ],
            )
            verified = await adapter.get_torrent(attempt.info_hash, include_files=True)
            if verified is None or {
                i for i, f in enumerate(verified.files) if f.selected
            } != expected:
                raise keyed_error(RuntimeError, "errors.torrent.selectionReadbackMismatch")
        if before_resume is not None:
            await before_resume()
        # 已完成的包在做种：新勾的文件由下载器自动补下；停在暂停/停止态的需要恢复。
        # 恢复是幂等操作
        await adapter.resume(attempt.info_hash)
        logger.info(
            "订阅 #%s 并入已有整包：hash=%s 新增 %d 个单元",
            subscription.id,
            attempt.info_hash,
            len(targets - previous),
        )
        return (
            SubmitResult(
                info_hash=attempt.info_hash,
                name=status.name,
                already_exists=False,
                skipped_file_count=len(plan.skip_indices),
            ),
            row,
        )
    finally:
        await adapter.close()
