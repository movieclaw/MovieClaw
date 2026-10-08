"""从 A9 极光母版生成 Android TV 启动器资源（macOS / Pillow）。

用法：.venv/bin/python scripts/brand/generate_android_tv_assets.py
横幅：16:9、不透明黑底 + 标志与 MovieClaw 字标，xhdpi 为 320×180 px。
方形图标：mdpi 为 80×80 px；API 26+ 使用 108dp 前景 + 纯黑背景。
字标复用 tvOS 的 Quick Look 提取方法，取自已转路径的 SVG，不依赖字体。
规范：https://developer.android.com/design/ui/tv/guides/system/tv-app-icon-guidelines
"""

from pathlib import Path

from generate_tvos_assets import mark_glyph, scaled, wordmark
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "docs/brand"
RES = ROOT / "apps/android-tv/app/src/main/res"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def banner(glyph: Image.Image, word: Image.Image) -> Image.Image:
    # 在 4x 画布上排版后缩小，避免各密度出现不同的字形与间距。
    canvas = Image.new("RGBA", (640, 360), (0, 0, 0, 255))
    # 横版组合宽约 80%，字标高 0.6H、间距 0.3H，沿用品牌规范。
    mark = scaled(glyph, 96)
    text = scaled(word, 58)
    gap = 29
    x = (canvas.width - mark.width - gap - text.width) // 2
    canvas.alpha_composite(mark, (x, (canvas.height - mark.height) // 2))
    canvas.alpha_composite(text, (x + mark.width + gap, (canvas.height - text.height) // 2))
    return canvas.convert("RGB")


def main() -> None:
    glyph = mark_glyph()
    tv_banner = banner(glyph, wordmark())
    icon = Image.open(BRAND / "masters/app-icon-1024.png").convert("RGB")
    # 108dp 图层的中心 72dp 是系统展示区域；标志占其 64%，保留遮罩安全区。
    foreground = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    mark = scaled(glyph, round(72 * 4 * 0.64))
    foreground.alpha_composite(mark, ((432 - mark.width) // 2, (432 - mark.height) // 2))
    for density, factor in DENSITIES.items():
        mipmap = RES / f"mipmap-{density}"
        drawable = RES / f"drawable-{density}"
        mipmap.mkdir(parents=True, exist_ok=True)
        drawable.mkdir(parents=True, exist_ok=True)
        tv_banner.resize((round(160 * factor), round(90 * factor)), Image.Resampling.LANCZOS).save(
            mipmap / "banner.png", optimize=True
        )
        size = round(80 * factor)
        icon.resize((size, size), Image.Resampling.LANCZOS).save(
            mipmap / "ic_launcher.png", optimize=True
        )
        size = round(108 * factor)
        foreground.resize((size, size), Image.Resampling.LANCZOS).save(
            drawable / "ic_launcher_foreground.png", optimize=True
        )
    print(f"已生成 {RES.relative_to(ROOT)} 下的 Android TV 图标与横幅")


if __name__ == "__main__":
    main()
