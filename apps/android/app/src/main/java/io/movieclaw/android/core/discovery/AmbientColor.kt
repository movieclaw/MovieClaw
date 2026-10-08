package io.movieclaw.android.core.discovery

import android.graphics.Bitmap
import androidx.compose.ui.graphics.Color
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** 氛围色（0~255） */
data class AmbientRgb(val r: Int, val g: Int, val b: Int) {
    fun toColor(): Color = Color(r, g, b)
}

/**
 * 沉浸式 Hero 的「氛围底色」取色 —— 与移动端网页 lib/hero-ambient-color.ts 同一套算法
 * （该文件又是从 iOS Im[mersiveHeroAmbientColor 移植的，三端同源）。
 *
 * 规则（逐条对齐网页实现）：
 *  1. 缩到 24×24 取样；
 *  2. 每个像素按 **饱和度² × (亮度 + 0.25)** 加权；
 *  3. 色相按**单位圆**求平均（cos/sin 累加再 atan2）——直接平均红色 0/1 两端会相消；
 *  4. 灰黑白不参与（亮度 ≤ 0.12 或色差 ≤ 0.04）；
 *  5. 结果**亮度统一压到 0.44**、饱和度夹在 0.28~0.72 —— 上面的白字永远读得清；
 *  6. 有效权重太少（黑白片、夜景这种灰调剧照）回落冷银灰。
 *
 * 实测校验：网页端同算法算出的 rgb(34,92,112)/rgb(49,112,69)，
 * 与实例上 getComputedStyle 抓到的氛围层 rgba(35,92,112)/rgba(49,112,70) 只差 1。
 */
object AmbientColor {

    /** 灰调剧照的回落色：冷银灰（HSB 0.61 / 0.14 / 0.36） */
    val FALLBACK = hsbToRgb(0.61f, 0.14f, 0.36f)

    /** 取样边长 */
    private const val SIDE = 24

    /** 亮度档（实测 0.44，六个样本的最大通道都正好是 112 = 0.439×255） */
    private const val BRIGHTNESS = 0.44f

    /** ARGB 像素数组 → 氛围色；纯函数，便于单测 */
    fun fromPixels(argb: IntArray): AmbientRgb {
        var x = 0.0
        var y = 0.0
        var saturationSum = 0.0
        var weightSum = 0.0
        for (pixel in argb) {
            val r = ((pixel shr 16) and 0xFF) / 255.0
            val g = ((pixel shr 8) and 0xFF) / 255.0
            val b = (pixel and 0xFF) / 255.0
            val maxC = max(r, max(g, b))
            val minC = min(r, min(g, b))
            val delta = maxC - minC
            if (maxC <= 0.12 || delta <= 0.04) continue
            val s = delta / maxC
            var hue = when (maxC) {
                r -> (g - b) / delta
                g -> 2 + (b - r) / delta
                else -> 4 + (r - g) / delta
            } / 6.0
            if (hue < 0) hue += 1.0
            val weight = s * s * (maxC + 0.25)
            x += cos(hue * 2 * Math.PI) * weight
            y += sin(hue * 2 * Math.PI) * weight
            saturationSum += s * weight
            weightSum += weight
        }
        if (weightSum <= 2.0) return FALLBACK
        var hue = atan2(y, x) / (2 * Math.PI)
        if (hue < 0) hue += 1.0
        val meanSaturation = saturationSum / weightSum
        return hsbToRgb(
            hue.toFloat(),
            min(0.72f, max(0.28f, (meanSaturation * 1.1).toFloat())),
            BRIGHTNESS,
        )
    }

    /** 位图 → 氛围色（内部先缩到 24×24 再取像素） */
    fun fromBitmap(bitmap: Bitmap): AmbientRgb {
        val scaled = Bitmap.createScaledBitmap(bitmap, SIDE, SIDE, true)
        val pixels = IntArray(SIDE * SIDE)
        scaled.getPixels(pixels, 0, SIDE, 0, 0, SIDE, SIDE)
        if (scaled !== bitmap) scaled.recycle()
        return fromPixels(pixels)
    }

    /**
     * 底部色带取色（iOS HeroEdgeColor）：剧照**底部 6% 色带**的平均色，
     * 饱和度 ×1.1（上限 1）、亮度钉在 0.34 以下。
     *
     * 英雄大图是「底部淡出」的，所以衔接处的底色必须取底部那一带的颜色，
     * 而不是整张图的主色——否则溶解末端（暗）与底色（提亮后的主色）不同族，
     * 眼睛会读到一次颜色跳变（实机踩过）。
     */
    fun fromBottomBand(bitmap: Bitmap): AmbientRgb {
        val w = bitmap.width
        val h = bitmap.height
        val bandTop = (h * 0.94f).toInt().coerceIn(0, h - 1)
        val bandH = (h - bandTop).coerceAtLeast(1)
        val sw = 24
        val sh = 4
        val scaled = Bitmap.createScaledBitmap(bitmap, sw, sh, true)
        val pixels = IntArray(sw * sh)
        scaled.getPixels(pixels, 0, sw, 0, 0, sw, sh)
        if (scaled !== bitmap) scaled.recycle()
        // 只取缩放后对应的底部几行（原图底部 6% 在 sh=4 时即最后一行）
        val rows = maxOf(1, (sh * (bandH.toFloat() / h)).toInt())
        var r = 0L; var g = 0L; var b = 0L; var n = 0
        for (y in (sh - rows) until sh) {
            for (x in 0 until sw) {
                val c = pixels[y * sw + x]
                r += (c shr 16) and 0xFF; g += (c shr 8) and 0xFF; b += c and 0xFF; n++
            }
        }
        if (n == 0) return FALLBACK
        val rf = r.toFloat() / n / 255f
        val gf = g.toFloat() / n / 255f
        val bf = b.toFloat() / n / 255f
        val maxC = maxOf(rf, gf, bf); val minC = minOf(rf, gf, bf)
        val v = maxC
        val s = if (maxC <= 0f) 0f else (maxC - minC) / maxC
        val hDeg = when (maxC) {
            minC -> 0f
            rf -> 60f * (((gf - bf) / (maxC - minC)) % 6f)
            gf -> 60f * (((bf - rf) / (maxC - minC)) + 2f)
            else -> 60f * (((rf - gf) / (maxC - minC)) + 4f)
        }
        val hue = ((hDeg / 360f) + 1f) % 1f
        val sat = (s * 1.1f).coerceAtMost(1f)
        val bri = v.coerceAtMost(0.34f)
        return hsbToRgb(hue, sat, bri)
    }

    /** HSB（均 0~1）→ RGB（0~255），与 SwiftUI Color(hue:saturation:brightness:) 同一换算 */
    fun hsbToRgb(hue: Float, saturation: Float, brightness: Float): AmbientRgb {
        val h = (((hue % 1f) + 1f) % 1f) * 6f
        val c = brightness * saturation
        val x = c * (1 - abs((h % 2f) - 1))
        val m = brightness - c
        val rgb = when {
            h < 1 -> floatArrayOf(c, x, 0f)
            h < 2 -> floatArrayOf(x, c, 0f)
            h < 3 -> floatArrayOf(0f, c, x)
            h < 4 -> floatArrayOf(0f, x, c)
            h < 5 -> floatArrayOf(x, 0f, c)
            else -> floatArrayOf(c, 0f, x)
        }
        return AmbientRgb(
            (((rgb[0] + m) * 255).toInt()),
            (((rgb[1] + m) * 255).toInt()),
            (((rgb[2] + m) * 255).toInt()),
        )
    }
}
