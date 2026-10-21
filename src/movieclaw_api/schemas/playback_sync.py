"""第三方观看历史交换；只交换电影 / 单集事实，不模拟播放过程。"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Literal

from pydantic import ConfigDict, Field, field_validator

from movieclaw_api.schemas.base import BaseModel
from movieclaw_db.models.base import utcnow


class SyncMedia(BaseModel):
    id: int
    kind: Literal["movie", "tv"]
    title: str
    tmdb_id: int | None
    imdb_id: str | None


class SyncWatch(BaseModel):
    id: str
    watched_at: datetime
    basis: Literal["playback", "import", "state"]


class SyncUnit(BaseModel):
    media: SyncMedia
    season: int
    episode: int
    played: bool
    position_ms: int
    updated_at: datetime | None
    last_played_at: datetime | None
    watches: list[SyncWatch]


class SyncCatalog(BaseModel):
    items: list[SyncUnit]
    next_cursor: str | None


class SyncRecordIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    media_item_id: int = Field(ge=1)
    kind: Literal["movie", "tv"]
    tmdb_id: int | None = Field(default=None, ge=1)
    imdb_id: str | None = None
    season: int = Field(default=0, ge=0)
    episode: int = Field(default=0, ge=0)
    source_id: str = Field(min_length=1, max_length=128)
    watched_at: datetime
    expected_updated_at: datetime | None  # 必填；null 表示预览时没有该状态行。

    @field_validator("watched_at", "expected_updated_at")
    @classmethod
    def aware(cls, value):
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("时间必须包含时区")
        if value is not None and value.timestamp() > utcnow().replace(tzinfo=UTC).timestamp() + 5:
            raise ValueError("不能使用未来时间")
        return value


class SyncImportIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    member_id: int = Field(default=0, ge=0)
    records: list[SyncRecordIn] = Field(min_length=1, max_length=100)


class SyncOutcome(BaseModel):
    status: Literal["applied", "already", "conflict", "not_found", "mismatch"]
    state_version: datetime | None = None


class SyncImportResult(BaseModel):
    outcomes: list[SyncOutcome]
