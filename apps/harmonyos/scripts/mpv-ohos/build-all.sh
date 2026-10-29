#!/bin/zsh
# MovieClaw libmpv (dex2oat/mpv + OHCodec 硬解) aarch64-linux-ohos 交叉编译流水线
#
# 产物:
#   entry/libs/arm64-v8a/libmpv.so            —— 单文件播放引擎（静态链入 ffmpeg/libass/依赖）
#   entry/src/main/cpp/include/mpv/*.h        —— NAPI 封装用的头文件
#
# 依赖链: zlib → freetype → fribidi → harfbuzz → libass → mbedtls → ffmpeg(ohcodec) → mpv(ohos)
# 增量: 每个组件有 build/locks/<name>.stamp，存在即跳过；强制重建删对应 stamp 或整目录。
#
# 注意: fork 的 meson.build 引用了两个不存在的文件（vo_ohcodec.c / vo_ohcodec_osd.c），
#       本脚本用 patches/apply-mpv-patch.py 打补丁移除，改走 vo_gpu + egl-ohos + hwdec=ohcodec 路径。

set -eu -o pipefail
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/env.sh"
_ohos_env_ready || exit 1

mkdir -p "$MPV_OHOS_SRC_DIR" "$MPV_OHOS_PREFIX/lib/pkgconfig" "$MPV_OHOS_PREFIX/include" \
         "$MPV_OHOS_LOGS" "$MPV_OHOS_BUILD_DIR/locks" "$MPV_OHOS_BUILD_DIR/out"

NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)

# ---------- 基础设施 ----------

log_run() { # log_run <name> <cmd...>
  local name="$1"; shift
  echo "▶ [$name] $*" | tee -a "$MPV_OHOS_LOGS/$name.log"
  "$@" >>"$MPV_OHOS_LOGS/$name.log" 2>&1
}

step() { echo "===== $* ====="; }

stamp_ok() { [ -f "$MPV_OHOS_BUILD_DIR/locks/$1.stamp" ]; }
touch_stamp() { date "+%Y-%m-%d %H:%M:%S $1" >"$MPV_OHOS_BUILD_DIR/locks/$1.stamp"; }

# git clone --depth 1 并钉到指定 ref（ref 是 sha 时先浅克隆默认分支再 fetch 补齐）
fetch_pin() { # fetch_pin <name> <repo> <ref>
  local name="$1"
  local repo="$2"
  local ref="$3"
  local dir="$MPV_OHOS_SRC_DIR/$name"
  if [ -d "$dir/.git" ]; then
    echo "✔ [$name] 源码已存在"
  else
    step "fetch $name ($repo)"
    git clone --depth 1 "$repo" "$dir" >>"$MPV_OHOS_LOGS/fetch.log" 2>&1
  fi
  local cur
  cur=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)
  if [ "$cur" != "$ref" ] && [[ "$ref" =~ ^[0-9a-f]{8,}$ ]]; then
    git -C "$dir" fetch --depth 1 origin "$ref" >>"$MPV_OHOS_LOGS/fetch.log" 2>&1 \
      && git -C "$dir" checkout --detach "$ref" >>"$MPV_OHOS_LOGS/fetch.log" 2>&1
  elif [[ "$ref" != HEAD ]] && [[ ! "$ref" =~ ^[0-9a-f]{8,}$ ]]; then
    # tag：fetch 指定 tag 后按 FETCH_HEAD 检出（fetch 不建本地引用）
    git -C "$dir" fetch --depth 1 origin "refs/tags/$ref" >>"$MPV_OHOS_LOGS/fetch.log" 2>&1
    git -C "$dir" checkout --detach FETCH_HEAD >>"$MPV_OHOS_LOGS/fetch.log" 2>&1
  fi
  echo "  [$name] @ $(git -C "$dir" rev-parse --short HEAD)"
}

meson_build() { # meson_build <name> <srcdir> [extra meson options...]
  local name="$1" src="$2"; shift 2
  log_run "$name" meson setup "$MPV_OHOS_BUILD_DIR/out/$name" "$src" \
    --cross-file "$SCRIPT_DIR/meson-cross.txt" \
    --prefix "$MPV_OHOS_PREFIX" --default-library=static --buildtype=release "$@"
  log_run "$name" meson compile -C "$MPV_OHOS_BUILD_DIR/out/$name"
  log_run "$name" meson install -C "$MPV_OHOS_BUILD_DIR/out/$name"
}

# ---------- 依赖组件 ----------

build_zlib() {
  if stamp_ok zlib; then echo "✔ zlib 已构建"; return 0; fi
  fetch_pin zlib https://github.com/madler/zlib.git "$MPV_OHOS_ZLIB_REF"
  step "build zlib"
  log_run zlib cmake -S "$MPV_OHOS_SRC_DIR/zlib" -B "$MPV_OHOS_BUILD_DIR/out/zlib" \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/ohos-toolchain.cmake" \
    -DCMAKE_INSTALL_PREFIX="$MPV_OHOS_PREFIX" -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
  log_run zlib cmake --build "$MPV_OHOS_BUILD_DIR/out/zlib" -j "$NPROC"
  log_run zlib cmake --install "$MPV_OHOS_BUILD_DIR/out/zlib"
  touch_stamp zlib
}

build_freetype() {
  if stamp_ok freetype; then echo "✔ freetype 已构建"; return 0; fi
  fetch_pin freetype https://github.com/freetype/freetype.git "$MPV_OHOS_FREETYPE_REF"
  step "build freetype"
  meson_build freetype "$MPV_OHOS_SRC_DIR/freetype" \
    -Dzlib=enabled -Dpng=disabled -Dharfbuzz=disabled -Dbrotli=disabled -Dbzip2=disabled
  touch_stamp freetype
}

build_fribidi() {
  if stamp_ok fribidi; then echo "✔ fribidi 已构建"; return 0; fi
  fetch_pin fribidi https://github.com/fribidi/fribidi.git "$MPV_OHOS_FRIBIDI_REF"
  step "build fribidi"
  meson_build fribidi "$MPV_OHOS_SRC_DIR/fribidi" -Ddocs=false -Dtests=false
  touch_stamp fribidi
}

build_harfbuzz() {
  if stamp_ok harfbuzz; then echo "✔ harfbuzz 已构建"; return 0; fi
  fetch_pin harfbuzz https://github.com/harfbuzz/harfbuzz.git "$MPV_OHOS_HARFBUZZ_REF"
  step "build harfbuzz"
  meson_build harfbuzz "$MPV_OHOS_SRC_DIR/harfbuzz" \
    -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled -Dfreetype=disabled \
    -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled -Dbenchmark=disabled \
    -Dutilities=disabled
  touch_stamp harfbuzz
}

build_libass() {
  if stamp_ok libass; then echo "✔ libass 已构建"; return 0; fi
  step "build libass $MPV_OHOS_LIBASS_VER"
  local tarball="$MPV_OHOS_SRC_DIR/libass-$MPV_OHOS_LIBASS_VER.tar.gz"
  local src="$MPV_OHOS_SRC_DIR/libass"
  if [ ! -d "$src" ]; then
    log_run libass curl -L --fail -o "$tarball" \
      "https://github.com/libass/libass/releases/download/$MPV_OHOS_LIBASS_VER/libass-$MPV_OHOS_LIBASS_VER.tar.gz"
    mkdir -p "$src"
    tar -xzf "$tarball" -C "$src" --strip-components=1
  fi
  local bdir="$MPV_OHOS_BUILD_DIR/out/libass"
  rm -rf "$bdir" && mkdir -p "$bdir"
  local configure_args=(--host=aarch64-linux-ohos --prefix="$MPV_OHOS_PREFIX"
    --disable-shared --enable-static --with-pic
    --disable-fontconfig --disable-coretext --disable-directwrite
    --disable-require-system-font-provider)
  ( cd "$bdir" && log_run libass "$src/configure" "${configure_args[@]}" ) || {
    echo "  config.sub 不认识 ohos，退回 aarch64-linux 重试"
    ( cd "$bdir" && log_run libass "$src/configure" --host=aarch64-linux "${configure_args[@]:1}" )
  }
  log_run libass make -C "$bdir" -j "$NPROC"
  log_run libass make -C "$bdir" install
  touch_stamp libass
}

build_libplacebo() {
  if stamp_ok libplacebo; then echo "✔ libplacebo 已构建"; return 0; fi
  fetch_pin libplacebo https://github.com/haasn/libplacebo.git "v7.351.0"
  # fast_float 是 header-only 的 3rdparty submodule（转义数字解析必需）
  git -C "$MPV_OHOS_SRC_DIR/libplacebo" submodule update --init --depth 1 \
    3rdparty/fast_float >>"$MPV_OHOS_LOGS/fetch.log" 2>&1
  step "build libplacebo (最小化：纯 C，无 vulkan/glslang/dovi)"
  meson_build libplacebo "$MPV_OHOS_SRC_DIR/libplacebo" \
    -Dvulkan=disabled -Dopengl=disabled -Dglslang=disabled -Dshaderc=disabled \
    -Dd3d11=disabled -Ddovi=disabled -Ddemos=false -Dtests=false -Dxxhash=disabled \
    -Dlibdovi=disabled
  touch_stamp libplacebo
}

build_mbedtls() {
  if stamp_ok mbedtls; then echo "✔ mbedtls 已构建"; return 0; fi
  fetch_pin mbedtls https://github.com/Mbed-TLS/mbedtls.git "$MPV_OHOS_MBEDTLS_REF"
  step "build mbedtls"
  log_run mbedtls cmake -S "$MPV_OHOS_SRC_DIR/mbedtls" -B "$MPV_OHOS_BUILD_DIR/out/mbedtls" \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/ohos-toolchain.cmake" \
    -DCMAKE_INSTALL_PREFIX="$MPV_OHOS_PREFIX" -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_INSTALL_LIBDIR=lib
  log_run mbedtls cmake --build "$MPV_OHOS_BUILD_DIR/out/mbedtls" -j "$NPROC"
  log_run mbedtls cmake --install "$MPV_OHOS_BUILD_DIR/out/mbedtls"
  touch_stamp mbedtls
}

build_ffmpeg() {
  if stamp_ok ffmpeg; then echo "✔ ffmpeg 已构建"; return 0; fi
  fetch_pin ffmpeg "$MPV_OHOS_FFMPEG_REPO" "$MPV_OHOS_FFMPEG_REF"
  step "build ffmpeg (ohcodec + mbedtls, LGPL, static PIC)"
  local cfg="$MPV_OHOS_BUILD_DIR/out/ffmpeg"
  rm -rf "$cfg" && mkdir -p "$cfg"
  ( cd "$cfg" && log_run ffmpeg "$MPV_OHOS_SRC_DIR/ffmpeg/configure" \
    --prefix="$MPV_OHOS_PREFIX" \
    --enable-cross-compile --target-os=linux --arch=aarch64 \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
    --pkg-config=pkg-config \
    --sysroot="$MPV_OHOS_SYSROOT" \
    --extra-cflags="-D__MUSL__" \
    --extra-ldflags="-L$MPV_OHOS_PREFIX/lib -L$MPV_OHOS_TARGET_LIB" \
    --enable-static --disable-shared --enable-pic \
    --disable-programs --disable-doc --disable-debug \
    --disable-avdevice \
    --disable-autodetect \
    --enable-version3 \
    --enable-ohcodec \
    --enable-mbedtls \
    --disable-protocol=rtmps --disable-protocol=rtmpte --disable-protocol=rtmpts \
    --disable-protocol=ffrtmpcrypt \
    --enable-zlib --enable-iconv --enable-network \
    --pkg-config-flags=--static )
  log_run ffmpeg make -C "$cfg" -j "$NPROC"
  log_run ffmpeg make -C "$cfg" install
  touch_stamp ffmpeg
}

build_mpv() {
  if stamp_ok mpv; then echo "✔ mpv 已构建"; return 0; fi
  fetch_pin mpv "$MPV_OHOS_MPV_REPO" "$MPV_OHOS_MPV_REF"
  step "patch mpv meson.build（移除不存在的 vo_ohcodec 引用）"
  python3 "$SCRIPT_DIR/patches/apply-mpv-patch.py" "$MPV_OHOS_SRC_DIR/mpv/meson.build" | tee -a "$MPV_OHOS_LOGS/mpv.log"
  step "patch mpv options.h（补上漏提交的 ohos_surface_size 成员）"
  python3 "$SCRIPT_DIR/patches/apply-mpv-patch.py" "$MPV_OHOS_SRC_DIR/mpv/options/options.h" | tee -a "$MPV_OHOS_LOGS/mpv.log"
  step "patch mpv ohos_common.c（ff_ohcodec_discard_buffer 符号错位 → no-op）"
  python3 "$SCRIPT_DIR/patches/apply-mpv-patch.py" "$MPV_OHOS_SRC_DIR/mpv/video/out/ohos_common.c" | tee -a "$MPV_OHOS_LOGS/mpv.log"
  step "patch mpv vo.c（移除缺失的 vo_ohcodec 驱动注册）"
  python3 "$SCRIPT_DIR/patches/apply-mpv-patch.py" "$MPV_OHOS_SRC_DIR/mpv/video/out/vo.c" | tee -a "$MPV_OHOS_LOGS/mpv.log"
  step "patch mpv context_ohos.c（真机 EGL surface 创建兜底）"
  python3 "$SCRIPT_DIR/patches/apply-egl-fix.py" "$MPV_OHOS_SRC_DIR/mpv/video/out/opengl/context_ohos.c" | tee -a "$MPV_OHOS_LOGS/mpv.log"
  step "patch ao_ohaudio.c（音频焦点中断 → 嵌入方钩子）"
  python3 "$SCRIPT_DIR/patches/apply-ao-patch.py" "$MPV_OHOS_SRC_DIR/mpv/audio/out/ao_ohaudio.c" | tee -a "$MPV_OHOS_LOGS/mpv.log"
  step "build libmpv (ohos EGL + OHCodec hwdec + ohaudio)"
  rm -rf "$MPV_OHOS_BUILD_DIR/out/mpv"
  log_run mpv meson setup "$MPV_OHOS_BUILD_DIR/out/mpv" "$MPV_OHOS_SRC_DIR/mpv" \
    --cross-file "$SCRIPT_DIR/meson-cross.txt" \
    --prefix "$MPV_OHOS_PREFIX" --default-library=shared --buildtype=release \
    -Dlibmpv=true -Dcplayer=false -Dgpl=false \
    -Dohos=enabled -Degl-ohos=enabled \
    -Dvulkan=disabled -Dshaderc=disabled \
    -Dlua=disabled -Djavascript=disabled -Duchardet=disabled -Dlibarchive=disabled \
    -Dlibavdevice=disabled -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled -Ddvbin=disabled \
    -Dvaapi=disabled -Dvdpau=disabled -Ddrm=disabled -Dgbm=disabled \
    -Dwayland=disabled -Dx11=disabled -Dxv=disabled -Degl=disabled \
    -Dalsa=disabled -Dpulse=disabled -Dpipewire=disabled -Djack=disabled -Dopenal=disabled \
    -Doss-audio=disabled -Dsndio=disabled -Daudiounit=disabled -Davfoundation=disabled \
    -Dcoreaudio=disabled -Dwasapi=disabled -Ddirect3d=disabled -Dd3d11=disabled \
    -Daudiotrack=disabled -Daaudio=disabled -Dopensles=disabled -Dandroid-media-ndk=disabled \
    -Djpeg=disabled -Drubberband=disabled -Dlcms2=disabled -Dzimg=disabled \
    -Dvapoursynth=disabled -Dsixel=disabled -Dcaca=disabled \
    -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
    -Dtests=false -Dfuzzers=false \
    -Dzlib=enabled -Diconv=enabled
  log_run mpv meson compile -C "$MPV_OHOS_BUILD_DIR/out/mpv"
  log_run mpv meson install -C "$MPV_OHOS_BUILD_DIR/out/mpv"
  touch_stamp mpv
}

export_lib() {
  step "export libmpv.so + headers → app"
  local so="$MPV_OHOS_PREFIX/lib/libmpv.so"
  [ -f "$so" ] || { echo "❌ libmpv.so 不存在"; exit 1; }
  mkdir -p "$MPV_OHOS_APP_LIBS_DIR" "$MPV_OHOS_APP_CPP_DIR/include"
  "$STRIP" --strip-unneeded "$so" -o "$MPV_OHOS_APP_LIBS_DIR/libmpv.so"
  # meson 给 libmpv 设了 SONAME libmpv.so.2（版本化命名），但 HAP 只按 libmpv.so 打包，
  # 运行时 NEEDED libmpv.so.2 解析不到 → 整个 NAPI 模块加载失败。改写 SONAME 对齐打包名。
  patchelf --set-soname libmpv.so "$MPV_OHOS_APP_LIBS_DIR/libmpv.so"
  # 系统命名空间里没有 libz.so.1（应用 ndk namespace 找不到 zlib），改挂私有名字随 HAP 打包
  patchelf --replace-needed libz.so.1 libmovieclaw_z.so "$MPV_OHOS_APP_LIBS_DIR/libmpv.so"
  cp "$MPV_OHOS_PREFIX/lib/libz.so.1"(N) "$MPV_OHOS_APP_LIBS_DIR/libmovieclaw_z.so"
  rm -rf "$MPV_OHOS_APP_CPP_DIR/include/mpv"
  cp -R "$MPV_OHOS_PREFIX/include/mpv" "$MPV_OHOS_APP_CPP_DIR/include/mpv"
  local sz=$(du -h "$MPV_OHOS_APP_LIBS_DIR/libmpv.so" | cut -f1)
  echo "✔ libmpv.so ($sz, SONAME→libmpv.so) → entry/libs/arm64-v8a/"
  echo "✔ headers → entry/src/main/cpp/include/mpv/"
  {
    echo "ffmpeg $MPV_OHOS_FFMPEG_REF | mpv $MPV_OHOS_MPV_REF | zlib $MPV_OHOS_ZLIB_REF"
    echo "freetype $MPV_OHOS_FREETYPE_REF | fribidi $MPV_OHOS_FRIBIDI_REF | harfbuzz $MPV_OHOS_HARFBUZZ_REF"
    echo "libass $MPV_OHOS_LIBASS_VER | mbedtls $MPV_OHOS_MBEDTLS_REF"
    echo "built $(date '+%Y-%m-%d %H:%M')"
  } > "$SCRIPT_DIR/BUILT-VERSIONS.txt"
}

main() {
  step "MovieClaw mpv-ohos build  (jobs=$NPROC)"
  generate_cross_file
  build_zlib
  build_freetype
  build_fribidi
  build_harfbuzz
  build_libass
  build_libplacebo
  build_mbedtls
  build_ffmpeg
  build_mpv
  export_lib
  echo "🎉 全部完成"
}

generate_cross_file() {
  cat > "$SCRIPT_DIR/meson-cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
ninja = 'ninja'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-D__MUSL__', '-fPIC']
cpp_args = ['-D__MUSL__', '-fPIC']
c_link_args = ['-fPIC', '-L$MPV_OHOS_PREFIX/lib']
cpp_link_args = ['-fPIC', '-L$MPV_OHOS_PREFIX/lib']

[properties]
pkg_config_libdir = '$MPV_OHOS_PREFIX/lib/pkgconfig'
needs_exe_wrapper = true
skip_sanity_check = true
EOF
}

main "$@"
