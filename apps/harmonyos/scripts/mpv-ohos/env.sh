#!/usr/bin/env bash
# MovieClaw mpv 交叉编译环境（aarch64-linux-ohos）
# 被 build-all.sh source；不要单独执行。
# 平台: macOS / Linux / Windows(Cygwin|MSYS Git Bash)。
# Windows 注意: DevEco 的 OHOS NDK 默认装在带空格路径（"D:\DevEco Studio"），shell/make 处理不了，
#   先建无空格 junction（PowerShell，无需管理员）：
#   New-Item -ItemType Junction C:\Users\<user>\ohos-ndk -Target "D:\DevEco Studio\sdk\default\openharmony\native"
#   然后默认用该路径，或用 OHOS_NDK_JUNCTION 环境变量覆盖。

# ---------- 平台检测 ----------
_ostype="$(uname -s)"
case "$_ostype" in
  Darwin)              export MPV_OHOS_HOST=mac ;;
  CYGWIN*|MSYS*|MINGW*) export MPV_OHOS_HOST=windows ;;
  Linux*)              export MPV_OHOS_HOST=linux ;;
  *) echo "未知平台: $_ostype"; return 1 2>/dev/null || exit 1 ;;
esac

case "$MPV_OHOS_HOST" in
  mac)
    export MPV_OHOS_NDK="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
    ;;
  linux)
    # Linux 版 OHOS NDK（commandline-tools 解压后）；路径可用 OHOS_NDK_HOME 覆盖
    export MPV_OHOS_NDK="${OHOS_NDK_HOME:-$HOME/ohos-ndk}"
    ;;
  windows)
    export MPV_OHOS_NDK="${OHOS_NDK_JUNCTION:-C:/Users/wtj20/ohos-ndk}"
    # 路径统一 Windows 混合形式（盘符:/前斜杠）：native 工具（cmake/meson/pkg-config）吃 Windows 路径；
    # PATH 条目在下方单独用 cygpath -u 转 POSIX（Cygwin 的 PATH 用冒号分隔，C: 会被拆断）。
    export MPV_OHOS_NDK="$(cygpath -m "$MPV_OHOS_NDK")"
    export MPV_OHOS_SCRIPTS_DIR="$(cygpath -m "${MPV_OHOS_SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}")"
    ;;
esac

export MPV_OHOS_SCRIPTS_DIR="${MPV_OHOS_SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
export MPV_OHOS_BUILD_DIR="$MPV_OHOS_SCRIPTS_DIR/build"
export MPV_OHOS_SRC_DIR="$MPV_OHOS_BUILD_DIR/src"
export MPV_OHOS_PREFIX="$MPV_OHOS_BUILD_DIR/prefix"
export MPV_OHOS_LOGS="$MPV_OHOS_BUILD_DIR/logs"

# ---------- 工具链 ----------
export MPV_OHOS_TOOLS="$MPV_OHOS_NDK/llvm/bin"
export MPV_OHOS_SYSROOT="$MPV_OHOS_NDK/sysroot"

if [ "$MPV_OHOS_HOST" = windows ]; then
  # SDK 自带的 sh wrapper 会 readlink 解析回带空格的真实路径（exec 断词），Windows 上不可用；
  # 自建 wrapper：clang.exe + --target + --sysroot。
  _w="$MPV_OHOS_SCRIPTS_DIR/build/tools-win"
  mkdir -p "$_w"
  printf '#!/bin/sh\nexec "%s/clang.exe" --target=aarch64-unknown-linux-ohos --sysroot="%s" "$@"\n' \
    "$MPV_OHOS_TOOLS" "$MPV_OHOS_SYSROOT" > "$_w/aarch64-unknown-linux-ohos-clang"
  printf '#!/bin/sh\nexec "%s/clang++.exe" --target=aarch64-unknown-linux-ohos --sysroot="%s" "$@"\n' \
    "$MPV_OHOS_TOOLS" "$MPV_OHOS_SYSROOT" > "$_w/aarch64-unknown-linux-ohos-clang++"
  chmod +x "$_w/aarch64-unknown-linux-ohos-clang" "$_w/aarch64-unknown-linux-ohos-clang++"
  # PATH: 自建 wrapper + pkg-config（build/tools-win/bin）+ SDK 自带 cmake/ninja + pip meson
  # PATH 条目必须 POSIX 形式（cygpath -u），否则 C: 的冒号会拆断 Cygwin 的 PATH 解析
  PATH="$(cygpath -u "$_w"):$PATH"
  [ -d "$_w/bin" ] && PATH="$(cygpath -u "$_w/bin"):$PATH"
  PATH="$(cygpath -u "$MPV_OHOS_NDK/build-tools/cmake/bin"):$PATH"
  # mingw-w64 gcc（build/tools-win/mingw/mingw64，MSYS2 仓库包）：fribidi 等 meson 组件要在构建机上
  # 编译并运行原生生成器，meson 的 build-machine 编译器只从 PATH 找（不用 env CC）——
  # mac 上由 /usr/bin/cc 顶住，Windows 用这套补齐（安装步骤见 RUNBOOK-HWDEC.md）
  [ -d "$_w/mingw/mingw64/bin" ] && PATH="$(cygpath -u "$_w/mingw/mingw64/bin"):$PATH"
  # hermes 自带的 /usr/bin/make.exe 是 32 位 PE32 孤儿（加载即失败）；用 MSYS2 msys 仓库的 64 位 make
  #（build/tools-win/msys/usr/bin，运行时直接用本环境已有的 /usr/bin/msys-2.0.dll）
  [ -d "$_w/msys/usr/bin" ] && PATH="$(cygpath -u "$_w/msys/usr/bin"):$PATH"
  export PATH
  if ! command -v meson >/dev/null 2>&1; then
    _py="$(command -v python || command -v python3 || true)"
    [ -n "$_py" ] && PATH="$(dirname "$_py")/Scripts:$PATH" && export PATH
  fi
  export CC="$_w/aarch64-unknown-linux-ohos-clang"
  export CXX="$_w/aarch64-unknown-linux-ohos-clang++"
  # cmake/meson 是 native 进程跑不动 sh wrapper，直接用 clang.exe + --target（见 meson-cross.txt / ohos-toolchain.cmake）
  export MPV_OHOS_CC_NATIVE="$MPV_OHOS_TOOLS/clang.exe"
  export MPV_OHOS_CXX_NATIVE="$MPV_OHOS_TOOLS/clang++.exe"
  export MPV_OHOS_TARGET_TRIPLE=aarch64-unknown-linux-ohos
  # git 默认 autocrlf 会把克隆下来的源码检出成 CRLF，破坏 ./configure —— 本环境内克隆强制 LF；
  # 这台机器的 git(Git for Windows) 默认 Schannel，吊销检查离线必挂（CRYPT_E_REVOCATION_OFFLINE），
  # https 一律切 openssl 后端（GIT_CONFIG env 注入，环境内所有 git 调用生效，git>=2.31）
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0=core.autocrlf
  export GIT_CONFIG_VALUE_0=false
  export GIT_CONFIG_KEY_1=http.sslBackend
  export GIT_CONFIG_VALUE_1=openssl
  # 同机 Windows curl 也是 Schannel：github https 需要 --ssl-no-revoke（Linux/macOS 的 curl 不认此参，保持空）
  export MPV_OHOS_CURL_FLAGS="--ssl-no-revoke"
  # MSYS 系 spawn 层会把 /d/… 参数自动转换成 D:/…（上面 meson 的 --prefix /d/… 被改回 D:/… 即此因）。
  # 本构建所有参数要么本就是 Windows 形式（D:/…），要么特意用 POSIX 形式（/d/… + 盘根 junction），
  # 全局关闭参数自动转换；PATH 等环境变量转换不受影响（那是 MSYS2_ENV_CONV_EXCL 管的）。
  export MSYS2_ARG_CONV_EXCL='*'
  # meson 交叉编译按“目标主机(linux)”规则校验 prefix，必须是 POSIX 绝对路径（/ 开头）——D:/ 会被拒
  # （sanitize_prefix → PurePosixPath.is_absolute）。转成 /d/… 后：
  #   - bash/Cygwin 侧：/d 就是挂载点，天然解析；
  #   - native 侧（meson install / clang -L / pkg-config）：/d/… 按“当前盘根相对”解析 → D:\d\…，
  #     依赖盘根 junction（cmd /c mklink /J D:\d D:\，_ohos_env_ready 会检查），
  #     且要求所有 native 子进程 cwd 在 D: 盘 —— build-all.sh 开头 cd 到 build 目录保证这一点。
  export MPV_OHOS_PREFIX="$(cygpath -u "$MPV_OHOS_PREFIX")"
  # Windows 的 python3 常是 WindowsApps 占位符，优先 python
  export MPV_OHOS_PYTHON="$(command -v python || command -v python3)"
else
  export CC="$MPV_OHOS_TOOLS/aarch64-unknown-linux-ohos-clang"
  export CXX="$MPV_OHOS_TOOLS/aarch64-unknown-linux-ohos-clang++"
  export MPV_OHOS_CC_NATIVE="$CC"
  export MPV_OHOS_CXX_NATIVE="$CXX"
  export MPV_OHOS_PYTHON="$(command -v python3 || command -v python)"
fi

if [ "$MPV_OHOS_HOST" = windows ]; then _ext=".exe"; else _ext=""; fi
export AR="$MPV_OHOS_TOOLS/llvm-ar$_ext"
export RANLIB="$MPV_OHOS_TOOLS/llvm-ranlib$_ext"
export NM="$MPV_OHOS_TOOLS/llvm-nm$_ext"
export STRIP="$MPV_OHOS_TOOLS/llvm-strip$_ext"
export LD="$MPV_OHOS_TOOLS/ld.lld$_ext"
export MPV_OHOS_READELF="$MPV_OHOS_TOOLS/llvm-readelf$_ext"

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
export MPV_OHOS_HARFBUZZ_REF="8.5.0"
export MPV_OHOS_LIBASS_VER="0.17.4"
export MPV_OHOS_MBEDTLS_REF="mbedtls-2.28.9"

# app 侧产物路径
export MPV_OHOS_APP_LIBS_DIR="$MPV_OHOS_SCRIPTS_DIR/../../entry/libs/arm64-v8a"
export MPV_OHOS_APP_CPP_DIR="$MPV_OHOS_SCRIPTS_DIR/../../entry/src/main/cpp"

_ohos_env_ready() {
  [ -d "$MPV_OHOS_NDK/llvm/bin" ] || { echo "❌ 找不到 OHOS NDK: $MPV_OHOS_NDK"; return 1; }
  [ -x "$MPV_OHOS_CC_NATIVE" ] || { echo "❌ 找不到交叉编译器: $MPV_OHOS_CC_NATIVE"; return 1; }
  command -v meson >/dev/null && command -v ninja >/dev/null && command -v cmake >/dev/null \
    || { echo "❌ 需要 meson/ninja/cmake（macOS: brew install meson ninja cmake；Windows: pip install meson + SDK 自带 cmake/ninja）"; return 1; }
  if [ "$MPV_OHOS_HOST" = windows ]; then
    # /d/… 前缀的 native 解析依赖盘根 junction：/d/… → D:\d\… → D:\…
    local _drv="${MPV_OHOS_PREFIX#/}"; _drv="${_drv%%/*}"
    [ -n "$_drv" ] && [ -d "/$_drv/$_drv" ] \
      || { echo "❌ 缺少盘根 junction /$_drv/$_drv（管理员不要求）：cmd /c mklink /J $(echo $_drv | tr a-z A-Z):\\$_drv $(echo $_drv | tr a-z A-Z):\\"; return 1; }
  fi
  return 0
}
