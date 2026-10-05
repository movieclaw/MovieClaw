"""全局待处理事项（状态化告警中心）的写入与消退原语。

设计（见 movieclaw_db.models.system_notice 模块头）：告警是**有生命周期的
问题**而非事件流——同一问题靠 dedupe_key 收敛为一行，问题消失时由恢复
路径调用 resolve 自动熄灯。本模块只提供三个原语，写入点各自决定
dedupe_key 与文案：

- ``upsert_notice``：问题发生/仍在。已有活跃行只刷新内容；用户 dismiss
  过的行保持沉默（同一问题不再打扰）；已 resolve 的行重新点亮（问题
  复发是新事件）。
- ``resolve_notices``：问题消失。按精确 key 或前缀批量消退（active 与
  dismissed 都消退——问题没了，沉默标记也该一起清场，复发时才能再亮）。
- 用户 dismiss 走 API 路由直接改状态，不在此处。

提交语义与 SubscriptionRepository.add_activity 一致：每个原语自行 commit。
调用点都在后台任务/服务尾部，就地提交不会打断上层事务语义。
"""

from __future__ import annotations

import logging

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models import NoticeSeverity, NoticeStatus, SystemNotice, utcnow

logger = logging.getLogger("movieclaw_api.system_notice")


async def upsert_notice(
    session: AsyncSession,
    *,
    dedupe_key: str,
    severity: NoticeSeverity,
    source: str,
    title: str,
    message: str,
    payload: dict | None = None,
) -> None:
    """报告一个需要用户行动的问题（幂等：同 dedupe_key 只存一行）。"""
    row = (
        await session.execute(select(SystemNotice).where(SystemNotice.dedupe_key == dedupe_key))
    ).scalar_one_or_none()
    now = utcnow()
    # 新出现或复发的问题推到管理员的手机上（仍在发生的只刷新内容，不重复推）
    fresh = row is None or row.status == NoticeStatus.RESOLVED.value
    if row is None:
        session.add(
            SystemNotice(
                dedupe_key=dedupe_key,
                severity=severity.value,
                source=source,
                title=title,
                message=message,
                payload=payload or {},
            )
        )
        logger.info("新增待处理告警（%s）：%s", dedupe_key, title)
    else:
        if row.status == NoticeStatus.DISMISSED.value:
            return  # 用户已选择忽略这个仍在发生的问题，不再打扰
        reactivated = row.status == NoticeStatus.RESOLVED.value
        row.severity = severity.value
        row.title = title
        row.message = message
        row.payload = payload or {}
        row.status = NoticeStatus.ACTIVE.value
        row.resolved_at = None
        row.updated_at = now
        if reactivated:
            logger.info("待处理告警复发（%s）：%s", dedupe_key, title)
    await session.commit()
    if fresh:
        from movieclaw_api.services.push import events as push_events

        push_events.system_alert(
            dedupe_key=dedupe_key,
            source=source,
            title=title,
            message=message,
            payload=payload or {},
        )


async def resolve_notices(
    session: AsyncSession, *, dedupe_key: str | None = None, prefix: str | None = None
) -> int:
    """问题消失，消退对应告警。按精确 key 或前缀批量；返回消退条数。"""
    assert (dedupe_key is None) != (prefix is None), "精确 key 与前缀二选一"
    query = select(SystemNotice).where(
        SystemNotice.status != NoticeStatus.RESOLVED.value  # type: ignore[arg-type]
    )
    if dedupe_key is not None:
        query = query.where(SystemNotice.dedupe_key == dedupe_key)
    else:
        assert prefix is not None
        query = query.where(SystemNotice.dedupe_key.startswith(prefix))  # type: ignore[attr-defined]
    rows = list((await session.execute(query)).scalars().all())
    if not rows:
        return 0
    now = utcnow()
    for row in rows:
        row.status = NoticeStatus.RESOLVED.value
        row.resolved_at = now
        row.updated_at = now
    await session.commit()
    logger.info("已消退 %d 条待处理告警（%s）", len(rows), dedupe_key or f"{prefix}*")
    return len(rows)
