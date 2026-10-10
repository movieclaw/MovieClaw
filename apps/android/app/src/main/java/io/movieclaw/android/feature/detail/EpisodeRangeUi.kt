package io.movieclaw.android.feature.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.EpisodeView

/*
 * 长剧集分段的界面件（docs/design/long-season-episode-ranges.md §4，手机版）：
 * 段胶囊、横排两头的「上一段 / 下一段」、「接着看」标、「全部分集」面板。
 * 视觉照用户确认的 v2 原型（iPhone 那一半）。
 */

/** 锚点色：橙点、「接着看」标、面板里锚点格子的描边与进度条（原型 --accent #ffb340） */
private val AnchorOrange = Color(0xFFFFB340)

/** 把第 [index] 项滚到横排正中（段胶囊打开时、换段后用） */
private suspend fun LazyListState.centerItem(index: Int) {
    if (layoutInfo.visibleItemsInfo.none { it.index == index }) scrollToItem(index)
    val item = layoutInfo.visibleItemsInfo.firstOrNull { it.index == index } ?: return
    val center = (layoutInfo.viewportStartOffset + layoutInfo.viewportEndOffset) / 2
    animateScrollBy((item.offset + item.size / 2 - center).toFloat())
}

/** 一排段胶囊：选中段实心，锚点段右上角橙点；选中段滚到中间 */
@Composable
internal fun EpisodeRangeChips(
    ranges: List<EpisodeRanges.Range>,
    current: Int,
    anchor: Int?,
    onPick: (EpisodeRanges.Range) -> Unit,
    tagPrefix: String,
) {
    val state = rememberLazyListState()
    val anchorRange = anchor?.let(EpisodeRanges::indexOf)
    LaunchedEffect(current) {
        val position = ranges.indexOfFirst { it.index == current }
        if (position >= 0) state.centerItem(position)
    }
    LazyRow(
        state = state,
        contentPadding = PaddingValues(horizontal = McMetrics.pagePadding),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(ranges, key = { it.index }) { range ->
            val on = range.index == current
            Box(
                Modifier
                    .testTag("$tagPrefix-${range.first}-${range.last}")
                    .semantics { selected = on }
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (on) Color.White else Color.White.copy(alpha = 0.06f))
                    .clickable { onPick(range) }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            ) {
                Text(
                    range.label,
                    style = if (on) McType.captionSemibold else McType.caption,
                    color = if (on) Color.Black else TextMuted,
                )
                if (range.index == anchorRange) {
                    Box(
                        Modifier
                            .align(Alignment.TopEnd)
                            .offset(x = 7.dp, y = (-3).dp)
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(AnchorOrange)
                            .semantics { contentDescription = "接着看在这一段" },
                    )
                }
            }
        }
    }
}

/** 横排首尾的「← 上一段 / 下一段 →」小卡：点了 = 手动换到那一段 */
@Composable
internal fun RangeEdgeCard(label: String, range: EpisodeRanges.Range, tag: String, onClick: () -> Unit) {
    Box(
        Modifier
            .testTag(tag)
            .width(96.dp)
            .height(112.5.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "$label\n${range.label}",
            style = McType.micro.copy(lineHeight = 18.sp),
            color = TextMuted,
            textAlign = TextAlign.Center,
        )
    }
}

/** 锚点卡左上角的「接着看」 */
@Composable
internal fun ResumeTag(modifier: Modifier = Modifier) {
    Text(
        "接着看",
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        color = Color.Black,
        modifier = modifier
            .testTag("ep-resume-tag")
            .clip(RoundedCornerShape(5.dp))
            .background(AnchorOrange)
            .padding(horizontal = 6.dp, vertical = 1.dp),
    )
}

/**
 * 「全部分集」面板：标题 +「在库 x / y」、一排段胶囊（打开时落在锚点段）、5 列数字宫格。
 * 格子：已看 ✓、进度条、缺集虚线、锚点橙边、选中实心；点格子 = 关面板 + 选中那一集（段跟着锁过去）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AllEpisodesSheet(
    episodes: List<EpisodeView>,
    ranges: List<EpisodeRanges.Range>,
    anchor: Int?,
    selected: Int?,
    onPick: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    var sheetRange by remember {
        mutableIntStateOf(
            anchor?.let(EpisodeRanges::indexOf)?.takeIf { a -> ranges.any { it.index == a } }
                ?: selected?.let(EpisodeRanges::indexOf)?.takeIf { s -> ranges.any { it.index == s } }
                ?: ranges.first().index,
        )
    }
    val range = ranges.firstOrNull { it.index == sheetRange } ?: ranges.first()
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Color(0xFF1C1E24),
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .semantics { testTagsAsResourceId = true }
                .testTag("ep-sheet"),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding),
            ) {
                Text("全部分集", style = McType.headline, color = TextPrimary)
                Spacer(Modifier.width(8.dp))
                Text(
                    "在库 ${episodes.count { it.owned }} / ${episodes.size}",
                    style = McType.micro,
                    color = TextFaint,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    "完成",
                    style = McType.sub,
                    color = TextMuted,
                    modifier = Modifier
                        .testTag("ep-sheet-done")
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(onClick = onDismiss)
                        .padding(horizontal = 6.dp, vertical = 4.dp),
                )
            }
            Spacer(Modifier.height(12.dp))
            EpisodeRangeChips(
                ranges = ranges,
                current = range.index,
                anchor = anchor,
                onPick = { sheetRange = it.index },
                tagPrefix = "ep-sheet-chip",
            )
            val grid = rememberLazyGridState()
            // 锚点在这一段就把它滚到可见（第 50 集在宫格最底下，不滚看不见）；不在就回到顶
            LaunchedEffect(range.index) {
                val hit = range.episodes.indexOfFirst { it.episodeNumber == anchor }
                if (hit < 0) {
                    grid.scrollToItem(0)
                    return@LaunchedEffect
                }
                grid.scrollToItem(hit)
                val info = grid.layoutInfo
                val cell = info.visibleItemsInfo.firstOrNull { it.index == hit } ?: return@LaunchedEffect
                val center = (info.viewportStartOffset + info.viewportEndOffset) / 2
                grid.scrollBy((cell.offset.y + cell.size.height / 2 - center).toFloat())
            }
            LazyVerticalGrid(
                columns = GridCells.Fixed(5),
                state = grid,
                contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 12.dp, bottom = 30.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth().heightIn(max = 460.dp),
            ) {
                items(range.episodes, key = { it.episodeNumber }) { episode ->
                    EpisodeCell(
                        episode = episode,
                        anchor = episode.episodeNumber == anchor,
                        selected = episode.episodeNumber == selected,
                        onClick = { onPick(episode.episodeNumber) },
                    )
                }
            }
        }
    }
}

@Composable
private fun EpisodeCell(episode: EpisodeView, anchor: Boolean, selected: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(10.dp)
    val missing = !episode.owned
    val progress = episode.progressPercent?.takeIf { !episode.played && it > 0 }
    Box(
        Modifier
            .testTag("ep-cell-${episode.episodeNumber}")
            .semantics {
                this.selected = selected
                if (anchor) contentDescription = "接着看"
            }
            .height(46.dp)
            .clip(shape)
            .background(
                when {
                    selected -> Color.White
                    missing -> Color.Transparent
                    episode.played -> Color.White.copy(alpha = 0.03f)
                    else -> Color.White.copy(alpha = 0.063f)
                },
            )
            .then(
                if (missing && !selected) {
                    Modifier.drawBehind {
                        drawRoundRect(
                            color = Color.White.copy(alpha = 0.15f),
                            cornerRadius = CornerRadius(10.dp.toPx()),
                            style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f))),
                        )
                    }
                } else {
                    Modifier
                },
            )
            .then(if (anchor) Modifier.border(2.dp, AnchorOrange, shape) else Modifier)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "${episode.episodeNumber}",
            fontSize = 15.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = when {
                selected -> Color.Black
                missing -> TextFaint
                episode.played -> TextMuted
                else -> TextPrimary
            },
        )
        if (episode.played) {
            Text(
                "✓",
                fontSize = 9.sp,
                color = Success,
                modifier = Modifier.align(Alignment.TopEnd).padding(top = 2.dp, end = 5.dp),
            )
        }
        if (progress != null) {
            Box(
                Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth(progress / 100f)
                    .height(3.dp)
                    .background(AnchorOrange),
            )
        }
    }
}
