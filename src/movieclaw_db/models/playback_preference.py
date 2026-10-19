"""播放器的个人偏好：每人一行，跟账号走（换台设备也一样）。

目前只有自动跳过（docs/design/skip-intro.md §5）：
- ``auto_skip`` 总开关，默认开：广告、预告直接跳；
- ``auto_skip_intro_item_ids`` 记着哪几部剧的片头要自动跳——用户在这部剧里手动点过一次
  「跳过片头」就记下，跳过后点了「撤回」或「不用」就删掉。没记的剧片头只给按钮。
"""

from __future__ import annotations

from sqlalchemy import JSON, Column, UniqueConstraint
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin
from movieclaw_db.models.member_scoped import MemberScopedMixin, register_member_scoped


@register_member_scoped
class PlaybackPreference(MemberScopedMixin, TimestampMixin, table=True):
    """一行 = 一个人的播放偏好（``member_id`` 0 = 超管哨兵）。"""

    __tablename__ = "playback_preference"
    __table_args__ = (UniqueConstraint("member_id", name="uq_playback_preference_member"),)

    id: int | None = Field(default=None, primary_key=True)
    auto_skip: bool = Field(default=True, description="自动跳过总开关；关了只给按钮")
    auto_skip_intro_item_ids: list | None = Field(
        default=None,
        sa_column=Column(JSON, nullable=True),
        description="片头自动跳的剧（媒体条目 id）；空 = 一部都没有",
    )
