"""手动下载的「入库完成」要推给谁（docs/design/cloud-push.md §5）。

每次手动提交下载（网页、App、命令行；家庭成员选库下载也算）都记一行：谁点的、哪个
种子、下到了哪。入库时对上就把「入库完成」推给他，然后删掉这一行：

- 经监听导入入库的：入库那一刻按种子的 infohash 对上；边下边入库的分几批，每批记下
  批次号，整个种子入库完才推，推的是这次下载的全部季集；
- 直接下进库目录、靠扫描入账的：按「保存目录 / 任务名」这个路径对上（后台每两分钟一轮）。

没对上的（任务被删、下到了不进媒体库的目录）30 天后清理。

单独一张表、不挂在手动下载锚（``manual_download_intent``）上：锚是「智能入库确认过的
身份」，只有管理员的智能入库才有；推送要覆盖每一次手动下载。
"""

from __future__ import annotations

from sqlalchemy import JSON, Column, Text, UniqueConstraint
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin
from movieclaw_db.models.member_scoped import MemberScopedMixin, register_member_scoped


@register_member_scoped
class PushDownloadWatch(MemberScopedMixin, TimestampMixin, table=True):
    """一行 = 一个人点的一次手动下载（``member_id`` 0 = 超管哨兵）。"""

    __tablename__ = "push_download_watch"
    __table_args__ = (
        UniqueConstraint("member_id", "info_hash", name="uq_push_download_watch_member_hash"),
    )

    id: int | None = Field(default=None, primary_key=True)
    info_hash: str = Field(
        sa_column=Column(Text, nullable=False, index=True),
        description="下载器任务的 infohash（小写十六进制）",
    )
    save_path: str | None = Field(
        default=None,
        sa_column=Column(Text, nullable=True),
        description="保存目录（movieclaw 视角）；用下载器默认目录时为空",
    )
    download_name: str | None = Field(
        default=None,
        sa_column=Column(Text, nullable=True),
        description="下载器返回的任务名（种子里顶层的文件或目录名）",
    )
    batch_ids: list = Field(
        default_factory=list,
        sa_column=Column(JSON, nullable=False),
        description="已经入库的批次号（台账的 added_batch_id）；边下边入库时一次下载分几批",
    )
