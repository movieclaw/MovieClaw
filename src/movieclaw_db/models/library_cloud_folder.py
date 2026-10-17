from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, Column, ForeignKey, Index, Integer, Text
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin


class LibraryCloudFolder(TimestampMixin, table=True):
    """挂在媒体库上的网盘文件夹（docs/design/cloud-storage.md §3.2、§4）。

    挂上即纳管：文件夹里已有的视频按文件名识别入账（台账行 ``local_bytes`` 为假 + 副本），
    之后靠操作动态与每周复查跟上变化。一个库可以挂多个文件夹，同一个文件夹只能挂在一个库上。

    纳管进来的文件没有本地位置，台账 ``file_path`` 是一个虚拟位置：
    ``local_dir``（库主根下的隐藏目录）+ 文件在网盘文件夹里的相对路径。扫描不进隐藏目录，
    海报、外挂字幕之类的旁车文件可以放在这里。

    ``is_primary``：新内容落在这个文件夹（主根在网盘）。此时库的 ``root_paths[0]`` 是本地暂存
    目录，新片入库后先在那里，上传核验完再腾空。
    """

    __tablename__ = "library_cloud_folder"
    __table_args__ = (
        Index("uq_library_cloud_folder_remote", "account_id", "remote_dir_id", unique=True),
    )

    id: int | None = Field(default=None, primary_key=True)
    library_id: int = Field(
        sa_column=Column(
            Integer, ForeignKey("library.id", ondelete="CASCADE"), nullable=False, index=True
        ),
        description="归属库",
    )
    # 账号在被库用着时不能删（删账号的接口先拦），这里不级联
    account_id: int = Field(
        sa_column=Column(Integer, ForeignKey("drive_account.id"), nullable=False),
        description="网盘账号",
    )
    remote_dir_id: str = Field(description="网盘目录 id（一切操作只认它）")
    display_path: str = Field(
        sa_column=Column(Text, nullable=False), description="挂上时的网盘路径（展示用）"
    )
    local_dir: str = Field(
        sa_column=Column(Text, nullable=False), description="纳管文件的虚拟位置前缀"
    )
    is_primary: bool = Field(default=False, description="新内容落在这里（主根在网盘）")
    sort_order: int = Field(default=0, description="在库的根目录里的展示顺序")
    listed_at: datetime | None = Field(default=None, description="上次整树列举的时间")
    # 整树列举时记下的全部子目录 id：操作动态里的变化落没落在这个文件夹里，靠它判断
    dir_ids: list = Field(
        default_factory=list, sa_column=Column(JSON, nullable=False), description="子目录 id"
    )
    # 上次纳管 / 复查的报告（视频总数、已识别、待认领、跳过分类、调用次数、用时）
    report: dict | None = Field(
        default=None, sa_column=Column(JSON, nullable=True), description="纳管报告"
    )
