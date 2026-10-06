"""App 推送的个人偏好：每人一行，记自己想收哪些通知（docs/design/cloud-push.md §5）。

只存「改过的」开关：``events`` 是 ``{事件键: 开/关}``，没出现的事件用代码里的默认值。
这样以后加新事件不用回填存量行，回退到旧版本时旧代码也只是不认识新键。
"""

from __future__ import annotations

from sqlalchemy import JSON, Column, UniqueConstraint
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin
from movieclaw_db.models.member_scoped import MemberScopedMixin, register_member_scoped


@register_member_scoped
class PushPreference(MemberScopedMixin, TimestampMixin, table=True):
    """一行 = 一个人的推送开关（``member_id`` 0 = 超管哨兵）。"""

    __tablename__ = "push_preference"
    __table_args__ = (UniqueConstraint("member_id", name="uq_push_preference_member"),)

    id: int | None = Field(default=None, primary_key=True)
    events: dict = Field(
        default_factory=dict,
        sa_column=Column(JSON, nullable=False),
        description="改过的事件开关 {事件键: bool}；没出现的事件用默认值",
    )
    library_ids: list | None = Field(
        default=None,
        sa_column=Column(JSON, nullable=True),
        description="「媒体库有新片」关心哪些库；空 = 我能看到的全部（含以后新建的）",
    )
    muted_item_ids: list | None = Field(
        default=None,
        sa_column=Column(JSON, nullable=True),
        description="「这部剧不再提醒」静音的条目 id；空 = 没静音过",
    )
