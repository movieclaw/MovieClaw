"""第三方观看历史交换；只交换电影 / 单集事实，不模拟播放过程。"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Literal

from pydantic import ConfigDict, Field, field_validator, model_validator

from movieclaw_api.schemas.base import BaseModel
from movieclaw_db.models.base import utcnow


class SyncFavorite(BaseModel):
    """整剧 / 整季收藏所在的哨兵状态行；updated_at 供写回时做 compare-and-set。"""

    is_favorite: bool
    updated_at: datetime


class SyncSeasonFavorite(SyncFavorite):
    season: int


class SyncMedia(BaseModel):
    id: int
    kind: Literal["movie", "tv"]
    title: str
    tmdb_id: int | None
    imdb_id: str | None
    # 只有剧集有；null 表示整剧没有状态行（写回时 expected_updated_at 传 null）。
    favorite: SyncFavorite | None = None
    season_favorites: list[SyncSeasonFavorite] = []


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
    is_favorite: bool
    updated_at: datetime | None
    last_played_at: datetime | None
    watches: list[SyncWatch]


class SyncCatalog(BaseModel):
    items: list[SyncUnit]
    next_cursor: str | None


def _aware_past(value: datetime | None) -> datetime | None:
    if value is not None and (value.tzinfo is None or value.utcoffset() is None):
        raise ValueError("时间必须包含时区")
    if value is not None and value.timestamp() > utcnow().replace(tzinfo=UTC).timestamp() + 5:
        raise ValueError("不能使用未来时间")
    return value


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
        return _aware_past(value)


class SyncImportIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    member_id: int = Field(default=0, ge=0)
    records: list[SyncRecordIn] = Field(min_length=1, max_length=100)


class SyncOutcome(BaseModel):
    status: Literal["applied", "already", "conflict", "not_found", "mismatch"]
    state_version: datetime | None = None


class SyncImportResult(BaseModel):
    outcomes: list[SyncOutcome]


class SyncChangeIn(BaseModel):
    """一个单元的状态写回；played / position_ms / is_favorite 省略即不改。

    单集 / 电影可写全部字段；剧集省略集号（整季）或季集都省略（整剧）时只能写收藏。
    """

    model_config = ConfigDict(extra="forbid")
    media_item_id: int = Field(ge=1)
    kind: Literal["movie", "tv"]
    tmdb_id: int | None = Field(default=None, ge=1)
    imdb_id: str | None = None
    season: int | None = Field(default=None, ge=0)
    episode: int | None = Field(default=None, ge=0)
    expected_updated_at: datetime | None  # 必填；null 表示预览时没有该状态行。
    played: bool | None = None
    position_ms: int | None = Field(default=None, ge=0)
    is_favorite: bool | None = None
    last_played_at: datetime | None = None

    @field_validator("expected_updated_at", "last_played_at")
    @classmethod
    def aware(cls, value):
        return _aware_past(value)

    @model_validator(mode="after")
    def shape(self):
        if self.played is None and self.position_ms is None and self.is_favorite is None:
            raise ValueError("played、position_ms、is_favorite 至少要给一个")
        if self.season is None and self.episode is not None:
            raise ValueError("给了集号就必须同时给季号")
        if self.kind == "movie" and (self.season or self.episode):
            raise ValueError("电影的季集只能为 0 或省略")
        if self.kind == "tv" and self.episode == 0:
            raise ValueError("集号从 1 开始")
        folder = self.kind == "tv" and self.episode is None
        if folder and (
            self.played is not None or self.position_ms is not None or self.last_played_at
        ):
            raise ValueError("整剧 / 整季只能写收藏；已看与续播请逐集写")
        if self.played and self.position_ms:
            raise ValueError("已看的单元不能带续播位置")
        return self


class SyncStateIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    member_id: int = Field(default=0, ge=0)
    changes: list[SyncChangeIn] = Field(min_length=1, max_length=100)


class SyncStateOutcome(BaseModel):
    status: Literal["applied", "unchanged", "conflict", "not_found", "mismatch"]
    state_version: datetime | None = None


class SyncStateResult(BaseModel):
    outcomes: list[SyncStateOutcome]
