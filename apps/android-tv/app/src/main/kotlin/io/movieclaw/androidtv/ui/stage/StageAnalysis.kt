package io.movieclaw.androidtv.ui.stage

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.ui.graphics.Color
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

/**
 * 剧照分析（TVStageEdgeColor、TVStageCornerScrim）：都量同一张 240 宽的小图。
 * - 边缘色：左 6% 与下 8% 两条的平均色，饱和度 ×1.1、亮度封顶 0.3（左边压着白字，底色再亮字就读不清）；
 * - 托字压暗的深浅：文字会落的那一块（左 55%，详情页再只取下 65%）缩成 24×24，取第 80 百分位亮度，
 *   `clamp(0.15 + (luma − 0.3) / 0.45 × 0.5, 下限, 0.65)`，首页下限 0.3、详情页 0.15。
 */
object StageAnalysis {
    private val edge = ConcurrentHashMap<String, Color>()
    private val scrim = ConcurrentHashMap<String, Float>()

    suspend fun edgeColor(context: Context, url: String): Color? {
        edge[url]?.let { return it }
        val bitmap = load(context, url) ?: return null
        val color = withContext(Dispatchers.Default) {
            val w = bitmap.width
            val h = bitmap.height
            var r = 0.0
            var g = 0.0
            var b = 0.0
            var n = 0
            fun strip(x0: Int, y0: Int, x1: Int, y1: Int) {
                val stepX = maxOf(1, (x1 - x0) / 16)
                val stepY = maxOf(1, (y1 - y0) / 16)
                var y = y0
                while (y < y1) {
                    var x = x0
                    while (x < x1) {
                        val p = bitmap.getPixel(x, y)
                        r += (p shr 16 and 0xFF); g += (p shr 8 and 0xFF); b += (p and 0xFF); n++
                        x += stepX
                    }
                    y += stepY
                }
            }
            strip(0, 0, maxOf(1, (w * 0.06).toInt()), h)
            strip(0, (h * 0.92).toInt(), w, h)
            if (n == 0) return@withContext null
            val hsv = FloatArray(3)
            android.graphics.Color.RGBToHSV((r / n).toInt(), (g / n).toInt(), (b / n).toInt(), hsv)
            hsv[1] = minOf(1f, hsv[1] * 1.1f)
            hsv[2] = minOf(0.3f, hsv[2])
            Color(android.graphics.Color.HSVToColor(hsv))
        } ?: return null
        edge[url] = color
        return color
    }

    suspend fun scrimStrength(context: Context, url: String, corner: Boolean): Float? {
        val key = "$corner|$url"
        scrim[key]?.let { return it }
        val bitmap = load(context, url) ?: return null
        val strength = withContext(Dispatchers.Default) {
            val w = bitmap.width
            val h = bitmap.height
            val top = if (corner) (h * 0.35).toInt() else 0
            val right = maxOf(1, (w * 0.55).toInt())
            val lumas = ArrayList<Double>(576)
            for (j in 0 until 24) for (i in 0 until 24) {
                val x = minOf(w - 1, i * right / 24)
                val y = minOf(h - 1, top + j * (h - top) / 24)
                lumas += srgbLuma(bitmap.getPixel(x, y))
            }
            lumas.sort()
            val luma = lumas[((lumas.size - 1) * 0.8).toInt()]
            val floor = if (corner) 0.15 else 0.3
            minOf(0.65, maxOf(floor, 0.15 + (luma - 0.3) / 0.45 * 0.5)).toFloat()
        }
        scrim[key] = strength
        return strength
    }

    private fun srgbLuma(p: Int): Double =
        (0.2126 * (p shr 16 and 0xFF) + 0.7152 * (p shr 8 and 0xFF) + 0.0722 * (p and 0xFF)) / 255

    private suspend fun load(context: Context, url: String): Bitmap? {
        val request = ImageRequest.Builder(context).data(url).allowHardware(false).build()
        val result = SingletonImageLoader.get(context).execute(request) as? SuccessResult ?: return null
        return result.image.toBitmap()
    }
}
