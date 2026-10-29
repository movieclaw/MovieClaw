# MovieClaw 播放器 native 模块：NAPI 封装 libmpv（dex2oat/mpv OHOS 移植）
#
# libmpv.so 预编译产物在 entry/libs/arm64-v8a/（scripts/mpv-ohos/build-all.sh 导出），
# 头文件在 ./include/mpv/。本模块只做 ArkTS ↔ libmpv client API 的桥接。
cmake_minimum_required(VERSION 3.5.0)
project(movieclaw_mpv)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}/include)

add_library(movieclaw_mpv SHARED mpv_napi.cpp)

target_link_libraries(movieclaw_mpv PUBLIC libace_napi.z.so)

# 预编译 libmpv（SHARED IMPORTED：打包时 entry/libs/<abi>/libmpv.so 随 HAP 分发）
add_library(mpv SHARED IMPORTED)
set_target_properties(mpv PROPERTIES
  IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libmpv.so)
target_link_libraries(movieclaw_mpv PUBLIC mpv)
