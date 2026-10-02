"""
从 docs/brand/masters 的母版图生成网页端全部品牌位图。

用法（仓库根目录）：
    .venv/bin/python scripts/brand/generate_web_assets.py

产出：
    apps/web/public/brand/movieclaw-mark.png   标志（透明底，512），侧栏与加载指示用
    apps/web/app/favicon.ico                    浏览器标签页图标（16 / 32 / 48 三档合一）
    apps/web/public/favicon.svg                 矢量标签页图标（拷自 docs/brand/favicon.svg，
                                                在 layout.tsx 的 metadata 里声明）
    apps/web/public/apple-touch-icon.png        添加到主屏幕（180，不透明，iOS 自己加圆角）
    apps/web/public/icons/icon-{192,512}.png    PWA 图标（不透明、全出血，同时兼作 maskable）
    apps/web/public/splash/splash-*.png         iOS PWA 启动图：纯黑底 + 居中标志

启动图的设备清单只维护一份：直接解析 apps/web/lib/apple-splash.ts 里的 IPHONES / IPADS 两张表，
新机型上市后在那里加一行、重跑本脚本即可。

母版图怎么来：docs/brand/README.md。
"""

import re
import shutil
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
MASTERS = ROOT / "docs/brand/masters"
WEB = ROOT / "apps/web"

# 启动图里标志所占的方框边长（逻辑 pt）：字形约占方框 91%，即约 91pt 宽，
# 与旧启动图一致，也与网页 SplashLayer 里 BrandLoader size-24 的观感衔接。
SPLASH_MARK_BOX_PT = 100


def resized(im: Image.Image, size: int) -> Image.Image:
    return im.resize((size, size), Image.LANCZOS)


def splash_devices() -> list[tuple[int, int, int, bool]]:
    """解析 apple-splash.ts，返回 (逻辑宽, 逻辑高, DPR, 是否横屏)。

    iPhone 只要竖屏，iPad 竖横都要。
    """
    src = (WEB / "lib/apple-splash.ts").read_text(encoding="utf-8")

    def table(name: str) -> list[tuple[int, int, int]]:
        block = re.search(rf"const {name}[^=]*=\s*\[(.*?)\];", src, re.S)
        if not block:
            raise SystemExit(f"apple-splash.ts 里找不到 {name} 表，脚本需要同步更新")
        rows = re.findall(r"\[(\d+),\s*(\d+),\s*(\d+)\]", block.group(1))
        return [tuple(map(int, m)) for m in rows]

    devices = [(w, h, r, False) for w, h, r in table("IPHONES")]
    for w, h, r in table("IPADS"):
        devices += [(w, h, r, False), (w, h, r, True)]
    return devices


def main() -> None:
    mark = Image.open(MASTERS / "mark-1024.png").convert("RGBA")
    icon = Image.open(MASTERS / "app-icon-1024.png").convert("RGB")
    favicon = Image.open(MASTERS / "favicon-1024.png").convert("RGBA")

    (WEB / "public/brand").mkdir(parents=True, exist_ok=True)
    resized(mark, 512).save(WEB / "public/brand/movieclaw-mark.png", optimize=True)

    favicon.save(WEB / "app/favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
    shutil.copyfile(ROOT / "docs/brand/favicon.svg", WEB / "public/favicon.svg")

    resized(icon, 180).save(WEB / "public/apple-touch-icon.png", optimize=True)
    for px in (192, 512):
        resized(icon, px).save(WEB / f"public/icons/icon-{px}.png", optimize=True)

    splash_dir = WEB / "public/splash"
    for old in splash_dir.glob("splash-*.png"):
        old.unlink()
    for w, h, r, land in splash_devices():
        pw, ph = (h * r, w * r) if land else (w * r, h * r)
        canvas = Image.new("RGB", (pw, ph), (0, 0, 0))
        box = resized(mark, SPLASH_MARK_BOX_PT * r)
        canvas.paste(box, ((pw - box.width) // 2, (ph - box.height) // 2), box)
        canvas.save(splash_dir / f"splash-{w}x{h}@{r}{'-land' if land else ''}.png", optimize=True)

    print("网页品牌位图已生成。")


if __name__ == "__main__":
    main()
