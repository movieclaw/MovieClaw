"""使用提示接口：每个人的提示状态读写（对标 Apple TipKit，docs/design/tips.md）。

提示本身（文案、动作按钮、出现条件）写在各端代码里；本接口只存三样跟人走的
状态，各端启动时 GET 一次全量、之后按需上报：

- 事件：用户做过某件事（``POST /tips/events/{event_id}``，计数 +1）；
- 展示：某条提示出现了一次（``POST /tips/{tip_id}/displays``）；
- 作废：用户关掉了提示或用过了它说的功能，这条以后不再出现
  （``POST /tips/{tip_id}/invalidate``，首次作废为准，重复上报无副作用）。

写入一律原子 upsert：同一个人在手机和电视上同时上报，计数不丢。标识由客户端
定义、服务端不认识含义——新提示上线不用改服务端。
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Path
from pydantic import Field
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.api.deps import require_login
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services import tips
from movieclaw_api.services.auth import Principal
from movieclaw_db.engine import get_session
from movieclaw_db.models import TipEvent, TipRecord

router = APIRouter(prefix="/tips", tags=["tips"])

# 提示状态是各端界面内部用的，不做成命令行命令
_HIDDEN = {"x-cli-hidden": True}

# 标识形如 ``player.opened``、``library.filter-tip``：小写字母数字开头，
# 限长防止有人往表里灌任意字符串
_ID_PATTERN = r"^[a-z0-9][a-z0-9._-]{0,63}$"
EventId = Annotated[str, Path(pattern=_ID_PATTERN, description="客户端定义的事件标识")]
TipId = Annotated[str, Path(pattern=_ID_PATTERN, description="客户端定义的提示标识")]


class TipEventView(BaseModel):
    """一种行为事件的累计情况。"""

    event_id: str
    count: int
    first_at: datetime
    last_at: datetime


class TipRecordView(BaseModel):
    """一条提示的展示与作废情况；没出现在列表里的提示 = 从没展示过、仍有效。"""

    tip_id: str
    display_count: int
    first_displayed_at: datetime | None
    last_displayed_at: datetime | None
    invalidated_at: datetime | None
    #: action_performed（用过了）/ closed（用户关掉）/ 客户端自定义；服务端不校验取值
    invalidated_reason: str | None


class TipStateView(BaseModel):
    """一个人的全部提示状态，各端启动时拉一次。"""

    events: list[TipEventView]
    tips: list[TipRecordView]


class InvalidateTipRequest(BaseModel):
    # 不收紧成枚举：新端上报新原因时旧服务端照收不报 422
    reason: str = Field(default="action_performed", min_length=1, max_length=64)


def _event_view(row: TipEvent) -> TipEventView:
    return TipEventView(
        event_id=row.event_id, count=row.count, first_at=row.first_at, last_at=row.last_at
    )


def _record_view(row: TipRecord) -> TipRecordView:
    return TipRecordView(
        tip_id=row.tip_id,
        display_count=row.display_count,
        first_displayed_at=row.first_displayed_at,
        last_displayed_at=row.last_displayed_at,
        invalidated_at=row.invalidated_at,
        invalidated_reason=row.invalidated_reason,
    )


@router.get(
    "/state",
    response_model=ApiResponse[TipStateView],
    summary="我的提示状态（事件计数 + 各提示的展示/作废记录）",
    operation_id="tips.state.show",
    openapi_extra=_HIDDEN,
)
async def get_state(
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[TipStateView]:
    owner = principal.owner_id
    events = (
        (await session.execute(select(TipEvent).where(TipEvent.member_id == owner))).scalars().all()
    )
    records = (
        (await session.execute(select(TipRecord).where(TipRecord.member_id == owner)))
        .scalars()
        .all()
    )
    return ok(
        TipStateView(
            events=[_event_view(r) for r in events], tips=[_record_view(r) for r in records]
        )
    )


@router.post(
    "/events/{event_id}",
    response_model=ApiResponse[TipEventView],
    summary="记一次用户行为（计数 +1）",
    operation_id="tips.events.donate",
    openapi_extra=_HIDDEN,
)
async def donate_event(
    event_id: EventId,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[TipEventView]:
    return ok(_event_view(await tips.donate(session, principal.owner_id, event_id)))


@router.post(
    "/{tip_id}/displays",
    response_model=ApiResponse[TipRecordView],
    summary="记一次提示展示（展示次数 +1）",
    operation_id="tips.displays.record",
    openapi_extra=_HIDDEN,
)
async def record_display(
    tip_id: TipId,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[TipRecordView]:
    return ok(_record_view(await tips.record_display(session, principal.owner_id, tip_id)))


@router.post(
    "/{tip_id}/invalidate",
    response_model=ApiResponse[TipRecordView],
    summary="作废一条提示（以后不再出现；已作废的保留第一次的原因）",
    operation_id="tips.invalidate",
    openapi_extra=_HIDDEN,
)
async def invalidate_tip(
    tip_id: TipId,
    payload: InvalidateTipRequest | None = None,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[TipRecordView]:
    reason = (payload or InvalidateTipRequest()).reason
    return ok(_record_view(await tips.invalidate(session, principal.owner_id, tip_id, reason)))


@router.delete(
    "/state",
    response_model=ApiResponse[None],
    summary="重置我的提示状态（所有提示重新按条件出现）",
    operation_id="tips.state.reset",
    openapi_extra={**_HIDDEN, "x-cli-dangerous": "confirm"},
)
async def reset_state(
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[None]:
    owner = principal.owner_id
    await session.execute(delete(TipEvent).where(TipEvent.member_id == owner))
    await session.execute(delete(TipRecord).where(TipRecord.member_id == owner))
    await session.commit()
    return ok(None, message="使用提示已重置")
