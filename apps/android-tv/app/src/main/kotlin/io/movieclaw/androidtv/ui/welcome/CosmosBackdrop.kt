package io.movieclaw.androidtv.ui.welcome

import android.graphics.Bitmap
import android.graphics.ComposeShader
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.SweepGradient
import android.provider.Settings
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random
import java.lang.ref.WeakReference

/*
 * 欢迎页的整屏背景（Apple 端 Shared/Welcome/CosmosBackdrop.swift，同一套美术）：写实、克制的深空。
 * 一片真实感的星空（固定种子，每次看到的都是同一片天）缓缓转动（40 分钟一圈）、偶尔划过一颗流星、
 * 画面下方一道行星的地平线，大气辉光像轨道日出一样慢慢亮起。系统关掉动画（「移除动画」）时星空不转、没有流星。
 *
 * 所有尺寸按 Apple 的点（pt）写，1 pt = 0.5 dp。
 */

private val EaseIn = CubicBezierEasing(0.42f, 0f, 1f, 1f)
private val EaseInOut = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)

/** 转一圈的秒数 */
private const val REVOLUTION_SECONDS = 2400.0

/**
 * @param lit 片头：星空从黑暗中浮现、地平线随后亮起
 * @param dimmed 表单展开时整体压暗 25%，把视线让给卡片
 */
@Composable
fun CosmosBackdrop(lit: Boolean, dimmed: Boolean, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val reduceMotion = remember {
        runCatching { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false)
    }
    BoxWithConstraints(modifier.fillMaxSize().background(Color.Black)) {
        val density = LocalDensity.current.density
        val widthPt = maxWidth.value * 2
        val heightPt = maxHeight.value * 2
        // 星空位图边长取屏幕对角线：旋转到任何角度都铺得满四角
        val sidePt = ceil(sqrt(widthPt * widthPt + heightPt * heightPt))
        // 每 pt 多少像素：最多按 2 倍；位图边长不超过 4000 像素（GPU 纹理上限常是 4096）
        val scale = min(min(density * 0.5f, 2f), 4000f / sidePt)

        var stars by remember { mutableStateOf<ImageBitmap?>(null) }
        var atmosphere by remember { mutableStateOf<ImageBitmap?>(null) }
        LaunchedEffect(sidePt, scale) {
            stars = BitmapCache.stars.get("$sidePt@$scale") {
                StarfieldRenderer.render(sidePt.toDouble(), scale.toDouble()).asImageBitmap()
            }
        }
        LaunchedEffect(widthPt, heightPt, scale) {
            atmosphere = BitmapCache.atmosphere.get("${widthPt}x$heightPt@$scale") {
                PlanetRenderer.atmosphere(widthPt.toDouble(), heightPt.toDouble(), scale.toDouble()).asImageBitmap()
            }
        }
        val starAlpha by animateFloatAsState(if (stars != null) 1f else 0f, tween(2000, easing = EaseIn), label = "stars")
        val sunrise by animateFloatAsState(
            if (lit && atmosphere != null) 1f else 0f,
            tween(4500, delayMillis = if (lit) 1200 else 0, easing = EaseInOut),
            label = "sunrise",
        )
        val rotation = remember { mutableFloatStateOf(0f) }
        if (!reduceMotion) {
            // 0.15°/秒的转动：十分之一秒推一次就足够顺滑（每次挪不到一个像素），只重绘这一层
            LaunchedEffect(Unit) {
                val start = System.nanoTime()
                while (true) {
                    delay(100)
                    val seconds = (System.nanoTime() - start) / 1e9
                    rotation.floatValue = ((seconds / REVOLUTION_SECONDS * 360.0) % 360.0).toFloat()
                }
            }
        }

        Box(Modifier.fillMaxSize().graphicsLayer { alpha = if (lit) 1f else 0f }) {
            stars?.let { image ->
                Canvas(Modifier.fillMaxSize().graphicsLayer { rotationZ = rotation.floatValue; alpha = starAlpha }) {
                    val sidePx = (sidePt * 0.5f * density).roundToInt()
                    drawImage(
                        image,
                        dstOffset = IntOffset(((size.width - sidePx) / 2).roundToInt(), ((size.height - sidePx) / 2).roundToInt()),
                        dstSize = IntSize(sidePx, sidePx),
                    )
                }
            }
            // 画在星空之上、行星之下：划到地平线以下的部分被行星挡住
            if (!reduceMotion) MeteorShower()
            // 行星夜面：不是纯黑，带一点极暗的蓝，和深空分得开
            Canvas(Modifier.fillMaxSize()) {
                val radius = size.width * 2.4f
                rotate(-4f) {
                    drawCircle(Color(0.012f, 0.016f, 0.026f), radius, Offset(size.width / 2, size.height * 0.8f + radius))
                }
                atmosphere?.let { image ->
                    drawImage(
                        image,
                        dstOffset = IntOffset(0, (size.height * PlanetRenderer.TOP).roundToInt()),
                        dstSize = IntSize(size.width.roundToInt(), (size.height * (1 - PlanetRenderer.TOP)).roundToInt()),
                        alpha = sunrise,
                    )
                }
            }
        }
        if (dimmed) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.25f)))
    }
}

/**
 * 渲染好的位图在同时显示的几处（「谁在看」与盖在上面的「添加账号」）之间共用：弱引用，没人显示了就随内存回收。
 */
private object BitmapCache {
    class Slot {
        private var key: String? = null
        private var ref = WeakReference<ImageBitmap>(null)

        suspend fun get(key: String, render: () -> ImageBitmap): ImageBitmap {
            ref.get()?.takeIf { this.key == key }?.let { return it }
            val image = withContext(Dispatchers.Default) { render() }
            this.key = key
            ref = WeakReference(image)
            return image
        }
    }

    val stars = Slot()
    val atmosphere = Slot()
}

/**
 * 流星：出现后 4～9 秒来第一颗，之后每隔 7～18 秒随机划过一颗，同一时间最多一颗。
 * 一道很细的亮线，头部最亮、尾迹渐隐，点燃后迅速变亮、烧到后段熄灭；多数暗淡，偶尔一颗亮的带一点光晕。
 * 平时什么都不画，只有飞的那一秒逐帧重绘。
 */
@Composable
private fun MeteorShower() {
    var meteor by remember { mutableStateOf<Meteor?>(null) }
    val started = remember { mutableLongStateOf(0L) }
    val now = remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        var count = 0
        var wait = Random.nextDouble(4.0, 9.0)
        while (true) {
            delay((wait * 1000).toLong())
            count++
            val next = Meteor.random(count)
            val begin = withFrameNanos { it }
            started.longValue = begin
            now.longValue = begin
            meteor = next
            // 飞完就移除：两颗之间屏幕上什么都不画
            while (now.longValue - begin < next.duration * 1e9) {
                withFrameNanos { now.longValue = it }
            }
            meteor = null
            wait = Random.nextDouble(7.0, 18.0)
        }
    }
    val current = meteor ?: return
    val density = LocalDensity.current.density
    Canvas(Modifier.fillMaxSize()) {
        val pt = 0.5f * density
        val linear = ((now.longValue - started.longValue) / 1e9 / current.duration).coerceIn(0.0, 1.0)
        // 先慢后快：流星冲进大气层时越烧越快
        val progress = linear * linear
        val radians = current.angle * PI / 180
        val dx = cos(radians).toFloat()
        val dy = sin(radians).toFloat()
        val distance = (current.travel * size.width * progress).toFloat()
        val head = Offset(current.startX.toFloat() * size.width + dx * distance, current.startY.toFloat() * size.height + dy * distance)
        // 亮度：点燃后迅速变亮，后段慢慢熄灭；尾迹跟着先拉长再收短
        val glow = sin(PI * progress.pow(0.7)).toFloat()
        val tailLength = (current.length * (0.3 + 0.7 * glow)).toFloat() * pt
        val tail = Offset(head.x - dx * tailLength, head.y - dy * tailLength)
        val alpha = (current.brightness * glow).toFloat().coerceIn(0f, 1f)
        drawLine(
            Brush.linearGradient(listOf(Color.White.copy(alpha = 0f), Color(0.9f, 0.94f, 1f).copy(alpha = 0.85f * alpha)), tail, head),
            tail,
            head,
            strokeWidth = (if (current.brightness > 0.9) 1.6f else 1.1f) * pt,
            cap = StrokeCap.Round,
        )
        drawCircle(Color.White.copy(alpha = alpha), 1.1f * pt, head)
        if (current.brightness > 0.9) {
            val r = 8f * pt
            drawCircle(
                Brush.radialGradient(listOf(Color(0.85f, 0.92f, 1f).copy(alpha = 0.35f * alpha), Color.Transparent), head, r),
                r,
                head,
            )
        }
    }
}

private data class Meteor(
    val id: Int,
    /** 起点（占屏幕宽高的比例） */
    val startX: Double,
    val startY: Double,
    /** 飞行方向（度；屏幕坐标，0 向右、90 向下） */
    val angle: Double,
    /** 飞过的距离（占屏宽的比例） */
    val travel: Double,
    /** 最长时的尾迹长度（pt） */
    val length: Double,
    val duration: Double,
    /** 亮度 0~1：多数在 0.5~0.8，偶尔一颗很亮 */
    val brightness: Double,
) {
    companion object {
        fun random(id: Int): Meteor {
            val towardRight = Random.nextBoolean()
            val bright = Random.nextDouble() < 0.15
            return Meteor(
                id = id,
                startX = if (towardRight) Random.nextDouble(0.05, 0.5) else Random.nextDouble(0.5, 0.95),
                startY = Random.nextDouble(0.04, 0.38),
                angle = if (towardRight) Random.nextDouble(22.0, 40.0) else Random.nextDouble(140.0, 158.0),
                travel = Random.nextDouble(0.28, 0.48),
                length = Random.nextDouble(70.0, 140.0),
                duration = Random.nextDouble(0.7, 1.2),
                brightness = if (bright) 1.0 else Random.nextDouble(0.5, 0.8),
            )
        }
    }
}

/**
 * 地平线上的大气层（夜面朝向我们，太阳正要从右侧升起），后台画进一张位图，日出时整体渐显、不重画。
 *
 * Apple 端是「描边 + 高斯模糊 + 抹掉行星本体那半边」。这里不用模糊滤镜（大圆描边加模糊的离屏缓冲太大，
 * 老电视上也不一定支持），而是按同样的参数算出辉光沿半径的强度分布，用一道径向渐变画出来：
 * 颜色沿弧线变化（锥形渐变），强度沿半径变化（径向渐变），两者相乘。效果与模糊描边相同。
 */
private object PlanetRenderer {
    /** 位图只覆盖屏幕下半部分（地平线和辉光都在这里） */
    const val TOP = 0.5f

    /** 大气层沿弧线的颜色：色标压在 -104° 起的 34° 里（可见的弧大约是 -102° 到 -78°） */
    private const val SPAN = 34f / 360f
    private val rimColors = intArrayOf(
        argb(0.2, 0.3, 0.48, 0.85),
        argb(0.6, 0.42, 0.64, 1.0),
        argb(1.0, 0.72, 0.85, 1.0),
        argb(1.0, 1.0, 0.84, 0.64),
        argb(1.0, 1.0, 0.95, 0.86),
    )
    private val rimStops = floatArrayOf(0f, 0.45f * SPAN, 0.8f * SPAN, 0.93f * SPAN, SPAN)

    fun atmosphere(widthPt: Double, heightPt: Double, scale: Double): Bitmap {
        val top = heightPt * TOP
        val bitmap = Bitmap.createBitmap(
            ceil(widthPt * scale).toInt().coerceAtLeast(1),
            ceil((heightPt - top) * scale).toInt().coerceAtLeast(1),
            Bitmap.Config.ARGB_8888,
        )
        val canvas = android.graphics.Canvas(bitmap)
        canvas.scale(scale.toFloat(), scale.toFloat())
        canvas.translate(0f, -top.toFloat())
        // 地平线微微倾斜（绕屏幕中心转 -4°）：真实的轨道照片很少是水平的
        canvas.rotate(-4f, (widthPt / 2).toFloat(), (heightPt / 2).toFloat())
        val radius = widthPt * 2.4
        val cx = (widthPt / 2).toFloat()
        val cy = (heightPt * 0.8 + radius).toFloat()

        val sweep = SweepGradient(cx, cy, rimColors, rimStops).apply {
            setLocalMatrix(Matrix().apply { setRotate(-104f, cx, cy) })
        }
        val extent = 170.0
        val outer = radius + extent
        val samples = profileSamples()
        val positions = FloatArray(samples.size + 1)
        val alphas = IntArray(samples.size + 1)
        positions[0] = 0f
        alphas[0] = 0
        samples.forEachIndexed { i, d ->
            positions[i + 1] = ((radius + d) / outer).toFloat()
            alphas[i + 1] = argb(rimAlpha(d), 0.0, 0.0, 0.0)
        }
        val profile = RadialGradient(cx, cy, outer.toFloat(), alphas, positions, Shader.TileMode.CLAMP)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { shader = ComposeShader(sweep, profile, PorterDuff.Mode.DST_IN) }
        canvas.drawCircle(cx, cy, outer.toFloat(), paint)

        // 可见弧右端：太阳就在它后面，叠一团很淡的暖光
        val dawn = -79.0 * PI / 180
        val px = (cx + radius * cos(dawn)).toFloat()
        val py = (cy + radius * sin(dawn)).toFloat()
        val warm = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(px, py, 110f, intArrayOf(argb(0.16, 1.0, 0.86, 0.7), argb(0.0, 1.0, 0.86, 0.7)), null, Shader.TileMode.CLAMP)
        }
        canvas.drawCircle(px, py, 110f, warm)
        return bitmap
    }

    /** 采样点：离地平线的距离（pt，负数在行星里面），越靠近边缘越密 */
    private fun profileSamples(): List<Double> {
        val near = listOf(-4.0, -2.0, -1.2, -0.8, -0.4, -0.1, 0.0, 0.1, 0.4, 0.8, 1.2, 2.0, 3.0, 4.5)
        val far = (1..40).map { 4.5 + it * 3.9 }
        return near + far
    }

    /**
     * 离地平线 [d] pt 处大气层的不透明度：两道模糊的辉光（56pt 宽、模糊 38、0.22；10pt 宽、模糊 7、0.45，
     * 只在行星外面——里面那半被行星挡住）叠一道 1.2pt 的边缘亮线（模糊 0.5）。三层同色，按「上层盖下层」合成。
     */
    private fun rimAlpha(d: Double): Double {
        val outside = if (d >= 0) 1.0 else 0.0
        val glowWide = 0.22 * blurredStroke(d, 56.0, 38.0) * outside
        val glowNarrow = 0.45 * blurredStroke(d, 10.0, 7.0) * outside
        val edge = blurredStroke(d, 1.2, 0.5)
        return 1 - (1 - glowWide) * (1 - glowNarrow) * (1 - edge)
    }

    /** 宽 [width] 的描边经 σ = [sigma] 的高斯模糊后，在离中线 [d] 处的覆盖率 */
    private fun blurredStroke(d: Double, width: Double, sigma: Double): Double {
        val k = sigma * sqrt(2.0)
        return (0.5 * (erf((d + width / 2) / k) - erf((d - width / 2) / k))).coerceIn(0.0, 1.0)
    }

    /** 误差函数（Abramowitz–Stegun 7.1.26，误差 < 1.5e-7） */
    private fun erf(x: Double): Double {
        val t = 1 / (1 + 0.3275911 * abs(x))
        val y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x)
        return if (x >= 0) y else -y
    }
}

private fun argb(a: Double, r: Double, g: Double, b: Double): Int =
    android.graphics.Color.argb(
        (a.coerceIn(0.0, 1.0) * 255).roundToInt(),
        (r.coerceIn(0.0, 1.0) * 255).roundToInt(),
        (g.coerceIn(0.0, 1.0) * 255).roundToInt(),
        (b.coerceIn(0.0, 1.0) * 255).roundToInt(),
    )

/**
 * 把整片星空一次性画进一张位图（后台线程执行），逐行对齐 Apple 端 StarfieldRenderer（同一个种子、同样的三步）：
 * 1. 银河的弥散光：沿星带铺几百团极淡的柔光，亮度由分形噪声调制成一块块星云，再被尘埃带挖暗；
 * 2. 银河的星点：几万颗极暗的小星，同样按噪声与尘埃带取舍；
 * 3. 前景恒星：一千多颗，亮度按幂律分布，颜色按色温取，亮星加一圈光晕。
 * Core Graphics 的坐标 y 轴朝上，这里先翻过来，画出来和 Apple 端是同一片天。
 */
private object StarfieldRenderer {
    fun render(side: Double, scale: Double): Bitmap {
        val pixels = (side * scale).toInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(pixels, pixels, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        canvas.translate(0f, pixels.toFloat())
        canvas.scale(scale.toFloat(), -scale.toFloat())
        val rng = SeededRandom(0x4D6F_7669_6543_6C61L) // "MovieCla"
        val band = Band(side)
        drawGalacticGlow(canvas, band, rng)
        drawGalacticStars(canvas, band, rng)
        drawFieldStars(canvas, side, band, rng)
        return bitmap
    }

    /** 银河星带的几何：一条斜穿画面的直线，星带宽度按高斯分布衰减；一端是更亮的银心方向 */
    private class Band(val side: Double) {
        val ox = side * 0.5
        val oy = side * 0.44
        private val angle = 58.0 * PI / 180
        val ax = cos(angle)
        val ay = sin(angle)
        val nx = -sin(angle)
        val ny = cos(angle)
        val sigma = side * 0.085

        fun x(t: Double, offset: Double) = ox + ax * t + nx * offset
        fun y(t: Double, offset: Double) = oy + ay * t + ny * offset

        /** 某点的银河亮度（0~1）：星带高斯衰减 × 银心方向渐强 × 星云纹理 × 尘埃带 */
        fun density(px: Double, py: Double): Double {
            val dx = px - ox
            val dy = py - oy
            val across = (dx * nx + dy * ny) / sigma
            val lengthwise = (dx * ax + dy * ay) / side
            val profile = exp(-across * across)
            val core = 0.45 + 0.55 * exp(-((lengthwise + 0.18) / 0.32).pow(2))
            val clouds = Noise.smoothstep(0.32, 0.78, Noise.fbm(px / 95, py / 95, 11))
            // 尘埃带：星带中线附近被一条条暗缝切开
            val dust = Noise.smoothstep(0.5, 0.66, Noise.fbm(px / 42, py / 42, 29)) * exp(-(across / 0.55).pow(2))
            return profile * core * clouds * (1 - 0.85 * dust)
        }
    }

    private fun drawGalacticGlow(canvas: android.graphics.Canvas, band: Band, rng: SeededRandom) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        repeat(360) {
            val t = (rng.next() - 0.5) * band.side * 1.5
            val offset = rng.gaussian() * band.sigma
            val x = band.x(t, offset)
            val y = band.y(t, offset)
            val strength = band.density(x, y)
            if (strength <= 0.02) return@repeat
            val radius = 16 + 34 * rng.next()
            val alpha = 0.045 * strength
            paint.shader = RadialGradient(
                x.toFloat(), y.toFloat(), radius.toFloat(),
                intArrayOf(argb(alpha, 0.93, 0.92, 0.9), argb(0.0, 0.93, 0.92, 0.9)), null, Shader.TileMode.CLAMP,
            )
            canvas.drawCircle(x.toFloat(), y.toFloat(), radius.toFloat(), paint)
        }
    }

    private fun drawGalacticStars(canvas: android.graphics.Canvas, band: Band, rng: SeededRandom) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        repeat(70_000) {
            val t = (rng.next() - 0.5) * band.side * 1.5
            val offset = rng.gaussian() * band.sigma * 1.2
            val x = band.x(t, offset)
            val y = band.y(t, offset)
            if (rng.next() >= band.density(x, y)) return@repeat
            val alpha = 0.05 + 0.3 * rng.next().pow(2)
            val radius = 0.28 + 0.25 * rng.next()
            // 银心附近偏暖，外侧偏冷
            val warm = rng.next() < 0.5
            paint.color = if (warm) argb(alpha, 1.0, 0.95, 0.88) else argb(alpha, 0.88, 0.92, 1.0)
            canvas.drawCircle(x.toFloat(), y.toFloat(), radius.toFloat(), paint)
        }
    }

    private fun drawFieldStars(canvas: android.graphics.Canvas, side: Double, band: Band, rng: SeededRandom) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val halo = Paint(Paint.ANTI_ALIAS_FLAG)
        for (index in 0 until 1700) {
            // 前 1100 颗均匀撒满全天，后 600 颗沿星带加密
            val x: Double
            val y: Double
            if (index < 1100) {
                x = rng.next() * side
                y = rng.next() * side
            } else {
                val t = (rng.next() - 0.5) * side * 1.5
                val offset = rng.gaussian() * band.sigma * 1.6
                x = band.x(t, offset)
                y = band.y(t, offset)
            }
            // 亮度按幂律：绝大多数星都很暗，显眼的亮星只有几十颗
            val brightness = rng.next().pow(if (index < 1100) 7 else 9)
            val radius = 0.26 + 0.75 * brightness.pow(0.8)
            val alpha = 0.16 + 0.84 * brightness.pow(0.55)
            val (r, g, b) = temperatureColor(rng.next())
            if (brightness > 0.55) {
                // 只有最亮的几十颗带光晕：很淡、很小，不是卡通的光圈
                val glow = radius * 2.6 + 3 * brightness
                halo.shader = RadialGradient(
                    x.toFloat(), y.toFloat(), glow.toFloat(),
                    intArrayOf(argb(0.16 * brightness, r, g, b), argb(0.0, r, g, b)), null, Shader.TileMode.CLAMP,
                )
                canvas.drawCircle(x.toFloat(), y.toFloat(), glow.toFloat(), halo)
            }
            paint.color = argb(alpha, r, g, b)
            canvas.drawCircle(x.toFloat(), y.toFloat(), radius.toFloat(), paint)
        }
    }

    /** 恒星颜色按色温抽样：蓝白、白、淡黄（像太阳）、橙，都压得很淡 */
    private fun temperatureColor(u: Double): Triple<Double, Double, Double> = when {
        u < 0.22 -> Triple(0.8, 0.87, 1.0)
        u < 0.68 -> Triple(1.0, 1.0, 1.0)
        u < 0.9 -> Triple(1.0, 0.95, 0.85)
        else -> Triple(1.0, 0.84, 0.66)
    }
}

/** 固定种子的伪随机数（SplitMix64）：同一个种子永远生成同一片星空 */
private class SeededRandom(seed: Long) {
    private var state = seed

    /** 0~1 均匀分布 */
    fun next(): Double {
        state += -0x61c8864680b583ebL // 0x9E3779B97F4A7C15
        var z = state
        z = (z xor (z ushr 30)) * -0x40a7b892e31b1a47L // 0xBF58476D1CE4E5B9
        z = (z xor (z ushr 27)) * -0x6b2fb644ecceee15L // 0x94D049BB133111EB
        z = z xor (z ushr 31)
        return (z ushr 11).toDouble() / (1L shl 53).toDouble()
    }

    /** 标准正态分布（Box-Muller） */
    fun gaussian(): Double {
        val u = maxOf(next(), 1e-12)
        return sqrt(-2 * ln(u)) * cos(2 * PI * next())
    }
}

/** 值噪声 + 分形叠加：给银河加上一块块的星云纹理与尘埃暗缝 */
private object Noise {
    fun fbm(x: Double, y: Double, seed: Int): Double {
        var total = 0.0
        var amplitude = 0.5
        var frequency = 1.0
        var norm = 0.0
        for (octave in 0 until 5) {
            total += amplitude * value(x * frequency, y * frequency, seed + octave * 131)
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return total / norm
    }

    fun smoothstep(edge0: Double, edge1: Double, x: Double): Double {
        val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0.0, 1.0)
        return t * t * (3 - 2 * t)
    }

    private fun value(x: Double, y: Double, seed: Int): Double {
        val xi = floor(x).toLong()
        val yi = floor(y).toLong()
        val fx = x - floor(x)
        val fy = y - floor(y)
        val ux = fx * fx * (3 - 2 * fx)
        val uy = fy * fy * (3 - 2 * fy)
        val a = hash(xi, yi, seed)
        val b = hash(xi + 1, yi, seed)
        val c = hash(xi, yi + 1, seed)
        val d = hash(xi + 1, yi + 1, seed)
        return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
    }

    /** 同 Swift 的 64 位整数溢出运算（&* &+） */
    private fun hash(x: Long, y: Long, seed: Int): Double {
        var h = x * 374_761_393L + y * 668_265_263L + seed.toLong() * 1_274_126_177L
        h = (h xor (h ushr 13)) * 0x5851F42D4C957F2DL
        h = h xor (h ushr 29)
        return (h and 0xFFFFFF).toDouble() / 0xFFFFFF.toDouble()
    }
}
