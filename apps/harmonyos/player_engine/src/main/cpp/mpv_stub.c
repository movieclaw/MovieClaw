// x86_64 emulator: AVPlayer remains usable; lazy MPV initialization rejects.
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

void mpv_free_node_contents(mpv_node *node)
{
    (void)node;
}
