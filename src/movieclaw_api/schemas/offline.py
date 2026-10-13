"""离线下载的接口模型（docs/design/offline-download.md）。"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.library import LibraryItemDetailView, LibraryView, SeasonEpisodesView
from movieclaw_api.schemas.playback import (
    AudioTrackView,
    PlaybackChapterMarkView,
    PlaybackSegmentView,
)


class OfflineProfileView(BaseModel):
    """这个文件可选的一档下载画质。"""

    profile: str = Field(description="original / 1080p / 720p / 480p")
    label: str = Field(description="给人看的档名（「原画 · 4K HEVC」「720p」）")
    height: int | None = Field(default=None, description="目标高度；原画为源高度")
    expected_bytes: int = Field(description="预计大小（原画即原文件大小）")


class OfflineSubtitleView(BaseModel):
    """要随视频一起下载的一条文本字幕（地址带签名，打包时当场取）。"""

    track_ref: str
    format: str = Field(description="存盘格式：srt / ass / ssa / vtt")
    language: str | None = None
    title: str | None = None
    is_default: bool = False
    is_forced: bool = False
    is_ai: bool = False
    embedded: bool = Field(description="内封轨抽出来的（原画档不用下，引擎直接读文件里的）")
    url: str


class OfflineManifestView(BaseModel):
    """一个播放单元打包所需的一切：展示数据、播放数据、要下载的文件与可选档位。"""

    file_id: int
    media_item_id: int
    library_id: int
    season_number: int = 0
    episode_number: int = 0
    container: str | None = Field(default=None, description="原文件容器（原画档存盘扩展名）")
    size_bytes: int = 0
    duration_ms: int | None = None
    item: LibraryItemDetailView
    library: LibraryView
    season: SeasonEpisodesView | None = Field(default=None, description="剧集：这一集所在季的分集清单")
    chapters: list[PlaybackChapterMarkView] = []
    segments: list[PlaybackSegmentView] = []
    audio_tracks: list[AudioTrackView] = []
    default_audio: str | None = Field(default=None, description="按偏好与轨道记忆选中的音轨")
    default_subtitle: str | None = Field(default=None, description="默认字幕轨；None=不开字幕")
    subtitles: list[OfflineSubtitleView] = []
    fonts_url: str | None = Field(
        default=None, description="ASS 字幕要的内嵌字体清单地址（带签名）；没有 ASS 轨为空"
    )
    profiles: list[OfflineProfileView] = Field(
        default=[], description="这个文件能选的档位；空 = 不能下载，原因见 unavailable_reason"
    )
    unavailable_reason: str | None = None
    resume_position_ms: int | None = Field(default=None, description="打包时服务器上的续播点")


class OfflineExportRequest(BaseModel):
    file_id: int
    profile: Literal["1080p", "720p", "480p"]
    audio_track: str | None = Field(default=None, description="转码档只带这一条音轨；空=默认轨")


class OfflineExportView(BaseModel):
    export_id: str
    status: str = Field(description="queued / running / done / failed")
    etag: str
    expected_bytes: int
    final_bytes: int | None = None
    error: str | None = None
    queue_position: int | None = Field(default=None, description="排队中的位置（0=下一个）")
    content_url: str = Field(description="下载地址（Bearer 设备令牌鉴权）")


class PlaybackViewingRecordIn(BaseModel):
    """一次本机播放（docs/design/offline-download.md §7），时间都是手机时钟。"""

    viewing_id: str = Field(min_length=8, max_length=64, description="客户端生成的 UUID")
    media_item_id: int
    season_number: int = 0
    episode_number: int = 0
    file_id: int | None = None
    started_at: datetime
    updated_at: datetime
    start_position_ms: int = Field(default=0, ge=0)
    position_ms: int = Field(ge=0)
    watched_ms: int = Field(default=0, ge=0, description="实际在播的墙钟时长")
    completed: bool = Field(default=False, description="播到了片尾")
    ended: bool = Field(default=False, description="这次播放已结束（之后不会再更新）")
    duration_ms: int | None = Field(default=None, ge=0)


class PlaybackViewingsRequest(BaseModel):
    sent_at: datetime = Field(description="发送时的手机时间，服务端据此校正时钟偏差")
    records: list[PlaybackViewingRecordIn] = Field(max_length=100)


class PlaybackViewingResultView(BaseModel):
    viewing_id: str
    status: Literal["applied", "stale", "rejected"] = Field(
        description="applied=已写入；stale=续播点比服务器旧没改（观看日志照记）；rejected=对不上条目"
    )


class PlaybackViewingsView(BaseModel):
    results: list[PlaybackViewingResultView] = []
