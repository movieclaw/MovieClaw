package io.movieclaw.androidtv.ui.detail

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import io.movieclaw.androidtv.core.model.generated.EpisodeView
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import kotlinx.coroutines.delay
import kotlin.math.max

/**
 * 「全部分集」面板（在集段页签上按确认打开，盖满整屏）：左栏段列表（锚点段橙点），右边 10 列数字宫格。
 * 格子：已看 ✓、看了一半压橙色进度、缺集虚线框、锚点描橙边。打开时焦点落在 [startRange] 的入口集（锚点或段首）；
 * 左栏上下换段，往右 / 确认进宫格；宫格最左列再按左回左栏。返回键 [onClose]，格子上按确认 [onPick] 那一集。
 * 焦点关在面板里（同排序菜单）。
 */
@Composable
internal fun EpisodePanel(
    title: String?,
    episodes: List<EpisodeView>,
    ranges: List<EpisodeRange>,
    anchor: Long?,
    startRange: Int,
    onPick: (Long) -> Unit,
    onClose: () -> Unit,
) {
    var range by remember { mutableIntStateOf(startRange.coerceIn(0, ranges.lastIndex)) }
    var focused by remember { mutableStateOf<EpisodeView?>(null) }
    val anchorRange = EpisodeRanges.position(anchor, ranges)
    val rangeRequesters = remember { HashMap<Int, FocusRequester>() }
    val cellRequesters = remember { HashMap<Long, FocusRequester>() }
    fun rangeReq(index: Int) = rangeRequesters.getOrPut(index) { FocusRequester() }
    fun cellReq(number: Long) = cellRequesters.getOrPut(number) { FocusRequester() }
    fun entryCell() = cellReq(EpisodeRanges.entry(ranges[range], anchor))
    val cells = episodes.filter { ranges[range].contains(it.episodeNumber) }

    BackHandler(onBack = onClose)
    LaunchedEffect(Unit) {
        // 等面板排好再交焦点
        repeat(5) {
            delay(16)
            if (entryCell().tryFocus()) return@LaunchedEffect
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFF0B0D12))
            .testTag("episode-panel")
            .focusProperties { onExit = { cancelFocusChange() } }
            .focusGroup(),
    ) {
        Row(Modifier.padding(start = 96.pt, top = 70.pt), verticalAlignment = Alignment.Bottom) {
            Text("全部分集", style = McType.size(44, FontWeight.Bold))
            val owned = episodes.count { it.owned }
            Text(
                listOfNotNull(title, "在库 $owned / ${episodes.size}").joinToString(" · "),
                style = McType.size(26),
                color = McColors.TextMuted,
                modifier = Modifier.padding(start = 20.pt, bottom = 6.pt),
            )
        }
        LazyColumn(
            state = rememberLazyListState(max(0, range - 5)),
            modifier = Modifier
                .padding(start = 96.pt, top = 170.pt)
                .width(300.pt)
                .height(860.pt)
                .focusProperties {
                    // 从宫格往左进来落在当前段；上下到头不出去（程序给焦点的 Enter 要放行，否则左右进出时的转交会被拦下）
                    onEnter = { if (requestedFocusDirection == FocusDirection.Left) rangeReq(range).tryFocus() }
                    onExit = { if (requestedFocusDirection == FocusDirection.Up || requestedFocusDirection == FocusDirection.Down) cancelFocusChange() }
                }
                .focusGroup(),
            verticalArrangement = Arrangement.spacedBy(8.pt),
        ) {
            itemsIndexed(ranges, key = { _, it -> it.index }) { index, item ->
                PanelRange(
                    label = item.label,
                    current = index == range,
                    dot = index == anchorRange,
                    onClick = { entryCell().tryFocus() },
                    modifier = Modifier
                        .focusRequester(rangeReq(index))
                        .testTag("panel-range:$index")
                        .semantics { selected = index == range }
                        .onFocusChanged {
                            if (it.isFocused) {
                                range = index
                                focused = null
                            }
                        },
                )
            }
        }
        LazyVerticalGrid(
            columns = GridCells.Fixed(10),
            modifier = Modifier
                .padding(start = 448.pt, top = 158.pt)
                .width(1384.pt)
                .height(644.pt)
                .focusProperties {
                    // 从左栏往右进来落在这一段的入口集；上下右到头不出去（下沿往下会跳到左栏下面的段）
                    onEnter = { if (requestedFocusDirection == FocusDirection.Right) entryCell().tryFocus() }
                    onExit = {
                        val dir = requestedFocusDirection
                        if (dir == FocusDirection.Up || dir == FocusDirection.Down || dir == FocusDirection.Right) cancelFocusChange()
                    }
                }
                .focusGroup(),
            // 四周 12 的内边：焦点格放大 1.12 不被裁
            contentPadding = PaddingValues(12.pt),
            horizontalArrangement = Arrangement.spacedBy(18.pt),
            verticalArrangement = Arrangement.spacedBy(18.pt),
        ) {
            items(cells, key = { it.episodeNumber }) { episode ->
                PanelCell(
                    episode = episode,
                    anchor = episode.episodeNumber == anchor,
                    onClick = { onPick(episode.episodeNumber) },
                    modifier = Modifier
                        .focusRequester(cellReq(episode.episodeNumber))
                        .testTag("panel-cell:${episode.episodeNumber}")
                        .onFocusChanged { if (it.isFocused) focused = episode },
                )
            }
        }
        // 宫格只有集号：焦点那一格的集名与状态写在下面
        Column(Modifier.padding(start = 460.pt, top = 880.pt).width(1360.pt), verticalArrangement = Arrangement.spacedBy(6.pt)) {
            val current = focused
            if (current != null) {
                Text(
                    listOfNotNull("第 ${current.episodeNumber} 集", current.name).joinToString(" · "),
                    style = McType.size(28, FontWeight.SemiBold),
                    maxLines = 1,
                )
                Text("${cellStatus(current)} · 按确认回到详情页，焦点落在这一集", style = McType.size(24), color = McColors.TextMuted)
            } else {
                Text("上下换段，往右进宫格", style = McType.size(24), color = McColors.TextMuted)
            }
        }
    }
}

private fun cellStatus(episode: EpisodeView): String = when {
    !episode.owned -> "缺集"
    episode.played -> "已看"
    episode.positionMs > 0 -> "看到 ${episode.progressPercent ?: 0}%"
    else -> "未看"
}

/** 左栏一段：68 高、28 字；当前段垫白 10%，焦点白底黑字（不放大），锚点段右边橙点 */
@Composable
private fun PanelRange(label: String, current: Boolean, dot: Boolean, onClick: () -> Unit, modifier: Modifier) {
    Surface(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().height(68.pt),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(16.pt)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (current) Color.White.copy(alpha = 0.1f) else Color.Transparent,
            contentColor = if (current) Color.White else McColors.TextMuted,
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White,
            pressedContentColor = Color.Black,
        ),
        // 不放大：左栏是裁切的滚动列表，放大会被裁边
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f, pressedScale = 1f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Row(
            Modifier.fillMaxSize().padding(horizontal = 26.pt),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, style = McType.size(28))
            if (dot) Box(Modifier.size(12.pt).background(ResumeOrange, CircleShape))
        }
    }
}

/** 宫格一格：96 高、集号 32；已看灰字 + 右上绿勾，看了一半底边橙色进度，缺集虚线框，锚点 4pt 橙色内描边；焦点白底黑字放大 1.12 */
@Composable
private fun PanelCell(episode: EpisodeView, anchor: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val missing = !episode.owned
    Surface(
        onClick = onClick,
        modifier = modifier.height(96.pt),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(16.pt)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = when {
                missing -> Color.Transparent
                episode.played -> Color.White.copy(alpha = 0.04f)
                else -> Color.White.copy(alpha = 0.08f)
            },
            contentColor = when {
                missing -> McColors.TextFaint
                episode.played -> McColors.TextMuted
                else -> Color.White
            },
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White,
            pressedContentColor = Color.Black,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.12f, pressedScale = 1.12f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Box(
            Modifier.fillMaxSize().drawBehind {
                val radius = CornerRadius(16.pt.toPx())
                if (missing) {
                    val width = 2.pt.toPx()
                    drawRoundRect(
                        Color.White.copy(alpha = 0.15f),
                        topLeft = Offset(width / 2, width / 2),
                        size = Size(size.width - width, size.height - width),
                        cornerRadius = radius,
                        style = Stroke(width, pathEffect = PathEffect.dashPathEffect(floatArrayOf(8.pt.toPx(), 6.pt.toPx()))),
                    )
                }
                if (anchor) {
                    val width = 4.pt.toPx()
                    drawRoundRect(
                        ResumeOrange,
                        topLeft = Offset(width / 2, width / 2),
                        size = Size(size.width - width, size.height - width),
                        cornerRadius = radius,
                        style = Stroke(width),
                    )
                }
            },
            contentAlignment = Alignment.Center,
        ) {
            Text(episode.episodeNumber.toString(), style = McType.size(32))
            if (episode.played) {
                Icon(McIcons.Check, null, tint = McColors.Success, modifier = Modifier.align(Alignment.TopEnd).padding(top = 8.pt, end = 10.pt).size(20.pt))
            }
            val percent = episode.progressPercent
            if (!episode.played && episode.positionMs > 0 && percent != null) {
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(percent / 100f).height(6.pt).background(ResumeOrange))
            }
        }
    }
}
