package io.movieclaw.androidtv.ui.home

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.animate
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import io.movieclaw.androidtv.ui.components.imageUrl
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Surface
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.core.model.generated.LibraryItemShowcaseView
import io.movieclaw.androidtv.ui.components.ModulatedCrossfade
import io.movieclaw.androidtv.ui.components.RemoteImage
import io.movieclaw.androidtv.ui.stage.TitleArt
import io.movieclaw.androidtv.ui.theme.Formatters
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.theme.ptSp
import io.movieclaw.androidtv.ui.components.layerFocus

data class ShowcaseEntry(
    val id: Long,
    val title: String,
    val kind: String,
    val year: Long?,
    val poster: String?,
    val backdrop: String?,
    val seasonCount: Int,
    val libraryId: Long?,
)

/**
 * 选中展开的海报行（TVShowcaseShelf）：平时 300×450 海报，焦点所在那一部在行首（左 80）展开到 800 宽、换成背景图 + 片名 Logo；
 * 行下面写这一部的「类型 · 年份 · 片长 · 分级」与两行简介。
 * 展开位固定在行首、大小不变（同 Apple 端，2026-10-11 用户定，同 Netflix）：往右按，展开位里直接换成下一部，后面的海报整体往左
 * 平移一格滑进来。原先两张卡同时做 0.3 秒宽度动画、整行同时滚动，动画的每一帧整行都要重新测量排版；
 * 现在宽度与滚动位置在同一帧里直接到位，只有后面海报的平移这一个动画（只改图层位移，不重新排版）。
 * 从上下切进这一行只落在上次停的那张（没停过就第一张；上次停在「查看全部」就落它），不按位置挑最近的（同 Apple 端）。
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun ShowcaseShelf(
    title: String,
    entries: List<ShowcaseEntry>,
    details: Map<Long, LibraryItemShowcaseView>,
    onOpen: (ShowcaseEntry) -> Unit,
    onRowFocus: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    /** 行末「查看全部」：把给的 Modifier 挂到它身上，入口才认得它 */
    trailing: LazyListScope.(Modifier) -> Unit = {},
) {
    var focusedId by remember { mutableStateOf<Long?>(null) }
    var remembered by remember { mutableStateOf<Long?>(null) }
    var leftAtTrailing by remember { mutableStateOf(false) }
    val cardFocus = remember { mutableMapOf<Long, FocusRequester>() }
    val trailingFocus = remember { FocusRequester() }
    // 展开位后面那些海报的平移：换一部的那一帧排版已经到位，先把它们放回原来的位置（往右按是右边一格），再滑过来。
    // 只在图层里读
    val slide = remember { mutableFloatStateOf(0f) }
    val scope = rememberCoroutineScope()
    var slideJob by remember { mutableStateOf<Job?>(null) }
    var rowFocused by remember { mutableStateOf(false) }
    val color = animateColorAsState(if (rowFocused) McColors.Text else McColors.Secondary, tween(200), label = "showcase-title")
    val state = rememberLazyListState()
    val density = androidx.compose.ui.platform.LocalDensity.current
    val stepPx = with(density) { (McMetrics.ShowcasePosterWidth + McMetrics.CardSpacing).toPx() }
    val trailingModifier = Modifier
        .focusRequester(trailingFocus)
        .onFocusChanged { if (it.hasFocus) leftAtTrailing = true }
        .graphicsLayer { translationX = if (focusedId != null) slide.floatValue else 0f }

    fun focusCard(entry: ShowcaseEntry) {
        val from = entries.indexOfFirst { it.id == focusedId }
        val to = entries.indexOfFirst { it.id == entry.id }
        focusedId = entry.id
        remembered = entry.id
        leftAtTrailing = false
        if (to < 0) return
        // 宽度、滚动位置在同一帧里直接到位：展开位停在行首（偏移 0 就是贴着左边的内边距，屏幕左 80）
        state.requestScrollToItem(to)
        slideJob?.cancel()
        if (from >= 0 && from != to) {
            slide.floatValue = if (to > from) stepPx else -stepPx
            slideJob = scope.launch {
                animate(slide.floatValue, 0f, animationSpec = tween(250, easing = LinearOutSlowInEasing)) { value, _ -> slide.floatValue = value }
            }
        } else {
            slide.floatValue = 0f
        }
    }

    val expandedIndex = entries.indexOfFirst { it.id == focusedId }
    // 预载展开位前后几部的背景图与 Logo（与卡片取图同一个地址，命中内存缓存）：往右按时展开位里直接换图，不等加载
    if (expandedIndex >= 0) {
        val neighbours = listOf(expandedIndex - 1, expandedIndex + 1, expandedIndex + 2).mapNotNull { entries.getOrNull(it) }
        val urls = neighbours.flatMap { e -> listOf(imageUrl(showcaseBackdrop(e, details[e.id]), 800f), imageUrl(details[e.id]?.logoUrl, 380f)) }.filterNotNull()
        val context = androidx.compose.ui.platform.LocalContext.current
        LaunchedEffect(urls) {
            val loader = SingletonImageLoader.get(context)
            urls.forEach { loader.enqueue(ImageRequest.Builder(context).data(it).build()) }
        }
    }
    Column(
        modifier.onFocusChanged {
            rowFocused = it.hasFocus
            onRowFocus(it.hasFocus)
            if (!it.hasFocus) {
                focusedId = null
                slideJob?.cancel()
                slide.floatValue = 0f
            }
        },
        verticalArrangement = Arrangement.spacedBy(8.pt),
    ) {
        // 标题变色只在绘制时读：焦点进出这一行时不让整行跟着每帧重组
        Text(title, style = McType.size(32, FontWeight.SemiBold), color = { color.value }, modifier = Modifier.padding(horizontal = McMetrics.Edge))
        io.movieclaw.androidtv.ui.components.NoAutoScroll {
        LazyRow(
            state = state,
            modifier = Modifier
                .fillMaxWidth()
                .focusProperties {
                    enter = {
                        if (leftAtTrailing) trailingFocus
                        else (remembered ?: entries.firstOrNull()?.id)?.let { cardFocus[it] } ?: FocusRequester.Default
                    }
                }
                .focusGroup(),
            // 右侧留出 1920 − 80 − 800 的余量：最后一张也能滚到左边展开
            contentPadding = PaddingValues(start = McMetrics.Edge, end = (1920 - 80 - 800).pt, top = 20.pt, bottom = 20.pt),
            horizontalArrangement = Arrangement.spacedBy(McMetrics.CardSpacing),
        ) {
            itemsIndexed(entries, key = { _, e -> e.id }) { index, entry ->
                val requester = remember { FocusRequester() }
                DisposableEffect(entry.id) {
                    cardFocus[entry.id] = requester
                    onDispose { if (cardFocus[entry.id] === requester) cardFocus.remove(entry.id) }
                }
                val behind = expandedIndex in 0 until index
                ShowcaseCard(
                    entry,
                    details[entry.id],
                    expanded = index == expandedIndex,
                    modifier = Modifier
                        .focusRequester(requester)
                        .graphicsLayer { translationX = if (behind) slide.floatValue else 0f },
                    onFocus = { if (it) focusCard(entry) },
                ) { onOpen(entry) }
            }
            trailing(trailingModifier)
        }
        }
        Box(Modifier.padding(horizontal = McMetrics.Edge)) {
            // 几行字的交叉淡入：透明度直接乘到字上，不离屏（ModulatedCrossfade）；简介行数不同时高度照旧平滑过渡
            ModulatedCrossfade(entries.getOrNull(expandedIndex), tween(300), Modifier.animateContentSize()) { entry ->
                if (entry != null) ShowcaseInfo(entry, details[entry.id])
            }
        }
    }
}

/** 展开时的背景图：展开接口给的优先，列表里带的兜底，再没有用海报 */
private fun showcaseBackdrop(entry: ShowcaseEntry, detail: LibraryItemShowcaseView?): String? = detail?.backdropUrl ?: entry.backdrop ?: entry.poster

/**
 * 一张卡：平时竖海报，展开时同高的横版背景图 + 左下 Logo。宽度、内容直接到位（见 [ShowcaseShelf]），不做宽度动画与交叉淡入；
 * 海报一直留着、展开时盖上背景图，收回时不用重建海报
 */
@Composable
private fun ShowcaseCard(entry: ShowcaseEntry, detail: LibraryItemShowcaseView?, expanded: Boolean, modifier: Modifier, onFocus: (Boolean) -> Unit, onClick: () -> Unit) {
    val shape = RoundedCornerShape(McMetrics.CardCorner)
    Surface(
        onClick = onClick,
        modifier = modifier
            .layerFocus()
            .width(if (expanded) McMetrics.ShowcaseExpandedWidth else McMetrics.ShowcasePosterWidth)
            .height(McMetrics.ShowcaseHeight)
            .onFocusChanged { onFocus(it.isFocused) },
        shape = ClickableSurfaceDefaults.shape(shape),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f, pressedScale = 0.98f),
        border = ClickableSurfaceDefaults.border(
            border = androidx.tv.material3.Border(BorderStroke(1.pt, Color.White.copy(alpha = 0.14f)), shape = shape),
            focusedBorder = androidx.tv.material3.Border(BorderStroke(4.pt, Color.White.copy(alpha = 0.9f)), shape = shape),
        ),
        glow = ClickableSurfaceDefaults.glow(focusedGlow = androidx.tv.material3.Glow(Color.Black.copy(alpha = 0.55f), 26.pt)),
        colors = ClickableSurfaceDefaults.colors(containerColor = McColors.SurfaceRaised, focusedContainerColor = McColors.SurfaceRaised),
    ) {
        Box(Modifier.fillMaxSize().clip(shape)) {
            // 海报不垫底色：卡片本身就是同一种底色（ClickableSurfaceDefaults.colors）
            RemoteImage(
                entry.poster,
                300f,
                Modifier.width(McMetrics.ShowcasePosterWidth).fillMaxSize().graphicsLayer { alpha = if (expanded) 0f else 1f },
                placeholder = entry.title,
                showsPlaceholderBox = false,
            )
            if (expanded) {
                Box(Modifier.width(McMetrics.ShowcaseExpandedWidth).height(McMetrics.ShowcaseHeight)) {
                    RemoteImage(showcaseBackdrop(entry, detail), 800f, Modifier.fillMaxSize(), placeholder = entry.title)
                    Box(
                        Modifier.fillMaxSize().background(
                            Brush.linearGradient(
                                0f to Color.Black.copy(alpha = 0.7f),
                                0.55f to Color.Transparent,
                                start = androidx.compose.ui.geometry.Offset(0f, Float.POSITIVE_INFINITY),
                                end = androidx.compose.ui.geometry.Offset(Float.POSITIVE_INFINITY, 0f),
                            ),
                        ),
                    )
                    TitleArt(
                        entry.title,
                        detail?.logoUrl,
                        Modifier.align(Alignment.BottomStart).padding(start = 36.pt, bottom = 32.pt),
                        maxWidthPt = 380,
                        maxHeightPt = 120,
                        textSizePt = 52,
                    )
                }
            }
        }
    }
}

@Composable
private fun ShowcaseInfo(entry: ShowcaseEntry, detail: LibraryItemShowcaseView?) {
    Column(verticalArrangement = Arrangement.spacedBy(20.pt)) {
        // 行高照 tvOS 的 SF 量的（元信息一行 32、简介行距 36）：Noto 默认行框高，整行会往下多占二十来点
        Text(showcaseMeta(entry, detail), style = McType.size(27, FontWeight.SemiBold).copy(lineHeight = 32.ptSp), maxLines = 1)
        detail?.overview?.trim()?.takeIf { it.isNotEmpty() }?.let {
            Text(
                it,
                style = McType.size(25).copy(lineHeight = 36.ptSp),
                color = Color.White.copy(alpha = 0.82f),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.width(720.pt),
            )
        }
    }
}

/** 「电影 · 科幻 · 悬疑 · 2021 · 2 小时 8 分钟 · PG-13」；剧集写「N 季」 */
fun showcaseMeta(entry: ShowcaseEntry, detail: LibraryItemShowcaseView?): String {
    val parts = mutableListOf<String>()
    when (entry.kind) {
        "movie" -> parts += "电影"
        "tv" -> parts += "剧集"
    }
    parts += detail?.genres.orEmpty().take(2)
    entry.year?.let { parts += it.toString() }
    if (entry.kind == "tv") {
        if (entry.seasonCount > 0) parts += "${entry.seasonCount} 季"
    } else {
        detail?.runtimeMinutes?.takeIf { it > 0 }?.let { parts += Formatters.runtime(it.toInt()) }
    }
    detail?.contentRating?.takeIf { it.isNotEmpty() }?.let { parts += it }
    return parts.joinToString(" · ")
}
