#!/usr/bin/env python3
"""修复真机（Pura X 实测）上 eglCreateWindowSurface 失败 → 黑屏（只有声音）的问题。

模拟器宽松、真机 GPU/EGL 严格。两段防御：
1. surfaceId 创建的 NativeWindow 在真机初建时几何可能为 0 —— eglCreateWindowSurface
   直接失败。创建 surface 前读 GET_BUFFER_GEOMETRY，为 0 时先 SET 一个占位几何
   （1280x720）；ohos_reconfig() 之后会用真实尺寸修正。
2. mpegl 选中的 config 可能与 NativeWindow 不匹配（BAD_MATCH/BAD_NATIVE_WINDOW）——
   枚举所有 WINDOW_BIT + GLES2 + RGB8 的 config，逐个「建 context + 建 surface +
   试 MakeCurrent」，成功即采纳该 config/context。
幂等：重复执行无副作用。用法：apply-egl-fix.py <context_ohos.c>
"""
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()
orig = src

OLD = """    EGLConfig config;
    if (!mpegl_create_context(ctx, p->egl_display, &p->egl_context, &config))
        goto fail;

    OHNativeWindow *native_window = vo_ohos_native_window(ctx->vo);
    p->egl_surface = eglCreateWindowSurface(p->egl_display, config,
                                    (EGLNativeWindowType)native_window, NULL);

    if (p->egl_surface == EGL_NO_SURFACE) {
        MP_FATAL(ctx, "Could not create EGL surface!\\n");
        goto fail;
    }
"""

NEW = """    OHNativeWindow *native_window = vo_ohos_native_window(ctx->vo);

    // MovieClaw patch (1/2): 真机上 surfaceId 窗口初建时几何可能为 0，
    // eglCreateWindowSurface 会直接失败。为 0 时先给占位几何，
    // ohos_reconfig() 之后会用真实尺寸修正。
    int gw = 0, gh = 0;
    OH_NativeWindow_NativeWindowHandleOpt(native_window, GET_BUFFER_GEOMETRY, &gh, &gw);
    MP_VERBOSE(ctx, "EGL window geometry at init: %dx%d\\n", gw, gh);
    if (gw <= 0 || gh <= 0) {
        gh = 720;
        gw = 1280;
        OH_NativeWindow_NativeWindowHandleOpt(native_window, SET_BUFFER_GEOMETRY, gh, gw);
        MP_WARN(ctx, "Window geometry was unset, preset %dx%d\\n", gw, gh);
    }

    EGLConfig config;
    if (!mpegl_create_context(ctx, p->egl_display, &p->egl_context, &config))
        goto fail;

    p->egl_surface = eglCreateWindowSurface(p->egl_display, config,
                                    (EGLNativeWindowType)native_window, NULL);

    if (p->egl_surface == EGL_NO_SURFACE) {
        // MovieClaw patch (2/2): mpegl 选中的 config 可能与 NativeWindow 不匹配
        // （真机 BAD_MATCH/BAD_NATIVE_WINDOW 实测）。枚举全部 WINDOW_BIT + GLES2 +
        // RGB8 的 config，逐个「建 context + 建 surface」，成功即采纳。
        MP_FATAL(ctx, "Could not create EGL surface (EGL error 0x%04x), "
                 "retrying with config enumeration\\n", eglGetError());

        EGLint cfg_attrs[] = {
            EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_RED_SIZE, 8,
            EGL_GREEN_SIZE, 8,
            EGL_BLUE_SIZE, 8,
            EGL_NONE
        };
        EGLConfig candidates[32];
        EGLint ncandidates = 0;
        if (eglChooseConfig(p->egl_display, cfg_attrs, candidates, 32, &ncandidates)) {
            for (EGLint n = 0; n < ncandidates && p->egl_surface == EGL_NO_SURFACE; n++) {
                if (candidates[n] == config)
                    continue; // 刚失败过的原始 config 不重试

                static const EGLint ctx_attrs[] = {
                    EGL_CONTEXT_CLIENT_VERSION, 2,
                    EGL_NONE
                };
                EGLContext retry_ctx = eglCreateContext(p->egl_display, candidates[n],
                                                        EGL_NO_CONTEXT, ctx_attrs);
                if (!retry_ctx)
                    continue;

                EGLSurface retry_surf = eglCreateWindowSurface(p->egl_display,
                                                    candidates[n],
                                                    (EGLNativeWindowType)native_window,
                                                    NULL);
                if (retry_surf == EGL_NO_SURFACE) {
                    MP_WARN(ctx, "retry config #%d: surface failed (0x%04x)\\n",
                            (int)n, eglGetError());
                    eglDestroyContext(p->egl_display, retry_ctx);
                    continue;
                }
                if (!eglMakeCurrent(p->egl_display, retry_surf, retry_surf, retry_ctx)) {
                    MP_WARN(ctx, "retry config #%d: makeCurrent failed (0x%04x)\\n",
                            (int)n, eglGetError());
                    eglDestroySurface(p->egl_display, retry_surf);
                    eglDestroyContext(p->egl_display, retry_ctx);
                    continue;
                }
                eglMakeCurrent(p->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                               EGL_NO_CONTEXT);

                eglDestroyContext(p->egl_display, p->egl_context);
                p->egl_context = retry_ctx;
                p->egl_surface = retry_surf;
                config = candidates[n];
                MP_WARN(ctx, "retry config #%d accepted\\n", (int)n);
            }
        }
        if (p->egl_surface == EGL_NO_SURFACE) {
            MP_FATAL(ctx, "all EGL config candidates failed\\n");
            goto fail;
        }
    }
"""

if OLD not in src:
    if "MovieClaw patch (2/2)" in src:
        print("egl patch: 无变化（已打过补丁）")
        raise SystemExit(0)
    print("egl patch: 目标代码块未匹配！")
    raise SystemExit(1)

src = src.replace(OLD, NEW, 1)

with open(path, "w") as f:
    f.write(src)
print("egl patch: 已注入几何兜底 + config 枚举重试 + 错误码日志")
