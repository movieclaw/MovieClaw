#!/usr/bin/env bash
# 构建可直接安装的完整正式 APK；密钥由环境变量提供，不写入 Gradle 配置缓存。
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ANDROID_KEYSTORE_PATH:?需要正式签名 keystore 路径}"
: "${ANDROID_KEYSTORE_PASSWORD:?需要 keystore 密码}"
: "${ANDROID_KEY_ALIAS:?需要签名密钥 alias}"
: "${ANDROID_KEY_PASSWORD:?需要签名密钥密码}"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
: "${sdk:?需要 ANDROID_HOME 或 ANDROID_SDK_ROOT}"
tools="$sdk/build-tools/36.0.0"
bash gradlew :app:assembleRelease :app:lintRelease -PrequireNativeLibs=true \
  --no-configuration-cache --no-daemon
mkdir -p build/release
apk="build/release/MovieClaw-Android-arm64.apk"
cp app/build/outputs/apk/release/app-release.apk "$apk"
python3 scripts/build-release-metadata.py "$apk" --aapt2 "$tools/aapt2" \
  --apksigner "$tools/apksigner"
