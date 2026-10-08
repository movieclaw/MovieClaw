cmake_minimum_required(VERSION 3.22.1)
project(movieclaw_native LANGUAGES C CXX)

# MPV JNI 桥:HAS_MPV 启用后按已验证的 dlopen 方案加载 libmp2.so
# (libmpv 全量版,静态编入 libass/fontconfig/ffmpeg;符号经 dlsym 解析,
#  不与其余库的 DT_NEEDED 冲突)。
add_library(movieclaw_jni SHARED
    mpv_bridge.cpp
    libass_bridge.cpp
    # ISO 原盘直连:自定义块读取把 libudfread 的 UDF 卷读翻译成对远端 ISO 的 HTTP Range,
    # 再把 BDMV/STREAM 的正片 m2ts 用本机 127.0.0.1 服务暴露给 mpv。
    # 配套 vendored libudfread(纯 C,零依赖,源码直编)。
    iso_native.cpp
    libudfread/udfread.c
    libudfread/udf_volume.c
    libudfread/udf_fs.c
    libudfread/ecma167.c
    libudfread/udfread-version.c
    # 注：default_blockinput.c（本地文件块读取）不编——我们走自定义 HTTP Range 回调，用不到它
)

target_include_directories(movieclaw_jni PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/mpv_include)
target_compile_definitions(movieclaw_jni PRIVATE HAS_MPV)
# libudfread 是纯 C，混编同一个 target：这些开关只能给 C++ 源，
# 否则 C 文件会报 "invalid argument '-std=c++17' not allowed with 'C'"
target_compile_options(movieclaw_jni PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-std=c++17;-fexceptions;-frtti>
)

find_library(log-lib log)
target_link_libraries(movieclaw_jni PRIVATE ${log-lib} android)
