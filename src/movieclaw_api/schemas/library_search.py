"""电视优先的媒体库搜索契约：相关度结果、人物入口及稳定分页。"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

from movieclaw_api.schemas.library import LibraryItemView


class LibrarySearchMatch(BaseModel):
    """可解释的命中证据；原始名称保留，客户端无需知道拼音索引的实现。"""

    type: str
    source_field: str
    matched_name: str
    label: str
    person_id: int | None = None


class LibrarySearchHit(BaseModel):
    item: LibraryItemView
    library_ids: list[int]
    match: LibrarySearchMatch


class LibrarySearchPerson(BaseModel):
    id: int
    # 本服务端总会给出；声明可空是为了让新客户端连旧服务端（还没有这个字段）时整页照常解码
    tmdb_person_id: int | None = Field(
        default=None, description="TMDB 影人 ID：客户端据此打开库内影人页（与演职员入口同一页）"
    )
    name: str
    profile_path: str | None
    avatar_url: str | None = Field(
        default=None, description="头像地址：本地已下载给本地，否则给 TMDB 图床；没有照片为空"
    )
    item_count: int
    match: LibrarySearchMatch


class LibrarySearchSuggestion(BaseModel):
    type: Literal["title", "person"]
    text: str
    # 本服务端总会给出；声明可空是为了让新客户端连旧服务端（还没有这个字段）时整页照常解码
    label: str | None = Field(
        default=None, description="为什么联想到它，与结果卡片同一份命中原因（如「演员：李一桐」）"
    )
    media_item_id: int | None = None
    person_id: int | None = None


class LibrarySearchView(BaseModel):
    """索引更新不改变同一次浏览的候选顺序；库存和权限在每一页实时核验。"""

    query: str
    person_id: int | None = None
    items: list[LibrarySearchHit]
    people: list[LibrarySearchPerson]
    suggestions: list[LibrarySearchSuggestion]
    next_cursor: str | None = None
    index_pending: bool = Field(description="名称索引尚有待更新实体；查询已合并最新名称")
