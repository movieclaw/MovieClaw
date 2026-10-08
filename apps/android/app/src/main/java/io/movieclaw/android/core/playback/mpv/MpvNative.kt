package io.movieclaw.android.core.playback.mpv

import android.view.Surface

/**
 * MPV JNI 桥(libmovieclaw_jni,源码 cpp/mpv_bridge.cpp)。
 * libmp2.so 为已验证的 libmpv 构建(共享 FFmpeg,清单见 README「预编译依赖」),
 * 经 dlopen 加载、dlsym 解析符号。加载失败置 available=false,上层回退 Exo 而非闪退。
 *
 * `available` 取的是 **libmp2.so 的 dlopen 结果**,不只是我们自己的 JNI 库加载成功:
 * JNI 库永远随源码编出来,只看它的话,一份没带 libmp2.so 的构建(vendored 二进制
 * 没入库时的默认情形)也会把 MPV 选项摆在菜单里——点下去黑屏、不报错、不回退。
 */
object MpvNative {
    var available: Boolean = false
        private set

    init {
        available = try {
            System.loadLibrary("movieclaw_jni")
            nativeMpvAvailable()
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    /** libmp2.so 是否真的加载并解析出符号(C++ 侧的 dlopen 结果) */
    private external fun nativeMpvAvailable(): Boolean

    /** 创建 mpv 核心并绑定 Surface(wid = Surface 全局引用,官方契约) */
    external fun nativeCreate(surface: Surface): Long

    /** 销毁核心(释放 Surface 前必须调用) */
    external fun nativeDestroy(handle: Long)

    /** Surface 被系统重建后重新挂载并恢复 VO */
    external fun nativeAttachSurface(handle: Long, surface: Surface): Boolean

    /** wid=0 + 释放全局引用;必须在 Surface 真正失效前调用 */
    external fun nativeDetachSurface(handle: Long)

    /** 发送 mpv 命令(loadfile/seek/set …) */
    external fun nativeCommand(handle: Long, cmd: String): Boolean

    /** 设置字符串属性 */
    external fun nativeSetProperty(handle: Long, name: String, value: String): Boolean

    /** 读取字符串属性 */
    external fun nativeGetProperty(handle: Long, name: String): String?
}
