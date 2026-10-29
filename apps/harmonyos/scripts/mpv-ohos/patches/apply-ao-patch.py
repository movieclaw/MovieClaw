#!/usr/bin/env python3
"""给 mpv fork 的 audio/out/ao_ohaudio.c 打音频焦点补丁。

原实现不注册 OHAudio 中断回调，来电/其他应用抢焦点时播放不会被打断，
PlaybackGuard（AVSession/长时任务壳）也就拿不到中断事件。

补丁内容：
1. 在 libmpv.so 里导出一个全局函数指针 mpv_ohos_interrupt_hook。
   （不用弱符号 + 跨 .so 符号解析：NAPI 模块是被 dlopen 的，弱符号解析不可靠；
   函数指针由嵌入方在运行时赋值，链接期只依赖 DT_NEEDED。）
2. init() 里注册 SetRendererInterruptCallback，把系统焦点中断转发给该钩子。
幂等：重复执行无副作用。
"""
import re
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# 幂等标记：钩子已存在就不再动文件（防止重复应用产生重复定义）
if "mpv_ohos_interrupt_hook" in src or "SetRendererInterruptCallback" in src:
    print("ao patch: 已打过补丁（检测到标记），跳过")
    raise SystemExit(0)

orig = src

HOOK = '''
// MovieClaw patch: 音频焦点中断要接到嵌入方（PlaybackGuard）。
// 导出函数指针而不是弱符号：libmovieclaw_mpv.so 在 init 时赋值，
// dlopen 场景下函数指针不依赖跨 .so 的未定义符号解析。
__attribute__((visibility("default")))
void (*mpv_ohos_interrupt_hook)(int type, int hint) = NULL;

static void audio_interrupt_callback(OH_AudioRenderer *renderer, void *userData,
                                     OH_AudioInterrupt_ForceType type,
                                     OH_AudioInterrupt_Hint hint)
{
    (void)renderer;
    (void)userData;
    void (*hook)(int, int) = mpv_ohos_interrupt_hook;
    if (hook != NULL)
        hook((int)type, (int)hint);
}

'''

# fork 里签名写作 `static int init(struct ao* ao)`（`*` 靠着 ao），兼容两种空格写法
init_sig = "static int init(struct ao* ao)\n"
src, n = re.subn(r"static int init\(struct ao\s*\*\s*ao\)\n",
                 HOOK + init_sig, src, count=1)

src = src.replace(
    """    OH_AudioRenderer_OnWriteDataCallback callback = audio_on_write_callback;
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(p->builder, callback, ao);
""",
    """    OH_AudioRenderer_OnWriteDataCallback callback = audio_on_write_callback;
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(p->builder, callback, ao);

    // MovieClaw patch: 注册焦点中断回调（来电 / 其他应用抢占）
    OH_AudioStreamBuilder_SetRendererInterruptCallback(p->builder,
                                                       audio_interrupt_callback, ao);
""")

if src == orig:
    print("ao patch: 无变化（模式未匹配！）")
    raise SystemExit(1)
else:
    assert n == 1, "ao patch: init 函数签名未匹配"
    assert "SetRendererInterruptCallback" in src, "ao patch: 回调注册失败"
    assert "mpv_ohos_interrupt_hook" in src, "ao patch: 钩子导出失败"
    with open(path, "w") as f:
        f.write(src)
    print("ao patch: 已注入音频焦点中断转发（函数指针钩子）")
