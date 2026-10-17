#!/usr/bin/env python3
"""从 MovieClaw 品牌母版生成鸿蒙应用图标（分层图标 + 启动页图标）。

品牌母版是 MovieClaw/docs/brand/masters/app-icon-1024.png —— 已经合成好的成品：
暗底 + 一圈淡淡的外溢光 + 极光播放三角。鸿蒙用的是「分层图标」，
由背景层和前景层两张 1024×1024 PNG 叠加而成（系统再按设备形状裁剪），
所以这里要把成品拆回两层：

  背景层 = 把三角笔画挖掉后做低频扩散填补（保留母版原有的暗底渐晕与外溢光），
           必须铺满画布且完全不透明；
  前景层 = 「透明底三角」——按前景叠在背景层上能逐像素还原母版反解出来，
           所以自带母版那道外溢光，且不会和背景层的填补痕迹错位。

拆出来的两层重新合成后与母版一致，换设备形状也只是裁掉四周留白。

用法：python3 tools/gen_brand_icon.py（在 Movie_Claw 工程根目录执行）
依赖 Pillow 与 numpy。
"""

import os

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(ROOT, 'MovieClaw/docs/brand/masters/app-icon-1024.png')

# 分层图标要同时喂给 AppScope（应用图标）和 entry（入口 Ability 图标）
MEDIA_DIRS = [
    os.path.join(ROOT, 'AppScope/resources/base/media'),
    os.path.join(ROOT, 'entry/src/main/resources/base/media'),
]

SIZE = 1024
# 母版里极光三角的笔画亮度 >200、外溢光 <40，取 45 能干净地把笔画和光晕分开
STROKE_THRESHOLD = 45
# 低频扩散的分辨率：外溢光本就是低频，在 1/8 尺寸上填补再放大足够
DIFFUSE_SIZE = 128
DIFFUSE_ITERATIONS = 240
# 背景层与母版的过渡羽化半径：让「填补区」和「原始光晕区」接缝看不出来
FEATHER_RADIUS = 10


def load_master():
    """读取品牌母版，返回 (RGB 浮点数组, 笔画掩膜)。"""
    rgb = np.asarray(Image.open(MASTER).convert('RGB')).astype(np.float32)
    stroke = rgb.max(axis=2) > STROKE_THRESHOLD
    return rgb, stroke


def diffuse_plate(rgb, stroke):
    """把笔画区域做低频扩散填补，得到「没有三角只有底和光晕」的背景层。

    做法是把掩膜内像素在低分辨率上反复用高斯模糊的结果替换自己 —— 等价于求解
    调和方程，笔画会被四周的底色/光晕平滑地接上，且不产生明显的涂抹感。
    """
    small_rgb = np.asarray(
        Image.fromarray(rgb.astype(np.uint8)).resize((DIFFUSE_SIZE, DIFFUSE_SIZE), Image.LANCZOS)
    ).astype(np.float32)
    # 缩小后笔画仍要从掩膜里完整去掉：取最大池化，宁可多扩几像素
    small_stroke = np.asarray(
        Image.fromarray((stroke * 255).astype(np.uint8)).resize(
            (DIFFUSE_SIZE, DIFFUSE_SIZE), Image.BOX
        )
    ) > 8

    work = small_rgb.copy()
    # 先给个初值：掩膜内全部填成未被遮挡像素的均值，扩散从这开始收敛
    work[small_stroke] = small_rgb[~small_stroke].mean(axis=0)
    for _ in range(DIFFUSE_ITERATIONS):
        blurred = np.asarray(
            Image.fromarray(work.astype(np.uint8)).filter(ImageFilter.GaussianBlur(2))
        ).astype(np.float32)
        work[small_stroke] = blurred[small_stroke]

    plate = Image.fromarray(work.astype(np.uint8)).resize((SIZE, SIZE), Image.BICUBIC)
    return np.asarray(plate).astype(np.float32)


def build_layers():
    """拆出 (背景层 RGB, 前景层 RGBA) 两组 1024×1024 数组。"""
    rgb, stroke = load_master()
    plate = diffuse_plate(rgb, stroke)

    # 羽化后的掩膜当作混合权重：掩膜内用填补值，掩膜外保留母版原像素（光晕原样保留）
    weight = np.asarray(
        Image.fromarray((stroke * 255).astype(np.uint8)).filter(
            ImageFilter.GaussianBlur(FEATHER_RADIUS)
        )
    ).astype(np.float32) / 255.0
    weight = weight[:, :, None]
    background = rgb * (1.0 - weight) + plate * weight

    # 反解前景：设前景以 alpha 叠加在背景上得到母版 target，
    #   target = fg * a + bg * (1 - a)
    # 取能还原出最亮通道的 a，再逐通道解 fg；三层通道都按此式成立，故合成后与母版一致。
    room = np.maximum(255.0 - background, 1e-3)
    alpha = np.clip((rgb - background) / room, 0.0, 1.0).max(axis=2)
    alpha = np.where(alpha < 1e-3, 0.0, alpha)

    safe_alpha = np.where(alpha > 1e-3, alpha, 1.0)[:, :, None]
    foreground_rgb = np.clip((rgb - background * (1.0 - safe_alpha)) / safe_alpha, 0.0, 255.0)
    foreground_rgb = np.where((alpha > 1e-3)[:, :, None], foreground_rgb, 0.0)

    foreground = np.dstack([foreground_rgb, alpha * 255.0]).astype(np.uint8)
    return background.astype(np.uint8), foreground


def write_outputs(background, foreground):
    """写出两层图标到各模块，并从合成结果生成启动页图标。"""
    background_img = Image.fromarray(background, 'RGB').convert('RGBA')
    foreground_img = Image.fromarray(foreground, 'RGBA')
    # 启动页图标用合成结果：启动窗口底色已改成纯黑，暗底会自动融进背景，只看得见三角
    start_icon = Image.alpha_composite(background_img, foreground_img).convert('RGB')

    for media_dir in MEDIA_DIRS:
        background_img.save(os.path.join(media_dir, 'background.png'))
        foreground_img.save(os.path.join(media_dir, 'foreground.png'))
        print('写入', os.path.join(media_dir, 'background.png'))
        print('写入', os.path.join(media_dir, 'foreground.png'))

    start_path = os.path.join(MEDIA_DIRS[1], 'startIcon.png')
    start_icon.resize((144, 144), Image.LANCZOS).save(start_path)
    print('写入', start_path)


def main():
    background, foreground = build_layers()
    write_outputs(background, foreground)


if __name__ == '__main__':
    main()
