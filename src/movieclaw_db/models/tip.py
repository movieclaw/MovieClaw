"""使用提示（对标 Apple TipKit）的个人状态：事件计数 + 每条提示的展示/作废记录。

设计见 docs/design/tips.md。提示的文案与出现条件写在各端代码里，服务端只记「这个人
做过什么、看过哪条、哪条不用再出现」，好让换设备、换端时不重复提示。

两张表都按 ``(member_id, 标识)`` 唯一、一行一个标识，写入走原子 upsert：同一个人
多台设备同时上报时计数不丢。标识由客户端定义（如 ``player.opened``），服务端不认识
具体含义，新提示上线不用改服务端。
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import UniqueConstraint
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin, utcnow
from movieclaw_db.models.member_scoped import MemberScopedMixin, register_member_scoped


@register_member_scoped
class TipEvent(MemberScopedMixin, TimestampMixin, table=True):
    """一行 = 一个人的一种行为事件（对应 TipKit 的 ``Event.donate()``）。"""

    __tablename__ = "tip_event"
    __table_args__ = (UniqueConstraint("member_id", "event_id", name="uq_tip_event_member_event"),)

    id: int | None = Field(default=None, primary_key=True)
    event_id: str = Field(description="客户端定义的事件标识")
    count: int = Field(default=0, description="累计发生次数")
    first_at: datetime = Field(default_factory=utcnow, description="第一次发生（naive UTC）")
    last_at: datetime = Field(default_factory=utcnow, description="最近一次发生（naive UTC）")


@register_member_scoped
class TipRecord(MemberScopedMixin, TimestampMixin, table=True):
    """一行 = 一个人的一条提示：展示过几次、是否已作废。"""

    __tablename__ = "tip_record"
    __table_args__ = (UniqueConstraint("member_id", "tip_id", name="uq_tip_record_member_tip"),)

    id: int | None = Field(default=None, primary_key=True)
    tip_id: str = Field(description="客户端定义的提示标识")
    display_count: int = Field(default=0, description="展示次数（每出现一次 +1）")
    first_displayed_at: datetime | None = Field(default=None, description="第一次展示")
    last_displayed_at: datetime | None = Field(default=None, description="最近一次展示")
    invalidated_at: datetime | None = Field(default=None, description="作废时间；None=仍有效")
    invalidated_reason: str | None = Field(
        default=None, description="作废原因：action_performed / closed / 客户端自定义"
    )
