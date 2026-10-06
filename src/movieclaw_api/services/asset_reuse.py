"""刮削图片的防重复下载：能不联网就不联网（docs/design/image-dedup.md）。

刮削要把海报、背景、Logo、季海报、分集剧照、演职员头像落成本地资产。图床
（TMDB / Fanart.tv）的图片地址是**一图一址**——图换了地址就变、地址不变内容就
不变，所以「这张图本地有没有」可以不下载就判断。不联网的取图法按顺序尝试，都不
成才真正下载：

1. **沿用**（media_scrape._sync_asset）：资产文件在、格式对、溯源（档位 + 路径 /
   Fanart 地址）一致——连请求都不发；
2. **本地缩图**（``derive``）：要的是同一张图的**更小档位**，而本地已有更大的
   一档（典型：画质从「原图」改成「标准」）——从本地那张缩出来；
3. **收编媒体目录里的同一张图**：数据目录重建、换机、或媒体目录里本来就有别的
   刮削软件（tinyMediaManager 等）刮好的图时，资产目录是空的、媒体目录里却躺着
   同一张图。判定靠 **HEAD**：只问远端字节数（几百字节流量），与本地候选文件的
   长度逐字节一致才认。要的不是原图档位时再问一次原图的字节数：别的软件多半存的
   是原图，对上了就收编后本地缩图。

   注意（2026-10-04 实测）：TMDB 图床（BunnyCDN）会在边缘节点即时压缩优化，同一
   地址在不同节点、不同缓存时刻给出的字节数可能略有出入（同一张海报实测 1016287
   与 1024639 字节）。所以「同址」只保证是同一张图、不保证同一份字节——沿用只比
   地址不受影响；收编按字节数比对偶尔会因此对不上，对不上就退回下载（少省一次
   流量，不会错收编）。

为什么不靠 NFO 里记的图片地址判定（零请求）：NFO 只能说明「这部片的海报是某个
地址」，证明不了目录里**哪个文件**是它——用户自己放的 ``logo.png``、换过而没被
镜像覆盖的 ``poster.jpg``，都会让 NFO 记录指向别人的图，错收编就是功能缺陷。
字节数比对拿的是真实的远端与本地，没有这个歧义。

任何一步拿不准都退回正常下载：省流量是优化，不能拿正确性换。
"""

from __future__ import annotations

import io
import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path

_TIER = re.compile(r"^([wh])(\d+)$")
# 本地缩图的 JPEG 质量：与 TMDB 小档位的观感相当，体积不至于比图床版大一截
_JPEG_QUALITY = 90


# ---------------------------------------------------------------------------
# 档位：谁比谁大、能不能从大的缩出小的
# ---------------------------------------------------------------------------


def tier_rank(tier: str) -> float | None:
    """档位的「清晰度」可比值：original 最大；wN 取宽度；hN 按 2:3 竖图折算成宽度
    （hN 只用于头像，头像是竖图）。认不出的档位返回 None（不参与缩图判断）。"""
    if tier == "original":
        return float("inf")
    match = _TIER.match(tier)
    if match is None:
        return None
    value = int(match.group(2))
    return float(value) if match.group(1) == "w" else value * 2 / 3


def derivable(source_tier: str, target_tier: str) -> bool:
    """能否从 ``source_tier`` 的图在本地缩出 ``target_tier``：目标不是原图、且源严格更大。

    要原图永远得下载（本地缩不出原图）；源比目标小更不可能（不放大）。
    """
    if target_tier == "original":
        return False
    source, target = tier_rank(source_tier), tier_rank(target_tier)
    return source is not None and target is not None and source > target


def derive(data: bytes, target_tier: str, *, png: bool) -> bytes:
    """从更大档位的图缩出 ``target_tier``（wN 按宽、hN 按高，等比）。

    源图本身已经不比目标大（TMDB 也不放大，小于档位的原图按原尺寸给）时原样
    返回字节。解不了图就抛异常，调用方退回下载。
    """
    from PIL import Image

    match = _TIER.match(target_tier)
    if match is None:
        raise ValueError(f"无法本地缩图的档位：{target_tier}")
    axis, limit = match.group(1), int(match.group(2))
    with Image.open(io.BytesIO(data)) as image:
        width, height = image.size
        current = width if axis == "w" else height
        if current <= limit:
            return data
        scale = limit / current
        size = (max(1, round(width * scale)), max(1, round(height * scale)))
        resized = image.convert("RGBA" if png else "RGB").resize(size, Image.Resampling.LANCZOS)
        buffer = io.BytesIO()
        if png:
            resized.save(buffer, "PNG")
        else:
            resized.save(buffer, "JPEG", quality=_JPEG_QUALITY)
    return buffer.getvalue()


def split_want(want: str) -> tuple[str, str] | None:
    """TMDB 资产的溯源串 ``w780/abc.jpg`` → (档位, 路径)；Fanart 绝对地址返回 None。"""
    if want.startswith(("https://", "http://")):
        return None
    slash = want.find("/")
    if slash <= 0:
        return None
    return want[:slash], want[slash:]


# ---------------------------------------------------------------------------
# 媒体目录里的候选图
# ---------------------------------------------------------------------------


@dataclass
class MediaDirArt:
    """条目在媒体目录里已有的图：资产键 → 候选文件（键与 sources.json 同口径：
    poster / backdrop / logo / season-<n> / sNNeNN）。"""

    candidates: dict[str, list[Path]] = field(default_factory=dict)


def _season_names(number: int) -> list[str]:
    stem = "season-specials" if number == 0 else f"season{number:02d}"
    return [f"{stem}-poster.jpg", f"{stem}-poster.png"]


def scan_entry_art(
    entries: Iterable[Path],
    videos: Iterable[Path],
    season_numbers: Iterable[int],
    *,
    media_kind: str,
) -> MediaDirArt:
    """条目级的已有图：海报 / 背景 / Logo / 季海报（同步磁盘 IO，调用方放线程池）。

    条目图按 Kodi/Jellyfin 命名规则找（与详情页、Jellyfin 接口同一份规则，混放目录
    不串图）；季海报找 ``seasonNN-poster``。
    """
    from movieclaw_api.services.library.artwork import find_artwork

    art = MediaDirArt()
    own = list(videos)
    entries = [entry for entry in entries if entry.is_dir()]
    cache: dict = {}
    for key, kind in (("poster", "poster"), ("backdrop", "fanart"), ("logo", "clearlogo")):
        for entry in entries:
            found = find_artwork(entry, kind, own, media_kind=media_kind, cache=cache)
            if found is not None:
                art.candidates.setdefault(key, []).append(found)
    numbers = list(season_numbers)
    for entry in entries:
        for number in numbers:
            for name in _season_names(number):
                path = entry / name
                if path.is_file():
                    art.candidates.setdefault(f"season-{number}", []).append(path)
    return art


def scan_episode_art(key: str, videos: Iterable[Path]) -> MediaDirArt:
    """一集的已有剧照：视频同名的 ``-thumb``（同步磁盘 IO）。

    按集现查而不是整部剧一次扫完：日常刷新里绝大多数剧照直接沿用，只有真要
    下载的那几集才值得去媒体盘（NAS 上常是网络挂载）找文件。
    """
    art = MediaDirArt()
    for video in videos:
        for ext in (".jpg", ".png"):
            thumb = video.with_name(f"{video.stem}-thumb{ext}")
            if thumb.is_file():
                art.candidates.setdefault(key, []).append(thumb)
    return art
