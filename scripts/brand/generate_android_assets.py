"""从 A9 极光母版生成 Android 手机端启动器图标（Pillow）。

用法：.venv/bin/python scripts/brand/generate_android_assets.py
API 26+ 自适应图标：108dp 前景（极光标志）+ 深色渐变背景
（drawable/ic_launcher_background.xml，与 iOS 图标底色一致）+ 单色层（Android 13 主题图标）。
minSdk 26，不需要旧式整张 PNG。
标志大小与位置对齐 iOS AppIcon：外框占可见 72dp 的 64%，按 iOS 图标同样向右偏一点做视觉居中。
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
MASTERS = ROOT / "docs/brand/masters"
RES = ROOT / "apps/android/app/src/main/res"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

# 在 xxxhdpi（108dp = 432px）画布上排版，再缩到各密度
CANVAS = 432
VISIBLE = 72 * 4
GLYPH_RATIO = 0.64
# iOS AppIcon-1024 里三角外框中心在 x=538（画布中心 512），即右移 2.5%
OPTICAL_SHIFT = 26 / 1024


def main() -> None:
    mark = Image.open(MASTERS / "mark-1024.png").convert("RGBA")
    solid = mark.getchannel("A").point(lambda v: 255 if v > 200 else 0).getbbox()
    if solid is None:
        raise SystemExit("mark-1024.png 里找不到标志")
    glyph_w = solid[2] - solid[0]
    scale = VISIBLE * GLYPH_RATIO / glyph_w
    size = round(mark.width * scale)
    mark = mark.resize((size, size), Image.Resampling.LANCZOS)
    # 以字形外框中心对齐画布中心，再加视觉偏移
    cx = (solid[0] + solid[2]) / 2 * scale
    cy = (solid[1] + solid[3]) / 2 * scale
    x = round(CANVAS / 2 + VISIBLE * OPTICAL_SHIFT - cx)
    y = round(CANVAS / 2 - cy)

    foreground = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    foreground.alpha_composite(mark, (x, y))
    # 主题图标只取形状：系统按壁纸取色着色
    monochrome = Image.new("RGBA", (CANVAS, CANVAS), (255, 255, 255, 0))
    monochrome.putalpha(foreground.getchannel("A"))

    for density, factor in DENSITIES.items():
        drawable = RES / f"drawable-{density}"
        drawable.mkdir(parents=True, exist_ok=True)
        px = round(108 * factor)
        layers = {"ic_launcher_foreground": foreground, "ic_launcher_monochrome": monochrome}
        for name, im in layers.items():
            out = drawable / f"{name}.png"
            im.resize((px, px), Image.Resampling.LANCZOS).save(out, optimize=True)
    print(f"已生成 {RES.relative_to(ROOT)} 下的 Android 启动器图标")


if __name__ == "__main__":
    main()
