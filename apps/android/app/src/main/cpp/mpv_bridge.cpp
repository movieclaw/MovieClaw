// mpv_bridge.cpp — 定制 libmpv 的 JNI 桥
//
// 编译开关 HAS_MPV：链接预编译的 libmpv.so（我们构建的版本，静态含
// libass/fontconfig/ffmpeg）。未启用时提供桩实现，构建不失败。
//
// 线程模型：事件线程由实例持有；销毁先 wakeup + join，禁止与销毁并发读取事件。
//
// Surface 生命周期：实例持有 JNI Surface 全局引用，detach 停止 VO 后交还；
// destroy 等待事件线程退出并销毁内核，最后释放 Surface。

#include <jni.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <string>
#include <thread>
#include <dlfcn.h>
#include <cstring>
#include <vector>
#include <atomic>
#include <mutex>

#ifdef HAS_MPV
#include <mpv/client.h>
#endif

#define LOG_TAG "McMpv"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ── mpv API 动态符号(dlopen libmpv2.so)──
// 为什么 dlopen 而非链接期 IMPORTED:libmpv 定制内核(libmp2.so)与 media_kit
// 的 libmpv.so 同进程共存,DT_NEEDED 按名解析会绑到 media_kit 的库
// (无 libass 的旧构建),定制内核完全不生效,且跨实例 wid 直渲黑屏(实证)。
typedef struct mpv_handle mpv_handle;
struct mpv_event_stub { int event_id; int error; unsigned long long reply_userdata; void *data; };
struct mpv_event_log_stub { const char *prefix; const char *level; const char *text; int log_level; };
static mpv_handle *(*p_create)(void);
static int (*p_init)(mpv_handle *);
static void (*p_terminate)(mpv_handle *);
static int (*p_cmd)(mpv_handle *, const char **);
static int (*p_setstr)(mpv_handle *, const char *, const char *);
static char *(*p_getstr)(mpv_handle *, const char *);
static void (*p_free)(void *);
static int (*p_observe)(mpv_handle *, unsigned long long, const char *, int);
static const char *(*p_error_string)(int);
static void (*p_wakeup)(mpv_handle *, void (*)(void *), void *);
static void (*p_interrupt)(mpv_handle *);
static int (*p_logreq)(mpv_handle *, const char *);
static mpv_event_stub *(*p_waitev)(mpv_handle *, double);
// FFmpeg JNI 桥:mpv 的 android GPU context 与 audiotrack 均经此取 JavaVM
static void (*p_av_set_java_vm)(void *vm, void *log_ctx);
static bool g_mpv_loaded = false;
static std::mutex g_load_mutex;

static bool load_mpv_symbols() {
    std::lock_guard<std::mutex> lock(g_load_mutex);
    if (g_mpv_loaded) return true;
    void *h = dlopen("libmp2.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) { LOGE("dlopen libmpv2.so: %s", dlerror()); return false; }
#define DLSYM(v, n) v = reinterpret_cast<decltype(v)>(dlsym(h, n)); if (!v) { LOGE("dlsym %s", n); dlclose(h); return false; }
    DLSYM(p_create, "mpv_create")
    DLSYM(p_init, "mpv_initialize")
    DLSYM(p_terminate, "mpv_terminate_destroy")
    DLSYM(p_cmd, "mpv_command")
    DLSYM(p_setstr, "mpv_set_property_string")
    DLSYM(p_getstr, "mpv_get_property_string")
    DLSYM(p_free, "mpv_free")
    DLSYM(p_observe, "mpv_observe_property")
    DLSYM(p_error_string, "mpv_error_string")
    DLSYM(p_wakeup, "mpv_set_wakeup_callback")
    DLSYM(p_interrupt, "mpv_wakeup")
    DLSYM(p_logreq, "mpv_request_log_messages")
    DLSYM(p_waitev, "mpv_wait_event")
    DLSYM(p_av_set_java_vm, "av_jni_set_java_vm")
#undef DLSYM
    g_mpv_loaded = true;
    LOGI("libmp2.so loaded, symbols resolved");
    return true;
}

#ifdef HAS_MPV
static JavaVM *g_vm = nullptr;
static jobject g_wakeup_target = nullptr;
static jmethodID g_wakeup_method = nullptr;

static void mpv_wakeup_stub(void *ctx) { // legacy
    // mpv 回调线程：通知 Dart 侧有事件（单发 signal，Dart 侧拉取状态）
    JavaVMAttachArgs args{JNI_VERSION_1_6, "mpv-wakeup", nullptr};
    JNIEnv *env = nullptr;
    if (g_vm->AttachCurrentThread(&env, &args) == JNI_OK) {
        if (g_wakeup_target && g_wakeup_method) {
            env->CallVoidMethod(g_wakeup_target, g_wakeup_method);
        }
        g_vm->DetachCurrentThread();
    }
}

// 每个 Kotlin 引擎独占 Surface 和事件线程，不能用进程全局引用互相覆盖。
struct MpvInstance {
    mpv_handle *mpv;
    jobject surface = nullptr;
    std::atomic<bool> stopping{false};
    std::atomic<unsigned long long> loaded_files{0};
    std::thread events;
    explicit MpvInstance(mpv_handle *value) : mpv(value) {}
};
static inline MpvInstance *I(jlong handle) {
    return reinterpret_cast<MpvInstance *>(handle);
}
static inline mpv_handle *H(jlong handle) { return I(handle)->mpv; }
static void destroy_instance(JNIEnv *env, MpvInstance *instance) {
    instance->stopping = true;
    // 唤醒等待者并等待它不再访问 handle/事件数据，之后才允许销毁内核。
    p_interrupt(instance->mpv);
    if (instance->events.joinable()) instance->events.join();
    p_terminate(instance->mpv);
    if (instance->surface) env->DeleteGlobalRef(instance->surface);
    delete instance;
}

// Surface 生命周期（对齐 mpv-android 官方 render.cpp 契约）：
//   attach = NewGlobalRef(surface) + wid = 引用值
//   detach = wid = 0 + DeleteGlobalRef(surface)
// mpv 的 android 路径把 wid 当 Java Surface 的 jobject 全局引用解析，
// 运行期换 Surface 必须走这一对，不能只设 wid 不管旧引用。
static bool attach_surface(JNIEnv *env, MpvInstance *instance, jobject surface) {
    mpv_handle *mpv = instance->mpv;
    if (surface == nullptr) { LOGE("attach_surface: null surface"); return false; }
    if (instance->surface && p_setstr(mpv, "vo", "null") < 0) {
        LOGW("cannot stop VO before Surface replacement");
        return false;
    }
    jobject next = env->NewGlobalRef(surface);
    if (!next) { LOGE("NewGlobalRef failed"); return false; }
    char wid[32];
    snprintf(wid, sizeof(wid), "%lld", (long long)(intptr_t)next);
    int r = p_setstr(mpv, "wid", wid);
    if (r < 0) {
        env->DeleteGlobalRef(next);
        LOGE("set wid failed: %s", p_error_string(r));
        return false;
    }
    if (instance->surface) env->DeleteGlobalRef(instance->surface);
    instance->surface = next;
    LOGI("surface attached, wid=%s", wid);
    return true;
}
#endif

/**
 * libmp2.so 到底在不在。
 *
 * Kotlin 侧的 `MpvNative.available` 原本只看「我们自己的 JNI 库加载成功没有」——
 * 那个库永远随源码一起编出来,所以**没有 libmp2.so 它也是 true**：引擎菜单会给出
 * 一个点了就黑屏的 MPV 选项(不报错、不回退,最难查的那种)。这里把 dlopen 的真实
 * 结果报上去,让上层在缺库时干净地只用 Exo。
 */
extern "C" JNIEXPORT jboolean JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeMpvAvailable(JNIEnv *, jclass) {
    return load_mpv_symbols() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jlong JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeCreate(JNIEnv *env, jclass,
                                          jobject surface) {
#ifdef HAS_MPV
    if (!load_mpv_symbols()) return 0;
    mpv_handle *mpv = p_create();
    if (!mpv) { LOGE("mpv_create failed"); return 0; }
    // 注册 JavaVM 给 FFmpeg JNI 桥:gpu-context=android 与 audiotrack
    // 经 mp_jni_get_env(→av_jni_get_java_vm)获取 JVM,不注册则
    // 'Failed initializing any suitable GPU context'(真机日志实证)
    if (g_vm == nullptr) {
        env->GetJavaVM(&g_vm);
        if (p_av_set_java_vm) p_av_set_java_vm(g_vm, nullptr);
        LOGI("JavaVM registered to ffmpeg jni bridge");
    }
    // 渲染：GPU 管线渲染到外部 Surface（对照 Streama/mpv-android）
    p_setstr(mpv, "vo", "gpu-next");
    p_setstr(mpv, "gpu-context", "android");
    p_setstr(mpv, "hwdec", "mediacodec,mediacodec-copy");
    p_setstr(mpv, "osc", "no");
    // 字幕交给 mpv 内核内置的 libass 渲染（sub-visibility 保持默认 yes）：
    // ASS 定位/卡拉OK/动画完整，PGS 位图也能出，且字幕画在视频 Surface 上、
    // 不经过 Flutter 层 —— 弹幕层零额外成本。此前这里关掉字幕是想走 Dart 层
    // LibassBridge，内核自带 libass 后那条路没必要了。
    p_setstr(mpv, "terminal", "no");

    // 诊断:mpv 内部日志全量转发 logcat(黑屏/渲染错误定位)
    p_logreq(mpv, "info");
    if (p_init(mpv) < 0) {
        LOGE("mpv_initialize failed");
        p_terminate(mpv);
        return 0;
    }
    auto *instance = new MpvInstance(mpv);
    // 事件泵线程:log-message → logcat;mpv 日志是唯一可靠的渲染诊断源
    instance->events = std::thread([instance]() {
        while (!instance->stopping) {
            mpv_event_stub *ev = p_waitev(instance->mpv, -1);
            // 枚举值以 client.h 为准:LOG_MESSAGE=2,SHUTDOWN=1
            // (此前误写 6=LOG_MESSAGE,实为 START_FILE,data 结构不同,解析即崩)
            if (!ev || ev->event_id == 0) continue;   // MPV_EVENT_NONE
            if (ev->event_id == 1) break;             // MPV_EVENT_SHUTDOWN
            if (ev->event_id == 8) ++instance->loaded_files; // MPV_EVENT_FILE_LOADED
            if (ev->event_id == 2) {                  // MPV_EVENT_LOG_MESSAGE
                mpv_event_log_stub *m = (mpv_event_log_stub *)ev->data;
                // prefix/text 可能为 NULL(空消息),直接 %s 会 strlen 崩溃
                if (m->text) {
                    if (m->prefix) {
                        LOGI("[mpv/%s] %s", m->prefix, m->text);
                    } else {
                        LOGI("[mpv] %s", m->text);
                    }
                }
            }
        }
    });

    // mpv 的 android 路径(video/out/android_common.c)把 WinID 当作
    // Java Surface 的 jobject 全局引用,内部 ANativeWindow_fromSurface
    // 解析 —— 与 mpv-android 官方架构一致。传 ANativeWindow 指针会被
    // 当 jobject 解析而崩溃(真机 SIGSEGV 实证)。
    if (!attach_surface(env, instance, surface)) {
        destroy_instance(env, instance);
        return 0;
    }
    return reinterpret_cast<jlong>(instance);
#else
    (void)env; (void)surface;
    LOGW("HAS_MPV not enabled");
    return 0;
#endif
}

extern "C" JNIEXPORT void JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeDestroy(JNIEnv *env, jclass, jlong handle) {
#ifdef HAS_MPV
    if (handle) destroy_instance(env, I(handle));
#else
    (void)env; (void)handle;
#endif
}

// 运行期重新挂载 Surface（Surface 被系统重建后恢复渲染：切后台再回、
// 视图重建）。surfaceCreated 里在已有 handle 时调用。
extern "C" JNIEXPORT jboolean JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeAttachSurface(JNIEnv *env, jclass,
                                                 jlong handle, jobject surface) {
#ifdef HAS_MPV
    if (!handle || !g_mpv_loaded) return JNI_FALSE;
    return attach_surface(env, I(handle), surface) ? JNI_TRUE : JNI_FALSE;
#else
    (void)env; (void)handle; (void)surface; return JNI_FALSE;
#endif
}

// 交还 Surface：wid=0 让 mpv 立刻停止使用该窗口，再释放全局引用。
// 必须在 surfaceDestroyed 里、Surface 真正失效前调用（防 use-after-free）。
extern "C" JNIEXPORT void JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeDetachSurface(JNIEnv *env, jclass,
                                                 jlong handle) {
#ifdef HAS_MPV
    if (handle && g_mpv_loaded) {
        if (p_setstr(H(handle), "vo", "null") < 0) return;
        if (p_setstr(H(handle), "wid", "0") < 0) {
            LOGW("set wid=0 failed; Surface retained until destroy");
            return;
        }
    }
    if (handle && I(handle)->surface) {
        env->DeleteGlobalRef(I(handle)->surface);
        I(handle)->surface = nullptr;
    }
#else
    (void)env; (void)handle;
#endif
}

extern "C" JNIEXPORT jboolean JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeCommand(JNIEnv *env, jclass,
                                           jlong handle, jstring cmd) {
#ifdef HAS_MPV
    if (!handle || !g_mpv_loaded) return JNI_FALSE;
    if (!cmd) return JNI_FALSE;
    const char *c = env->GetStringUTFChars(cmd, nullptr);
    if (!c) return JNI_FALSE;
    // mpv_command 需要参数数组：按空格拆分（带引号的段保留整体）
    std::vector<std::string> parts;
    std::string cur;
    bool inQuote = false;
    for (const char *p = c; *p; ++p) {
        if (*p == '"') { inQuote = !inQuote; continue; }
        if (*p == ' ' && !inQuote) {
            if (!cur.empty()) { parts.push_back(cur); cur.clear(); }
            continue;
        }
        cur += *p;
    }
    if (!cur.empty()) parts.push_back(cur);
    if (inQuote || parts.empty()) {
        env->ReleaseStringUTFChars(cmd, c);
        return JNI_FALSE;
    }
    std::vector<const char *> argv;
    for (auto &p : parts) argv.push_back(p.c_str());
    argv.push_back(nullptr);
    int r = p_cmd(H(handle), argv.data());
    if (r < 0) LOGW("command failed (err=%d)", r);
    env->ReleaseStringUTFChars(cmd, c);
    return r >= 0 ? JNI_TRUE : JNI_FALSE;
#else
    (void)env; (void)handle; (void)cmd; return JNI_FALSE;
#endif
}

extern "C" JNIEXPORT jboolean JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeSetProperty(JNIEnv *env, jclass,
                                               jlong handle, jstring name,
                                               jstring value) {
#ifdef HAS_MPV
    if (!handle || !g_mpv_loaded) return JNI_FALSE;
    const char *n = env->GetStringUTFChars(name, nullptr);
    const char *v = env->GetStringUTFChars(value, nullptr);
    int r = p_setstr(H(handle), n, v);
    env->ReleaseStringUTFChars(name, n);
    env->ReleaseStringUTFChars(value, v);
    return r >= 0 ? JNI_TRUE : JNI_FALSE;
#else
    (void)env; (void)handle; (void)name; (void)value; return JNI_FALSE;
#endif
}

extern "C" JNIEXPORT jstring JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeGetProperty(JNIEnv *env, jclass,
                                               jlong handle, jstring name) {
#ifdef HAS_MPV
    if (!handle || !g_mpv_loaded) return nullptr;
    const char *n = env->GetStringUTFChars(name, nullptr);
    // 宿主以 FILE_LOADED 代次判断本次打开完成，不再拿上个文件的 duration 猜时序。
    if (strcmp(n, "movieclaw-file-loaded") == 0) {
        std::string generation = std::to_string(I(handle)->loaded_files.load());
        env->ReleaseStringUTFChars(name, n);
        return env->NewStringUTF(generation.c_str());
    }
    char *v = p_getstr(H(handle), n);
    env->ReleaseStringUTFChars(name, n);
    if (!v) return nullptr;
    jstring result = env->NewStringUTF(v);
    p_free(v);
    return result;
#else
    (void)env; (void)handle; (void)name; return nullptr;
#endif
}

extern "C" JNIEXPORT jboolean JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeObserve(JNIEnv *env, jclass,
                                           jlong handle, jstring name,
                                           jint id) {
#ifdef HAS_MPV
    if (!handle) return JNI_FALSE;
    const char *n = env->GetStringUTFChars(name, nullptr);
    // 统一按 double 观测（time-pos/duration/speed 都是数值；字符串属性
    // 用 getProperty 主动拉）
    int r = p_observe(H(handle), id, n, MPV_FORMAT_DOUBLE);
    env->ReleaseStringUTFChars(name, n);
    return r >= 0 ? JNI_TRUE : JNI_FALSE;
#else
    (void)env; (void)handle; (void)name; (void)id; return JNI_FALSE;
#endif
}

extern "C" JNIEXPORT void JNICALL
Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeSetEventCallback(JNIEnv *env, jclass,
                                                    jlong handle,
                                                    jobject callback) {
#ifdef HAS_MPV
    if (!handle) return;
    if (!g_vm) env->GetJavaVM(&g_vm);
    if (g_wakeup_target) { env->DeleteGlobalRef(g_wakeup_target); }
    g_wakeup_target = env->NewGlobalRef(callback);
    jclass cls = env->GetObjectClass(g_wakeup_target);
    g_wakeup_method = env->GetMethodID(cls, "onMpvWakeup", "()V");
    p_wakeup(H(handle), [](void *) {}, nullptr);
#else
    (void)env; (void)handle; (void)callback;
#endif
}
