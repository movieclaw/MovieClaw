"""
从 docs/brand 的母版生成 Mac 版 App（MovieClawMac）的图标。

用法（仓库根目录）：
    .venv/bin/python scripts/brand/generate_macos_assets.py

产出：apps/apple/MovieClawMac/Assets.xcassets/AppIcon.appiconset/
    icon_{16,32,128,256,512}x{同}.png 与 @2x   mac idiom 全套 10 张，Contents.json 一并重写

为什么不能直接用 iPhone 的满幅方图：iOS 由系统给图标套圆角，图本身是满幅不透明方块；macOS 不套，
图标的外形、留边和投影都画在图里（Apple 的 macOS 图标网格）。把满幅方图塞给 Mac，Dock 里就是一块
直角黑方块，macOS 26 起还会被系统判成「形状不合规」、缩小后再套一层灰色圆角底框。

所以本脚本按 macOS 图标网格画：
    1024 画布正中一块 824×824 的圆角方块，四周 100 透明留边；
    圆角是 Apple 的「连续圆角」（曲率连续，比普通圆弧收得更圆润），半径 185；
    方块下方带 macOS 图标的标准柔和投影（向下 10、模糊 10、黑色 30%）。
方块里的内容直接取 iPhone 图标的母版 docs/brand/masters/app-icon-1024.png 整张缩放进去——
纯黑底（左上角极淡的提亮）+ 标志，比例沿用品牌规范「尺寸 B」（标志外框约占 64%，含视觉居中的右移），
两端图标因此是同一套视觉，不必在这里重算标志位置。

小尺寸（16、32）也从 1024 的成品直接缩：App 图标里标志本身就有 64% 的分量，不换细笔画版
（品牌规范里「32px 以下换细笔画」说的是贴着文字的界面标志，不是 App 图标）。
"""

import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
MASTER = ROOT / "docs/brand/masters/app-icon-1024.png"
OUT = ROOT / "apps/apple/MovieClawMac/Assets.xcassets/AppIcon.appiconset"

CANVAS = 1024
# macOS 图标网格：824 的圆角方块居中，半径 185（与 Apple 设计模板一致）
BODY = 824
RADIUS = 185
# macOS 图标标准投影：向下偏移、模糊半径、不透明度（均按 1024 画布）
SHADOW_OFFSET = 10
SHADOW_BLUR = 10
SHADOW_ALPHA = 0.30
# 画外形时的超采样倍数：多边形在 4 倍尺寸上画、再缩回来，边缘才平滑
SUPERSAMPLE = 4

# Apple「连续圆角」右上角的三段三次贝塞尔，坐标是（距右边, 距上边）÷ 半径。
# 曲线从上边距角 1.5287r 处开始弯、到右边距角 1.5287r 处结束，比普通圆角（1r）铺得更开，
# 这就是 macOS / iOS 图标那种「没有接缝」的圆角。系数来自对 UIBezierPath 连续圆角的公开逆向测量。
CORNER_SEGMENTS = [
    ((1.52866471, 0.0), (1.08849323, 0.0), (0.86840689, 0.0), (0.66993427, 0.06549600)),
    ((0.66993427, 0.06549600), (0.37282392, 0.16232684), (0.16232684, 0.37282392),
     (0.06549600, 0.66993427)),
    ((0.06549600, 0.66993427), (0.0, 0.86840689), (0.0, 1.08849323), (0.0, 1.52866471)),
]

# mac idiom 全套：点尺寸 × 倍率
MAC_SIZES = [16, 32, 128, 256, 512]


def bezier(p0, p1, p2, p3, steps: int = 48) -> list[tuple[float, float]]:
    points = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1]
        points.append((x, y))
    return points


def squircle_polygon(left: float, top: float, size: float, r: float) -> list[tuple[float, float]]:
    """连续圆角方块的轮廓多边形（顺时针，从右上角开始）。

    先算出右上角那一段曲线（以方块中心为原点），再绕中心依次转 90° 得到另外三个角；
    方块是正方形，四个角的曲线互为旋转，相邻两角之间的直边由多边形自动连上。
    """
    half = size / 2
    corner: list[tuple[float, float]] = []
    for segment in CORNER_SEGMENTS:
        # （距右边, 距上边）→ 以中心为原点、y 向下的坐标
        pts = [(half - dx * r, -half + dy * r) for dx, dy in segment]
        corner.extend(bezier(*pts))
    polygon = []
    for quarter in range(4):
        for x, y in corner:
            # 顺时针转 quarter×90°（y 向下的屏幕坐标系里，(x, y) → (-y, x)）
            for _ in range(quarter):
                x, y = -y, x
            polygon.append((left + half + x, top + half + y))
    return polygon


def body_mask(scale: int) -> Image.Image:
    """1024×scale 画布上的方块外形蒙版（L 模式）"""
    mask = Image.new("L", (CANVAS * scale, CANVAS * scale), 0)
    offset = (CANVAS - BODY) / 2 * scale
    polygon = squircle_polygon(offset, offset, BODY * scale, RADIUS * scale)
    ImageDraw.Draw(mask).polygon(polygon, fill=255)
    return mask


def render_icon() -> Image.Image:
    """1024 的成品图标：透明留边 + 投影 + 连续圆角方块里的 iPhone 图标视觉"""
    mask = body_mask(SUPERSAMPLE).resize((CANVAS, CANVAS), Image.LANCZOS)

    # 投影：外形蒙版下移、模糊，作为黑色层的不透明度
    shadow_alpha = Image.new("L", (CANVAS, CANVAS), 0)
    shadow_alpha.paste(mask, (0, SHADOW_OFFSET))
    shadow_alpha = shadow_alpha.filter(ImageFilter.GaussianBlur(SHADOW_BLUR / 2))
    shadow_alpha = shadow_alpha.point(lambda v: round(v * SHADOW_ALPHA))
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    icon.putalpha(shadow_alpha)

    # 方块：iPhone 图标母版整张缩到 824，按外形蒙版裁出来
    content = Image.open(MASTER).convert("RGBA").resize((BODY, BODY), Image.LANCZOS)
    body = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    body.paste(content, (offset, offset))
    body.putalpha(mask)
    return Image.alpha_composite(icon, body)


def main() -> None:
    icon = render_icon()
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    entries = []
    for points in MAC_SIZES:
        for factor in (1, 2):
            pixels = points * factor
            suffix = "" if factor == 1 else "@2x"
            name = f"icon_{points}x{points}{suffix}.png"
            image = icon if pixels == CANVAS else icon.resize((pixels, pixels), Image.LANCZOS)
            image.save(OUT / name, optimize=True)
            entries.append({
                "filename": name,
                "idiom": "mac",
                "scale": f"{factor}x",
                "size": f"{points}x{points}",
            })
    data = {"images": entries, "info": {"author": "xcode", "version": 1}}
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    (OUT / "Contents.json").write_text(text, encoding="utf-8")
    print(f"已生成 {OUT.relative_to(ROOT)}（{len(entries)} 张）")


if __name__ == "__main__":
    main()
