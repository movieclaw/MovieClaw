package io.movieclaw.androidtv.ui.stage

import android.os.Build
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import coil3.compose.AsyncImagePainter
import coil3.request.ImageRequest
import io.movieclaw.androidtv.ui.components.MediaBadge
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
 * [scrollPx] 是所在列表的滚动量（像素）：滚动 [pinnedPt] 以内背景不动，之后整层跟着上移并在 [fadePt] 内淡完。
 * [preview] 是盖在剧照上的预告画面层（首页 / 详情页的 TVStagePreviewLayer）。
 */
@Composable
fun StageBackdrop(
    image: String?,
    modifier: Modifier = Modifier,
    fullImage: Boolean = false,
    scrollPx: Float = 0f,
    pinnedPt: Float = 460f,
    fadePt: Float = 700f,
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
    val animatedTint by animateColorAsState(tint ?: McColors.Page, tween(800), label = "tint")
    val animatedStrength by animateFloatAsState(strength, tween(400), label = "scrim")
    val ptPx = density * 0.5f
    val scroll = maxOf(0f, scrollPx)
    val shift = maxOf(0f, scroll - pinnedPt * ptPx)
    val alpha = maxOf(0f, 1 - shift / (fadePt * ptPx))
    val inPlace = scroll <= (pinnedPt + 120) * ptPx
    val fadeFrom = if (fullImage) 1 - minOf(1f, scroll / (500 * ptPx)) * 0.4f else 0.4f

    Box(modifier.fillMaxSize().clipToBounds()) {
        if (fullImage) BlurredBackdrop(ambientUrl) else Box(Modifier.fillMaxSize().background(McColors.Page))
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer {
                    translationY = -shift
                    this.alpha = alpha
                    compositingStrategy = CompositingStrategy.Offscreen
                },
        ) {
            if (!fullImage && tint != null) {
                Box(Modifier.fillMaxSize().background(animatedTint))
            }
            Box(Modifier.fillMaxWidth().height(1080.pt)) {
                Crossfade(screenUrl, animationSpec = tween(600), label = "stage") { url ->
                    if (url != null) KenBurnsImage(url)
                }
                if (screenUrl != null && preview != null) preview(inPlace)
                if (!fullImage) {
                    Box(Modifier.fillMaxSize().background(EasedFade.vertical(EasedFade.rising(animatedTint, fadeFrom))))
                }
            }
            if (screenUrl != null) {
                if (fullImage) {
                    Canvas(Modifier.fillMaxWidth().height(1080.pt)) {
                        drawRect(
                            Brush.radialGradient(
                                *EasedFade.stops(Color.Black.copy(alpha = animatedStrength), 0f, 1f),
                                center = Offset(0f, size.height),
                                radius = 1500 * ptPx,
                            ),
                        )
                    }
                } else {
                    // 横向托字黑 × 剧照下沿渐隐：先画横向渐变，再用纵向渐隐当遮罩（DstIn）
                    Canvas(Modifier.fillMaxWidth().height(1080.pt).graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }) {
                        drawRect(Brush.horizontalGradient(*EasedFade.stops(Color.Black.copy(alpha = animatedStrength), 0.1f, 0.65f)))
                        drawRect(
                            Brush.verticalGradient(*EasedFade.stops(Color.Black, fadeFrom, 1f)),
                            blendMode = androidx.compose.ui.graphics.BlendMode.DstIn,
                        )
                    }
                }
            }
        }
    }
}

private fun withWidth(url: String, w: Int): String {
    val parsed = url.toHttpUrlOrNull() ?: return url
    return parsed.newBuilder().setQueryParameter("w", w.toString()).build().toString()
}

/** 一张铺满整屏的剧照：出现后 40 秒线性推近到 1.06 倍（Ken Burns），每换一部从头开始 */
@Composable
private fun KenBurnsImage(url: String) {
    val zoom = remember(url) { Animatable(1f) }
    LaunchedEffect(url) { zoom.animateTo(McMetrics.StageZoom, tween(40_000, easing = LinearEasing)) }
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
                AsyncImage(
                    model = current,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer { alpha = 0.45f }
                        // 模糊要 Android 12；更老的系统只压暗（看起来是一张更暗的图）
                        .then(if (Build.VERSION.SDK_INT >= 31) Modifier.blur(25.dp) else Modifier.graphicsLayer { alpha = 0.3f }),
                )
            }
        }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.2f), Color.Black.copy(alpha = 0.75f)))))
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
    val trimmed = name?.trim().orEmpty()
    if (trimmed.isEmpty() || Regex("^(第\\s*\\d+\\s*集|Episode\\s*\\d+)$", RegexOption.IGNORE_CASE).matches(trimmed)) return number
    return "$number · $trimmed"
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
    AnimatedContent(target, transitionSpec = { fadeIn(tween(450)) togetherWith fadeOut(tween(450)) }, label = "stage-info", contentAlignment = Alignment.BottomStart) {
        content(it)
    }
}

