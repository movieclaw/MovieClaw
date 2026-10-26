"""全局待处理事项的接口：活跃告警列表 + 用户手动忽略。

告警的产生与自动消退都在服务端各写入点（见 services.system_notice 模块头），
接口只负责两件事：
- 前端全局红点轮询活跃列表（正常运行时为空数组，查询极轻）；
- 用户对"知道了但暂不处理"的问题手动 dismiss（同一问题此后不再打扰，
  问题消失时仍会被自动 resolve 清场，复发时重新点亮）。
"""

from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.i18n import t
from movieclaw_api.i18n.stored import stored_message
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_db.engine import get_session
from movieclaw_db.models import NoticeStatus, SystemNotice, utcnow

router = APIRouter(prefix="/system/notices", tags=["system"])


class NoticeView(BaseModel):
    """一条待处理事项（面板列表行）。"""

    id: int
    severity: str
    source: str
    title: str
    message: str
    title_key: str | None = None
    message_key: str | None = None
    message_params: dict | None = None
    payload: dict
    created_at: datetime
    updated_at: datetime

    @classmethod
    def from_model(cls, row: SystemNotice) -> NoticeView:
        def _utc(value: datetime) -> datetime:
            return value.replace(tzinfo=UTC) if value.tzinfo is None else value

        assert row.id is not None
        return cls(
            id=row.id,
            severity=row.severity,
            source=row.source,
            title=stored_message(row.title, row.title_key, row.message_params),
            message=stored_message(row.message, row.message_key, row.message_params),
            title_key=row.title_key,
            message_key=row.message_key,
            message_params=row.message_params,
            payload=row.payload,
            created_at=_utc(row.created_at),
            updated_at=_utc(row.updated_at),
        )


@router.get(
    "",
    response_model=ApiResponse[list[NoticeView]],
    summary="列出全部活跃的待处理事项（error 在前，新的在前）",
    operation_id="notices.list",
)
async def list_notices(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[NoticeView]]:
    rows = list(
        (
            await session.execute(
                select(SystemNotice).where(SystemNotice.status == NoticeStatus.ACTIVE.value)
            )
        )
        .scalars()
        .all()
    )
    # error 组在前；组内新的在前（两次稳定排序）
    rows.sort(key=lambda r: r.updated_at, reverse=True)
    rows.sort(key=lambda r: r.severity != "error")
    return ok([NoticeView.from_model(r) for r in rows])


@router.post(
    "/{notice_id}/dismiss",
    response_model=ApiResponse[None],
    summary="忽略一条待处理事项（问题仍在也不再提示；自动消退不受影响）",
    operation_id="notices.dismiss",
)
async def dismiss_notice(
    notice_id: int,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[None]:
    row = await session.get(SystemNotice, notice_id)
    if row is None:
        raise NotFoundException(message_key="errors.notices.missing", params={"id": notice_id})
    if row.status == NoticeStatus.ACTIVE.value:
        row.status = NoticeStatus.DISMISSED.value
        row.resolved_at = utcnow()
        row.updated_at = utcnow()
        await session.commit()
    return ok(None, message=t("notify.notices.dismissed"))
