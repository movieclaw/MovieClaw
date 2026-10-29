/*
 * libmpv 桩库（x86_64 模拟器专用，由 CMakeLists.txt 的 OHOS_ARCH 分支编成 libmpv.so）。
 *
 * libmpv.so 的预编译产物只有 arm64-v8a（scripts/mpv-ohos/build-all.sh 只交叉编译
 * aarch64），x86_64 模拟器装不上只带 arm64 原生库的 HAP（安装器报 9568347 ABI
 * 不匹配）。本文件导出 mpv_napi.cpp 用到的全部符号，但一律返回失败：
 * - NAPI 模块 libmovieclaw_mpv.so 照常加载（ArkTS 侧是静态 import，缺 so 会启动崩）；
 * - MpvPlayer.create() 在 mpv_create() 返回 NULL 后抛「mpv_create failed」；
 * - 播放引擎在设置里切回 avplayer 即可正常播放。
 * 真机（arm64）仍链接真 libmpv，不受本文件影响。
 */
#include "mpv/client.h"

/* libmpv 补丁导出的音频焦点转发函数指针（mpv_napi.cpp 以 extern "C" 引用并赋值） */
void (*mpv_ohos_interrupt_hook)(int type, int hint) = NULL;

static mpv_event none_event = { MPV_EVENT_NONE, 0, 0, NULL };

mpv_handle *mpv_create(void)
{
    return NULL;
}

int mpv_initialize(mpv_handle *ctx)
{
    (void)ctx;
    return MPV_ERROR_UNINITIALIZED;
}

void mpv_terminate_destroy(mpv_handle *ctx)
{
    (void)ctx;
}

int mpv_command(mpv_handle *ctx, const char **args)
{
    (void)ctx;
    (void)args;
    return MPV_ERROR_UNINITIALIZED;
}

int mpv_set_option_string(mpv_handle *ctx, const char *name, const char *data)
{
    (void)ctx;
    (void)name;
    (void)data;
    return MPV_ERROR_UNINITIALIZED;
}

int mpv_set_property(mpv_handle *ctx, const char *name, mpv_format format, void *data)
{
    (void)ctx;
    (void)name;
    (void)format;
    (void)data;
    return MPV_ERROR_UNINITIALIZED;
}

int mpv_set_property_string(mpv_handle *ctx, const char *name, const char *data)
{
    (void)ctx;
    (void)name;
    (void)data;
    return MPV_ERROR_UNINITIALIZED;
}

char *mpv_get_property_string(mpv_handle *ctx, const char *name)
{
    (void)ctx;
    (void)name;
    return NULL;
}

int mpv_get_property(mpv_handle *ctx, const char *name, mpv_format format, void *data)
{
    (void)ctx;
    (void)name;
    (void)format;
    (void)data;
    return MPV_ERROR_UNINITIALIZED;
}

int mpv_request_log_messages(mpv_handle *ctx, const char *min_level)
{
    (void)ctx;
    (void)min_level;
    return MPV_ERROR_UNINITIALIZED;
}

int mpv_observe_property(mpv_handle *mpv, uint64_t reply_userdata, const char *name, mpv_format format)
{
    (void)mpv;
    (void)reply_userdata;
    (void)name;
    (void)format;
    return MPV_ERROR_UNINITIALIZED;
}

int mpv_unobserve_property(mpv_handle *mpv, uint64_t registered_reply_userdata)
{
    (void)mpv;
    (void)registered_reply_userdata;
    return MPV_ERROR_UNINITIALIZED;
}

mpv_event *mpv_wait_event(mpv_handle *ctx, double timeout)
{
    (void)ctx;
    (void)timeout;
    return &none_event;
}

const char *mpv_error_string(int error)
{
    (void)error;
    return "libmpv unavailable (x86_64 emulator stub)";
}

void mpv_free(void *data)
{
    (void)data;
}
