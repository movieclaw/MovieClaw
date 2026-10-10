"""媒体库文件来自哪个下载任务（docs/design/library-boundary.md §5）。

种子关联属于下载领域：媒体库只管文件、条目、库、回收站，不认识种子。入库与扫描（入库桥）写完台账后，
把「这个文件来自哪个种子、哪个下载器、哪个站点种子」记在这里。

**不设到 ``library_file`` 的级联外键**：媒体库删文件不动别人的记录（谁的数据谁清理）。
文件行没了以后，这里的记录还在，下载模块处理删除（删种、清理）时据此找到种子；处理不到的由每日清扫收尾：
第一次发现文件行已不在时记下 ``orphaned_at``，满 7 天删除。
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Column, ForeignKey, Integer
from sqlmodel import Field, SQLModel

from movieclaw_db.models.base import utcnow


class DownloadFileSource(SQLModel, table=True):
    __tablename__ = "download_file_source"

    id: int | None = Field(default=None, primary_key=True)
    library_file_id: int = Field(
        unique=True, index=True, description="媒体库文件行 id（不设外键：文件删了记录还在）"
    )
    info_hash: str | None = Field(default=None, index=True, description="来源种子 infohash（小写）")
    downloader_id: int | None = Field(
        default=None,
        sa_column=Column(
            Integer, ForeignKey("downloader_client.id", ondelete="SET NULL"), nullable=True
        ),
        description="承载它的下载器；下载器配置删了为空",
    )
    site_id: str | None = Field(default=None, description="来源站点")
    torrent_id: str | None = Field(default=None, description="站点上的种子编号")
    orphaned_at: datetime | None = Field(
        default=None, description="清扫时发现文件行已不在的时间；满 7 天删除"
    )
    created_at: datetime = Field(default_factory=utcnow)
    updated_at: datetime = Field(default_factory=utcnow)
