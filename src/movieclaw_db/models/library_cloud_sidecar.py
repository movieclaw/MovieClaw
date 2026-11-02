from __future__ import annotations

from sqlalchemy import BigInteger, Column, ForeignKey, Index, Integer, Text
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin


class LibraryCloudSidecar(TimestampMixin, table=True):
    """传到网盘的旁车文件（海报、NFO、外挂字幕、分集剧照；docs/design/cloud-storage.md §5.5）。

    视频传上去以后，它所在目录里的旁车文件按库的「写入图片 / NFO」开关跟着传到网盘的同一目录。
    这里记下传上去的是本地哪个文件、当时的（大小, 修改时间）与网盘文件 id：本地文件变了就先删
    网盘上的旧文件再传新的（网盘遇到同名不同内容的文件会拒绝上传）。旁车文件不进 ``library_file``
    台账，只在这里记。
    """

    __tablename__ = "library_cloud_sidecar"
    __table_args__ = (
        Index("uq_library_cloud_sidecar_path", "folder_id", "local_path", unique=True),
    )

    id: int | None = Field(default=None, primary_key=True)
    folder_id: int = Field(
        sa_column=Column(
            Integer, ForeignKey("library_cloud_folder.id", ondelete="CASCADE"), nullable=False
        ),
        description="传到的网盘文件夹（library_cloud_folder）",
    )
    local_path: str = Field(sa_column=Column(Text, nullable=False), description="本地文件")
    remote_id: str = Field(description="网盘文件 id")
    size_bytes: int = Field(sa_column=Column(BigInteger, nullable=False), description="大小")
    file_mtime_ns: int = Field(
        sa_column=Column(BigInteger, nullable=False), description="传的时候本地的修改时间"
    )
    sha1: str = Field(description="全文 SHA1（大写十六进制）")
