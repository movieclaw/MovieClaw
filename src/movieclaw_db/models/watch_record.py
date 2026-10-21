"""外部历史导入的观看事实；与实际播放会话及其观看时长分开。"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import UniqueConstraint
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin
from movieclaw_db.models.member_scoped import MemberScopedMixin, register_member_scoped


@register_member_scoped
class WatchRecord(MemberScopedMixin, TimestampMixin, table=True):
    __tablename__ = "watch_record"
    __table_args__ = (
        UniqueConstraint("member_id", "source", "source_id", name="uq_watch_record_source"),
    )

    id: int | None = Field(default=None, primary_key=True)
    media_item_id: int = Field(foreign_key="media_item.id", ondelete="CASCADE", index=True)
    season_number: int = 0
    episode_number: int = 0
    watched_at: datetime = Field(index=True)
    state_version: datetime
    source: str = Field(max_length=100)
    source_id: str = Field(max_length=128)
