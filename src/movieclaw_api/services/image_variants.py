"""图片派生缓存：把原图按受控尺寸压成可复用的小图。

尺寸口径两种：宽度阶梯 ``w``（新，客户端按「显示点数 × 屏幕倍率 × 放大系数」要像素，
见 docs/design/image-sizing.md §5）与固定预设 ``variant``（旧客户端兼容）。

原图仍是事实源（远程图由 ``ImageCache`` 缓存，本地刮削图在 metadata 目录）；
本模块只生成可随时删除重建的 WebP 派生物。派生结果继续写进同一个图片缓存，
因此与原图共用 singleflight、LRU 容量上限和 ``data/`` 持久化约定。
"""

from __future__ import annotations

import asyncio
import logging
import math
import mimetypes
import os
from dataclasses import dataclass
from enum import StrEnum
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError

from movieclaw_api.exceptions import UpstreamServiceException
from movieclaw_api.services.image_cache import CachedImage, ImageCache, get_image_cache

logger = logging.getLogger("movieclaw_api.image_variants")

# 改编码参数时 bump：旧派生图留给 LRU 淘汰，新请求自动生成新版本。
_ENCODER_VERSION = "v3"


class ImageVariant(StrEnum):
    """允许从 HTTP 暴露的固定预设；拒绝任意宽高，避免制造无限缓存键。"""

    LANDSCAPE_CARD = "landscape-card"
    POSTER_CARD = "poster-card"
    # 图片库（docs/design/library-photo-kind.md 3.4）：相册墙的瓦片与灯箱的
    # 屏幕适配图。两者都是「装进盒子、不裁切」——照片的比例本身就是内容
    PHOTO_TILE = "photo-tile"
    PHOTO_SCREEN = "photo-screen"
    # 影视库 / 其他库的图床浏览模式（瀑布流墙）在宽松密度下的瓦片。相册墙同一档
    # 直接用原图是因为图片库的墙图本来就是 720 缩略图；图廊的源却是 TMDB w1280
    # 剧照与本地刮削原件，一张几百 KB 到几 MB，滑过去就是一片黑等着下载
    GALLERY_TILE = "gallery-tile"
    # 刷片等画面时垫在视频横带里的剧照（docs/design/reels.md）：横带占满手机屏宽，
    # 3x 屏约 1200px，480 的横卡放大 2.5 倍发虚
    REEL_STILL = "reel-still"
    # Apple TV 的卡片（docs/design/tvos-app.md §2）：电视画布固定 1920×1080 点，接 4K
    # 电视时按 2 倍渲染。手机那两档（480 横卡 / 328 海报）铺到电视卡片上要再放大约 2 倍，
    # 三米外也看得出糊，所以电视单独两档
    TV_LANDSCAPE = "tv-landscape"
    TV_POSTER = "tv-poster"


@dataclass(frozen=True)
class VariantPreset:
    width: int
    height: int
    quality: int


_PRESETS = {
    # 预设的宽高是**外接框**而不是输出尺寸：派生图按原图比例等比缩到框内，
    # 绝不裁切。卡片框的比例由后端按真实尺寸给出（primary_aspect），派生图若
    # 在服务端先裁成固定比例，其他库里 16:9 的横版封面会被裁成 2:3 竖条、再被
    # 前端 object-cover 二次裁切，用户看到的只剩画面正中一小块。
    # 最近观看/分集横卡最大 240 CSS px，480px 足够覆盖常见 2x 屏。
    ImageVariant.LANDSCAPE_CARD: VariantPreset(width=480, height=270, quality=78),
    # 竖海报最大 164 CSS px，328px 覆盖 2x 屏；也供横卡缺背景时的海报兜底复用。
    ImageVariant.POSTER_CARD: VariantPreset(width=328, height=492, quality=80),
    # 相册墙瓦片：紧凑/标准密度列宽 ≤230 CSS px，480px 覆盖 2x 屏；宽松密度用 720 的原缩略图
    ImageVariant.PHOTO_TILE: VariantPreset(width=480, height=480, quality=78),
    # 灯箱屏幕适配图：长边 2048 覆盖 4K 以下全屏，几百 KB 而不是原图的几 MB；放大才拉原图
    ImageVariant.PHOTO_SCREEN: VariantPreset(width=2048, height=2048, quality=82),
    # 图廊宽松密度：列宽 340 CSS px，720px 覆盖 2x 屏
    ImageVariant.GALLERY_TILE: VariantPreset(width=720, height=720, quality=78),
    # 刷片剧照：720p（1280×720），一张约 60～150KB；原图多是 4K，现压要 0.15～0.55 秒（NAS 实测），
    # 所以刷片接口返回一页时就在后台把前几张压好（services/reels/feed.py `_warm_stills`）
    ImageVariant.REEL_STILL: VariantPreset(width=1280, height=720, quality=78),
    # 电视横卡最宽 460 点（4K 下 920px）：960×540，一张约 60～120KB
    ImageVariant.TV_LANDSCAPE: VariantPreset(width=960, height=540, quality=80),
    # 电视海报卡 266 点宽（4K 下 532px）：540×810
    ImageVariant.TV_POSTER: VariantPreset(width=540, height=810, quality=80),
}


# 宽度阶梯（docs/design/image-sizing.md §5）：客户端只说「我要多宽」（``w``，像素），
# 服务端向上取到最近一档。相邻两档不超过 1.5 倍——最多多给 1.5 倍宽，缓存键却有界
# （每张原图最多 10 个派生）。加设备、改布局都不用再改后端加预设
WIDTH_LADDER = (160, 240, 360, 480, 720, 960, 1280, 1920, 2560, 3840)
# 宽度档的派生画质；高度上限取宽的 2 倍：极端竖图（长截图）的保险，海报 1.5 倍不受影响
_WIDTH_QUALITY = 80
# 没发布过的电视两档（v0.30.0 之后才加）直接并进阶梯；已发布的预设原样保留，旧客户端行为不变
_LEGACY_WIDTH = {ImageVariant.TV_LANDSCAPE: 960, ImageVariant.TV_POSTER: 960}


def snap_width(width: int) -> int:
    """把需要的像素宽向上取到阶梯；超过最大一档按最大一档。"""
    for rung in WIDTH_LADDER:
        if width <= rung:
            return rung
    return WIDTH_LADDER[-1]


@dataclass(frozen=True)
class Sizing:
    """一次派生的尺寸口径：``key`` 进缓存键，``box`` 是外接框；``passthrough`` 表示
    原图不比框大时直接回原图（宽度档如此；旧预设保持一律重编码的老行为）。"""

    key: str
    box: VariantPreset
    passthrough: bool


def sizing_for(*, variant: ImageVariant | None = None, width: int | None = None) -> Sizing | None:
    """请求参数 → 尺寸口径；``w`` 优先，两者都没有返回 None（回原图）。"""
    if variant in _LEGACY_WIDTH and not width:
        width = _LEGACY_WIDTH[variant]
    if width:
        rung = snap_width(width)
        return Sizing(f"w{rung}", VariantPreset(rung, rung * 2, _WIDTH_QUALITY), True)
    if variant is not None:
        return Sizing(variant.value, _PRESETS[variant], False)
    return None


def local_source_version(path: Path) -> str:
    """本地事实源的轻量版本指纹；不读整文件即可让原地换图自动失效。"""
    return source_version_of(path.stat())


def source_version_of(stat: os.stat_result) -> str:
    """已经 stat 过的调用方直接用它，不必为了版本指纹再 stat 一次。"""
    return f"{stat.st_mtime_ns}:{stat.st_size}"


class ImageVariantService:
    """按尺寸口径惰性生成 WebP；同一原图/版本/口径只编码一次。

    原图不比请求的宽度档大时不重编码，直接回原图：电视海报墙要 960 档、原图 780 宽，
    就该给原图本身，而不是再压一遍更糊的 780 WebP。
    """

    def __init__(self, cache: ImageCache, *, max_parallel: int = 2) -> None:
        self._cache = cache
        # 首页首次出现多张原图时限制 Pillow 并发，避免 NAS 瞬间吃满 CPU。
        self._slots = asyncio.Semaphore(max_parallel)
        # 原图尺寸（只读文件头）：(来源键, 版本) → (宽, 高)，有界，满了整体清空
        self._dims: dict[tuple[str, str], tuple[int, int]] = {}

    async def get_or_create(
        self,
        source_path: Path,
        *,
        source_key: str,
        source_version: str,
        variant: ImageVariant | None = None,
        width: int | None = None,
        content_type: str | None = None,
    ) -> CachedImage:
        """本地来源的派生。``content_type`` 是原图的类型，原样回原图时用（缺省按扩展名推断）。"""
        sizing = sizing_for(variant=variant, width=width)
        if sizing is None:
            return CachedImage(
                source_path, content_type or _guess_type(source_path), source_version
            )
        if sizing.passthrough and await self._fits(source_path, source_key, source_version, sizing):
            return CachedImage(
                source_path, content_type or _guess_type(source_path), source_version
            )
        cache_key = f"image-variant:{_ENCODER_VERSION}:{sizing.key}:{source_key}:{source_version}"

        async def produce() -> tuple[bytes, str]:
            return await self._render(source_path, sizing)

        return await self._cache.get_or_create(
            cache_key,
            produce,
            metadata={
                "source_key": source_key,
                "source_version": source_version,
                "variant": sizing.key,
            },
        )

    async def get_or_create_remote(
        self, url: str, *, variant: ImageVariant | None = None, width: int | None = None
    ) -> CachedImage:
        """远程图（图床 URL）的派生：缓存键只认 URL，命中就不碰原图。

        图床 URL 的内容不可变（换图就是换地址，代理也据此给一年 immutable），
        所以派生图不必跟着原图的缓存版本走。原先键里带原图版本，取派生图得先
        把原图读出来：原图被 LRU 淘汰后，哪怕派生图还在，断网时也只能 502。
        现在只有派生图也不在时才回源取原图；原图不比宽度档大时原样存一份。
        """
        sizing = sizing_for(variant=variant, width=width)
        if sizing is None:
            return await self._cache.get_or_fetch(url)
        cache_key = f"image-variant:{_ENCODER_VERSION}:{sizing.key}:remote:{url}"

        async def produce() -> tuple[bytes, str]:
            original = await self._cache.get_or_fetch(url)
            if sizing.passthrough and await self._fits(
                original.path, f"remote:{url}", original.version, sizing
            ):
                data = await asyncio.to_thread(original.path.read_bytes)
                return data, original.content_type
            return await self._render(original.path, sizing)

        return await self._cache.get_or_create(
            cache_key,
            produce,
            metadata={"source_key": f"remote:{url}", "variant": sizing.key},
        )

    async def _fits(self, path: Path, source_key: str, version: str, sizing: Sizing) -> bool:
        """原图（按 EXIF 方向摆正后）装得进外接框吗——装得进就不必重编码。"""
        key = (source_key, version)
        dims = self._dims.get(key)
        if dims is None:
            try:
                dims = await asyncio.to_thread(_oriented_size, path)
            except (OSError, ValueError, UnidentifiedImageError):
                return False
            if len(self._dims) >= 4096:
                self._dims.clear()
            self._dims[key] = dims
        return dims[0] <= sizing.box.width and dims[1] <= sizing.box.height

    async def _render(self, source_path: Path, sizing: Sizing) -> tuple[bytes, str]:
        async with self._slots:
            try:
                data = await asyncio.to_thread(_render_webp, source_path, sizing.box)
            except (OSError, ValueError, UnidentifiedImageError) as exc:
                logger.warning("图片派生失败：%s（%s）", source_path, exc)
                raise UpstreamServiceException("图片缩略图生成失败") from exc
            return data, "image/webp"


_ROTATED_ORIENTATIONS = (5, 6, 7, 8)


def _guess_type(path: Path) -> str:
    return mimetypes.guess_type(path.name)[0] or "image/jpeg"


def _oriented_size(path: Path) -> tuple[int, int]:
    """只读文件头取尺寸；EXIF 方向是转 90° 的，宽高对调（与 exif_transpose 后一致）。"""
    with Image.open(path) as image:
        width, height = image.size
        if image.getexif().get(0x0112) in _ROTATED_ORIENTATIONS:
            return height, width
        return width, height


def _render_webp(source_path: Path, preset: VariantPreset) -> bytes:
    """同步解码、等比缩放到预设外接框内并编码；不裁切，小于目标的原图绝不放大。

    JPEG 原图先用 ``draft`` 让解码器直接按 1/2、1/4、1/8 缩小解码：原图做默认母版后，
    派生的大头开销是解码一张 4K 图，这一步把它降一个量级（最终尺寸仍由 LANCZOS 精缩）。
    """
    with Image.open(source_path) as opened:
        opened.seek(0)  # 动图只取首帧；卡片缩略图不承诺播放动画。
        if opened.format == "JPEG":
            raw_w, raw_h = opened.size
            rotated = opened.getexif().get(0x0112) in _ROTATED_ORIENTATIONS
            box_w, box_h = (
                (preset.height, preset.width) if rotated else (preset.width, preset.height)
            )
            scale = min(1.0, box_w / raw_w, box_h / raw_h)
            if scale < 1.0:
                target = (max(1, math.ceil(raw_w * scale)), max(1, math.ceil(raw_h * scale)))
                opened.draft("RGB", target)
        image = ImageOps.exif_transpose(opened)
        if image.mode not in ("RGB", "RGBA"):
            # 调色板 / 灰度 + 透明（片名 Logo 常见）要转 RGBA，转 RGB 会把透明区压成黑底
            has_alpha = image.mode in ("LA", "PA") or "transparency" in image.info
            image = image.convert("RGBA" if has_alpha else "RGB")

        # 所有预设同一口径：等比装进外接框、不裁切、不放大。照片与卡片曾各走一条
        # 分支（卡片按框比例裁切），卡片改为不裁切后两条分支已无差别，合成一条
        scale = min(
            1.0,
            preset.width / image.width,
            preset.height / image.height,
        )
        output_size = (
            max(1, round(image.width * scale)),
            max(1, round(image.height * scale)),
        )
        rendered = (
            image
            if output_size == image.size
            else image.resize(output_size, Image.Resampling.LANCZOS)
        )
        output = BytesIO()
        rendered.save(output, "WEBP", quality=preset.quality, method=4)
        return output.getvalue()


_service: ImageVariantService | None = None


def get_image_variant_service() -> ImageVariantService:
    global _service
    if _service is None:
        _service = ImageVariantService(get_image_cache())
    return _service


def reset_image_variant_service() -> None:
    """仅供测试：图片缓存实例重建后同步丢弃持有旧缓存的服务单例。"""
    global _service
    _service = None
