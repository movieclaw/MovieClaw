"""智能投递的数据库意图。网络失败只能重放同一意图。"""

import logging
from datetime import timedelta
from uuid import uuid4

from pydantic import TypeAdapter
from sqlalchemy import update
from sqlalchemy.dialects.sqlite import insert
from sqlmodel import select

from movieclaw_api.i18n.stored import reference, source_render
from movieclaw_api.services.subscription.attempt_notes import set_note
from movieclaw_api.services.subscription.smart_profiles import conflict
from movieclaw_db.models import (
    DownloadAttemptStatus,
    SmartSeason,
    Subscription,
    SubscriptionDownloadAttempt,
    WantedItem,
    WantedStatus,
    utcnow,
)
from movieclaw_matcher import TorrentCandidate
from movieclaw_matcher.smart import series_key

logger = logging.getLogger("movieclaw_api.download_dispatch")

# 恢复失败的退避：1 分钟起翻倍，封顶 1 小时。下载器离线等真故障仍会自愈，
# 但不会每 30 秒刷一次日志
SMART_RECOVER_BASE_DELAY = timedelta(minutes=1)
SMART_RECOVER_MAX_DELAY = timedelta(hours=1)


class SubmissionRejected(Exception):
    """网络提交前已确定本意图无效，可以结束而无需对账。``ref`` 是原因的文案引用。"""

    def __init__(self, key: str, **params) -> None:
        self.ref = reference(key, **params)
        super().__init__(source_render(self.ref))


class _ClaimLost(Exception):
    pass


async def claim_intent(
    session,
    subscription,
    wanted_rows,
    upgrade_rows,
    candidate,
    versions,
    match=None,
    replacing=None,
):
    # 竞争失败只撤回本次认领，不能使同批其他订阅的 ORM 上下文过期。
    try:
        async with session.begin_nested():
            intent = await _claim_intent(
                session,
                subscription,
                wanted_rows,
                upgrade_rows,
                candidate,
                versions,
                match,
                replacing,
            )
    except _ClaimLost:
        return None
    if intent is not None:
        await session.commit()
        for row in wanted_rows + upgrade_rows:
            await session.refresh(row)
    return intent


async def _claim_intent(
    session,
    subscription,
    wanted_rows,
    upgrade_rows,
    candidate,
    versions,
    match=None,
    replacing=None,
):
    targets = wanted_rows + upgrade_rows
    if not targets or versions is None:
        return None
    now = utcnow()
    # 保存点的首条 SQL 必须是条件写入，避免 SQLite 读快照升级写锁竞争。
    for row in targets:
        result = await session.execute(
            update(WantedItem)
            .execution_options(synchronize_session=False)
            .where(
                WantedItem.id == row.id,
                WantedItem.selection_version == versions.get(row.id),
                WantedItem.in_scope.is_(True),
                WantedItem.status == row.status,
                WantedItem.subscription_id.in_(
                    select(Subscription.id).where(
                        Subscription.status != "paused", Subscription.selection_mode == "smart"
                    )
                ),
            )
            .values(
                selection_version=WantedItem.selection_version + 1,
                status=WantedStatus.GRABBED if row in wanted_rows else row.status,
                grabbed_at=now if row in wanted_rows else row.grabbed_at,
                next_selection_at=None,
                selection_state={**(row.selection_state or {}), "reason": "submitting"},
                updated_at=now,
            )
        )
        if result.rowcount != 1:
            raise _ClaimLost()
    # 已入库单元不改物理状态，仍须用尝试台账拦住冲突洗版。
    in_flight = (
        (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.subscription_id == subscription.id,
                    SubscriptionDownloadAttempt.status.in_(
                        ["submitting", "active", "replacement_pending", "trial"]
                    ),
                )
            )
        )
        .scalars()
        .all()
    )
    units = {(r.season_number, r.episode_number) for r in targets}
    if replacing is not None and replacing.status != DownloadAttemptStatus.REPLACEMENT_PENDING:
        raise _ClaimLost()
    if any(
        units.intersection(tuple(u) for u in a.units)
        for a in in_flight
        if replacing is None or a.id != replacing.id
    ):
        raise _ClaimLost()

    # 原子建立暂定系列；同一季的并发首次选择只能接受第一个系列。
    key = series_key(candidate)
    if subscription.kind == "tv" and key and replacing is None:
        for season in {r.season_number for r in wanted_rows}:
            existing = (
                await session.execute(
                    select(SmartSeason).where(
                        SmartSeason.subscription_id == subscription.id,
                        SmartSeason.season_number == season,
                    )
                )
            ).scalar_one_or_none()
            if existing is None:
                await session.execute(
                    insert(SmartSeason)
                    .values(
                        subscription_id=subscription.id,
                        season_number=season,
                        series_key=key,
                        confirmed=False,
                        evidence={"reason": "first_submission"},
                        created_at=now,
                        updated_at=now,
                    )
                    .on_conflict_do_nothing(index_elements=["subscription_id", "season_number"])
                )
                existing = (
                    await session.execute(
                        select(SmartSeason).where(
                            SmartSeason.subscription_id == subscription.id,
                            SmartSeason.season_number == season,
                        )
                    )
                ).scalar_one()
            planned = next(
                (r.selection_state or {}).get("following")
                for r in wanted_rows
                if r.season_number == season
            )
            if existing.series_key != key and planned != existing.series_key:
                raise _ClaimLost()
    intent = SubscriptionDownloadAttempt(
        subscription_id=subscription.id,
        info_hash=f"pending:{uuid4()}",
        site_id=candidate.site_id,
        torrent_id=candidate.torrent_id,
        torrent_title=candidate.title,
        status=DownloadAttemptStatus.SUBMITTING,
        purpose=replacing.purpose if replacing else ("upgrade" if upgrade_rows else "download"),
        replaces_attempt_id=replacing.id if replacing else None,
        identity_confidence=match.confidence if match else None,
        matched_alias=match.matched_alias if match else None,
        last_progress_at=now,
        units=[[r.season_number, r.episode_number] for r in targets],
        submission={
            "candidate": TypeAdapter(TorrentCandidate).dump_python(candidate, mode="json"),
            "wanted_ids": [r.id for r in wanted_rows],
            "upgrade_ids": [r.id for r in upgrade_rows],
            "stage": "claimed",
        },
    )
    session.add(intent)
    await session.flush()
    return intent


async def prepare_remote(session, intent, info_hash, downloader_id, save_path):
    """提交前冻结指纹；恢复不能静默换下载器或种子。"""
    previous = intent.submission or {}
    if intent.replaces_attempt_id:
        parent = await session.get(
            SubscriptionDownloadAttempt, intent.replaces_attempt_id, populate_existing=True
        )
        if (
            parent is None
            or parent.status != DownloadAttemptStatus.REPLACEMENT_PENDING
            or parent.info_hash == info_hash
        ):
            raise SubmissionRejected("subscription.smart.replacementEnded")

    duplicate = (
        await session.execute(
            select(SubscriptionDownloadAttempt.id).where(
                SubscriptionDownloadAttempt.subscription_id == intent.subscription_id,
                SubscriptionDownloadAttempt.info_hash == info_hash,
                SubscriptionDownloadAttempt.id != intent.id,
            )
        )
    ).first()
    if duplicate:
        raise SubmissionRejected("subscription.smart.duplicateAttempt")

    await ensure_can_submit(session, intent)
    if previous.get("info_hash") not in (None, info_hash) or intent.downloader_id not in (
        None,
        downloader_id,
    ):
        raise conflict()
    intent.save_path = intent.save_path or save_path
    intent.info_hash = info_hash
    intent.downloader_id = downloader_id
    intent.submission = {**previous, "stage": "remote_pending", "info_hash": info_hash}
    intent.updated_at = utcnow()
    await session.commit()


async def reconcile_remote(session, intent):
    """先查已有任务。此操作不取种、不新增任务，暂停时也可以恢复事实。"""
    if (intent.submission or {}).get("stage") != "remote_pending" or not intent.downloader_id:
        return None
    from movieclaw_db.models import DownloaderClient
    from movieclaw_db.repositories.downloader_repo import DownloaderRepository
    from movieclaw_downloader.factory import create_downloader
    from movieclaw_downloader.models import DownloaderConfig, SubmitResult

    row = await session.get(DownloaderClient, intent.downloader_id)
    if row is None:
        raise conflict()
    adapter = create_downloader(
        DownloaderConfig(
            type=row.client_type,
            url=row.url,
            username=row.username,
            password=DownloaderRepository.decrypted_password(row),
        )
    )
    try:
        status = await adapter.get_torrent(intent.info_hash)
        if status is None:
            return None
        result = SubmitResult(info_hash=intent.info_hash, name=status.name, already_exists=True)
        payload = intent.submission or {}
        if payload.get("select_units"):
            from movieclaw_api.services.torrent_submit import apply_strict_file_selection

            async def before_resume():
                await ensure_can_submit(session, intent)

            result = await apply_strict_file_selection(
                adapter,
                result,
                {tuple(u) for u in payload["select_units"]},
                known_seasons=payload.get("known_seasons"),
                owner=payload["selection_owner"],
                before_resume=before_resume,
            )
        return result, row
    finally:
        await adapter.close()


async def ensure_can_submit(session, intent):
    from movieclaw_api.services.subscription.smart_runtime import runtime_settings

    previous = intent.submission or {}
    subscription = await session.get(Subscription, intent.subscription_id, populate_existing=True)
    runtime = await runtime_settings()
    if (
        subscription is None
        or subscription.status == "paused"
        or not runtime.enabled
        or runtime.shadow_only
    ):
        raise conflict()
    targets = (
        (
            await session.execute(
                select(WantedItem).where(
                    WantedItem.id.in_(previous["wanted_ids"] + previous["upgrade_ids"])
                )
            )
        )
        .scalars()
        .all()
    )
    if len(targets) != len(previous["wanted_ids"]) + len(previous["upgrade_ids"]) or any(
        not row.in_scope for row in targets
    ):
        raise conflict()


async def reject_intent(session, intent, targets, reason: dict):
    intent.status = DownloadAttemptStatus.FAILED
    intent.submission = {**(intent.submission or {}), "stage": "rejected"}
    set_note(intent, reason)
    intent.updated_at = utcnow()
    for row in targets:
        row.selection_state = {**(row.selection_state or {}), "reason": "candidate_rejected"}
        if not intent.replaces_attempt_id and row.id in intent.submission["wanted_ids"]:
            row.status = WantedStatus.WANTED
            row.grabbed_at = None
            row.next_selection_at = utcnow()
    await session.commit()


async def settle_unsatisfiable(session, intent, targets, exc):
    """文件清单证明本发布满足不了部分单元：收窄意图，不再无限重放。

    满足不了的单元退回重找，并在意图上记负面记忆（``content_missing``），
    选种不会再拿这份发布补它们；其余仍在途的单元保留在意图里，下一轮恢复
    只为它们选文件。没有剩余在途单元时意图失败，并清理本次投递自己新建、
    尚未开始下载的暂停任务（``remove_own_paused_task``，issue #997）。
    返回被退回的工单。
    """
    payload = dict(intent.submission or {})
    unusable = set(exc.units)
    released = [r for r in targets if (r.season_number, r.episode_number) in unusable]
    now = utcnow()
    for row in released:
        explanation = reference("subscription.smart.unsatisfiedRetry", reason=exc.ref)
        row.selection_state = {
            **(row.selection_state or {}),
            "reason": "candidate_rejected",
            "choice_explanation": source_render(explanation),
        }
        row.selection_messages = {
            **(row.selection_messages or {}),
            "choice_explanation": explanation,
        }
        if row.id in payload["wanted_ids"] and row.status == WantedStatus.GRABBED:
            row.status = WantedStatus.WANTED
            row.grabbed_at = None
            row.next_selection_at = now
    memory = dict(intent.content_missing or {})
    units = {tuple(u) for u in memory.get("units", [])} | unusable
    sources = {tuple(s) for s in memory.get("sources", [])} | {(intent.site_id, intent.torrent_id)}
    intent.content_missing = {
        "units": [list(u) for u in sorted(units)],
        "sources": [list(s) for s in sorted(sources)],
    }
    released_ids = {r.id for r in released}
    # 已入库或已退出范围的单元不必再为它选文件
    pending = {
        r.id
        for r in targets
        if r.id not in released_ids
        and r.in_scope
        and (r.status == WantedStatus.GRABBED or r.id in payload["upgrade_ids"])
    }
    payload["wanted_ids"] = [i for i in payload["wanted_ids"] if i in pending]
    payload["upgrade_ids"] = [i for i in payload["upgrade_ids"] if i in pending]
    remaining = [[r.season_number, r.episode_number] for r in targets if r.id in pending]
    intent.units = remaining
    if payload.get("select_units") is not None:
        payload["select_units"] = remaining
    if remaining:
        set_note(intent, reference("subscription.smart.unsatisfiedPartial", reason=exc.ref))
    else:
        intent.status = DownloadAttemptStatus.FAILED
        payload["stage"] = "rejected"
        removed = await remove_own_paused_task(session, intent)
        key = (
            "subscription.smart.unsatisfiedAllRemoved"
            if removed
            else "subscription.smart.unsatisfiedAll"
        )
        set_note(intent, reference(key, reason=exc.ref))
    intent.submission = payload
    intent.updated_at = now
    return released


async def remove_own_paused_task(session, intent) -> bool:
    """意图确定失败后，删掉它自己新建且从未开始下载的暂停任务（保留数据）。

    暂停态本是留给重试找回同一任务的；意图一旦终结就再没有流程会碰它，
    会变成永久 0% 的孤儿任务（issue #997）。只删同时满足以下条件的任务：
    带本意图的所有权标签（下载器对已存在的任务不加标签，标签即证明是本次
    新建）、未完成、进度为 0、没有其他在途投递记录指向同一 hash。任何一条
    不满足或删除失败都原样保留，返回 False。
    """
    owner = (intent.submission or {}).get("selection_owner")
    info_hash = intent.info_hash
    if not owner or not intent.downloader_id or not info_hash or info_hash.startswith("pending:"):
        return False
    shared = (
        await session.execute(
            select(SubscriptionDownloadAttempt.id).where(
                SubscriptionDownloadAttempt.info_hash == info_hash,
                SubscriptionDownloadAttempt.id != intent.id,
                SubscriptionDownloadAttempt.status != DownloadAttemptStatus.FAILED,
            )
        )
    ).first()
    if shared:
        return False
    from movieclaw_db.models import DownloaderClient
    from movieclaw_db.repositories.downloader_repo import DownloaderRepository
    from movieclaw_downloader.factory import create_downloader
    from movieclaw_downloader.models import DownloaderConfig

    row = await session.get(DownloaderClient, intent.downloader_id)
    if row is None:
        return False
    try:
        adapter = create_downloader(
            DownloaderConfig(
                type=row.client_type,
                url=row.url,
                username=row.username,
                password=DownloaderRepository.decrypted_password(row),
            )
        )
    except Exception as exc:  # noqa: BLE001 -- 清理失败只记录，不改变意图结论
        logger.warning("智能投递 #%s 的暂停任务清理失败：%s", intent.id, exc)
        return False
    try:
        status = await adapter.get_torrent(info_hash)
        if (
            status is None
            or owner not in status.tags
            or status.completed
            or (status.progress or 0) > 0
        ):
            return False
        await adapter.delete_torrent(info_hash, delete_files=False)
        logger.info("智能投递 #%s 无法满足，已移除本次新建的暂停任务 hash=%s", intent.id, info_hash)
        return True
    except Exception as exc:  # noqa: BLE001 -- 清理失败只记录，不改变意图结论
        logger.warning(
            "智能投递 #%s 的暂停任务清理失败：hash=%s error=%s", intent.id, info_hash, exc
        )
        return False
    finally:
        await adapter.close()
