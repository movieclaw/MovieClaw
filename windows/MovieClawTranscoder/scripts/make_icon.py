"""把一组 PNG（小到大）打包成一个 .ico——PNG 直接内嵌，Vista 起的系统都认。

一次性工具：源图用网页的 ``apps/web/public/icons/icon-512.png``，各尺寸先由
ffmpeg 缩好（``-vf scale=N:N:flags=lanczos``），这里只负责装盒。用法::

    python make_icon.py -o ../app/movieclaw_transcoder_app/icon.ico icon-16.png …

托盘与安装包（NSIS 的 ``Icon`` 指令）都用这一个文件。
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


def pack(pngs: list[Path]) -> bytes:
    if not pngs:
        raise SystemExit("没有输入 PNG")
    images = [png.read_bytes() for png in pngs]
    header = struct.pack("<HHH", 0, 1, len(images))
    entries = b""
    offset = 6 + 16 * len(images)
    for png, image in zip(pngs, images, strict=True):
        side = png.stem.rsplit("-", 1)[-1]
        size = int(side) if side.isdigit() else 256
        if size > 256:
            raise SystemExit(f"{png.name} 的尺寸超过 256")
        width = 0 if size >= 256 else size
        entries += struct.pack(
            "<BBBBHHII",
            width,
            width,  # 高度与宽度同值（方形）
            0,  # 调色板色数（PNG 内嵌时不用）
            0,
            1,  # 颜色平面数
            32,  # 位深
            len(image),
            offset,
        )
        offset += len(image)
    return header + entries + b"".join(images)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pngs", nargs="+", type=Path, help="按从小到大排列的 PNG")
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_bytes(pack(args.pngs))
    print(f"已写出 {args.output}（{args.output.stat().st_size} 字节）")


if __name__ == "__main__":
    main()
