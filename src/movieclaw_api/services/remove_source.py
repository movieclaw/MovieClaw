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

import logging
import os
from typing import Any

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import AppException
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


async def _others(session: AsyncSession, file_ids: tuple[int, ...], media_item_id: int) -> str:
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
    parts = []
    if same:
        parts.append(f"同一部片的另外 {same} 个文件")
    if titles:
        shown = "、".join(f"《{t}》" for t in titles[:3])
        parts.append(shown + (f"等 {len(titles)} 部" if len(titles) > 3 else ""))
    if unknown:
        parts.append(f"{unknown} 个没识别的文件")
    return "、".join(parts) or "媒体库里别的文件"


async def _skip_reason(
    session: AsyncSession, torrent: FileTorrent, request: DeleteRequest
) -> str | None:
    """这个任务为什么不能删；能删返回 None。"""
    if torrent.downloader_id is None:
        return "下载器配置已删除，找不到这个任务"
    if torrent.owned_by_movieclaw is False:
        return "不是 MovieClaw 投递的种子"
    if torrent.hit_and_run:
        return "有 H&R 考核风险，删了可能违反站点规则"
    if torrent.other_file_ids:
        others = await _others(session, torrent.other_file_ids, request.media_item_id)
        return f"这个种子还供着{others}，删了会连带删掉它们"
    return None


def _name(torrent: FileTorrent) -> str:
    return torrent.title or torrent.info_hash[:12]


async def _assess(
    session: AsyncSession, request: DeleteRequest
) -> list[tuple[FileTorrent, str | None]]:
    torrents = await torrents_for_files(session, [f.id for f in request.files])
    return [(t, await _skip_reason(session, t, request)) for t in torrents]


def _counted(items: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """同一句合并成一行，重复的注明「（N 个任务）」；保持首次出现的顺序。"""
    counts: dict[tuple[str, str], int] = {}
    for item in items:
        counts[item] = counts.get(item, 0) + 1
    return [
        (text if n == 1 else f"{text}（{n} 个任务）", tone) for (text, tone), n in counts.items()
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
                reason="没找到对应的下载任务（扫描进来的文件或来源已不可考），只会删除媒体库文件",
            )
        lines: list[PreviewLine] = []
        found: list[tuple[str, str]] = []
        deletable: list[FileTorrent] = []
        kept: list[str] = []
        for torrent, reason in assessed:
            if reason is not None:
                kept.append(f"保留「{_name(torrent)}」：{reason}")
                continue
            assert torrent.downloader_id is not None
            try:
                plan = await plan_delete_download_task(
                    session, downloader_id=torrent.downloader_id, info_hash=torrent.info_hash
                )
            except AppException as exc:
                kept.append(f"保留「{_name(torrent)}」：{exc.message}")
                continue
            if plan.exists is False:
                kept.append(f"「{_name(torrent)}」已经不在下载器「{plan.downloader_name}」里了")
                continue
            deletable.append(torrent)
            where = f"下载器「{plan.downloader_name}」"
            if plan.exists is None:
                found.append(
                    (
                        f"{where}暂时连不上，确认不了「{_name(torrent)}」还在不在；"
                        "删不掉时可在「活动 → 任务」里重试",
                        "warn",
                    )
                )
            else:
                found.append((f"{where}：删除「{plan.title or _name(torrent)}」", "info"))
        tracking = await _subscription_tracking(session, deletable)

    # 追更的剧常是同名季包重发多次（hash 不同、名字相同）：同一句只列一次，后面注明个数
    lines.extend(PreviewLine(text=text, tone=tone) for text, tone in _counted(found))
    kept_lines = [text for text, _ in _counted([(k, "warn") for k in kept])]
    lines.extend(PreviewLine(text=text, tone="warn") for text in kept_lines)
    if not deletable:
        reason = kept_lines[0] if len(kept_lines) == 1 else "；".join(kept_lines)
        return Preview(available=False, reason=reason)
    if _hardlinked(request):
        # 媒体库的预览已经说了「只删库文件不释放空间」，这里只说勾上之后的事
        lines.append(PreviewLine(text="下载目录里的那份会一起删掉，空间才真正腾出来"))
    else:
        lines.append(PreviewLine(text="下载目录里的源文件会一起删除"))
    if tracking:
        lines.append(PreviewLine(text="这部片的订阅还在追：删除后对应的集会重新下载", tone="warn"))
    lines.append(PreviewLine(text="源文件删除后不可恢复", tone="danger"))
    return Preview(available=True, lines=tuple(lines))


PARTICIPANT = DeleteParticipant(
    label="同时删除下载任务和源文件",
    help="把下载器里对应的任务连同下载目录里的数据一起删掉，真正腾出空间；源文件删除不可恢复",
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
    kept: list[str] = []
    failures: list[str] = []
    for torrent, reason in assessed:
        await context.raise_if_cancelled()
        if reason is not None:
            kept.append(f"保留「{_name(torrent)}」：{reason}")
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
            failures.append(f"「{_name(torrent)}」删除失败：{exc.message}")
            logger.warning("删片联动删种失败 hash=%s：%s", torrent.info_hash, exc.message)
        except Exception as exc:  # noqa: BLE001 -- 单项异常不中断其余
            failures.append(f"「{_name(torrent)}」删除失败：{exc}")
            logger.warning("删片联动删种异常 hash=%s", torrent.info_hash, exc_info=True)

    parts = []
    if removed:
        names = "、".join(text for text, _ in _counted([(name, "") for name in removed]))
        parts.append(f"已删除 {len(removed)} 个下载任务和源文件：{names}")
    parts.extend(text for text, _ in _counted([(k, "") for k in kept]))
    if failures:
        message = "；".join([*parts, *failures])
        async with db.session() as session:
            await upsert_notice(
                session,
                dedupe_key=f"{NOTICE_PREFIX}{context.job_id}",
                severity=NoticeSeverity.WARNING,
                source="downloads",
                title=f"《{request.title}》的下载任务没能全部删除",
                message="媒体库文件已删除；" + message + "。可在「活动 → 任务」里重试",
                payload={"job_id": context.job_id, "action_href": "/activity"},
            )
        raise jobs.JobFailed(message, code="REMOVE_SOURCE_FAILED")

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
    message = "；".join(parts) or "没有需要删除的下载任务"
    return {"message": message, "removed": removed, "kept": kept}
