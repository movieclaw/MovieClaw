"""本地图片画质的磁盘估算（「设置 → 刮削与整理 → 本地图片画质」旁的「约 X GB」）。

画质档决定刮削下载到本地的图片多大（docs/design/image-sizing.md §8.1）。换档之前就该
知道代价：用媒体库里的图片张数，乘以各档位的单张均值，算出每一档大约占多少磁盘。

单张均值取自 2026-10-04 对 TMDB 的抽样（剧照 12 张，海报 / 背景 / 头像各 8 张，按原版
JPEG 字节计），只是量级参考——图片大小相差几十倍，估算不追求精确。
"""

from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import func
from sqlmodel import select

from movieclaw_api.services.scrape_config import (
    IMAGE_QUALITY_PRESETS,
    current_scrape_setting,
    effective_asset_sizes,
    effective_image_quality,
    effective_profile_size,
)

# 档位 → 单张平均字节数（KB 量级）。没抽样到的小档位按相邻档位折算，量级不影响结论
_KB = 1024
_AVERAGE_BYTES: dict[str, dict[str, int]] = {
    "poster": {
        "w92": 6 * _KB,
        "w154": 12 * _KB,
        "w185": 18 * _KB,
        "w342": 60 * _KB,
        "w500": 148 * _KB,
        "w780": 306 * _KB,
        "original": 759 * _KB,
    },
    "backdrop": {"w300": 25 * _KB, "w780": 120 * _KB, "w1280": 288 * _KB, "original": 1265 * _KB},
    "still": {"w92": 3 * _KB, "w185": 7 * _KB, "w300": 11 * _KB, "original": 188 * _KB},
    "profile": {"w45": 2 * _KB, "w185": 11 * _KB, "h632": 46 * _KB, "original": 273 * _KB},
}
# 片名 Logo 固定原图（透明底 PNG），各档一样
_LOGO_BYTES = 50 * _KB


@dataclass(frozen=True)
class ImageCounts:
    """媒体库里要落本地的图片张数（与刮削下载同一口径）。"""

    posters: int  # 条目海报 + 季海报（同一档位）
    backdrops: int
    logos: int
    stills: int  # 有文件的剧集的全部分集剧照
    people: int  # 演职员头像（按 TMDB 头像路径去重）


async def count_images(session) -> ImageCounts:  # noqa: ANN001
    from movieclaw_db.models import (
        LibraryFile,
        MediaEpisode,
        MediaItem,
        MediaItemPerson,
        MediaMetadata,
        MediaSeason,
        MediaSource,
        Person,
    )

    tmdb = MediaItem.source == MediaSource.TMDB

    async def scalar(statement) -> int:  # noqa: ANN001
        return int((await session.execute(statement)).scalar_one() or 0)

    item_posters = await scalar(
        select(func.count()).select_from(MediaItem).where(tmdb, MediaItem.poster_path.is_not(None))  # type: ignore[union-attr]
    )
    season_posters = await scalar(
        select(func.count())
        .select_from(MediaSeason)
        .join(MediaItem, MediaItem.id == MediaSeason.media_item_id)  # type: ignore[arg-type]
        .where(tmdb, MediaSeason.poster_path.is_not(None))  # type: ignore[union-attr]
    )
    backdrops = await scalar(
        select(func.count())
        .select_from(MediaItem)
        .where(tmdb, MediaItem.backdrop_path.is_not(None))  # type: ignore[union-attr]
    )
    logos = await scalar(
        select(func.count())
        .select_from(MediaItem)
        .where(tmdb, MediaItem.logo_path.is_not(None), MediaItem.logo_path != "")  # type: ignore[union-attr]
    )
    # 剧照只给有文件的条目下（media_scrape.download_item_assets 的 has_files）
    has_files = select(LibraryFile.media_item_id).where(LibraryFile.media_item_id.is_not(None))  # type: ignore[union-attr]
    stills = await scalar(
        select(func.count())
        .select_from(MediaEpisode)
        .where(
            MediaEpisode.still_path.is_not(None),  # type: ignore[union-attr]
            MediaEpisode.media_item_id.in_(has_files),  # type: ignore[attr-defined]
        )
    )
    paths: set[str] = set()
    for (cast,) in await session.execute(select(MediaMetadata.cast)):
        for actor in cast or []:
            if actor.get("profile_path"):
                paths.add(actor["profile_path"])
    for (profile,) in await session.execute(
        select(Person.profile_path)
        .join(MediaItemPerson, MediaItemPerson.person_id == Person.id)  # type: ignore[arg-type]
        .where(Person.profile_path.is_not(None))  # type: ignore[union-attr]
    ):
        paths.add(profile)
    return ImageCounts(
        posters=item_posters + season_posters,
        backdrops=backdrops,
        logos=logos,
        stills=stills,
        people=len(paths),
    )


def estimate_bytes(counts: ImageCounts, sizes: tuple[str, str, str, str]) -> int:
    """按 (海报, 背景, 剧照, 头像) 档位估算总字节数；没见过的档位按原图算（宁大勿小）。"""
    poster, backdrop, still, profile = sizes

    def avg(kind: str, size: str) -> int:
        table = _AVERAGE_BYTES[kind]
        return table.get(size, table["original"])

    return (
        counts.posters * avg("poster", poster)
        + counts.backdrops * avg("backdrop", backdrop)
        + counts.stills * avg("still", still)
        + counts.people * avg("profile", profile)
        + counts.logos * _LOGO_BYTES
    )


async def estimate_image_storage(session) -> dict[str, object]:  # noqa: ANN001
    """每个画质档的估算，加上当前生效档位（自定义也算得出来）的估算。"""
    counts = await count_images(session)
    setting = current_scrape_setting()
    current = (*effective_asset_sizes(setting), effective_profile_size(setting))
    return {
        "counts": counts.__dict__,
        "presets": {
            name: estimate_bytes(counts, sizes) for name, sizes in IMAGE_QUALITY_PRESETS.items()
        },
        "current_quality": effective_image_quality(setting),
        "current_bytes": estimate_bytes(counts, current),
    }
