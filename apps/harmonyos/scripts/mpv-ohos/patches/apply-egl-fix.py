#!/usr/bin/env python3
"""mpv ohos 上下文补丁（幂等，可重复执行）。用法：apply-egl-fix.py <context_ohos.c>

补丁 1（EGL surface 兜底）：修复真机（Pura X 实测）eglCreateWindowSurface 失败 → 黑屏。
1a. surfaceId 创建的 NativeWindow 初建时几何可能为 0 —— 先读 GET_BUFFER_GEOMETRY，
    为 0 时 SET 占位几何（1280x720）；ohos_reconfig() 之后用真实尺寸修正。
1b. mpegl 选中的 config 可能与 NativeWindow 不匹配（BAD_MATCH/BAD_NATIVE_WINDOW）——
    枚举所有 WINDOW_BIT + GLES2 + RGB8 的 config，逐个「建 context + 建 surface +
    试 MakeCurrent」，成功即采纳。

补丁 2（旋转/布局自适应）：ArkUI 旋转/全屏切换会静默 resize XComponent 的
NativeWindow，wid=surfaceId 模式下 mpv 收不到任何事件 → 横屏后视频仍按旧尺寸渲染
（不能全屏）。vo 线程每次循环都发 VOCTRL_CHECK_EVENTS（vo.c），节流轮询真实几何，
变化时更新 vo->dwidth/dheight + ra_gl_ctx_resize 刷新 backbuffer FBO，置
VO_EVENT_RESIZE 让 vo_gpu 重算渲染矩形（context_win.c wgl_control 同款模式）。
"""
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    src = f.read()
orig = src

# ---------- 补丁 1：EGL surface 创建兜底 ----------

OLD1 = """    EGLConfig config;
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

NEW1 = """    OHNativeWindow *native_window = vo_ohos_native_window(ctx->vo);

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

if OLD1 in src:
    src = src.replace(OLD1, NEW1, 1)
    print("egl patch: 已注入几何兜底 + config 枚举重试 + 错误码日志")
elif "MovieClaw patch (2/2)" in src:
    print("egl patch: 无变化（已打过补丁）")
else:
    print("egl patch: 目标代码块未匹配！")
    sys.exit(1)

# ---------- 补丁 2：旋转/布局变化自适应（VOCTRL_CHECK_EVENTS 节流轮询） ----------

OLD2_STRUCT = """    OH_NativeVSync *native_vsync;
    int64_t         vsync_period;  // vsync 周期 (ns)
};"""

NEW2_STRUCT = """    OH_NativeVSync *native_vsync;
    int64_t         vsync_period;  // vsync 周期 (ns)
    int             check_events_polls; // VOCTRL_CHECK_EVENTS 轮询节流计数
};"""

OLD2_CTRL = """static int ohos_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    struct priv *p = ctx->priv;
    switch (request) {
    case VOCTRL_GET_DISPLAY_FPS: {
        if (p->vsync_period > 0) {
            *(double *)arg = 1e9 / (double)p->vsync_period;
            return VO_TRUE;
        }
        return VO_NOTIMPL;
    }
    }
    return VO_NOTIMPL;
}"""

NEW2_CTRL = """static int ohos_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    struct priv *p = ctx->priv;
    switch (request) {
    case VOCTRL_GET_DISPLAY_FPS: {
        if (p->vsync_period > 0) {
            *(double *)arg = 1e9 / (double)p->vsync_period;
            return VO_TRUE;
        }
        return VO_NOTIMPL;
    }
    case VOCTRL_CHECK_EVENTS: {
        // MovieClaw rotate patch: ArkUI 旋转/布局变化会静默 resize XComponent 的
        // NativeWindow，wid=surfaceId 模式下 mpv 收不到任何事件。vo 线程每次
        // 循环都会发 CHECK_EVENTS（vo.c），节流轮询真实几何；变化时更新 vo
        // 尺寸 + 刷新 swapchain backbuffer FBO，置 VO_EVENT_RESIZE 让
        // vo_gpu 重算渲染矩形（context_win.c wgl_control 同款模式）。
        if (++p->check_events_polls < 8)
            return VO_TRUE;
        p->check_events_polls = 0;
        int w, h;
        if (vo_ohos_surface_size(ctx->vo, &w, &h)
            && (w != ctx->vo->dwidth || h != ctx->vo->dheight)) {
            MP_WARN(ctx, "surface size changed %dx%d -> %dx%d, adapting\\n",
                    ctx->vo->dwidth, ctx->vo->dheight, w, h);
            ctx->vo->dwidth = w;
            ctx->vo->dheight = h;
            ra_gl_ctx_resize(ctx->swapchain, w, h, 0);
            *events |= VO_EVENT_RESIZE;
        }
        return VO_TRUE;
    }
    }
    return VO_NOTIMPL;
}"""

if "MovieClaw rotate patch" in src:
    print("rotate patch: 无变化（已打过补丁）")
elif OLD2_STRUCT in src and OLD2_CTRL in src:
    src = src.replace(OLD2_STRUCT, NEW2_STRUCT, 1)
    src = src.replace(OLD2_CTRL, NEW2_CTRL, 1)
    print("rotate patch: 已注入 VOCTRL_CHECK_EVENTS 轮询自适应")
else:
    print("rotate patch: 目标代码块未匹配！")
    sys.exit(1)

if src != orig:
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
