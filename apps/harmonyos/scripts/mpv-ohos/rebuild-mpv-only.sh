#!/usr/bin/env bash
# 只重建 mpv + 导出（跳过 ffmpeg 及其余依赖的全量重建）。
# 适用：只改了 mpv 侧补丁（patches/apply-*.py，不改 PATCHES_VER）之后。
# PATCHES_VER 保持不变 → check_patch_version 不触发，手动删 mpv.stamp 即可；
# ffmpeg.stamp 完好 → build_ffmpeg 显示「已构建」直接跳过（省 ~10 分钟）。
# 用法: bash rebuild-mpv-only.sh
set -e
cd "$(dirname "$0")"
rm -f build/locks/mpv.stamp
bash build-all.sh
