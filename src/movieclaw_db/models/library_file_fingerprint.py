from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, Column, Index
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin, utcnow

#: 指纹从哪来：本地顺序读算的 / 网盘列表给的
FINGERPRINT_LOCAL = "local"
FINGERPRINT_CLOUD = "cloud"


class LibraryFileFingerprint(TimestampMixin, table=True):
    """库文件的内容指纹（docs/design/cloud-storage.md §3.4）。

    本地文件一次顺序读算齐（上传前）；用途：秒传、核验网盘副本、副本丢失时按指纹恢复。
    ``size_bytes`` 与 ``file_mtime_ns`` 记下算的时候文件的样子，文件变了指纹就作废。
    """

    __tablename__ = "library_file_fingerprint"
    __table_args__ = (Index("uq_library_file_fingerprint_file", "library_file_id", unique=True),)

    id: int | None = Field(default=None, primary_key=True)
    library_file_id: int = Field(description="库文件 id")
    size_bytes: int = Field(sa_column=Column(BigInteger, nullable=False), description="大小")
    file_mtime_ns: int | None = Field(
        default=None, sa_column=Column(BigInteger, nullable=True), description="算的时候的修改时间"
    )
    sha1: str = Field(description="全文 SHA1（大写十六进制）")
    md5: str | None = Field(default=None, description="全文 MD5（大写十六进制）")
    head_sha1: str | None = Field(default=None, description="前 128 KB 的 SHA1")
    source: str = Field(default=FINGERPRINT_LOCAL, description="local / cloud")
    computed_at: datetime = Field(default_factory=utcnow, description="计算时间")
