"""数据库行 → 事件载荷里的引用类型（``movieclaw_sdk.events``）。"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from movieclaw_sdk.events import FileRef, MediaRef, UnitRef


def media_ref(item: Any) -> MediaRef | None:
    if item is None or item.id is None:
        return None
    return MediaRef(
        id=item.id,
        kind=str(item.kind),
        title=item.title,
        original_title=item.original_title,
        year=item.year,
        tmdb_id=item.tmdb_id,
        imdb_id=item.imdb_id,
    )


def units(raw: Iterable[Any]) -> tuple[UnitRef, ...]:
    """(季, 集) 列表 → 单元；电影的内部单元 (0, 0) 与收藏哨兵（负数）不外泄。"""
    out: list[UnitRef] = []
    for unit in raw or ():
        try:
            season, episode = int(unit[0]), int(unit[1])
        except (TypeError, ValueError, IndexError):
            continue
        if (season, episode) == (0, 0) or season < 0 or episode < 0:
            continue
        ref = UnitRef(season=season, episode=episode)
        if ref not in out:
            out.append(ref)
    return tuple(out)


def unit(season: int, episode: int) -> UnitRef | None:
    found = units([(season, episode)])
    return found[0] if found else None


def file_ref(row: Any) -> FileRef:
    return FileRef(
        id=row.id,
        library_id=row.library_id,
        season=row.season_number,
        episode=row.episode_number,
        path=row.file_path,
        original_path=row.trash_original_path,
        size_bytes=row.size_bytes,
    )
