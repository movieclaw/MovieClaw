"""
从 docs/brand 的母版生成 Apple TV 版的 App 图标与 Top Shelf 图（docs/design/tvos-app.md §6.1）。

用法（仓库根目录，macOS）：
    .venv/bin/python scripts/brand/generate_tvos_assets.py

产出：apps/apple/MovieClawTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/
    App Icon.imagestack                 主屏图标 400×240（1x / 2x），两层：背景（纯黑 + 极淡的极光晕）、前景（标志）
    App Icon - App Store.imagestack     App Store 图标 1280×768，同样两层
    Top Shelf Image.imageset            1920×720（1x / 2x）：纯黑底 + 横版组合（标志 + 字标）
    Top Shelf Image Wide.imageset       2320×720（1x / 2x）：同上

tvOS 的图标是分层的：焦点落上去时系统按层做视差，所以标志单独一层、背景单独一层（背景必须不透明）。
比例沿用品牌规范（docs/brand/README.md）：标志在图标里约占短边的 64%（「尺寸 B」）；纯黑底，与 iPhone 图标一致。

字标取自 docs/brand/lockup-horizontal-black.svg：系统的 Quick Look（qlmanage）把它栅格化在白底上，
黑色字形的灰度正好就是不透明度，取出后再上深色底用的字标色 #F3F5F9。所以本脚本只能在 macOS 上跑。
"""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "docs/brand"
OUT = ROOT / "apps/apple/MovieClawTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"

WORDMARK_COLOR = (0xF3, 0xF5, 0xF9)
# 极光渐变的四个色（品牌规范），背景层的晕取其中两色、极淡
AURORA_GLOW = [(0x4C, 0x9D, 0xFF), (0x9A, 0x6B, 0xFF)]
# 标志在图标里占短边的比例（品牌「尺寸 B」：三角外框约占 App 图标 64%）
ICON_MARK_RATIO = 0.64
# Top Shelf 里横版组合的高度（标志高）占图高的比例
SHELF_MARK_RATIO = 0.30


def mark_glyph() -> Image.Image:
    """标志母版裁到字形本身（母版里字形约占 91%，四周是透明留白）"""
    master = Image.open(BRAND / "masters/mark-1024.png").convert("RGBA")
    return master.crop(master.getbbox())


def wordmark() -> Image.Image:
    """从黑色横版组合里取出字标（透明底、字标色）"""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            ["qlmanage", "-t", "-s", "3000", "-o", tmp, str(BRAND / "lockup-horizontal-black.svg")],
            check=True, capture_output=True,
        )
        raster = Image.open(next(Path(tmp).glob("*.png"))).convert("L")
    alpha = raster.point(lambda v: 255 - v)
    bbox = alpha.getbbox()
    alpha = alpha.crop(bbox)
    # 组合里左边是标志、右边是字标：按列找第一段空白，空白之后的是字标
    width, height = alpha.size
    columns = [any(alpha.getpixel((x, y)) > 8 for y in range(0, height, 2)) for x in range(width)]
    gap_start = next(x for x in range(width) if not columns[x])
    text_start = next(x for x in range(gap_start, width) if columns[x])
    text_alpha = alpha.crop((text_start, 0, width, height))
    text_alpha = text_alpha.crop(text_alpha.getbbox())
    word = Image.new("RGBA", text_alpha.size, WORDMARK_COLOR + (0,))
    word.putalpha(text_alpha)
    return word


def scaled(im: Image.Image, height: int) -> Image.Image:
    width = round(im.width * height / im.height)
    return im.resize((width, height), Image.LANCZOS)


def background(size: tuple[int, int], glow: bool) -> Image.Image:
    """纯黑底；图标的背景层叠一圈极淡的极光晕，焦点视差时前后层分得开"""
    bg = Image.new("RGBA", size, (0, 0, 0, 255))
    if not glow:
        return bg
    w, h = size
    halo = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(halo)
    for color, (cx, cy) in zip(AURORA_GLOW, [(0.42, 0.55), (0.6, 0.45)]):
        r = h * 0.45
        draw.ellipse([w * cx - r, h * cy - r, w * cx + r, h * cy + r], fill=color + (40,))
    halo = halo.filter(ImageFilter.GaussianBlur(h * 0.18))
    return Image.alpha_composite(bg, halo)


def icon_layers(size: tuple[int, int], glyph: Image.Image) -> tuple[Image.Image, Image.Image]:
    """（背景层, 前景层）"""
    w, h = size
    front = Image.new("RGBA", size, (0, 0, 0, 0))
    mark = scaled(glyph, round(h * ICON_MARK_RATIO))
    front.alpha_composite(mark, ((w - mark.width) // 2, (h - mark.height) // 2))
    return background(size, glow=True).convert("RGB"), front


def top_shelf(size: tuple[int, int], glyph: Image.Image, word: Image.Image) -> Image.Image:
    """横版组合（品牌规范：标志高 H，字标大写字母高 0.6H，间距 0.3H）居中放在纯黑底上"""
    w, h = size
    mark_h = round(h * SHELF_MARK_RATIO)
    mark = scaled(glyph, mark_h)
    text = scaled(word, round(mark_h * 0.6))
    gap = round(mark_h * 0.3)
    total = mark.width + gap + text.width
    canvas = background(size, glow=False)
    x = (w - total) // 2
    canvas.alpha_composite(mark, (x, (h - mark.height) // 2))
    canvas.alpha_composite(text, (x + mark.width + gap, (h - text.height) // 2))
    return canvas.convert("RGB")


def write_json(path: Path, data: dict) -> None:
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


INFO = {"author": "xcode", "version": 1}


def write_imageset(path: Path, images: list[tuple[Image.Image, str]]) -> None:
    """images: [(图, 倍率 "1x"/"2x")]"""
    entries = []
    path.mkdir(parents=True, exist_ok=True)
    for image, scale in images:
        name = f"{path.stem.replace(' ', '-').lower()}@{scale}.png"
        image.save(path / name, optimize=True)
        entries.append({"filename": name, "idiom": "tv", "scale": scale})
    write_json(path, {"images": entries, "info": INFO})


def write_imagestack(path: Path, size: tuple[int, int], scales: list[int], glyph: Image.Image) -> None:
    layers = {"Front": [], "Back": []}
    for factor in scales:
        back, front = icon_layers((size[0] * factor, size[1] * factor), glyph)
        layers["Back"].append((back, f"{factor}x"))
        layers["Front"].append((front, f"{factor}x"))
    write_json(path, {"layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}], "info": INFO})
    for name, images in layers.items():
        layer = path / f"{name}.imagestacklayer"
        write_json(layer, {"info": INFO})
        write_imageset(layer / "Content.imageset", images)


def main() -> None:
    glyph = mark_glyph()
    word = wordmark()
    if OUT.exists():
        shutil.rmtree(OUT)
    write_imagestack(OUT / "App Icon.imagestack", (400, 240), [1, 2], glyph)
    write_imagestack(OUT / "App Icon - App Store.imagestack", (1280, 768), [1], glyph)
    write_imageset(OUT / "Top Shelf Image.imageset",
                   [(top_shelf((1920, 720), glyph, word), "1x"), (top_shelf((3840, 1440), glyph, word), "2x")])
    write_imageset(OUT / "Top Shelf Image Wide.imageset",
                   [(top_shelf((2320, 720), glyph, word), "1x"), (top_shelf((4640, 1440), glyph, word), "2x")])
    write_json(OUT, {
        "assets": [
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
        ],
        "info": INFO,
    })
    write_json(OUT.parent, {"info": INFO})
    print(f"已生成 {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
