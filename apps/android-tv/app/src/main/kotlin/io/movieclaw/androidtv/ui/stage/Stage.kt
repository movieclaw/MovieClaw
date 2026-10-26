package io.movieclaw.androidtv.ui.stage

import android.graphics.ComposeShader
import android.graphics.PorterDuff
import android.os.Build
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.LinearGradientShader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import io.movieclaw.androidtv.ui.components.Text
import coil3.compose.AsyncImage
import coil3.compose.AsyncImagePainter
import coil3.request.ImageRequest
import io.movieclaw.androidtv.ui.components.MediaBadge
import io.movieclaw.androidtv.ui.components.ModulatedCrossfade
import io.movieclaw.androidtv.ui.components.RemoteImage
import io.movieclaw.androidtv.ui.components.imageUrl
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.theme.ptSp
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** 片源标签：实心（分辨率）/ 描边（HDR、音频） */
data class StageBadge(val text: String, val filled: Boolean)

/**
 * 大图区背景（TVStageBackdrop）：整屏，按剧照原始 16:9 铺满贴顶。
 * - 首页（[fullImage] = false）：底下垫剧照边缘色（屏幕下沿之外再延伸 600pt 渐变到深炭灰），剧照从屏高 0.4 处渐隐进边缘色；
 *   左侧托字的黑从左 10% 满强度到 65% 淡完；
 * - 详情页（true）：最底下是同一张图的模糊版，剧照不渐隐，左下角一团径向黑托字。
 * [scrollPx] 读所在列表的滚动量（像素）：滚动 [pinnedPt] 以内背景不动，之后整层跟着上移并在 [fadePt] 内淡完
 * （[fadePx] 给出正数时按它，像素）。只在图层 / 绘制阶段读，列表滚动时这里不重组。
 * 淡到不足 2% 按全透明，整层不画、慢推也停（滑回来接着推）：剩一点点看不见的透明度，这层大图连同慢推每帧都要重画
 * （同 Apple TV 详情页，docs/perf/tvos-home-gpu-2026-10.md §5）。
 * [preview] 是盖在剧照上的预告画面层（首页 / 详情页的 TVStagePreviewLayer）。
 *
 * 这一层铺满整屏、还在不停地动，所以任何时候都不离屏合成（docs/perf/androidtv-home-scroll-2026-10.md）：
 * - 首页往下滚时的整层淡出：底下正好是纯色页面底，改为在上面盖一层「页面底色 × (1 − 透明度)」，与整层离屏淡出逐像素相同；
 *   详情页底下是模糊图，仍按整层透明度淡出（这时才离屏）；
 * - 首页托字的黑用一个合成着色器一遍画完，不再离屏画横向渐变再用纵向渐隐 DstIn（Android 9 及以下仍离屏，见 [scrimInOnePass]）；
 * - 换片时新旧剧照的交叉淡入，透明度直接乘到图片上（单张图，与整层淡入相同）。
 */
@Composable
fun StageBackdrop(
    image: String?,
    modifier: Modifier = Modifier,
    fullImage: Boolean = false,
    scrollPx: () -> Float = { 0f },
    pinnedPt: Float = 460f,
    fadePt: Float = 700f,
    fadePx: (() -> Float)? = null,
    preview: (@Composable BoxScope.(visible: Boolean) -> Unit)? = null,
) {
    val context = LocalContext.current
    val density = LocalDensity.current.density
    val screenUrl = imageUrl(image, McMetrics.CanvasWidth.toFloat())
    val analysisUrl = imageUrl(image, null)?.let { withWidth(it, 240) }
    val ambientUrl = imageUrl(image, McMetrics.BlurredBackdropWidth.toFloat())
    var tint by remember { mutableStateOf<Color?>(null) }
    var strength by remember { mutableStateOf(0.4f) }
    LaunchedEffect(analysisUrl, fullImage) {
        val url = analysisUrl ?: return@LaunchedEffect
        if (!fullImage) StageAnalysis.edgeColor(context, url)?.let { tint = it }
        StageAnalysis.scrimStrength(context, url, corner = fullImage)?.let { strength = it }
    }
    // 两个渐变动画的值只在绘制时读（换片时边缘色渐变 0.8 秒，不让整块跟着每帧重组）
    val animatedTint = animateColorAsState(tint ?: McColors.Page, tween(800), label = "tint")
    val animatedStrength = animateFloatAsState(strength, tween(400), label = "scrim")
    val ptPx = density * 0.5f
    val currentScroll by rememberUpdatedState(scrollPx)
    val currentFade by rememberUpdatedState(fadePx)
    val inPlace by remember(pinnedPt, ptPx) { derivedStateOf { maxOf(0f, currentScroll()) <= (pinnedPt + 120) * ptPx } }
    // 整层的透明度（滑走的部分）：只在图层 / 绘制阶段、慢推的开停里读
    val layerAlpha = remember(pinnedPt, ptPx) {
        { stageLayerAlpha(currentScroll(), pinnedPt * ptPx, currentFade?.invoke()?.takeIf { it > 0f } ?: (fadePt * ptPx)) }
    }
    val fadeFrom = 0.4f

    Box(modifier.fillMaxSize().clipToBounds()) {
        if (fullImage) BlurredBackdrop(ambientUrl) else Box(Modifier.fillMaxSize().background(McColors.Page))
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer {
                    translationY = -maxOf(0f, maxOf(0f, currentScroll()) - pinnedPt * ptPx)
                    if (fullImage) alpha = layerAlpha()
                }
                .then(
                    if (fullImage) Modifier else Modifier.drawWithContent {
                        val alpha = layerAlpha()
                        if (alpha <= 0f) return@drawWithContent
                        drawContent()
                        // 盖住整层画到的范围（屏幕高再往下延伸的那 600pt 边缘色过渡也算上）
                        if (alpha < 1f) drawRect(McColors.Page, size = Size(size.width, size.height + 600 * ptPx), alpha = 1 - alpha)
                    },
                ),
        ) {
            if (!fullImage && tint != null) {
                // 边缘色铺满首屏，并在屏幕下沿之外再延伸 600pt 渐变到深炭灰：往下滚、背景上移时才露出这段过渡，
                // 首屏里只有「剧照渐隐进边缘色」一段过渡（两段过渡夹一截平台在真机上会看出横线）
                Column(Modifier.fillMaxWidth().wrapContentHeight(Alignment.Top, unbounded = true)) {
                    Box(Modifier.fillMaxWidth().height(1080.pt).drawBehind { drawRect(animatedTint.value) })
                    Box(Modifier.fillMaxWidth().height(600.pt).drawBehind { drawRect(EasedFade.vertical(EasedFade.stops(animatedTint.value, 0f, 1f))) })
                }
            }
            Box(Modifier.fillMaxWidth().height(1080.pt)) {
                ModulatedCrossfade(screenUrl, tween(600)) { url ->
                    if (url != null) KenBurnsImage(url, hidden = { layerAlpha() <= 0f })
                }
                if (screenUrl != null && preview != null) preview(inPlace)
                if (!fullImage) {
                    Box(Modifier.fillMaxSize().drawBehind { drawRect(EasedFade.vertical(EasedFade.rising(animatedTint.value, fadeFrom))) })
                }
            }
            if (screenUrl != null) {
                if (fullImage) {
                    Canvas(Modifier.fillMaxWidth().height(1080.pt)) {
                        drawRect(
                            Brush.radialGradient(
                                *EasedFade.stops(Color.Black.copy(alpha = animatedStrength.value), 0f, 1f),
                                center = Offset(0f, size.height),
                                radius = 1500 * ptPx,
                            ),
                        )
                    }
                } else if (scrimInOnePass(Build.VERSION.SDK_INT)) {
                    // 横向托字黑 × 剧照下沿渐隐：两条渐变用 DstIn 合成成一个着色器，深浅用整笔的透明度给
                    // （原先是离屏先画横向渐变、再用纵向渐隐 DstIn，结果相同）
                    Spacer(
                        Modifier.fillMaxWidth().height(1080.pt).drawWithCache {
                            val brush = ShaderBrush(
                                ComposeShader(
                                    gradient(EasedFade.stops(Color.Black, 0.1f, 0.65f), Offset(size.width, 0f)),
                                    gradient(EasedFade.stops(Color.Black, fadeFrom, 1f), Offset(0f, size.height)),
                                    PorterDuff.Mode.DST_IN,
                                ),
                            )
                            onDrawBehind { drawRect(brush, alpha = animatedStrength.value) }
                        },
                    )
                } else {
                    // 同一块托字黑的老画法：离屏先画横向渐变，再用纵向渐隐当遮罩（DstIn），多一遍全屏离屏
                    Canvas(Modifier.fillMaxWidth().height(1080.pt).graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }) {
                        drawRect(Brush.horizontalGradient(*EasedFade.stops(Color.Black.copy(alpha = animatedStrength.value), 0.1f, 0.65f)))
                        drawRect(Brush.verticalGradient(*EasedFade.stops(Color.Black, fadeFrom, 1f)), blendMode = BlendMode.DstIn)
                    }
                }
            }
        }
    }
}

/** 大图区整层的透明度：滚动 [pinnedPx] 以内不动，之后 [fadePx] 内淡完；不足 2% 按 0（整层不画、慢推停） */
internal fun stageLayerAlpha(scrollPx: Float, pinnedPx: Float, fadePx: Float): Float {
    val alpha = 1 - maxOf(0f, maxOf(0f, scrollPx) - pinnedPx) / fadePx
    return if (alpha < 0.02f) 0f else alpha
}

/**
 * 首页托字黑能否用合成着色器一遍画完（[sdk] 传 Build.VERSION.SDK_INT）。
 * 两条线性渐变是同类着色器，文档说硬件加速下要 Android 9（API 28）起才支持合成；但 Android 9 的真机（极米 H3S，芯片 m7642）上
 * 这一笔整块画成白色，盖住剧照和字。所以 Android 10 起才一遍画，更老的系统退回离屏 + DstIn。
 */
internal fun scrimInOnePass(sdk: Int) = sdk >= 29

/** 从原点到 [to] 的线性渐变着色器（与 Brush.horizontalGradient / verticalGradient 铺满整块时一致） */
private fun gradient(stops: Array<Pair<Float, Color>>, to: Offset) =
    LinearGradientShader(Offset.Zero, to, stops.map { it.second }, stops.map { it.first })

private fun withWidth(url: String, w: Int): String {
    val parsed = url.toHttpUrlOrNull() ?: return url
    return parsed.newBuilder().setQueryParameter("w", w.toString()).build().toString()
}

/**
 * 一张铺满整屏的剧照：出现后 40 秒线性推近到 1.06 倍（Ken Burns），每换一部从头开始。
 * [hidden] 时停在当前倍数（看不见还在推，界面就每帧都要出一帧），露出来按原来的速度接着推
 */
@Composable
private fun KenBurnsImage(url: String, hidden: () -> Boolean) {
    val zoom = remember(url) { Animatable(1f) }
    val isHidden by rememberUpdatedState(hidden)
    LaunchedEffect(url) {
        snapshotFlow { isHidden() }.distinctUntilChanged().collectLatest { off ->
            if (off) return@collectLatest
            val left = (McMetrics.StageZoom - zoom.value) / (McMetrics.StageZoom - 1f)
            if (left > 0f) zoom.animateTo(McMetrics.StageZoom, tween((40_000 * left).toInt(), easing = LinearEasing))
        }
    }
    AsyncImage(
        model = ImageRequest.Builder(LocalContext.current).data(url).build(),
        contentDescription = null,
        contentScale = ContentScale.Crop,
        alignment = Alignment.TopCenter,
        modifier = Modifier.fillMaxSize().clipToBounds().graphicsLayer {
            scaleX = zoom.value
            scaleY = zoom.value
        },
    )
}

/** 模糊背景（TVBlurredBackdrop）：深炭灰底 + 模糊 50、45% 不透明的图 + 上 20% 下 75% 的黑渐变，换图 0.6 秒交叉淡入 */
@Composable
fun BlurredBackdrop(url: String?, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize().background(McColors.Page)) {
        Crossfade(url, animationSpec = tween(600), label = "blurred") { current ->
            if (current != null) {
                // 模糊要 Android 12；更老的系统只压暗（看起来是一张更暗的图）
                if (Build.VERSION.SDK_INT >= 31) {
                    AsyncImage(
                        model = current,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize().reducedBlur(25.dp, alpha = 0.45f),
                    )
                } else {
                    AsyncImage(
                        model = current,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize().graphicsLayer { alpha = 0.45f }.graphicsLayer { alpha = 0.3f },
                    )
                }
            }
        }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.2f), Color.Black.copy(alpha = 0.75f)))))
    }
}

/**
 * 模糊（同 Modifier.blur，边缘按贴边延伸处理）在 1/[factor] 大小上算、再放大铺满，[alpha] 是整层透明度：
 * 模糊的像素少十几倍，结果肉眼看不出差别（模糊本身就把细节抹掉了，同 Apple TV 的模糊背景，docs/perf/tvos-home-gpu-2026-10.md §5）。
 * 内容按缩小后的尺寸排版、取图，只适合铺满的图片
 */
fun Modifier.reducedBlur(radius: Dp, alpha: Float = 1f, factor: Int = 4): Modifier = layout { measurable, constraints ->
    val width = constraints.maxWidth
    val height = constraints.maxHeight
    val placeable = measurable.measure(Constraints.fixed((width + factor - 1) / factor, (height + factor - 1) / factor))
    val blur = radius.toPx() / factor
    layout(width, height) {
        placeable.placeWithLayer(0, 0) {
            scaleX = width.toFloat() / placeable.width
            scaleY = height.toFloat() / placeable.height
            transformOrigin = TransformOrigin(0f, 0f)
            this.alpha = alpha
            renderEffect = BlurEffect(blur, blur, TileMode.Clamp)
            clip = true
        }
    }
}

/**
 * 片名 Logo（TVTitleArt）：最大 [maxWidthPt]×[maxHeightPt]、贴左下；加载中留空框，失败或没有 Logo 画片名文字（64 粗体）。
 */
@Composable
fun TitleArt(
    title: String,
    logo: String?,
    modifier: Modifier = Modifier,
    maxWidthPt: Int = 860,
    maxHeightPt: Int = 200,
    textSizePt: Int = 64,
    alignment: Alignment = Alignment.BottomStart,
) {
    val url = imageUrl(logo, maxWidthPt.toFloat())
    var failed by remember(url) { mutableStateOf(false) }
    if (url == null || failed) {
        Text(
            title,
            style = TextStyle(fontSize = textSizePt.ptSp, fontWeight = FontWeight.Bold),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = modifier,
        )
        return
    }
    Box(modifier.height(maxHeightPt.pt).widthIn(max = maxWidthPt.pt), contentAlignment = alignment) {
        AsyncImage(
            model = url,
            contentDescription = title,
            contentScale = ContentScale.Fit,
            alignment = alignment,
            onState = { if (it is AsyncImagePainter.State.Error) failed = true },
            modifier = Modifier.heightIn(max = maxHeightPt.pt).widthIn(max = maxWidthPt.pt),
        )
    }
}

/**
 * 左下角的文字（TVStageInfo）：片名 Logo（下 28）→ 加粗小字一行 + 片源标签（下 14 / 20）→ 灰色小字一行（下 20）→ 简介。
 * 整块投一层黑 55%、半径 10 的阴影托字。
 */
@Composable
fun StageInfo(
    title: String,
    logo: String?,
    modifier: Modifier = Modifier,
    headline: String? = null,
    meta: String? = null,
    badges: List<StageBadge> = emptyList(),
    overview: String? = null,
    overviewLines: Int = 2,
) {
    val shadow = Shadow(Color.Black.copy(alpha = 0.55f), blurRadius = 20f)
    Column(modifier.fillMaxWidth()) {
        TitleArt(title, logo, Modifier.padding(bottom = 28.pt))
        if (!meta.isNullOrEmpty() || badges.isNotEmpty()) {
            Row(
                Modifier.padding(bottom = if (headline == null) 20.pt else 14.pt),
                horizontalArrangement = Arrangement.spacedBy(12.pt),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (!meta.isNullOrEmpty()) {
                    Text(meta, style = McType.size(27, FontWeight.SemiBold).copy(shadow = shadow), maxLines = 1, modifier = Modifier.padding(end = 4.pt))
                }
                badges.forEach { MediaBadge(it.text, it.filled) }
            }
        }
        headline?.let {
            Text(
                it,
                style = McType.size(26, FontWeight.Medium).copy(shadow = shadow),
                color = Color.White.copy(alpha = 0.85f),
                maxLines = 1,
                modifier = Modifier.padding(bottom = 20.pt),
            )
        }
        overview?.trim()?.takeIf { it.isNotEmpty() }?.let {
            Text(
                it,
                style = McType.size(25).copy(lineHeight = (25 + 7 + 7).ptSp, shadow = shadow),
                color = Color.White.copy(alpha = 0.82f),
                maxLines = overviewLines,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 720.pt),
            )
        }
    }
}

/** 「第 1 季 第 3 集 · 名」；名字为空或就是「第 N 集 / Episode N」时省掉 */
fun episodeLine(season: Long, episode: Long, name: String?): String {
    val number = "第 $season 季 第 $episode 集"
    return episodeTitle(name)?.let { "$number · $it" } ?: number
}

/** 分集的真名：空的、或只是「第 N 集 / Episode N」这种占位名（TMDB 没有中文集名时就给这个）返回 null，界面只写一次集号 */
fun episodeTitle(name: String?): String? {
    val trimmed = name?.trim().orEmpty()
    if (trimmed.isEmpty() || Regex("^(第\\s*\\d+\\s*集|Episode\\s*\\d+)$", RegexOption.IGNORE_CASE).matches(trimmed)) return null
    return trimmed
}

/**
 * 首屏上半块（TVStageBlock）：文字贴底、下面一排按钮（间距 36、底 30），整块从屏幕顶到 [bottomPt]（两页都是 918）。
 * Apple 端列表内容从标签栏下方（首页 157、详情 48.5）开始排，这里直接从屏幕顶排满到同一条底线，位置一致。
 */
@Composable
fun StageBlock(
    modifier: Modifier = Modifier,
    bottomPt: Int = 918,
    info: @Composable () -> Unit,
    actions: @Composable () -> Unit,
) {
    Column(
        modifier.fillMaxWidth().height(bottomPt.pt).padding(start = McMetrics.Edge, end = McMetrics.Edge, bottom = 30.pt),
        verticalArrangement = Arrangement.spacedBy(36.pt, Alignment.Bottom),
    ) {
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.BottomStart) { info() }
        actions()
    }
}

/** 两段文字交叉淡入（换片时新旧文字在同一个框里重叠，不跳动） */
@Composable
fun <T> CrossfadeInfo(target: T, content: @Composable (T) -> Unit) {
    ModulatedCrossfade(target, tween(450), contentAlignment = Alignment.BottomStart) { content(it) }
}

