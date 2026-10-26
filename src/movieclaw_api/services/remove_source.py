"""删片时「同时删除下载任务和源文件」（docs/design/library-boundary.md §4；issue #622）。

下载模块是媒体库「删除参与方」的第一个使用者：媒体库只知道有这么个选项、用户勾了没，
种子、下载器、H&R 这些都在这里判断。

- **预览**（只读）：这次要删的文件来自哪些下载任务；哪些能删、哪些为什么保留；硬链接入库时
  只删库文件不释放空间；源文件删除不可恢复；
- **后续任务**（用户勾选后，随删除同一次提交建出）：执行时重新校验一遍，再逐个删任务和数据。
  单个失败不中断其余，失败时发系统通知（会推送到手机）并让任务失败、可在任务中心重试；
  全部处理完后清掉这些文件的来源记录（谁的数据谁清理）。

能删的安全线：下载器配置还在、MovieClaw 自己投递的（或不知道归属的扫描来源）、没有 H&R 风险、
不再供着媒体库里别的文件。删种前的否决钩子（``dl.torrent.before-delete``）在执行时照常询问。
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import AppException
from movieclaw_api.i18n import messages, t
from movieclaw_api.i18n.stored import (
    exception_reference,
    reference,
    reference_fields,
    render_value,
    source_render,
)
from movieclaw_api.services import jobs
from movieclaw_api.services.download_sources import FileTorrent, torrents_for_files
from movieclaw_api.services.library.delete_participants import (
    DeleteParticipant,
    DeleteRequest,
    Preview,
    PreviewLine,
)
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    DownloadFileSource,
    LibraryFile,
    MediaItem,
    NoticeSeverity,
    Subscription,
    SubscriptionStatus,
)

logger = logging.getLogger("movieclaw_api.remove_source")

PARTICIPANT_ID = "remove-source"
JOB_TYPE = "downloads.remove-source"
NOTICE_PREFIX = "downloads.remove-source:"


def _listed(parts: list, separator: str = "common.list.separator") -> dict:
    return {"message_list": parts, "separator_key": separator}


async def _others(session: AsyncSession, file_ids: tuple[int, ...], media_item_id: int) -> dict:
    """种子还供着的别的文件，说成人话：「同一部片的另外 3 个文件」「《电影乙》」「没识别的文件」。

    不按插件 / 条目定制，只按文件归属分三类。"""
    rows = (
        await session.execute(
            select(LibraryFile.media_item_id, MediaItem.title)
            .join(MediaItem, MediaItem.id == LibraryFile.media_item_id, isouter=True)
            .where(LibraryFile.id.in_(file_ids))  # type: ignore[union-attr]
        )
    ).all()
    same = sum(1 for item_id, _ in rows if item_id == media_item_id)
    titles = sorted({title for item_id, title in rows if item_id not in (None, media_item_id)})
    unknown = sum(1 for item_id, _ in rows if item_id is None)
    parts: list = []
    if same:
        parts.append(reference("download.removal.sameItemFiles", count=same))
    if titles:
        shown = _listed([reference("download.removal.workTitle", title=t) for t in titles[:3]])
        if len(titles) > 3:
            shown = reference("download.removal.titlesMore", titles=shown, count=len(titles))
        parts.append(shown)
    if unknown:
        parts.append(reference("download.removal.unknownFiles", count=unknown))
    return _listed(parts) if parts else reference("download.removal.otherLibraryFiles")


async def _skip_reason(
    session: AsyncSession, torrent: FileTorrent, request: DeleteRequest
) -> dict | None:
    """这个任务为什么不能删（文案引用）；能删返回 None。"""
    if torrent.downloader_id is None:
        return reference("download.removal.skipNoDownloader")
    if torrent.owned_by_movieclaw is False:
        return reference("download.removal.skipNotOwned")
    if torrent.hit_and_run:
        return reference("download.removal.skipHitAndRun")
    if torrent.other_file_ids:
        others = await _others(session, torrent.other_file_ids, request.media_item_id)
        return reference("download.removal.skipSharedFiles", others=others)
    return None


def _name(torrent: FileTorrent) -> str:
    return torrent.title or torrent.info_hash[:12]


async def _assess(
    session: AsyncSession, request: DeleteRequest
) -> list[tuple[FileTorrent, dict | None]]:
    torrents = await torrents_for_files(session, [f.id for f in request.files])
    return [(t, await _skip_reason(session, t, request)) for t in torrents]


def _counted(items: list[tuple[Any, str]]) -> list[tuple[Any, str]]:
    """同一句合并成一行，重复的注明「（N 个任务）」；保持首次出现的顺序。"""
    counts: dict[str, list] = {}
    for text, tone in items:
        slot = counts.setdefault(json.dumps([text, tone], sort_keys=True), [text, tone, 0])
        slot[2] += 1
    return [
        (text if n == 1 else reference("download.removal.taskCount", text=text, count=n), tone)
        for text, tone, n in counts.values()
    ]


def _hardlinked(request: DeleteRequest) -> bool:
    """要删的库文件里有没有和别处是同一份数据的（硬链接）。只看文件系统。"""
    for file in request.files:
        try:
            if os.stat(file.path).st_nlink > 1:
                return True
        except OSError:
            continue
    return False


async def _subscription_tracking(session: AsyncSession, torrents: list[FileTorrent]) -> bool:
    ids = {t.subscription_id for t in torrents if t.subscription_id is not None}
    if not ids:
        return False
    statuses = (
        await session.execute(
            select(Subscription.status).where(Subscription.id.in_(ids))  # type: ignore[union-attr]
        )
    ).scalars()
    return any(status == SubscriptionStatus.ACTIVE for status in statuses)


async def preview(request: DeleteRequest) -> Preview:
    from movieclaw_api.services.download_tasks import plan_delete_download_task

    async with get_database().session() as session:
        assessed = await _assess(session, request)
        if not assessed:
            return Preview(
                available=False,
                reason=t("download.removal.noTask"),
            )
        lines: list[PreviewLine] = []
        found: list[tuple[dict, str]] = []
        deletable: list[FileTorrent] = []
        kept: list[dict] = []
        for torrent, reason in assessed:
            if reason is not None:
                kept.append(reference("download.removal.kept", name=_name(torrent), reason=reason))
                continue
            assert torrent.downloader_id is not None
            try:
                plan = await plan_delete_download_task(
                    session, downloader_id=torrent.downloader_id, info_hash=torrent.info_hash
                )
            except AppException as exc:
                kept.append(
                    reference(
                        "download.removal.kept",
                        name=_name(torrent),
                        reason=exception_reference(exc),
                    )
                )
                continue
            if plan.exists is False:
                kept.append(
                    reference(
                        "download.removal.missingInDownloader",
                        name=_name(torrent),
                        downloader=plan.downloader_name,
                    )
                )
                continue
            deletable.append(torrent)
            if plan.exists is None:
                found.append(
                    (
                        reference(
                            "download.removal.downloaderUnreachable",
                            downloader=plan.downloader_name,
                            name=_name(torrent),
                        ),
                        "warn",
                    )
                )
            else:
                found.append(
                    (
                        reference(
                            "download.removal.willDelete",
                            downloader=plan.downloader_name,
                            name=plan.title or _name(torrent),
                        ),
                        "info",
                    )
                )
        tracking = await _subscription_tracking(session, deletable)

    # 追更的剧常是同名季包重发多次（hash 不同、名字相同）：同一句只列一次，后面注明个数
    lines.extend(PreviewLine(text=render_value(text), tone=tone) for text, tone in _counted(found))
    kept_lines = [render_value(text) for text, _ in _counted([(k, "warn") for k in kept])]
    lines.extend(PreviewLine(text=text, tone="warn") for text in kept_lines)
    if not deletable:
        return Preview(available=False, reason=t("common.list.issueSeparator").join(kept_lines))
    if _hardlinked(request):
        # 媒体库的预览已经说了「只删库文件不释放空间」，这里只说勾上之后的事
        lines.append(PreviewLine(text=t("download.removal.hardlinkedFreed")))
    else:
        lines.append(PreviewLine(text=t("download.removal.sourceDeleted")))
    if tracking:
        lines.append(PreviewLine(text=t("download.removal.subscriptionTracking"), tone="warn"))
    lines.append(PreviewLine(text=t("download.removal.irreversible"), tone="danger"))
    return Preview(available=True, lines=tuple(lines))


PARTICIPANT = DeleteParticipant(
    label=messages("zh-Hans")["download.removal.optionLabel"],
    label_key="download.removal.optionLabel",
    help=messages("zh-Hans")["download.removal.optionHelp"],
    help_key="download.removal.optionHelp",
    preview=preview,
    job_type=JOB_TYPE,
)


@jobs.register_job_handler(JOB_TYPE)
async def run_remove_source(context: jobs.JobContext, input_data: dict[str, Any]) -> dict[str, Any]:
    """执行时重新校验，再逐个删；单个失败不中断其余。"""
    from movieclaw_api.services.download_tasks import delete_download_task
    from movieclaw_api.services.system_notice import upsert_notice

    request = DeleteRequest.model_validate(input_data["request"])
    db = get_database()
    async with db.session() as session:
        assessed = await _assess(session, request)
    removed: list[str] = []
    kept: list[dict] = []
    failures: list[dict] = []
    for torrent, reason in assessed:
        await context.raise_if_cancelled()
        if reason is not None:
            kept.append(reference("download.removal.kept", name=_name(torrent), reason=reason))
            continue
        assert torrent.downloader_id is not None
        try:
            async with db.session() as session:
                await delete_download_task(
                    session,
                    downloader_id=torrent.downloader_id,
                    info_hash=torrent.info_hash,
                    delete_files=True,
                )
            removed.append(_name(torrent))
        except AppException as exc:
            failures.append(
                reference(
                    "download.removal.deleteFailed",
                    name=_name(torrent),
                    error=exception_reference(exc),
                )
            )
            logger.warning("删片联动删种失败 hash=%s：%s", torrent.info_hash, exc.message)
        except Exception as exc:  # noqa: BLE001 -- 单项异常不中断其余
            failures.append(
                reference("download.removal.deleteFailed", name=_name(torrent), error=str(exc))
            )
            logger.warning("删片联动删种异常 hash=%s", torrent.info_hash, exc_info=True)

    parts: list = []
    if removed:
        names = _listed([text for text, _ in _counted([(name, "") for name in removed])])
        parts.append(reference("download.removal.removed", count=len(removed), names=names))
    parts.extend(text for text, _ in _counted([(k, "") for k in kept]))
    if failures:
        message = reference(
            "download.removal.summary",
            parts=_listed([*parts, *failures], "common.list.issueSeparator"),
        )
        async with db.session() as session:
            await upsert_notice(
                session,
                dedupe_key=f"{NOTICE_PREFIX}{context.job_id}",
                severity=NoticeSeverity.WARNING,
                source="downloads",
                title_key="notify.removeSourceFailed.title",
                message_key="notify.removeSourceFailed.body",
                message_params={"title": request.title, "detail": message},
                payload={"job_id": context.job_id, "action_href": "/activity"},
            )
        raise jobs.JobFailed(**reference_fields(message), code="REMOVE_SOURCE_FAILED")

    # 处理完了：这些文件的来源记录不再需要（谁的数据谁清理）
    async with db.session() as session:
        await session.execute(
            delete(DownloadFileSource).where(
                DownloadFileSource.library_file_id.in_(  # type: ignore[attr-defined]
                    [f.id for f in request.files]
                )
            )
        )
        await session.commit()
    message = (
        reference("download.removal.summary", parts=_listed(parts, "common.list.issueSeparator"))
        if parts
        else reference("download.removal.nothingToDelete")
    )
    return {
        **reference_fields(message),
        "removed": removed,
        "kept": [source_render(k) for k in kept],
    }


# ---------------------------------------------------------------------- 网盘库腾空本地之后


async def after_local_released(released: Any) -> None:
    """库文件传到网盘、本地腾空了：来源种子不再供着任何本地库文件时删掉下载任务
    （docs/design/cloud-storage.md §6.3）。

    保留的：设置里关了、不是 MovieClaw 投递的、有 H&R 考核的、下载器配置没了的、还供着库里别的
    本地文件的、还没下完或名下还有没入库单元的（季包一集先腾空不代表整包干完，issue #943；
    等最后一个文件腾空时再判一次）。硬链接入库时这一步才让空间真正回来。删不掉发系统通知。
    """
    from movieclaw_api.services.download_tasks import (
        delete_download_task,
        download_task_finished,
    )
    from movieclaw_api.services.system_notice import upsert_notice
    from movieclaw_api.settings import DriveReleaseSetting, get_setting_store

    policy = await get_setting_store().get(DriveReleaseSetting)
    if not policy.remove_download_tasks:
        return
    db = get_database()
    async with db.session() as session:
        torrents = await torrents_for_files(session, [released.file_id])
        still_local: set[int] = set()
        others = {i for t in torrents for i in t.other_file_ids}
        if others:
            still_local = set(
                (
                    await session.execute(
                        select(LibraryFile.id).where(
                            LibraryFile.id.in_(others),  # type: ignore[union-attr]
                            LibraryFile.local_bytes.is_(True),  # type: ignore[attr-defined]
                        )
                    )
                )
                .scalars()
                .all()
            )
    failures: list[str] = []
    for torrent in torrents:
        if (
            torrent.downloader_id is None
            or torrent.owned_by_movieclaw is False
            or torrent.hit_and_run
            or still_local.intersection(torrent.other_file_ids)
        ):
            continue
        try:
            async with db.session() as session:
                if not await download_task_finished(
                    session, downloader_id=torrent.downloader_id, info_hash=torrent.info_hash
                ):
                    logger.info("网盘库腾空本地，但下载任务还没干完，先保留：%s", _name(torrent))
                    continue
                await delete_download_task(
                    session,
                    downloader_id=torrent.downloader_id,
                    info_hash=torrent.info_hash,
                    delete_files=True,
                    by_user=False,
                )
            logger.info("网盘库腾空本地后删除下载任务：%s", _name(torrent))
        except AppException as exc:
            failures.append(f"「{_name(torrent)}」：{exc.message}")
        except Exception as exc:  # noqa: BLE001 -- 单项异常不中断其余
            failures.append(f"「{_name(torrent)}」：{exc}")
            logger.warning("腾空后删种异常 hash=%s", torrent.info_hash, exc_info=True)
    if failures:
        async with db.session() as session:
            await upsert_notice(
                session,
                dedupe_key=f"{NOTICE_PREFIX}released:{released.file_id}",
                severity=NoticeSeverity.WARNING,
                source="downloads",
                title_key="notify.cloudSourceKept.title",
                message_key="notify.cloudSourceKept.body",
                message_params={
                    "detail": {
                        "message_list": failures,
                        "separator_key": "notify.details.separator",
                    }
                },
                payload={"action_href": "/downloads"},
            )
