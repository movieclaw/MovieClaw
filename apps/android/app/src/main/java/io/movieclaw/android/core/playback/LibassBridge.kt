package io.movieclaw.android.core.playback

import android.graphics.Bitmap
import android.util.Log

/**
 * libass 字幕渲染桥（方案 B：画面 Exo 硬解、字幕 libass 叠层）。
 *
 * 对应 `cpp/libass_bridge.cpp`：原生侧 dlopen 已随包发布的 libass.so，
 * 这里只做参数编解码 + 把「覆盖度位图 + 颜色」合成一张 ARGB 位图。
 *
 * 用法：
 * ```
 * LibassBridge.init(w, h, fontsDir)
 * LibassBridge.load(data, "zh.srt")
 * val bmp = LibassBridge.renderFrame(ptsMs)   // 该时刻没有字幕时返回 null
 * ```
 * 全部方法都是同步的，调用方负责放到渲染线程（或播放器的每一帧回调里）。
 */
object LibassBridge {

    private const val TAG = "McAss"

    /** 一帧字幕的最大像素缓冲（1080p 全屏字幕也够；超出部分会被原生侧截断） */
    private const val MAX_PIXELS = 4 * 1024 * 1024

    private var width = 0
    private var height = 0
    private var loaded = false

    init {
        loaded = runCatching { System.loadLibrary("movieclaw_jni"); true }
            .onFailure { Log.w(TAG, "loadLibrary 失败: ${it.message}") }
            .getOrDefault(false)
    }

    val available: Boolean get() = loaded

    /** 初始化渲染器；[fontsDir] 可传应用内字体目录（可空，默认用系统 fontconfig） */
    fun init(w: Int, h: Int, fontsDir: String? = null): Boolean {
        if (!loaded) return false
        width = w; height = h
        val ok = nativeInit(w, h, fontsDir)
        Log.i(TAG, "init($w, $h) -> $ok")
        return ok
    }

    /** 装载字幕内容（ASS / SSA / SRT 的**字节内容**，不是路径） */
    fun load(data: ByteArray, name: String? = null): Boolean {
        if (!loaded) return false
        val ok = nativeLoadData(data, name)
        Log.i(TAG, "load(${data.size} bytes, $name) -> $ok")
        return ok
    }

    /**
     * 渲染 [ptsMs] 时刻的字幕帧，合成到一张 ARGB_8888 位图（尺寸 = init 时的画面尺寸）。
     * 该时刻没有字幕时返回 null（调用方便可直接跳过绘制）。
     */
    fun renderFrame(ptsMs: Long): Bitmap? {
        if (!loaded || width <= 0 || height <= 0) return null
        val out = ByteArray(MAX_PIXELS)
        val meta = nativeRender(ptsMs, out) ?: return null
        if (meta.isEmpty()) return null

        val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        var i = 0
        while (i + 7 < meta.size) {
            val dstX = meta[i]
            val dstY = meta[i + 1]
            val w = meta[i + 2]
            val h = meta[i + 3]
            val color = meta[i + 4]        // 0xAABBGGRR（libass 口径）
            val stride = meta[i + 5]
            val offset = meta[i + 6]
            i += 8
            if (w <= 0 || h <= 0 || stride <= 0) continue

            // 关键：libass 的 color 里 AA 是**透明度**（ASS 规范：00 = 完全不透明），
            // 必须取反当不透明度用；直接用会算出 0 → 整张位图全透明（实机：日志全绿但屏幕无字幕）
            val a = 255 - ((color ushr 24) and 0xFF)
            val b = color and 0xFF
            val g = (color ushr 8) and 0xFF
            val r = (color ushr 16) and 0xFF
            if (a == 0) continue

            val pixels = IntArray(w * h)
            for (y in 0 until h) {
                val rowBase = offset + y * stride
                if (rowBase + w > out.size) break
                for (x in 0 until w) {
                    val coverage = out[rowBase + x].toInt() and 0xFF
                    if (coverage == 0) continue
                    // libass 的位图是「覆盖度」，真正透明度 = 颜色 alpha × 覆盖度
                    val alpha = a * coverage / 255
                    pixels[y * w + x] = (alpha shl 24) or (r shl 16) or (g shl 8) or b
                }
            }
            // 画到合成位图上（越界部分由 Bitmap 自己裁掉）
            bmp.setPixels(pixels, 0, w, dstX.coerceAtLeast(0), dstY.coerceAtLeast(0), w, h)
        }
        return bmp
    }

    fun release() {
        if (loaded) nativeRelease()
    }


    /* ---------------- native ---------------- */

    private external fun nativeInit(w: Int, h: Int, fontsDir: String?): Boolean
    private external fun nativeLoadData(data: ByteArray, name: String?): Boolean
    private external fun nativeRender(ptsMs: Long, outBytes: ByteArray): IntArray?
    private external fun nativeRelease()
}
