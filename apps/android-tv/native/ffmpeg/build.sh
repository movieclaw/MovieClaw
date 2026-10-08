#!/usr/bin/env bash
# 编 FFmpeg 音频解码库给 core/ffmpeg（Media3 decoder_ffmpeg 扩展）用（docs/design/androidtv-app.md §4.3）。
#
# 许可：只按 LGPL-2.1 编——不开 --enable-gpl / --enable-nonfree / --enable-version3；编成独立的共享库
# （libavcodec.so、libavutil.so、libswresample.so）动态链接，不静态并进 App 的代码。只启用音频解码器。
#
# 产物不入库：写到 core/ffmpeg/src/main/jni/ffmpeg/（.gitignore 已排除），模块看到它才开 CMake 编 JNI 胶水层；
# 没跑过这个脚本时模块是纯 Java，App 照常能编，只是没有 FFmpeg 软解（TrueHD / DTS 交给透传或服务端转音轨）。
#
#   NDK=~/Library/Android/sdk/ndk/27.3.13750724 apps/android-tv/native/ffmpeg/build.sh
#
# 版本与校验和固定：换版本时一起改，并核对「关于 → 开源许可」里写的版本号。
set -euo pipefail

FFMPEG_VERSION="6.0.1"
FFMPEG_SHA256="9b16b8731d78e596b4be0d720428ca42df642bb2d78342881ff7f5bc29fc9623"
# 电视与盒子：64 位为主，老盒子还有 32 位
ABIS=(arm64-v8a armeabi-v7a)
# 与 minSdk 一致
API=23
DECODERS=(ac3 eac3 truehd mlp dca flac alac mp3 mp2 vorbis opus)

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../core/ffmpeg/src/main/jni/ffmpeg"
WORK="${WORK:-${TMPDIR:-/tmp}/movieclaw-ffmpeg-build}"
NDK="${NDK:?设置 NDK 为 Android NDK 目录，例如 ~/Library/Android/sdk/ndk/27.3.13750724}"
case "$(uname -s)" in
  Darwin) HOST=darwin-x86_64 ;;
  Linux) HOST=linux-x86_64 ;;
  *) echo "不支持的系统 $(uname -s)" >&2; exit 1 ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
[[ -d "$TOOLCHAIN" ]] || { echo "NDK 目录不对：$TOOLCHAIN 不存在" >&2; exit 1; }

mkdir -p "$WORK"
TARBALL="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
if [[ ! -f "$TARBALL" ]]; then
  curl -sSfL -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
fi
if command -v sha256sum > /dev/null; then
  echo "$FFMPEG_SHA256  $TARBALL" | sha256sum -c -
else
  echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c -
fi
rm -rf "$WORK/src" && mkdir -p "$WORK/src"
tar -xJf "$TARBALL" -C "$WORK/src" --strip-components=1

OPTIONS=(
  --target-os=android --enable-cross-compile
  --enable-shared --disable-static --enable-pic
  --disable-doc --disable-programs --disable-everything
  --disable-avdevice --disable-avformat --disable-swscale --disable-postproc --disable-avfilter
  --enable-swresample --disable-symver --disable-v4l2-m2m --disable-vulkan
  --nm="$TOOLCHAIN/llvm-nm" --ar="$TOOLCHAIN/llvm-ar" --ranlib="$TOOLCHAIN/llvm-ranlib" --strip="$TOOLCHAIN/llvm-strip"
)
for decoder in "${DECODERS[@]}"; do OPTIONS+=("--enable-decoder=$decoder"); done
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

rm -rf "$OUT" && mkdir -p "$OUT"
cd "$WORK/src"
for abi in "${ABIS[@]}"; do
  case "$abi" in
    arm64-v8a) arch=aarch64 cpu=armv8-a prefix="aarch64-linux-android$API-" extra=() ;;
    armeabi-v7a) arch=arm cpu=armv7-a prefix="armv7a-linux-androideabi$API-" extra=(--extra-cflags="-march=armv7-a -mfloat-abi=softfp") ;;
  esac
  ./configure --prefix="$WORK/install/$abi" --libdir="$OUT/android-libs/$abi" --shlibdir="$OUT/android-libs/$abi" \
    --arch="$arch" --cpu="$cpu" --cc="$TOOLCHAIN/${prefix}clang" --cxx="$TOOLCHAIN/${prefix}clang++" \
    "${extra[@]}" "${OPTIONS[@]}" > "$WORK/configure-$abi.log"
  make -j"$JOBS" > "$WORK/make-$abi.log"
  make install-libs > /dev/null
  make clean > /dev/null
done
# 头文件各 ABI 相同，装一份；JNI 胶水层按源码树的布局 include（libavcodec/avcodec.h …）
make install-headers prefix="$WORK/install/headers" > /dev/null
cp -R "$WORK/install/headers/include/." "$OUT/"
# 头文件里的 avconfig.h / ffversion.h 是 configure 生成的，install-headers 已带上
{
  echo "FFmpeg $FFMPEG_VERSION（LGPL-2.1，未启用 GPL / nonfree / version3）"
  echo "源码：https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz（sha256 $FFMPEG_SHA256）"
  echo "编译脚本：apps/android-tv/native/ffmpeg/build.sh"
  echo "解码器：${DECODERS[*]}"
} > "$OUT/BUILD-INFO.txt"
find "$OUT/android-libs" -name "*.so" -exec ls -la {} \;
