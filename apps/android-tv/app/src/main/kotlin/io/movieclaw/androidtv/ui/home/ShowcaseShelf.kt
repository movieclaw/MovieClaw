package io.movieclaw.androidtv.ui.home

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
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
import androidx.tv.material3.Text
import io.movieclaw.androidtv.core.model.generated.LibraryItemShowcaseView
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
 * 选中展开的海报行（TVShowcaseShelf）：平时 300×450 海报，焦点所在那张横向展开到 800 宽、换成背景图 + 片名 Logo；
 * 行下面写这一部的「类型 · 年份 · 片长 · 分级」与两行简介。焦点那张滚到左边 80 处。
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
    val trailingModifier = Modifier.focusRequester(trailingFocus).onFocusChanged { if (it.hasFocus) leftAtTrailing = true }
    var rowFocused by remember { mutableStateOf(false) }
    val color by animateColorAsState(if (rowFocused) McColors.Text else McColors.Secondary, tween(200), label = "showcase-title")
    val state = rememberLazyListState()
    val edgePx = with(androidx.compose.ui.platform.LocalDensity.current) { McMetrics.Edge.roundToPx() }
    LaunchedEffect(focusedId) {
        val id = focusedId ?: return@LaunchedEffect
        val index = entries.indexOfFirst { it.id == id }
        // 焦点那张的左边停在屏幕左 80（同 Apple 端 scrollTo(anchor: 80/1120)）；展开动画与滚动同时进行会少走一截，多给 1/5 补上（截图量出）
        if (index >= 0) state.animateScrollToItem(index, -(edgePx + edgePx / 5))
    }
    Column(
        modifier.onFocusChanged {
            rowFocused = it.hasFocus
            onRowFocus(it.hasFocus)
            if (!it.hasFocus) focusedId = null
        },
        verticalArrangement = Arrangement.spacedBy(8.pt),
    ) {
        Text(title, style = McType.size(32, FontWeight.SemiBold), color = color, modifier = Modifier.padding(horizontal = McMetrics.Edge))
        io.movieclaw.androidtv.ui.components.TvScrollSpec(80) {
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
            itemsIndexed(entries, key = { _, e -> e.id }) { _, entry ->
                val requester = remember { FocusRequester() }
                DisposableEffect(entry.id) {
                    cardFocus[entry.id] = requester
                    onDispose { if (cardFocus[entry.id] === requester) cardFocus.remove(entry.id) }
                }
                ShowcaseCard(
                    entry,
                    details[entry.id],
                    expanded = focusedId == entry.id,
                    modifier = Modifier.focusRequester(requester),
                    onFocus = {
                        if (it) {
                            focusedId = entry.id
                            remembered = entry.id
                            leftAtTrailing = false
                        }
                    },
                ) { onOpen(entry) }
            }
            trailing(trailingModifier)
        }
        }
        Box(Modifier.padding(horizontal = McMetrics.Edge)) {
            AnimatedContent(
                entries.firstOrNull { it.id == focusedId },
                transitionSpec = { fadeIn(tween(300)) togetherWith fadeOut(tween(300)) },
                label = "showcase-info",
            ) { entry ->
                if (entry != null) ShowcaseInfo(entry, details[entry.id])
            }
        }
    }
}

@Composable
private fun ShowcaseCard(entry: ShowcaseEntry, detail: LibraryItemShowcaseView?, expanded: Boolean, modifier: Modifier, onFocus: (Boolean) -> Unit, onClick: () -> Unit) {
    val width by animateDpAsState(if (expanded) McMetrics.ShowcaseExpandedWidth else McMetrics.ShowcasePosterWidth, tween(300), label = "showcase-width")
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(McMetrics.CardCorner)
    Surface(
        onClick = onClick,
        modifier = modifier
            .layerFocus()
            .width(width)
            .height(McMetrics.ShowcaseHeight)
            .onFocusChanged {
                focused = it.isFocused
                onFocus(it.isFocused)
            },
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
            RemoteImage(entry.poster, 300f, Modifier.width(McMetrics.ShowcasePosterWidth).fillMaxSize(), placeholder = entry.title)
            androidx.compose.animation.AnimatedVisibility(expanded, enter = fadeIn(tween(300)), exit = fadeOut(tween(300))) {
                Box(Modifier.width(McMetrics.ShowcaseExpandedWidth).height(McMetrics.ShowcaseHeight)) {
                    RemoteImage(detail?.backdropUrl ?: entry.backdrop ?: entry.poster, 800f, Modifier.fillMaxSize(), placeholder = entry.title)
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
