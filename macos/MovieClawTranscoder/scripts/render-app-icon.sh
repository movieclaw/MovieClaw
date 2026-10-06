#!/usr/bin/env bash
# 从已锁定的三角循环 PNG 母版生成 Resources/AppIcon.icns。
# 保留设计稿的极光色光、外溢光、圆角和投影，避免原生绘制改变已确认的图标。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="${PROJECT_DIR}/../../docs/brand/transcoder/app-icon-1024.png"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/AppIcon.iconset"

for spec in \
    icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 \
    icon_128x128:128 icon_128x128@2x:256 icon_256x256:256 icon_256x256@2x:512 \
    icon_512x512:512 icon_512x512@2x:1024; do
    name="${spec%:*}"
    pixels="${spec##*:}"
    target="${WORK}/AppIcon.iconset/${name}.png"
    if [ "${pixels}" = 1024 ]; then
        cp "${MASTER}" "${target}"
    else
        sips -z "${pixels}" "${pixels}" "${MASTER}" --out "${target}" >/dev/null
    fi
done
iconutil -c icns "${WORK}/AppIcon.iconset" -o "${PROJECT_DIR}/Resources/AppIcon.icns"
echo "已生成：${PROJECT_DIR}/Resources/AppIcon.icns"
