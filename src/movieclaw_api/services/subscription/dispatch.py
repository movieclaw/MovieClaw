"""投递（F5）：选定的候选 → 认领工单 → （取种 → 提交下载器）→ 台账与状态推进。

幂等三层防线的第一层在这里：**条件更新认领**——被动匹配与主动搜索并发命中
同一工单时，数据库保证只有一个赢家（docs/design/subscription-p4.md 第 5/7 节）。

真实投递（2026-07-24 起默认）：取种 → 保存目录过下载器路径映射翻译 →
提交默认下载器（编排收口 torrent_submit）。``SUBSCRIPTION_DISPATCH_DRY_RUN``
设为 true 可切回模拟投递（短路取种与提交、纯日志、照常推进状态机，
活动标注"模拟投递"），供调试匹配规则用。
"""

from __future__ import annotations

import logging
from collections.abc import Collection
from datetime import UTC, datetime

from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api import hooks
from movieclaw_api.core.config import get_settings
from movieclaw_api.i18n.stored import (
    localize_fields,
    reference,
    reference_fields,
    source_render,
    stored_fields,
)
from movieclaw_api.services.subscription.attempt_notes import note_fields, set_note
from movieclaw_api.services.subscription.matching import units_reference
from movieclaw_db.models import (
    ActivityType,
    DownloadAttemptStatus,
    MediaItem,
    MediaSource,
    SiteTorrent,
    Subscription,
    SubscriptionActivity,
    SubscriptionDownloadAttempt,
    WantedItem,
    WantedStatus,
    utcnow,
)
from movieclaw_db.repositories import SubscriptionRepository
from movieclaw_matcher import IdentityMatch, RuleVerdict, TorrentCandidate

logger = logging.getLogger("movieclaw_api.download_dispatch")


def _utc_text(value: datetime | None) -> str | None:
    """把数据库 naive UTC / 接口 aware 时间统一冻结为带偏移 ISO 文本。"""
    if value is None:
        return None
    value = value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
    return value.isoformat()


async def dispatch(
    session: AsyncSession,
    *,
    subscription: Subscription,
    item: MediaItem,
    wanted_rows: list[WantedItem],
    candidate: TorrentCandidate,
    verdict: RuleVerdict,
    source: str,
    upgrade_rows: list[WantedItem] | None = None,
    upgrade_labels: tuple[str, str] | None = None,
    manual: bool = False,
    match: IdentityMatch | None = None,
    shadow_notes: dict | None = None,
    actor_member_id: int | None = None,
    selection_versions: dict[int, int] | None = None,
    submission_intent: SubscriptionDownloadAttempt | None = None,
    replacing_attempt: SubscriptionDownloadAttempt | None = None,
) -> bool:
    """把候选投递给下载器，满足给定的一批工单。返回是否有实际投递发生。

    洗版（quality-upgrade.md §6.2）：``upgrade_rows`` 是候选要洗版的已入库
    单元——**不认领、不改 status、不动 info_hash**（保持 imported、指向旧
    版本，直到入库验证确认升级），只进 attempt 的 units 台账；attempt 标记
    ``purpose="upgrade"`` 供在途去重与旧版清理定位。``upgrade_labels`` 是
    (当前档位, 候选档位) 的展示标签，进活动文案。

    ``manual``：手动选种投递（用户显式选择）。落在 attempt.manual 上，
    洗版验证据此在"未能证明更优"时保留共存而不是证伪（§13.8）。

    ``match``：身份匹配结果。只取其中的证据强度落台账（"当初凭什么认定这个
    种子就是这部片"），入库时 info_hash 认领据此分级；None=调用方没有身份
    上下文（旧调用点），台账留 NULL。

    ``actor_member_id``：手动选种时点下载的人（超管为 0），「开始下载」不推给他自己。

    ``shadow_notes``：尚未生效的判定的观察记录，原样并进投递活动 payload 的
    ``shadow`` 键（**不进 message，不打扰用户**）。用于给拍脑袋定的阈值攒真实
    数据，看过触发率与误报率再决定是否开成生效（identity-confidence.md §10.2）。
    """
    from movieclaw_api.services.subscription.core import recompute_subscription_status
    from movieclaw_api.services.subscription.matching import (
        DISPATCH_RETRY_DELAY,
        units_text,
    )

    upgrade_rows = upgrade_rows or []
    if upgrade_rows and submission_intent is None and replacing_attempt is None:
        # 洗版没有工单认领这道 DB 防线（不改 status），用投递前复查兜住
        # 被动匹配与搜索 worker 的并发窗口：单元已有在途洗版 attempt 即剔除
        upgrade_rows = await _filter_upgrade_in_flight(session, subscription, upgrade_rows)
    intent = submission_intent
    if subscription.selection_mode == "smart":
        from movieclaw_api.services.subscription.smart_submission import claim_intent

        if intent is None:
            intent = await claim_intent(
                session,
                subscription,
                wanted_rows,
                upgrade_rows,
                candidate,
                selection_versions
                if selection_versions is not None
                else (
                    {r.id: r.selection_version for r in wanted_rows + upgrade_rows}
                    if manual
                    else None
                ),
                match,
                replacing_attempt,
            )
        if intent is None:
            return False
        claimed = wanted_rows
    else:
        claimed = await _claim(session, wanted_rows)
    if not claimed and not upgrade_rows:
        return False  # 全部被另一条路径抢先，本候选无事可做

    is_trial = bool(intent and intent.replaces_attempt_id)
    repo = SubscriptionRepository(session)
    assert subscription.id is not None
    dry_run = get_settings().subscription_dispatch_dry_run
    submitted_info_hash: str | None = None
    skipped_files = 0
    all_targets = claimed + upgrade_rows
    units_label = units_text(all_targets)
    spec_ref = _describe(candidate)
    spec_text = source_render(spec_ref)  # 日志与事件载荷（外部契约）用中文原文

    # 选择性下载：候选呈整季包/多集包形态且覆盖明显多于本次要下的单元时，
    # 投递后只在下载器里保留缺口单元对应的文件（包里"已有集"不再重下，
    # 也不再混入库形成重复版本）。判定与规划见 file_selection 模块
    from movieclaw_api.services.subscription.file_selection import selective_units_for

    selective_units = selective_units_for(
        match,
        [(w.season_number, w.episode_number) for w in all_targets],
        subscription.kind,
    )

    if intent is not None and subscription.kind == "tv":
        # 首次提交冻结选择范围；恢复时 match 不再存在，必须使用同一范围。
        payload = dict(intent.submission or {})
        if "select_units" not in payload and payload.get("stage") == "claimed":
            payload.update(
                select_units=[[w.season_number, w.episode_number] for w in all_targets],
                known_seasons=subscription.selected_seasons,
                selection_owner=f"movieclaw-intent-{intent.id}",
            )
            intent.submission = payload
            await session.commit()
        if payload.get("select_units"):
            selective_units = {tuple(u) for u in payload["select_units"]}

    # 入库目标：订阅指定的库（缺省该类型默认库）→ 投递目录三级兜底走全仓
    # 唯一实现 resolve_save_path（口径与预检/体检/手动下载同源）。
    # 完成后的搬运/入账仍由监听导入或库扫描接管，工单由库存对账关闭——
    # 订阅不亲自跟踪下载，但投递必须把种子送到那两个机制看得见的地方。
    from movieclaw_api.services.library.config import LibraryConfigService
    from movieclaw_api.services.library.routing import resolve_save_path

    # library_id 常态下已在创建时定格（收藏范围路由，library-routing 2.1）；
    # NULL 仅剩老订阅/定格库被删的回落——带上 item 让回落也走路由而非裸默认库
    library = await LibraryConfigService(session).resolve_for_subscription(
        subscription.library_id, subscription.kind, item=item
    )
    decision = await resolve_save_path(
        session, library, kind=subscription.kind, title=item.title, year=item.year, item=item
    )
    dispatch_dir = intent.save_path if intent is not None and intent.save_path else decision.path
    # entry_level = 投递目录就是库内条目目录：可以安全锚定副标题线索，
    # 帮扫描器收敛拼音命名的种子内容（监听目录/默认目录锚线索会波及无关内容）
    entry_level = decision.entry_level
    # 自定义目录规则：落点由规则声明决定（不入库），文案陈述事实——
    # 整理到该目录后由外部流转，文件回到库根时才入账关单
    staging = getattr(decision.rule, "target_path", None)
    if library is not None and decision.mode == "watch" and staging:
        target_ref = reference("activity.subscription.targetStaging", path=staging)
    elif library is not None and decision.mode == "watch":
        target_ref = reference(
            "activity.subscription.targetWatch", library=library.name, path=decision.entry_dir
        )
    elif library is not None and decision.mode == "inplace":
        target_ref = reference(
            "activity.subscription.targetInPlace", library=library.name, path=decision.path
        )
    elif library is not None:
        target_ref = reference("activity.subscription.targetNoRoot", library=library.name)
    else:
        target_ref = reference("activity.subscription.targetNoLibrary")

    extended = None
    if not dry_run:
        try:
            submit_options = {}
            if intent is None and subscription.episode_caps:
                # 带订阅上限的规则订阅：整包可能是上千集，选择性下载不确定时也不回落
                # 全量（智能订阅本来就是严格路径）
                submit_options = {
                    "selection_owner": f"movieclaw-cap-{subscription.id}",
                    "strict_selection": True,
                }
            if intent is not None:
                from movieclaw_api.services.subscription.smart_submission import prepare_remote

                async def before_submit(info_hash, downloader_id):
                    await prepare_remote(session, intent, info_hash, downloader_id, dispatch_dir)

                async def before_resume():
                    from movieclaw_api.services.subscription.smart_submission import (
                        ensure_can_submit,
                    )

                    await ensure_can_submit(session, intent)

                submit_options = {
                    "before_submit": before_submit,
                    "downloader_id": intent.downloader_id,
                    "selection_owner": (intent.submission or {}).get("selection_owner"),
                    "before_resume": before_resume,
                }
            recovered = None
            if intent is not None:
                from movieclaw_api.services.subscription.smart_submission import reconcile_remote

                recovered = await reconcile_remote(session, intent)
            if recovered is not None:
                submit_result, downloader_row = recovered
            else:
                if intent is not None:
                    from movieclaw_api.services.subscription.smart_submission import (
                        ensure_can_submit,
                    )

                    await ensure_can_submit(session, intent)
                if (
                    selective_units
                    and subscription.kind == "tv"
                    and not is_trial
                    and not upgrade_rows
                ):
                    # 候选若是本订阅自己投递、还在下载器里的整包（调大订阅上限后的
                    # 下一批），把新单元并进它的文件选中集合，而不是当作重复投递
                    from movieclaw_api.services.subscription.pack_extension import (
                        extend_owned_pack,
                    )

                    extended = await extend_owned_pack(
                        session,
                        subscription=subscription,
                        candidate=candidate,
                        targets=set(selective_units),
                        before_resume=submit_options.get("before_resume"),
                    )
                if extended is not None:
                    submit_result, downloader_row = extended
                else:
                    submit_result, downloader_row = await _submit_real(
                        session,
                        candidate,
                        save_path=dispatch_dir,
                        subtitle=candidate.subtitle if entry_level else None,
                        select_units=selective_units,
                        known_seasons=subscription.selected_seasons or None,
                        media_kind=item.kind,
                        **submit_options,
                    )
            skipped_files = submit_result.skipped_file_count
        except Exception as exc:  # noqa: BLE001 -- 投递失败退回调度通道重试
            reason = f"{type(exc).__name__}: {exc}"
            if intent is not None:
                from movieclaw_api.services.subscription.file_selection import (
                    UnsatisfiableSelection,
                )
                from movieclaw_api.services.subscription.smart_submission import (
                    SubmissionRejected,
                    reject_intent,
                )

                if isinstance(exc, SubmissionRejected):
                    await reject_intent(session, intent, all_targets, exc.ref)
                    return False
                if isinstance(exc, UnsatisfiableSelection):
                    # 文件清单的结论不会因重试改变：给满足不了的单元一个终态
                    from movieclaw_api.services.subscription.core import (
                        recompute_subscription_status,
                    )
                    from movieclaw_api.services.subscription.smart_submission import (
                        settle_unsatisfiable,
                    )

                    released = await settle_unsatisfiable(session, intent, all_targets, exc)
                    if released:
                        await repo.add_activity(
                            SubscriptionActivity(
                                subscription_id=subscription.id,
                                wanted_item_id=released[0].id,
                                type=ActivityType.DISPATCH_FAILED,
                                payload={
                                    "site_id": candidate.site_id,
                                    "torrent_id": candidate.torrent_id,
                                    "source": source,
                                },
                                **stored_fields(
                                    "activity.subscription.releaseMissingUnits",
                                    units=units_reference(released),
                                    title=candidate.title,
                                    reason=exc.ref,
                                ),
                            )
                        )
                    await session.commit()
                    await recompute_subscription_status(session, subscription, item)
                    await session.commit()
                    logger.warning(
                        "智能投递 #%s 无法满足 %s：%s",
                        intent.id,
                        units_text(released) if released else "（无）",
                        exc,
                    )
                    return False
                from movieclaw_api.services.subscription.smart_submission import (
                    SMART_RECOVER_BASE_DELAY,
                    SMART_RECOVER_MAX_DELAY,
                )

                payload = dict(intent.submission or {})
                failures = int(payload.get("recover_failures", 0)) + 1
                retry_after = min(
                    SMART_RECOVER_BASE_DELAY * 2 ** (failures - 1), SMART_RECOVER_MAX_DELAY
                )
                intent.submission = {
                    **payload,
                    "recover_failures": failures,
                    "retry_at": (utcnow() + retry_after).isoformat(),
                }
                intent.updated_at = utcnow()
                set_note(intent, reference("subscription.smart.recoverPending", reason=reason))
                explanation = reference("subscription.smart.submitPending", reason=reason)
                for row in all_targets:
                    row.selection_state = {
                        **(row.selection_state or {}),
                        "reason": "reconciling",
                        "choice_explanation": source_render(explanation),
                    }
                    row.selection_messages = {
                        **(row.selection_messages or {}),
                        "choice_explanation": explanation,
                    }
                await session.commit()
                logger.warning(
                    "智能投递待对账 #%s（第 %d 次，%d 分钟后重试）：%s",
                    intent.id,
                    failures,
                    int(retry_after.total_seconds() // 60),
                    reason,
                )
                return False
            await _rollback_claim(session, claimed, retry_delay=DISPATCH_RETRY_DELAY)
            await repo.add_activity(
                SubscriptionActivity(
                    subscription_id=subscription.id,
                    wanted_item_id=all_targets[0].id,
                    type=ActivityType.DISPATCH_FAILED,
                    payload={
                        "site_id": candidate.site_id,
                        "torrent_id": candidate.torrent_id,
                        "source": source,
                    },
                    **stored_fields(
                        "activity.subscription.dispatchRetry",
                        units=units_reference(all_targets),
                        reason=reason,
                        minutes=int(DISPATCH_RETRY_DELAY.total_seconds() // 60),
                    ),
                )
            )
            logger.warning(
                "投递失败（%s）：《%s》%s ← %s/%s：%s",
                source,
                item.title,
                units_label,
                candidate.site_id,
                candidate.torrent_id,
                reason,
            )
            return False
        # 记录 infohash：完成轮询任务据此追踪下载进度并触发入库整理
        if submit_result.info_hash:
            now = utcnow()
            normalized_hash = submit_result.info_hash.lower()
            submitted_info_hash = normalized_hash
            for wanted in [] if is_trial else claimed:
                await session.execute(
                    update(WantedItem)
                    .where(
                        WantedItem.id == wanted.id,
                        WantedItem.status == WantedStatus.GRABBED,
                    )
                    .values(info_hash=normalized_hash, updated_at=now)
                )
            # 网络提交期间用户可能刚好取消季订阅。infohash 仍要写入以保存真实
            # 投递历史，但只有仍在范围内的目标才能让尝试保持 active。
            # 洗版单元不写 info_hash（保持指向旧版本），其在途性由 attempt 表达。
            active_targets = list(
                (
                    await session.execute(
                        select(WantedItem).where(
                            WantedItem.subscription_id == subscription.id,
                            WantedItem.info_hash == normalized_hash,
                            WantedItem.in_scope.is_(True),  # type: ignore[attr-defined]
                            WantedItem.status.in_(  # type: ignore[attr-defined]
                                (WantedStatus.GRABBED, WantedStatus.DOWNLOADED)
                            ),
                        )
                    )
                )
                .scalars()
                .all()
            )
            attempt_alive = bool(active_targets) or any(w.in_scope for w in upgrade_rows)
            if is_trial:
                parent = await session.get(
                    SubscriptionDownloadAttempt, intent.replaces_attempt_id, populate_existing=True
                )
                attempt_alive = bool(
                    parent
                    and parent.status == DownloadAttemptStatus.REPLACEMENT_PENDING
                    and any(w.in_scope for w in all_targets)
                )
            existing_attempt = (
                await session.execute(
                    select(SubscriptionDownloadAttempt).where(
                        SubscriptionDownloadAttempt.subscription_id == subscription.id,
                        SubscriptionDownloadAttempt.info_hash == normalized_hash,
                    )
                )
            ).scalar_one_or_none()
            # 所有权：全新提交归我们；「已存在」通常是用户自己的任务（不碰），
            # 但刷流引擎抢下后被接管的（reclaimed_from_boost）本来就是
            # movieclaw 的，数据也已迁到目标目录——按自有任务记
            owned = not submit_result.already_exists or submit_result.reclaimed_from_boost
            values = {
                "downloader_id": downloader_row.id,
                "site_id": candidate.site_id,
                "torrent_id": candidate.torrent_id,
                "torrent_title": candidate.title,
                "identity_confidence": match.confidence if match is not None else None,
                "matched_alias": match.matched_alias if match is not None else None,
                "download_name": submit_result.name or None,
                "save_path": dispatch_dir,
                "units": [[w.season_number, w.episode_number] for w in all_targets],
                "quality": candidate.attrs.model_dump(exclude_defaults=True),
                "hit_and_run": candidate.hit_and_run,
                "owned_by_movieclaw": owned,
                # 一旦承担过洗版语义就保持 upgrade（入库验证与旧版清理据此定位）
                "purpose": (
                    "upgrade"
                    if upgrade_rows
                    or (existing_attempt is not None and existing_attempt.purpose == "upgrade")
                    else "download"
                ),
                # 同理粘性：承担过手动选种语义就保持（验证裁决据此分流）
                "manual": manual or (existing_attempt is not None and existing_attempt.manual),
                "status": (
                    (DownloadAttemptStatus.TRIAL if is_trial else DownloadAttemptStatus.ACTIVE)
                    if attempt_alive
                    else DownloadAttemptStatus.CANCELLED
                ),
                "baseline_completed_bytes": 0 if owned else None,
                "last_completed_bytes": 0 if owned else None,
                "baseline_downloaded_bytes": 0 if owned else None,
                "last_downloaded_bytes": 0 if owned else None,
                "last_progress_at": now,
                "stalled_notified_at": None,
                "missing_observations": 0,
                # 同一 hash 重新投递是一次全新的下载，"曾经完成过"的记忆随
                # 心跳基线一起清零，不能让旧记忆压住新任务的救援判定
                "completed_at": None,
                "next_search_at": None,
                **note_fields(
                    None
                    if attempt_alive
                    else reference("subscription.attempt.networkOutOfScope")
                ),
                "updated_at": now,
            }
            if existing_attempt is None:
                session.add(
                    SubscriptionDownloadAttempt(
                        subscription_id=subscription.id,
                        info_hash=normalized_hash,
                        **values,
                    )
                )
            else:
                existing_units = {
                    (int(unit[0]), int(unit[1]))
                    for unit in existing_attempt.units
                    if isinstance(unit, list) and len(unit) == 2
                }
                existing_units.update(
                    (wanted.season_number, wanted.episode_number) for wanted in all_targets
                )
                values["units"] = [[season, episode] for season, episode in sorted(existing_units)]
                # 同一 hash 是同一份内容的续用，不抹掉首次投递时已经证明的
                # 所有权/来源/品质历史；旧字段缺失时才用本次更完整的证据回填。
                values["owned_by_movieclaw"] = existing_attempt.owned_by_movieclaw or owned
                if existing_attempt.site_id:
                    values["site_id"] = existing_attempt.site_id
                    values["torrent_id"] = existing_attempt.torrent_id
                    values["torrent_title"] = existing_attempt.torrent_title
                if match is None:
                    # 本次没有身份上下文（旧调用点）：保住首次投递记下的证据，
                    # 不用一个空值把它抹掉。有上下文时用新的——同一 hash 再次
                    # 投递时证据可能已经变强（例如详情页复核补回了 IMDb）
                    values["identity_confidence"] = existing_attempt.identity_confidence
                    values["matched_alias"] = existing_attempt.matched_alias
                if existing_attempt.download_name:
                    values["download_name"] = existing_attempt.download_name
                if existing_attempt.save_path:
                    values["save_path"] = existing_attempt.save_path
                if existing_attempt.quality:
                    values["quality"] = existing_attempt.quality
                if existing_attempt.hit_and_run is not None:
                    values["hit_and_run"] = existing_attempt.hit_and_run
                # 证伪过的洗版内容可能以同一 info_hash 在别的站点再现
                # （排除清单按 site/torrent 记，拦不住跨站同种）：实测已经
                # 证明它不构成升级，绝不复活为在途任务
                if (
                    existing_attempt.purpose == "upgrade"
                    and existing_attempt.status == DownloadAttemptStatus.FAILED
                ):
                    values["status"] = DownloadAttemptStatus.FAILED
                    values["purpose"] = "upgrade"
                for key, value in values.items():
                    setattr(existing_attempt, key, value)
                session.add(existing_attempt)
            if extended is not None and intent is not None:
                # 并进了既有的整包：本次的意图没有对应的远端任务，台账已合并进原尝试
                await session.delete(intent)
            await session.commit()

    if intent is not None and dry_run:
        intent.status = DownloadAttemptStatus.TRIAL if is_trial else DownloadAttemptStatus.ACTIVE
        await session.commit()
    if intent is not None:
        for row in all_targets:
            row.selection_state = {**(row.selection_state or {}), "reason": "submitted"}
        await session.commit()

    # 活动是投递事实的永久台账：这里把资源发布→首次索引→提交下载器的时间链
    # 一并冻结。不能只在详情页临时查 site_torrent——用户移除站点会清索引，
    # 历史耗时仍应保留。手动选种不落索引，first_seen_at 合理为空。
    torrent_row = (
        await session.execute(
            select(SiteTorrent).where(
                SiteTorrent.site_id == candidate.site_id,
                SiteTorrent.torrent_id == candidate.torrent_id,
            )
        )
    ).scalar_one_or_none()
    resource_publish_time = candidate.publish_time or (
        torrent_row.publish_time if torrent_row is not None else None
    )
    resource_first_seen_at = torrent_row.created_at if torrent_row is not None else None
    submitted_at = utcnow()

    # i18n-ignore: log prefix
    mode = "【模拟投递】" if dry_run else ""
    logger.info(
        "%s已投递（%s）：《%s》%s ← %s 的「%s」（%s）",
        mode,
        source,
        item.title,
        units_label,
        candidate.site_id,
        candidate.title[:80],
        spec_text,
    )
    # 洗版投递用专属活动类型与"从 X 洗到 Y"文案；混合投递（缺口+洗版）
    # 仍是 GRABBED，文案附注洗版单元数
    units_ref = units_reference(all_targets)
    tail = [target_ref]
    if skipped_files:
        tail.append(reference("activity.subscription.selective", count=skipped_files))
    if is_trial:
        activity_type = ActivityType.REPLACEMENT_TRIAL
        message = reference(
            "activity.subscription.trialSubmitted", units=units_ref, title=candidate.title[:60]
        )
    else:
        if upgrade_rows and not claimed:
            activity_type = ActivityType.UPGRADE_GRABBED
            head = [
                reference(
                    "activity.subscription.upgradeGrabbed",
                    units=units_ref,
                    site=candidate.site_id,
                    title=candidate.title[:60],
                    label=reference(
                        "activity.subscription.upgradeLabel",
                        new=upgrade_labels[1],
                        old=upgrade_labels[0],
                    )
                    if upgrade_labels
                    else spec_ref,
                )
            ]
        else:
            activity_type = ActivityType.GRABBED
            head = [
                reference(
                    "activity.subscription.grabbed",
                    units=units_ref,
                    site=candidate.site_id,
                    title=candidate.title[:60],
                    spec=spec_ref,
                )
            ]
            if upgrade_rows:
                head.append(
                    reference(
                        "activity.subscription.grabbedUpgradeUnits",
                        units=units_reference(upgrade_rows),
                    )
                )
        message = reference(
            "activity.subscription.dispatched",
            parts={"message_list": [*head, *tail], "separator_key": "common.list.issueSeparator"},
            dryRun="yes" if dry_run else "no",
        )
    # 单集履历注解：把「这集靠哪个种子拿到」冻结在工单上，详情页里程碑链的
    # 投递站直接读，不再回活动流水里按季集捞。只写认领的缺口单元——洗版
    # 单元仍指向在库旧版本，升级确认前候选种子不是它的「来源」。
    # 提交失败在上方已 return，走到这里必然是投递成立（含 dry-run 模拟投递）；
    # 随下方 add_activity 的 commit 一起落库。
    if claimed:
        grab_note = f"{candidate.site_id} · {candidate.title[:120]}"
        grab_ts = utcnow()
        for wanted in claimed:
            await session.execute(
                update(WantedItem)
                .where(WantedItem.id == wanted.id)
                .values(grab_title=grab_note, updated_at=grab_ts)
            )
    if not dry_run:
        # 「订阅开始下载」随下面这条抓取动态一起提交（domain-events.md §8）：通知（剧卡）、
        # Webhook、插件都从这一个事件取；模拟投递不是事实，不发
        from movieclaw_api.services.subscription.events import publish_download_started

        await publish_download_started(
            session,
            subscription_id=subscription.id,
            item=item,
            units=[(w.season_number, w.episode_number) for w in all_targets],
            site_id=candidate.site_id,
            torrent_id=candidate.torrent_id,
            torrent_title=candidate.title,
            info_hash=submitted_info_hash,
            resolution=candidate.attrs.resolution,
            spec=spec_text,
            upgrade=bool(upgrade_rows and not claimed),
            actor_member_id=actor_member_id,
        )
    await repo.add_activity(
        SubscriptionActivity(
            subscription_id=subscription.id,
            wanted_item_id=all_targets[0].id,
            type=activity_type,
            **reference_fields(message),
            payload={
                "site_id": candidate.site_id,
                "torrent_id": candidate.torrent_id,
                "score": verdict.score,
                "source": source,
                "dry_run": dry_run,
                "info_hash": submitted_info_hash,
                "units": [[w.season_number, w.episode_number] for w in claimed],
                "upgrade_units": [[w.season_number, w.episode_number] for w in upgrade_rows],
                "resource_publish_time": _utc_text(resource_publish_time),
                "resource_first_seen_at": _utc_text(resource_first_seen_at),
                "submitted_at": _utc_text(submitted_at),
                "library_id": library.id if library else None,
                "save_path": decision.entry_dir,
                "staging_path": staging,
                "dispatch_dir": dispatch_dir,
                **({"skipped_files": skipped_files} if skipped_files else {}),
                **({"shadow": shadow_notes} if shadow_notes else {}),
            },
        )
    )
    await recompute_subscription_status(session, subscription, item)
    return True


async def preview_dispatch_route(
    session: AsyncSession,
    *,
    kind: str,
    library_id: int | None,
    tmdb_id: int | None = None,
    downloader_id: int | None = None,
    title: str | None = None,
    year: int | None = None,
) -> dict:
    """预演一次投递的路由结论（订阅弹窗/下载弹窗的预检数据源）。

    与 dispatch() 的三级兜底同源：监听规则源目录 → 库主根（条目目录的
    基底）→ 下载器默认目录；再叠加 submit_torrent 的映射覆盖守门判定。
    ``downloader_id`` 缺省时维持默认下载器语义，显式传入时则用该台的
    可用状态与路径映射预演，供手动下载弹窗的多下载器选择复用。
    只读不投，返回结构化结论让前端在**订阅那一刻**就把问题亮给用户，
    而不是等投递失败/落点告警才发现。

    ``library_id`` 缺省且给了 ``tmdb_id`` 时按收藏范围路由选库，并返回
    路由结论（route_matched/route_reason）供前端预选与展示理由——规则
    只决定默认值，用户在弹窗里改库即显式指定，下次预检不再带路由徽标。

    ``title``/``year`` 只影响展示用的 ``entry_dir``（条目目录预览），不参与
    mode/path 的推导——预检给出的是投递基底目录，条目目录到投递时才推导。

    返回字段：mode（watch/inplace/downloader_default）、path（movieclaw
    视角的投递基底目录）、entry_dir（条目目录的完整路径预览，见下）、
    library_id/library_name、downloader_name、
    route_matched/route_reason（走了路由才有）、rule_set_id/rule_set_name/
    rule_set_matched/rule_set_reason（按规则组适用范围的预选，同样走了路由才有）、
    ok、warning（不 ok 时的中文指引）。
    """
    from movieclaw_api.services.library.config import LibraryConfigService, derive_save_path
    from movieclaw_api.services.library.routing import resolve_save_path
    from movieclaw_api.services.torrent_submit import mapping_covers
    from movieclaw_db.models.downloader_client import DownloaderClient
    from movieclaw_db.models.site_credential import ConfigStatus

    route_matched: bool | None = None
    route_reason: str | None = None
    route_fields: dict = {}
    routed_item = None
    rule_set_fields: dict = {}
    if library_id is None and tmdb_id is not None:
        from movieclaw_api.services.library.routing import route_for_tmdb
        from movieclaw_api.services.rule_sets import RuleSetService

        route_decision = await route_for_tmdb(session, kind, tmdb_id)
        library = route_decision.library
        route_matched = route_decision.matched
        route_reason = route_decision.reason
        message = getattr(route_decision, "reason_message", None)
        if message:
            route_fields = {
                "route_reason_key": message["message_key"],
                "route_reason_params": message["message_params"],
            }
        routed_item = route_decision.item
        # 规则组按适用范围的预选与库路由同一时机、同一份作品事实（不重复装配）
        pick = await RuleSetService(session).pick(kind, route_decision.facts)
        rule_set_fields = {
            "rule_set_id": pick.rule_set.id,
            "rule_set_name": pick.rule_set.name,
            "rule_set_matched": pick.matched,
            "rule_set_reason": pick.reason,
            **(
                {
                    "rule_set_reason_key": pick.reason_message["message_key"],
                    "rule_set_reason_params": pick.reason_message["message_params"],
                }
                if getattr(pick, "reason_message", None)
                else {}
            ),
        }
    else:
        library = await LibraryConfigService(session).resolve_for_subscription(library_id, kind)
    # 投递目录口径与真实投递同源（预检不给 title：条目目录到投递时才推导）
    decision = await resolve_save_path(session, library, kind=kind)
    base = decision.path
    # 条目目录预览：模板化之后前端不能再自己拼「标题 (年份)」，落点长什么样
    # 只能由后端用同一套模板渲染（命名同源，见 library/naming.py）。
    # 标题取值：已建档条目的权威标题优先，未建档（临时条目标题是 tmdb#id
    # 占位符）时用调用方传入的识别标题。
    if routed_item is None and tmdb_id is not None:
        # 显式选库时不走路由，但条目可能已建档——命名模板里的
        # {original_title}/{tmdb_id} 需要条目才渲染得出，补一次轻量查询
        from movieclaw_db.models import MediaItem

        routed_item = (
            await session.execute(
                select(MediaItem).where(
                    MediaItem.source == MediaSource.TMDB,
                    MediaItem.kind == kind,
                    MediaItem.external_id == str(tmdb_id),
                )
            )
        ).scalar_one_or_none()
    if routed_item is not None and routed_item.id is not None:
        entry_title, entry_year = routed_item.title, routed_item.year
        entry_item: object | None = routed_item
    else:
        entry_title, entry_year, entry_item = title, year, None
    entry_dir = (
        derive_save_path(library, title=entry_title, year=entry_year, item=entry_item)
        if library is not None and entry_title
        else None
    )

    if downloader_id is not None:
        # 手动下载弹窗可以显式选第二台下载器。预检必须以该台的路径映射
        # 判断，不能仍偷看默认下载器，否则「预检可投、提交被拒」会重新出现。
        downloader = await session.get(DownloaderClient, downloader_id)
    else:
        # 与实际投递同一个选择函数（含插件分流），预检结论不会与投递分家
        from movieclaw_api.services.torrent_submit import pick_downloader

        downloader = await pick_downloader(
            session, hooks.DownloaderQuery(title=entry_title, media_kind=kind)
        )

    mode = decision.mode
    ok = True
    warning_message = None
    if downloader is None:
        ok = False
        warning_message = (
            stored_fields("download.preview.downloaderMissing", id=downloader_id)
            if downloader_id is not None
            else stored_fields("download.preview.defaultMissing")
        )
    elif not downloader.enabled or downloader.status != ConfigStatus.ACTIVE:
        ok = False
        warning_message = stored_fields(
            "download.preview.downloaderUnavailable", name=downloader.name
        )
    elif base is None:
        ok = False
        warning_message = stored_fields("download.preview.noRoot")
    elif library is None:
        ok = False
        warning_message = (
            stored_fields("download.preview.noStagingLibrary")
            if getattr(decision.rule, "target_path", None)
            else stored_fields("download.preview.noWatchLibrary")
        )
    elif downloader.path_mappings and not mapping_covers(base, downloader.path_mappings):
        ok = False
        warning_message = stored_fields(
            "download.preview.unmapped", path=base, name=downloader.name
        )
    return localize_fields(
        {
            "mode": mode,
            "path": base,
            "entry_dir": entry_dir,
            "staging_path": getattr(decision.rule, "target_path", None),
            "library_id": library.id if library else None,
            "library_name": library.name if library else None,
            "downloader_name": downloader.name if downloader else None,
            "route_matched": route_matched,
            "route_reason": route_reason,
            **route_fields,
            **rule_set_fields,
            "ok": ok,
            "warning": warning_message["message"] if warning_message else None,
            "warning_key": warning_message["message_key"] if warning_message else None,
            "warning_params": warning_message["message_params"] if warning_message else None,
        }
    )

async def _filter_upgrade_in_flight(
    session: AsyncSession,
    subscription: Subscription,
    upgrade_rows: list[WantedItem],
) -> list[WantedItem]:
    """剔除已有在途洗版 attempt 的单元（洗版投递的并发防线）。"""
    in_flight: set[tuple[int, int]] = set()
    attempts = (
        await session.execute(
            select(SubscriptionDownloadAttempt).where(
                SubscriptionDownloadAttempt.subscription_id == subscription.id,
                SubscriptionDownloadAttempt.purpose == "upgrade",
                SubscriptionDownloadAttempt.status.in_(  # type: ignore[attr-defined]
                    (
                        DownloadAttemptStatus.ACTIVE,
                        DownloadAttemptStatus.SUBMITTING,
                        DownloadAttemptStatus.REPLACEMENT_PENDING,
                        DownloadAttemptStatus.TRIAL,
                        DownloadAttemptStatus.CLEANUP_PENDING,
                        DownloadAttemptStatus.COMPLETED,
                    )
                ),
            )
        )
    ).scalars()
    for attempt in attempts:
        in_flight.update(
            (int(u[0]), int(u[1])) for u in attempt.units if isinstance(u, list) and len(u) == 2
        )
    return [w for w in upgrade_rows if (w.season_number, w.episode_number) not in in_flight]


async def _claim(session: AsyncSession, wanted_rows: list[WantedItem]) -> list[WantedItem]:
    """条件更新认领（防线①）：只把仍是 wanted 态的工单推进到 grabbed。

    逐条执行拿到精确的"谁被我认领了"；工单数量级小（整季包也就几十条），
    不值得为省几次 UPDATE 引入批量+回读的复杂度。
    """
    claimed: list[WantedItem] = []
    now = utcnow()
    for wanted in wanted_rows:
        result = await session.execute(
            update(WantedItem)
            .where(
                WantedItem.id == wanted.id,
                WantedItem.status == WantedStatus.WANTED,
                WantedItem.in_scope.is_(True),  # type: ignore[attr-defined]
            )
            .values(status=WantedStatus.GRABBED, grabbed_at=now, updated_at=now)
        )
        if result.rowcount:
            claimed.append(wanted)
    await session.commit()
    return claimed


async def _rollback_claim(session: AsyncSession, claimed: list[WantedItem], *, retry_delay) -> None:
    """投递失败：认领回滚，退回调度通道（next_search_at 短冷却）择机重试。"""
    now = utcnow()
    for wanted in claimed:
        await session.execute(
            update(WantedItem)
            .where(
                WantedItem.id == wanted.id,
                WantedItem.status == WantedStatus.GRABBED,
                WantedItem.in_scope.is_(True),  # type: ignore[attr-defined]
            )
            .values(
                status=WantedStatus.WANTED,
                grabbed_at=None,
                next_search_at=now + retry_delay,
                updated_at=now,
            )
        )
        # 网络失败期间若用户取消了该范围，认领仍应回滚，但不能留下一个会在
        # 重新勾选前触发的退避时间。历史没有真实投递，所以回到 wanted 合理。
        await session.execute(
            update(WantedItem)
            .where(
                WantedItem.id == wanted.id,
                WantedItem.status == WantedStatus.GRABBED,
                WantedItem.in_scope.is_(False),  # type: ignore[attr-defined]
            )
            .values(
                status=WantedStatus.WANTED,
                grabbed_at=None,
                next_search_at=None,
                updated_at=now,
            )
        )
    await session.commit()


async def _submit_real(
    session: AsyncSession,
    candidate: TorrentCandidate,
    *,
    save_path: str | None = None,
    subtitle: str | None = None,
    select_units: set[tuple[int, int]] | None = None,
    known_seasons: Collection[int] | None = None,
    before_submit=None,
    downloader_id: int | None = None,
    selection_owner: str | None = None,
    before_resume=None,
    media_kind: str | None = None,
    strict_selection: bool = False,
):
    """真实投递：委托公共编排（站点取种 → 默认下载器提交，幂等判重）。

    save_path 按三级兜底解析（监听规则源目录 / 库条目目录 / None 退下载器
    默认目录），完成后的搬运/入账由监听导入或库扫描接管，库存对账关闭工单。
    subtitle 仅在投递目录为**条目级**时传入（download_hint 线索只能锚条目
    目录——锚到监听目录/默认目录会波及目录下全部内容）。
    select_units 非空时启用选择性下载（只下载缺口单元对应的文件），
    known_seasons 是订阅勾选的季号，供规划器做季号守卫。
    """
    from movieclaw_api.services.torrent_submit import submit_torrent

    result, row = await submit_torrent(
        session,
        site_id=candidate.site_id,
        download_url=candidate.download_url,
        tags=["movieclaw-sub"],
        save_path=save_path,
        subtitle=subtitle,
        select_units=select_units,
        known_seasons=known_seasons,
        before_submit=before_submit,
        downloader_id=downloader_id,
        selection_owner=selection_owner,
        before_resume=before_resume,
        strict_selection=strict_selection,
        route_hint=hooks.DownloaderQuery(
            site_id=candidate.site_id,
            title=candidate.title,
            size_bytes=candidate.size_bytes,
            media_kind=media_kind,
            category="movieclaw",
            tags=("movieclaw-sub",),
        ),
    )
    return result, row


def _describe(candidate: TorrentCandidate) -> dict:
    """候选的一句话规格描述（文案引用），进活动与日志。"""
    parts: list[str | dict] = []
    if candidate.attrs.resolution:
        parts.append(candidate.attrs.resolution)
    if candidate.is_free is True:
        parts.append("free")
    if candidate.seeders is not None:
        parts.append(reference("activity.subscription.seeders", count=candidate.seeders))
    if not parts:
        return reference("activity.subscription.specUnknown")
    return {"message_list": parts, "separator_key": "common.list.dotSeparator"}
