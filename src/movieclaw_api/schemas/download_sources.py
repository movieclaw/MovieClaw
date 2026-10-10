"""媒体库文件的下载来源（docs/design/library-boundary.md §5）。"""

from __future__ import annotations

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel


class TorrentRelationView(BaseModel):
    """条目背后的一个下载器任务（docs/design/plugin-phase2a.md §5.3）。"""

    info_hash: str
    downloader_id: int | None = Field(description="承载它的下载器；下载器配置已删除时为空")
    downloader_name: str | None = None
    title: str | None = None
    source: str = Field(
        description="从哪里知道的：subscription（订阅投递）/ manual（手动下载）/ file（文件来源）"
    )
    site_id: str | None = None
    torrent_id: str | None = None
    owned_by_movieclaw: bool | None = Field(default=None, description="是否由 MovieClaw 投递")
    hit_and_run: bool | None = Field(default=None, description="投递时观测到的 H&R 状态")
    status: str | None = Field(default=None, description="订阅下载记录的状态")
    units: list[list[int]] = Field(default_factory=list, description="覆盖的季集 [[季, 集]]")
    file_ids: list[int] = Field(default_factory=list, description="库里记着来自这个种子的文件")
    other_file_ids: list[int] = Field(
        default_factory=list,
        description=(
            "同一个种子还供着的别的文件（其他条目 / 没识别的文件，跨库）；非空时删种会连带毁掉它们"
        ),
    )


class ItemRelationsView(BaseModel):
    """条目关联的订阅与下载器任务。"""

    media_item_id: int
    subscription_id: int | None = None
    subscription_status: str | None = None
    torrents: list[TorrentRelationView] = Field(default_factory=list)


class FileTorrentView(BaseModel):
    """一组媒体库文件背后的一个下载器任务（docs/design/library-boundary.md §5）。"""

    info_hash: str
    downloader_id: int | None = Field(description="承载它的下载器；下载器配置已删除时为空")
    downloader_name: str | None = None
    title: str | None = Field(default=None, description="种子标题（订阅投递的才知道）")
    source: str = Field(description="subscription（订阅投递）/ file（只有文件来源记录）")
    subscription_id: int | None = Field(default=None, description="投递它的订阅")
    owned_by_movieclaw: bool | None = Field(
        default=None, description="是否 MovieClaw 投递的；不是或不知道时删种前要格外小心"
    )
    hit_and_run: bool | None = Field(default=None, description="是否有 H&R 考核风险")
    file_ids: list[int] = Field(description="问到的文件里来自这个种子的")
    other_file_ids: list[int] = Field(
        description="同一个种子还供着的、还在媒体库里的别的文件；非空时删种会连带毁掉它们"
    )
