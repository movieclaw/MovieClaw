# MovieClaw 播放器 native 模块：NAPI 封装 libmpv（dex2oat/mpv OHOS 移植）
#
# libmpv.so 预编译产物在 player_engine/libs/arm64-v8a/（scripts/mpv-ohos/build-all.sh 导出），
# 头文件在 ./include/mpv/。本模块只做 ArkTS ↔ libmpv client API 的桥接。
cmake_minimum_required(VERSION 3.5.0)
project(movieclaw_mpv)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}/include)

add_library(movieclaw_mpv SHARED mpv_napi.cpp)

target_link_libraries(movieclaw_mpv PUBLIC libace_napi.z.so)

# 预编译 libmpv（SHARED IMPORTED：打包时 player_engine/libs/<abi>/libmpv.so 随 HAP 分发）。
# x86_64（模拟器）没有预编译 libmpv——编 mpv_stub.c 顶位：导出 mpv_napi.cpp 用到的
# 全部符号、一律返回失败，NAPI 模块照常加载（initEngine 报不可用），
# 自动模式仍使用 AVPlayer；ARM64 模拟器和真机使用实际 MPV 库。
if(OHOS_ARCH STREQUAL "x86_64")
  add_library(mpv SHARED mpv_stub.c)
else()
  add_library(mpv SHARED IMPORTED)
  set_target_properties(mpv PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libmpv.so)
endif()
target_link_libraries(movieclaw_mpv PUBLIC mpv)
