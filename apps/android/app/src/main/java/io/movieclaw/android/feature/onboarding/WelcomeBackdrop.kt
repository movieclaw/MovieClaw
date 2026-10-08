package io.movieclaw.android.feature.onboarding

import android.graphics.BlurMaskFilter
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.nativeCanvas
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin
import kotlin.random.Random

/**
 * 登录/欢迎页的背景 —— 与移动端网页同一套做法（components/cosmos-backdrop.tsx +
 * lib/welcome-starfield.ts）：
 *
 *   · 星空：整张绕屏幕中心**约 40 分钟转一圈**（2400s）。星带沿 58° 方向，
 *     星点亮度按 rnd^7 分布（少数很亮、多数很暗），暖冷两色，亮星带一圈柔光，
 *     另有一层银河带的柔和光斑。
 *   · 地平线：半径 = 视口宽 ×2.4 的巨大球体，**只画可见那段弧**（−110°～−70°）——
 *     整圆直径是视口近五倍，模糊滤镜按整圆包围盒分配缓冲会非常吃内存（原生 App 踩过）。
 *     弧上三层大气辉光（56/blur38、10/blur7、1.2/blur0.5），色标左冷蓝 →
 *     近太阳处转暖，另有一团日出光晕；整体绕视口中心转 −4°。
 */
@Composable
fun StarfieldBackdrop(modifier: Modifier = Modifier, spins: Boolean = true) {
    val transition = rememberInfiniteTransition(label = "starfield")
    val angle by transition.animateFloat(
        initialValue = 0f,
        targetValue = if (spins) 360f else 0f,
        animationSpec = infiniteRepeatable(tween(2_400_000, easing = LinearEasing), RepeatMode.Restart),
        label = "starfield-angle",
    )
    val stars = remember { generateStars() }

    Canvas(modifier.fillMaxSize()) {
        val w = size.width * 2f
        val h = size.height * 2f
        val cx = size.width / 2f
        val cy = size.height / 2f
        val rad = 58f * (Math.PI / 180f).toFloat()
        val ax = cos(rad)
        val ay = sin(rad)
        val nx = -ay
        val ny = ax

        drawIntoCanvas { canvas ->
            val np = canvas.nativeCanvas
            np.save()
            np.rotate(angle, cx, cy)

            // 银河带：沿 58° 的柔和光斑
            val bandPaint = Paint().apply { isAntiAlias = true; color = 0xFFEDEBE6.toInt() }
            stars.glows.forEach { g ->
                val t = g.t * w * 0.95f
                val off = g.off * h * 0.075f
                bandPaint.maskFilter = BlurMaskFilter(g.radius, BlurMaskFilter.Blur.NORMAL)
                bandPaint.alpha = (g.alpha * 255f).toInt().coerceIn(0, 255)
                np.drawCircle(cx + ax * t + nx * off, cy + ay * t + ny * off, g.radius * 0.55f, bandPaint)
            }
            bandPaint.maskFilter = null

            // 星点（亮度按 rnd^7 分布，暖冷两色）
            val starPaint = Paint().apply { isAntiAlias = true }
            stars.dots.forEach { s ->
                val t = s.t * w * 0.95f
                val off = s.off * h * 0.10f
                val x = cx + ax * t + nx * off
                val y = cy + ay * t + ny * off
                if (s.brightness > 0.55f) {
                    starPaint.maskFilter =
                        BlurMaskFilter(s.radius * 2.6f + 3f * s.brightness, BlurMaskFilter.Blur.NORMAL)
                    starPaint.color = if (s.warm) 0xFFFFF2E0.toInt() else 0xFFE0EBFF.toInt()
                    starPaint.alpha = (0.16f * s.brightness * 255f).toInt().coerceIn(0, 255)
                    np.drawCircle(x, y, s.radius * 2.2f, starPaint)
                    starPaint.maskFilter = null
                }
                starPaint.color = if (s.warm) 0xFFFFF2E0.toInt() else 0xFFE0EBFF.toInt()
                starPaint.alpha = (s.alpha * 255f).toInt().coerceIn(0, 255)
                np.drawCircle(x, y, s.radius, starPaint)
            }
            np.restore()
        }
    }
}

/**
 * 行星地平线（下方那颗巨大的夜面球体 + 一线大气）。
 * 只画可见那段弧，理由见文件头注释。`reveal` 0→1 控制大气渐显（实测 4.5s、延迟 1.2s）。
 */
@Composable
fun PlanetHorizon(modifier: Modifier = Modifier, reveal: Float = 1f) {
    Canvas(modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height
        val r = w * 2.4f
        val cx = w / 2f
        val cy = h * 0.8f + r
        fun at(deg: Float): Offset {
            val a = deg * (Math.PI / 180f).toFloat()
            return Offset(cx + r * cos(a), cy + r * sin(a))
        }
        val p2 = at(-70f)
        val nativeArc = android.graphics.Path().apply {
            arcTo(RectF(cx - r, cy - r, cx + r, cy + r), -110f, 40f)
        }
        // 行星夜面（不是纯黑，带一点极暗的蓝）
        val body = Path().apply {
            moveTo(at(-110f).x, at(-110f).y)
            arcTo(androidx.compose.ui.geometry.Rect(cx - r, cy - r, cx + r, cy + r), -110f, 40f, forceMoveTo = false)
            lineTo(p2.x, h + 400f)
            lineTo(at(-110f).x, h + 400f)
            close()
        }
        val rim = Brush.horizontalGradient(
            0f to Color(0xFF4D7AD9),
            0.45f to Color(0xFF6BA3FF),
            0.8f to Color(0xFFB8D9FF),
            0.93f to Color(0xFFFFD6A3),
            1f to Color(0xFFFFF2DB),
            startX = at(-104f).x,
            endX = p2.x,
        )
        rotate(-4f, Offset(cx, cy)) {
            drawPath(body, Color(0xFF03040A))
            if (reveal > 0.001f) {
                drawIntoCanvas { canvas ->
                    val np = canvas.nativeCanvas
                    np.save()
                    // 抹掉落在行星本体上的那半边辉光（行星挡住了身后的大气）
                    np.clipPath(nativeArc, android.graphics.Region.Op.INTERSECT)
                    val wide = Paint().apply {
                        style = Paint.Style.STROKE
                        strokeWidth = 56f
                        isAntiAlias = true
                        maskFilter = BlurMaskFilter(38f, BlurMaskFilter.Blur.NORMAL)
                        color = 0xFF6BA3FF.toInt()
                        alpha = (0.22f * reveal * 255f).toInt()
                    }
                    np.drawPath(nativeArc, wide)
                    val mid = Paint().apply {
                        style = Paint.Style.STROKE
                        strokeWidth = 10f
                        isAntiAlias = true
                        maskFilter = BlurMaskFilter(7f, BlurMaskFilter.Blur.NORMAL)
                        color = 0xFFFFF2DB.toInt()
                        alpha = (0.45f * reveal * 255f).toInt()
                    }
                    np.drawPath(nativeArc, mid)
                    np.restore()
                }
                // 细亮线（大气边缘）
                drawPath(path = bodyPathArc(cx, cy, r), brush = rim, style = Stroke(width = 1.2f), alpha = reveal)
                // 日出光晕
                val dawn = at(-79f)
                drawCircle(
                    brush = Brush.radialGradient(
                        listOf(Color(0x29FFDBB2), Color.Transparent),
                        center = dawn,
                        radius = 110f,
                    ),
                    radius = 110f,
                    center = dawn,
                    alpha = reveal,
                )
            }
        }
    }
}

private fun bodyPathArc(cx: Float, cy: Float, r: Float): Path = Path().apply {
    arcTo(androidx.compose.ui.geometry.Rect(cx - r, cy - r, cx + r, cy + r), -110f, 40f, forceMoveTo = true)
}

private class Dot(
    val t: Float,
    val off: Float,
    val radius: Float,
    val alpha: Float,
    val brightness: Float,
    val warm: Boolean,
)

private class Glow(val t: Float, val off: Float, val radius: Float, val alpha: Float)

private class Starfield(val glows: List<Glow>, val dots: List<Dot>)

private fun generateStars(): Starfield {
    val rnd = Random(0x4d6f7669) // "Movi"
    val glows = (0 until 340).map {
        val t = (rnd.nextFloat() - 0.5f) * 1.9f
        val off = (rnd.nextFloat() + rnd.nextFloat() + rnd.nextFloat() - 1.5f) * 1.15f
        val k = (t / 2f + 0.18f) / 0.32f
        val core = 0.45f + 0.55f * exp(-(k * k).toDouble()).toFloat()
        Glow(
            t = t,
            off = off,
            radius = (16f + 34f * rnd.nextFloat()) * core,
            alpha = 0.022f * core * (0.4f + rnd.nextFloat() * 0.6f),
        )
    }
    val dots = (0 until 1500).map { i ->
        val t = (rnd.nextFloat() - 0.5f) * 1.9f
        val off = (rnd.nextFloat() + rnd.nextFloat() + rnd.nextFloat() - 1.5f) * 1.35f
        val b = rnd.nextFloat().pow(if (i < 1100) 7f else 9f)
        Dot(
            t = t,
            off = off,
            radius = 0.28f + 0.78f * b.pow(0.8f),
            alpha = 0.20f + 0.80f * b.pow(0.45f),
            brightness = b,
            warm = rnd.nextFloat() < 0.5f,
        )
    }
    return Starfield(glows, dots)
}
