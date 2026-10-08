// libass 字幕渲染桥（方案 B：画面走 Exo 硬解，字幕走 libass 叠层）
//
// 与 mpv_bridge.cpp 同一套做法：**dlopen 已随包发布的 libass.so + dlsym 解析符号**，
// 不引入新的链接依赖、不与其它库的 DT_NEEDED 冲突（jniLibs/arm64-v8a/libass.so 已在包里）。
// 头文件同理：这里只声明用到的那一小撮 libass 结构体与函数指针，不引入 ass/ass.h。
#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>

#define LOG_TAG "McAss"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

extern "C" {

/* ---- 用到的最小 libass 声明（对齐 ass.h，字段顺序必须一致）---- */
typedef struct ass_library ASS_Library;
typedef struct ass_renderer ASS_Renderer;
typedef struct ass_track ASS_Track;

typedef struct ass_image {
    int w, h;
    int stride;
    unsigned char *bitmap;   // 1 byte/px，覆盖度
    uint32_t color;          // 0xAABBGGRR
    int dst_x, dst_y;
    struct ass_image *next;
} ASS_Image;

typedef ASS_Library *(*fn_library_init)(void);
typedef void (*fn_library_done)(ASS_Library *);
typedef void (*fn_set_fonts_dir)(ASS_Library *, const char *);
typedef ASS_Renderer *(*fn_renderer_init)(ASS_Library *);
typedef void (*fn_renderer_done)(ASS_Renderer *);
typedef void (*fn_set_frame_size)(ASS_Renderer *, int, int);
typedef void (*fn_set_fonts)(ASS_Renderer *, const char *, const char *, int, const char *, int);
typedef ASS_Track *(*fn_read_memory)(ASS_Library *, char *, size_t, char *);
typedef void (*fn_free_track)(ASS_Track *);
typedef ASS_Image *(*fn_render_frame)(ASS_Renderer *, ASS_Track *, long long, int *);

/* ---- 样式覆盖用的结构体：字段顺序照抄 libass 的 ass_types.h（含 ABI 占位字段），
   手写容易错位导致内存踩坏，所以直接照抄一份已验证的头文件定义 ---- */
typedef struct ass_style {
    char *Name;
    char *FontName;
    double FontSize;
    uint32_t PrimaryColour;
    uint32_t SecondaryColour;
    uint32_t OutlineColour;
    uint32_t BackColour;
    int Bold;
    int Italic;
    int Underline;
    int StrikeOut;
    double ScaleX;
    double ScaleY;
    double Spacing;
    double Angle;
    int BorderStyle;
    double Outline;
    double Shadow;
    int Alignment;
    int MarginL;
    int MarginR;
    int MarginV;
    int Encoding;
    int treat_fontname_as_pattern;   // ABI 占位，不做任何事
    double Blur;
    int Justify;
} ASS_Style;

typedef void (*fn_set_override)(ASS_Renderer *, ASS_Style *);
typedef void (*fn_set_override_enabled)(ASS_Renderer *, int);

#define MC_OVERRIDE_BIT_STYLE (1 << 0)
typedef void (*fn_set_storage_size)(ASS_Renderer *, int, int);
typedef void (*fn_set_hinting)(ASS_Renderer *, int);
typedef void (*fn_set_use_margins)(ASS_Renderer *, int);

/* ---- 运行期句柄 ---- */
static void *g_lib = nullptr;
static ASS_Library *g_library = nullptr;
static ASS_Renderer *g_renderer = nullptr;
static ASS_Track *g_track = nullptr;
static int g_w = 0, g_h = 0;

static fn_library_init p_library_init = nullptr;
static fn_library_done p_library_done = nullptr;
static fn_set_fonts_dir p_set_fonts_dir = nullptr;
static fn_renderer_init p_renderer_init = nullptr;
static fn_renderer_done p_renderer_done = nullptr;
static fn_set_frame_size p_set_frame_size = nullptr;
static fn_set_fonts p_set_fonts = nullptr;
static fn_read_memory p_read_memory = nullptr;
static fn_free_track p_free_track = nullptr;
static fn_render_frame p_render_frame = nullptr;
static fn_set_storage_size p_set_storage_size = nullptr;
static fn_set_hinting p_set_hinting = nullptr;
static fn_set_use_margins p_set_use_margins = nullptr;
static fn_set_override p_set_override = nullptr;
static fn_set_override_enabled p_set_override_enabled = nullptr;
static ASS_Style g_style;

static bool ensure_lib() {
    if (g_lib) return true;
    // 先按常规名加载，失败再试绝对路径（不同 ABI 目录由 linker 自己选）
    g_lib = dlopen("libass.so", RTLD_NOW | RTLD_LOCAL);
    if (!g_lib) {
        LOGW("dlopen(libass.so) 失败: %s", dlerror());
        return false;
    }
#define BIND(name) \
    p_##name = reinterpret_cast<fn_##name>(dlsym(g_lib, "ass_" #name)); \
    if (!p_##name) { LOGW("缺少符号 ass_" #name); return false; }
    BIND(library_init)
    BIND(library_done)
    BIND(set_fonts_dir)
    BIND(renderer_init)
    BIND(renderer_done)
    BIND(set_frame_size)
    BIND(set_fonts)
    BIND(read_memory)
    BIND(free_track)
    BIND(render_frame)
#undef BIND
    // 下面三个是**可选**的：老版本 libass 可能没有，缺了不影响渲染（只影响定位精度）
    p_set_storage_size = reinterpret_cast<fn_set_storage_size>(dlsym(g_lib, "ass_set_storage_size"));
    p_set_hinting = reinterpret_cast<fn_set_hinting>(dlsym(g_lib, "ass_set_hinting"));
    p_set_use_margins = reinterpret_cast<fn_set_use_margins>(dlsym(g_lib, "ass_set_use_margins"));
    p_set_override = reinterpret_cast<fn_set_override>(dlsym(g_lib, "ass_set_selective_style_override"));
    p_set_override_enabled = reinterpret_cast<fn_set_override_enabled>(dlsym(g_lib, "ass_set_selective_style_override_enabled"));
    LOGI("libass 已加载");
    return true;
}

/* ================= JNI: io.movieclaw.android.core.playback.LibassBridge ================= */


/* ================= JNI: io.movieclaw.android.core.playback.LibassBridge ================= */

extern "C" JNIEXPORT jboolean JNICALL
Java_io_movieclaw_android_core_playback_LibassBridge_nativeInit(
        JNIEnv *env, jclass, jint w, jint h, jstring fontsDir) {
    if (!ensure_lib()) return JNI_FALSE;
    g_w = w; g_h = h;
    if (!g_library) {
        g_library = p_library_init();
        if (!g_library) { LOGW("ass_library_init 失败"); return JNI_FALSE; }
    }
    // Android 上必须显式告诉 libass 去哪找字体：只靠 fontconfig 自动探测常常一个字体都没有，
    // 表现就是「装载成功、渲染 0 张图」（实机踩过）
    if (fontsDir) {
        const char *dir = env->GetStringUTFChars(fontsDir, nullptr);
        p_set_fonts_dir(g_library, dir);
        env->ReleaseStringUTFChars(fontsDir, dir);
    } else {
        p_set_fonts_dir(g_library, "/system/fonts");
    }
    if (g_renderer) { p_renderer_done(g_renderer); g_renderer = nullptr; }
    g_renderer = p_renderer_init(g_library);
    if (!g_renderer) { LOGW("ass_renderer_init 失败"); return JNI_FALSE; }
    p_set_frame_size(g_renderer, w, h);
    // default_font 传一个**具体存在的**字体文件（Android 从 5.0 起都带 Noto CJK）；
    // 拿不到时退到 DroidSansFallback，再退到不指定
    const char *kFonts[] = {
        "/system/fonts/NotoSansCJK-Regular.ttc",
        "/system/fonts/NotoSansSC-Regular.otf",
        "/system/fonts/DroidSansFallback.ttf",
        nullptr,
    };
    const char *picked = nullptr;
    for (int i = 0; kFonts[i]; i++) {
        FILE *f = fopen(kFonts[i], "rb");
        if (f) { fclose(f); picked = kFonts[i]; break; }
    }
    LOGI("默认字体: %s", picked ? picked : "(未找到，交给 fontconfig)");
    p_set_fonts(g_renderer, picked, "sans-serif", 1, nullptr, 1);
    // 与已验证实现对齐的三处：storage 尺寸（影响定位/缩放）、轻提示（字形更利落）、不使用边距
    if (p_set_storage_size) p_set_storage_size(g_renderer, w, h);
    if (p_set_hinting) p_set_hinting(g_renderer, 1);      // ASS_HINTING_LIGHT
    if (p_set_use_margins) p_set_use_margins(g_renderer, 0);
    // **不要**再调 ass_set_selective_style_override：真机上它让 libass 一张图都渲染不出来
    // （探针实测 2026-10-01：同一份最简 ASS，覆盖关 → images=3；覆盖开 → images=0，
    // 轨道与字体都正常）。样式一律由 Kotlin 侧改写 `Style:` 行决定——那条路是确定性的、
    // 也验过；这里就不再插一层会打架的覆盖。
    LOGI("renderer 就绪 %dx%d（样式由 Kotlin 改写 Style: 行决定）", w, h);
    return JNI_TRUE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_io_movieclaw_android_core_playback_LibassBridge_nativeLoadData(
        JNIEnv *env, jclass, jbyteArray data, jstring name) {
    if (!ensure_lib() || !g_library) return JNI_FALSE;
    const jsize n = env->GetArrayLength(data);
    std::vector<char> buf(static_cast<size_t>(n));
    env->GetByteArrayRegion(data, 0, n, reinterpret_cast<jbyte *>(buf.data()));
    if (g_track) { p_free_track(g_track); g_track = nullptr; }
    const char *nm = name ? env->GetStringUTFChars(name, nullptr) : "sub";
    g_track = p_read_memory(g_library, buf.data(), static_cast<size_t>(n), const_cast<char *>(nm));
    if (name) env->ReleaseStringUTFChars(name, nm);
    if (!g_track) { LOGW("ass_read_memory 失败（%d 字节）", n); return JNI_FALSE; }
    LOGI("字幕已装载 %d 字节", n);
    return JNI_TRUE;
}

/**
 * 渲染一帧：返回「每个 ASS_Image 一条」的 int 数组，8 个一组：
 * [dst_x, dst_y, w, h, colorAABBGGRR, stride, bitmapOffset, reserved]
 * 位图字节放在 outBytes 里（调用方按 offset/stride 取）。
 */
extern "C" JNIEXPORT jintArray JNICALL
Java_io_movieclaw_android_core_playback_LibassBridge_nativeRender(
        JNIEnv *env, jclass, jlong ptsMs, jbyteArray outBytes) {
    if (!p_render_frame || !g_renderer || !g_track) return nullptr;
    int detect = 0;
    ASS_Image *img = p_render_frame(g_renderer, g_track, static_cast<long long>(ptsMs), &detect);
    std::vector<jint> meta;
    std::vector<unsigned char> pixels;
    for (ASS_Image *p = img; p; p = p->next) {
        if (p->w <= 0 || p->h <= 0 || !p->bitmap) continue;
        const int offset = static_cast<int>(pixels.size());
        const size_t bytes = static_cast<size_t>(p->stride) * static_cast<size_t>(p->h);
        pixels.insert(pixels.end(), p->bitmap, p->bitmap + bytes);
        meta.push_back(p->dst_x); meta.push_back(p->dst_y);
        meta.push_back(p->w);     meta.push_back(p->h);
        meta.push_back(static_cast<jint>(p->color));
        meta.push_back(p->stride);meta.push_back(offset);
        meta.push_back(0);
    }
    if (outBytes) {
        // 防越界：写入长度取「像素总数」与「目标数组长度」的较小值
        const jsize cap = env->GetArrayLength(outBytes);
        const jsize n = static_cast<jsize>(pixels.size());
        if (n > cap) LOGW("像素 %d 字节超过缓冲 %d，截断", n, cap);
        env->SetByteArrayRegion(outBytes, 0, n < cap ? n : cap,
                                reinterpret_cast<const jbyte *>(pixels.data()));
    }
    LOGI("render pts=%lld images=%zu bytes=%zu", static_cast<long long>(ptsMs),
         meta.size() / 8, pixels.size());
    jintArray out = env->NewIntArray(static_cast<jsize>(meta.size()));
    if (out && !meta.empty()) env->SetIntArrayRegion(out, 0, static_cast<jsize>(meta.size()), meta.data());
    return out;
}

extern "C" JNIEXPORT void JNICALL
Java_io_movieclaw_android_core_playback_LibassBridge_nativeRelease(JNIEnv *, jclass) {
    if (g_track && p_free_track) { p_free_track(g_track); g_track = nullptr; }
    if (g_renderer && p_renderer_done) { p_renderer_done(g_renderer); g_renderer = nullptr; }
    if (g_library && p_library_done) { p_library_done(g_library); g_library = nullptr; }
}

} // extern "C"
