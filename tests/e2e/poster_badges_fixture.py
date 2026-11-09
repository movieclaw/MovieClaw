"""海报角标的合成媒体库：浏览器端到端用例与本地截图共用。

全部是虚构片名与程序生成的海报（渐变底 + 片名），不碰任何真实片库。覆盖角标的每一种
取值：电影 / 剧集，高分 / 低分 / 无评分，4K / 1080p / 720p，杜比视界 / HDR10(+) / SDR，
Atmos，有无中文字幕（内封语言码 / 内封标题 / 外挂文件），完结 / 在播，在看 / 看完 /
没看，以及剧集的未看集数。

用法：库由调用方经真实接口建好（扫描空目录），再调 ``seed`` 往台账里写条目。
"""

from __future__ import annotations

import colorsys
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path

#: 内封中文轨 / 英文轨 / 带「简体中文」标题但语言码未知的轨
ZH = [{"codec": "subrip", "language": "chi", "title": None}]
EN = [{"codec": "subrip", "language": "eng", "title": "English"}]
ZH_TITLE = [
    {"codec": "ass", "language": "und", "title": "简体中文"}
]  # i18n-ignore: fixture track title
ATMOS = [{"codec": "truehd", "profile": "Dolby TrueHD + Dolby Atmos", "channels": 8}]
DDP = [{"codec": "eac3", "profile": None, "channels": 6}]
#: 外挂字幕台账（扫描时文件名 token 归一出 chi）
EXT_ZH = [{"filename": "x.chs.srt", "format": "srt", "language": "chi", "title": None}]


@dataclass
class Title:
    key: str
    title: str
    kind: str  # movie / tv
    year: int
    rating: float | None
    resolution: str
    hdr: str | None = None
    audio: list = field(default_factory=lambda: DDP)
    subtitles: list = field(default_factory=lambda: EN)
    external: list = field(default_factory=list)
    status: str | None = None  # TMDB status（剧集）
    episodes: int = 0
    #: 电影：看到的百分比（None=没看，100=看完）；剧集：看完的集数
    watched: int | None = None
    #: 剧集：正在看的那一集看到的百分比
    episode_progress: int | None = None
    favorite: bool = False


MOVIES = [
    Title(
        "aurora", "Aurora Line", "movie", 2023, 8.4, "2160p", "Dolby Vision", ATMOS, ZH, watched=35
    ),
    Title("paper", "Paper Harbor", "movie", 2019, 6.1, "1080p", "HDR10"),
    Title("orbit", "Quiet Orbit", "movie", 2021, None, "720p", None, external=EXT_ZH, watched=100),
    Title("tide", "Low Tide", "movie", 2016, 4.2, "1080p", None, subtitles=ZH_TITLE),
    Title(
        "garden", "Glass Garden", "movie", 2024, 7.6, "2160p", "HDR10+", watched=80, favorite=True
    ),
]
SHOWS = [
    Title(
        "signal",
        "Northern Signal",
        "tv",
        2020,
        8.9,
        "2160p",
        "Dolby Vision",
        ATMOS,
        ZH,
        status="Ended",
        episodes=10,
        watched=4,
        episode_progress=40,
    ),
    Title(
        "copper",
        "Copper Coast",
        "tv",
        2025,
        7.2,
        "1080p",
        status="Returning Series",
        episodes=8,
        watched=0,
    ),
    Title(
        "lantern",
        "Lantern Street",
        "tv",
        2018,
        5.8,
        "720p",
        external=EXT_ZH,
        status="Ended",
        episodes=6,
        watched=6,
    ),
    Title(
        "relay",
        "Midnight Relay",
        "tv",
        2026,
        None,
        "2160p",
        "HDR10",
        ATMOS,
        status="Returning Series",
        episodes=12,
        watched=2,
        favorite=True,
    ),
]


def poster(path: Path, title: str, index: int) -> tuple[int, int]:
    """程序生成的 2:3 海报：一张斜向渐变 + 几何块 + 片名（不是任何真实作品的海报）。"""
    from PIL import Image, ImageDraw, ImageFont

    width, height = 600, 900
    hue = (index * 0.137) % 1.0
    top = tuple(int(c * 255) for c in colorsys.hsv_to_rgb(hue, 0.55, 0.55))
    bottom = tuple(int(c * 255) for c in colorsys.hsv_to_rgb((hue + 0.08) % 1, 0.75, 0.16))
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        t = y / height
        draw.line(
            [(0, y), (width, y)],
            fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom, strict=True)),
        )
    accent = tuple(int(c * 255) for c in colorsys.hsv_to_rgb((hue + 0.5) % 1, 0.45, 0.9))
    draw.ellipse(
        [width * 0.18, height * 0.2, width * 0.82, height * 0.2 + width * 0.64],
        outline=accent,
        width=10,
    )
    draw.rectangle([0, height * 0.72, width, height * 0.725], fill=accent)
    try:
        font = ImageFont.truetype("DejaVuSans-Bold.ttf", 54)
    except OSError:
        font = ImageFont.load_default()
    words = title.upper().split()
    for row, word in enumerate(words):
        box = draw.textbbox((0, 0), word, font=font)
        draw.text(
            ((width - (box[2] - box[0])) / 2, height * 0.76 + row * 64),
            word,
            font=font,
            fill=(245, 245, 245),
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "JPEG", quality=88)
    return width, height


async def seed(
    database_url: str,
    movie_library: tuple[int, Path],
    tv_library: tuple[int, Path],
    metadata_dir: Path,
    *,
    member_id: int = 0,
) -> dict[str, int]:
    """把上面的片单写进台账（条目 + 档案 + 海报 + 文件 + 观看状态），返回 {key: 条目 id}。"""
    from movieclaw_db.engine import Database
    from movieclaw_db.models import (
        FileSource,
        LibraryFile,
        MediaItem,
        MediaMetadata,
        MediaSeason,
        PlaybackState,
        utcnow,
    )
    from movieclaw_db.repositories.library_repo import LibraryRepository

    database = Database(database_url)
    ids: dict[str, int] = {}
    now = utcnow()
    try:
        async with database.session() as session:
            for index, entry in enumerate(MOVIES + SHOWS):
                library_id, root = movie_library if entry.kind == "movie" else tv_library
                item = MediaItem(
                    kind=entry.kind,
                    tmdb_id=880000 + index,
                    title=entry.title,
                    original_title=entry.title,
                    year=entry.year,
                    status=entry.status,
                )
                session.add(item)
                await session.flush()
                assert item.id is not None
                ids[entry.key] = item.id
                width, height = poster(
                    metadata_dir / "images" / str(item.id) / "poster.jpg", entry.title, index
                )
                session.add(
                    MediaMetadata(
                        media_item_id=item.id,
                        vote_average=entry.rating,
                        release_date=date(entry.year, 3, 1),
                        poster_file=f"{item.id}/poster.jpg",
                        poster_width=width,
                        poster_height=height,
                    )
                )
                units = (
                    [(0, 0)]
                    if entry.kind == "movie"
                    else [(1, e) for e in range(1, entry.episodes + 1)]
                )
                if entry.kind == "tv":
                    session.add(
                        MediaSeason(
                            media_item_id=item.id, season_number=1, episode_count=entry.episodes
                        )
                    )
                folder = root / entry.title
                folder.mkdir(parents=True, exist_ok=True)
                for season, episode in units:
                    path = folder / (
                        f"{entry.title} S{season:02d}E{episode:02d}.mkv"
                        if season
                        else f"{entry.title}.mkv"
                    )
                    path.write_bytes(b"synthetic fixture")
                    session.add(
                        LibraryFile(
                            library_id=library_id,
                            media_item_id=item.id,
                            season_number=season,
                            episode_number=episode,
                            file_path=str(path),
                            size_bytes=path.stat().st_size,
                            source=FileSource.SCANNED,
                            container="mkv",
                            resolution=entry.resolution,
                            hdr=entry.hdr,
                            video_codec="hevc",
                            duration_seconds=7200 if entry.kind == "movie" else 2400,
                            audio_streams=entry.audio,
                            subtitle_streams=entry.subtitles,
                            external_subtitles=entry.external,
                        )
                    )
                # 观看状态
                if entry.kind == "movie" and entry.watched is not None:
                    session.add(
                        PlaybackState(
                            member_id=member_id,
                            media_item_id=item.id,
                            played=entry.watched >= 100,
                            position_ms=0
                            if entry.watched >= 100
                            else int(7200_000 * entry.watched / 100),
                            last_played_at=now - timedelta(hours=index),
                        )
                    )
                if entry.kind == "tv":
                    for episode in range(1, (entry.watched or 0) + 1):
                        session.add(
                            PlaybackState(
                                member_id=member_id,
                                media_item_id=item.id,
                                season_number=1,
                                episode_number=episode,
                                played=True,
                                last_played_at=now - timedelta(days=2, hours=episode),
                            )
                        )
                    if entry.episode_progress and (entry.watched or 0) < entry.episodes:
                        session.add(
                            PlaybackState(
                                member_id=member_id,
                                media_item_id=item.id,
                                season_number=1,
                                episode_number=(entry.watched or 0) + 1,
                                position_ms=int(2400_000 * entry.episode_progress / 100),
                                last_played_at=now - timedelta(minutes=index),
                            )
                        )
                if entry.favorite:
                    sentinel = (-1, -1) if entry.kind == "tv" else (0, 0)
                    existing = None
                    if sentinel == (0, 0):
                        # 电影的收藏与播放同一单元：在已有那行上打心
                        for obj in session.new:
                            if isinstance(obj, PlaybackState) and obj.media_item_id == item.id:
                                existing = obj
                    if existing is not None:
                        existing.is_favorite = True
                    else:
                        session.add(
                            PlaybackState(
                                member_id=member_id,
                                media_item_id=item.id,
                                season_number=sentinel[0],
                                episode_number=sentinel[1],
                                is_favorite=True,
                            )
                        )
            await session.commit()
            await LibraryRepository(session).refresh_stats([movie_library[0], tv_library[0]])
    finally:
        await database.dispose()
    return ids
