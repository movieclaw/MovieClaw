from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, Column, Index, Text
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin

#: 副本来源（docs/design/cloud-storage.md §3.5）
REPLICA_ORIGIN_UPLOADED = "uploaded"
REPLICA_ORIGIN_IMPORTED = "imported"

#: 副本状态。存值本身（普通字符串列，不用 StrEnum：SQLModel 的枚举列存成员名）
REPLICA_UPLOADING = "uploading"
REPLICA_VERIFIED = "verified"
REPLICA_LOST = "lost"
REPLICA_DELETING = "deleting"
#: 上传没成（原因在 ``error``）；过一段时间整理任务会再试
REPLICA_FAILED = "failed"


class LibraryFileReplica(TimestampMixin, table=True):
    """库文件在网盘上的副本（docs/design/cloud-storage.md §3.5）。

    一切网盘操作只认 ``remote_id``（网盘文件 id），``remote_path`` 只用于展示。一期每个文件
    最多一个副本（唯一约束），表结构不限制以后多副本。

    不设到 ``library_file`` 的级联外键：删台账行之前必须先处理副本（删云端或明确放弃），
    否则云端文件就成了孤儿（cloud-storage.md §10）。但副本记录随台账行一起删（迁移里的
    触发器 ``library_file_drop_replica``，级联删的行也算）：``library_file.id`` 会被
    SQLite 复用，留下的记录会挂到不相干的新文件上（#909）。
    """

    __tablename__ = "library_file_replica"
    __table_args__ = (
        Index("uq_library_file_replica_file", "library_file_id", unique=True),
        Index("ix_library_file_replica_account_remote", "account_id", "remote_id"),
    )

    id: int | None = Field(default=None, primary_key=True)
    library_file_id: int = Field(description="库文件 id")
    account_id: int = Field(description="网盘账号 id（drive_account）")
    remote_id: str = Field(description="网盘文件 id")
    remote_path: str | None = Field(
        default=None, sa_column=Column(Text, nullable=True), description="网盘上的路径（展示）"
    )
    origin: str = Field(description="uploaded（我们传的）/ imported（纳管来的）")
    # 纳管来的副本属于哪个库文件夹（library_cloud_folder）：复查时按它圈出「该在这个文件夹里」的行
    folder_id: int | None = Field(default=None, index=True, description="纳管来源文件夹")
    state: str = Field(description="uploading / verified / lost / deleting")
    size_bytes: int | None = Field(
        default=None, sa_column=Column(BigInteger, nullable=True), description="网盘报的大小"
    )
    sha1: str | None = Field(default=None, description="网盘报的 SHA1（大写十六进制）")
    verified_at: datetime | None = Field(default=None, description="核验时间")
    # 上传没成的原因（给用户看）；为空表示没出过错。出错的过一段时间再试
    error: str | None = Field(
        default=None, sa_column=Column(Text, nullable=True), description="上次上传失败的原因"
    )
    checked_at: datetime | None = Field(default=None, description="最近一次对账时间")
