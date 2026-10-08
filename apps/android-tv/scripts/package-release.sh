#!/usr/bin/env bash
# 构建可直接安装的 Android TV 正式 APK（docs/design/android-release.md「Android TV」）。
#
# 签名与手机版共用同一把正式密钥（同一组 ANDROID_KEYSTORE_* 环境变量 / GitHub Secrets）；版本独立，
# 唯一来源 version.properties。FFmpeg 音频解码库没编过时先编（native/ffmpeg/build.sh，要 NDK），
# 正式包必须带上它：-PrequireFfmpeg=true 缺库即失败。
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ANDROID_KEYSTORE_PATH:?需要正式签名 keystore 路径}"
: "${ANDROID_KEYSTORE_PASSWORD:?需要 keystore 密码}"
: "${ANDROID_KEY_ALIAS:?需要签名密钥 alias}"
: "${ANDROID_KEY_PASSWORD:?需要签名密钥密码}"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
: "${sdk:?需要 ANDROID_HOME 或 ANDROID_SDK_ROOT}"
if [[ ! -d core/ffmpeg/src/main/jni/ffmpeg/android-libs ]]; then
  NDK="${NDK:-$sdk/ndk/27.3.13750724}" bash native/ffmpeg/build.sh
fi
bash gradlew :app:assembleRelease :app:lintRelease -PrequireFfmpeg=true --no-configuration-cache --no-daemon
tools="$(ls -d "$sdk"/build-tools/* | sort -V | tail -1)"
mkdir -p build/release
apk="build/release/MovieClaw-AndroidTV.apk"
cp app/build/outputs/apk/release/app-release.apk "$apk"
python3 scripts/build-release-metadata.py "$apk" --aapt2 "$tools/aapt2" --apksigner "$tools/apksigner"
