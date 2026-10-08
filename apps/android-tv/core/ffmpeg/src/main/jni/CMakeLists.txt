# JNI 胶水层（取自 Media3 1.11.1 decoder_ffmpeg，Apache 2.0）。与上游的差别：FFmpeg 链接方式改成共享库
# （LGPL-2.1：FFmpeg 是独立的 .so，可被替换），不静态并进 libffmpegJNI.so。
cmake_minimum_required(VERSION 3.21.0 FATAL_ERROR)
set(CMAKE_CXX_STANDARD 11)
project(libffmpegJNI C CXX)

set(ffmpeg_location "${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg")
set(ffmpeg_binaries "${ffmpeg_location}/android-libs/${ANDROID_ABI}")

foreach(ffmpeg_lib avutil swresample avcodec)
    add_library(${ffmpeg_lib} SHARED IMPORTED)
    set_target_properties(${ffmpeg_lib} PROPERTIES IMPORTED_LOCATION ${ffmpeg_binaries}/lib${ffmpeg_lib}.so)
endforeach()

include_directories(${ffmpeg_location})
find_library(android_log_lib log)

add_library(ffmpegJNI SHARED ffmpeg_jni.cc)
set_target_properties(ffmpegJNI PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
target_link_libraries(ffmpegJNI PRIVATE android PRIVATE swresample PRIVATE avcodec PRIVATE avutil PRIVATE ${android_log_lib})
if(ANDROID_ABI STREQUAL "arm64-v8a")
    target_link_options(ffmpegJNI PRIVATE "-Wl,-Bsymbolic")
endif()
