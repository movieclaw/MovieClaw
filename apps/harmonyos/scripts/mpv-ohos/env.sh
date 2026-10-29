#!/bin/zsh
# MovieClaw mpv 交叉编译环境（aarch64-linux-ohos）
# 被 build-all.sh source；不要单独执行。
# DevEco Studio 自带的 OpenHarmony NDK
export MPV_OHOS_NDK="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
export MPV_OHOS_SCRIPTS_DIR="${0:A:h}"
export MPV_OHOS_BUILD_DIR="$MPV_OHOS_SCRIPTS_DIR/build"
export MPV_OHOS_SRC_DIR="$MPV_OHOS_BUILD_DIR/src"
export MPV_OHOS_PREFIX="$MPV_OHOS_BUILD_DIR/prefix"
export MPV_OHOS_LOGS="$MPV_OHOS_BUILD_DIR/logs"

# 工具链
export MPV_OHOS_TOOLS="$MPV_OHOS_NDK/llvm/bin"
export MPV_OHOS_SYSROOT="$MPV_OHOS_NDK/sysroot"
export CC="$MPV_OHOS_TOOLS/aarch64-unknown-linux-ohos-clang"
export CXX="$MPV_OHOS_TOOLS/aarch64-unknown-linux-ohos-clang++"
export AR="$MPV_OHOS_TOOLS/llvm-ar"
export RANLIB="$MPV_OHOS_TOOLS/llvm-ranlib"
export NM="$MPV_OHOS_TOOLS/llvm-nm"
export STRIP="$MPV_OHOS_TOOLS/llvm-strip"
export LD="$MPV_OHOS_TOOLS/ld.lld"

# 目标 sysroot 库目录（musl + OHOS 系统 .so 都在这里）
export MPV_OHOS_TARGET_LIB="$MPV_OHOS_SYSROOT/usr/lib/aarch64-linux-ohos"

# 通用编译参数：PIC（静态库要链进 libmpv.so）+ musl 标记
export MPV_OHOS_CFLAGS="-D__MUSL__ -fPIC -O2"
export MPV_OHOS_LDFLAGS="-fPIC -L$MPV_OHOS_PREFIX/lib -L$MPV_OHOS_TARGET_LIB"

# 依赖发现：所有自编库装在 prefix
export PKG_CONFIG_PATH="$MPV_OHOS_PREFIX/lib/pkgconfig"

# 版本固定
export MPV_OHOS_FFMPEG_REPO="https://github.com/dex2oat/FFmpeg.git"
export MPV_OHOS_FFMPEG_REF="dd2976b9"          # master @ 2026-01-22，含 ohcodec/hwcontext_oh
export MPV_OHOS_MPV_REPO="https://github.com/dex2oat/mpv.git"
export MPV_OHOS_MPV_REF="d974ee33"             # master @ 2026-04-19，含 ohos vo/ao/hwdec
export MPV_OHOS_ZLIB_REF="v1.3.1"
export MPV_OHOS_FREETYPE_REF="VER-2-13-3"
export MPV_OHOS_FRIBIDI_REF="v1.0.16"
export MPV_OHOS_HARFBUZZ_REF="8.5.1"
export MPV_OHOS_LIBASS_VER="0.17.4"
export MPV_OHOS_MBEDTLS_REF="mbedtls-2.28.9"

# app 侧产物路径
export MPV_OHOS_APP_LIBS_DIR="$MPV_OHOS_SCRIPTS_DIR/../../entry/libs/arm64-v8a"
export MPV_OHOS_APP_CPP_DIR="$MPV_OHOS_SCRIPTS_DIR/../../entry/src/main/cpp"

_ohos_env_ready() {
  [ -d "$MPV_OHOS_NDK/llvm/bin" ] || { echo "❌ 找不到 OHOS NDK: $MPV_OHOS_NDK"; return 1; }
  [ -x "$CC" ] || { echo "❌ 找不到交叉编译器: $CC"; return 1; }
  command -v meson >/dev/null && command -v ninja >/dev/null && command -v cmake >/dev/null \
    || { echo "❌ 需要 meson/ninja/cmake（brew install meson ninja cmake）"; return 1; }
  return 0
}
