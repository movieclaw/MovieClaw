package io.movieclaw.android.feature.discover

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.MenuSurface
import io.movieclaw.android.core.designsystem.PosterCard
import io.movieclaw.android.core.designsystem.PosterRibbon
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * 组合筛选的结果网格（iOS `DiscoverFilteredGrid` / 网页 `filtered-discovery-view.tsx`）。
 *
 * 条件生效（TMDB 源 + 至少一项条件）时，**发现页正文整块换成它**——不是压栈一个二级页：
 * 条件就在这页头部改（条件胶囊菜单），改了原地重查（300 毫秒防抖，连勾几个类型只查最后一次）。
 * 没有「查看结果」这一步，也没有第二份筛选状态（原先那个独立的「筛选结果」页已退役）。
 */

/** 筛选网格里的一格（TMDB discover 的返回切片） */
data class DiscTitle(
    val ref: String,
    val title: String,
    val year: Int?,
    val rating: Float?,
    val posterUrl: String?,
    val genres: List<String>,
    val owned: Boolean,
)

/** `discoverTitles` 的 `titles[]` → 网格数据（字段口径见服务端 DiscoveryTitleView） */
internal fun parseTitles(raw: JsonObject): List<DiscTitle> {
    val arr = raw["titles"]?.jsonArray ?: return emptyList()
    return arr.mapNotNull { el ->
        val o = el.jsonObject
        val ref = o["title_ref"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
        DiscTitle(
            ref = ref,
            title = o["title"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            year = o["release_year"]?.jsonPrimitive?.intOrNull,
            rating = o["provider_rating"]?.jsonPrimitive?.floatOrNull,
            posterUrl = o["poster_url"]?.jsonPrimitive?.contentOrNull,
            genres = (o["genres"]?.jsonArray ?: emptyList()).mapNotNull { it.jsonPrimitive.contentOrNull },
            // library_status 是**对象**（MediaLibraryStatus：media_item_id / library_count / file_count），
            // 不是字符串。以前拿它当 primitive 读，服务端一返回对象就抛
            // "Element class kotlinx.serialization.json.JsonObject is not a JsonPrimitive"，
            // 整页变成一串异常文字（用户报的"更多按钮点了报错"）。
            owned = (o["library_status"] as? JsonObject)?.let {
                (it["file_count"]?.jsonPrimitive?.intOrNull ?: 0) > 0
            } ?: false,
        )
    }
}

/**
 * 结果页头部的条件胶囊（iOS `DiscoverFilterChips`）：六个维度固定顺序各一颗，已启用的高亮
 * 并写出当前值，未启用的只写维度名；点开是同一份取值菜单（[DiscoveryFilterOptionsPanel]）。
 *
 * 顺序固定不按启用与否重排——改完一项胶囊原地变亮，手指下的东西不会跑位。
 * 这一排**固定在顶栏下方**（iOS 是随内容滚的）：安卓这里的取值菜单要从胶囊正下方长出，
 * 锚点固定才不会被滚动带偏；顶栏右上角那颗「全部」任何时候都能改条件。
 */
@Composable
fun DiscoverFilterChipsRow(
    filters: DiscoveryFilter,
    onOpenDim: (String) -> Unit,
    modifier: Modifier = Modifier,
    /** 横向留白；放进网格时网格自己的 contentPadding 已经让过页边距，传 0.dp */
    horizontalPadding: androidx.compose.ui.unit.Dp = McMetrics.pagePadding,
) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = horizontalPadding, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        items(discoveryDimKeys, key = { it }) { key ->
            val summary = discoveryDimSummary(key, filters)
            val on = summary != null
            Text(
                text = if (on) "${discoveryDimTitle(key)} · $summary" else discoveryDimTitle(key),
                style = McType.captionSemibold,
                color = if (on) TextPrimary else TextMuted,
                modifier = Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (on) Color.White.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.05f))
                    .border(
                        1.dp,
                        if (on) Color.Transparent else Color.White.copy(alpha = 0.1f),
                        RoundedCornerShape(999.dp),
                    )
                    .clickable { onOpenDim(key) }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }
    }
}

/**
 * 结果网格本体：**iOS `DiscoverFilteredGrid` 的头 + 胶囊 + 网格**（头与胶囊跟着滚，iOS 就是这样）。
 * 两列海报 + 滚到底自动翻页 + 空态 / 出错重试 / 到底提示（文案照 iOS）。
 * 翻页判定跟着网格的可见项走（同单库海报墙的写法），不靠哨兵行。
 */
@Composable
fun DiscoverFilteredGridBody(
    state: DiscoverViewModel.UiState,
    origin: String?,
    onOpenTitle: (String) -> Unit,
    onOpenDim: (String) -> Unit,
    onClear: () -> Unit,
    onLoadMore: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val grid = androidx.compose.foundation.lazy.grid.rememberLazyGridState()
    LaunchedEffect(grid, state.filtered.size) {
        androidx.compose.runtime.snapshotFlow {
            grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
        }.collect { last ->
            val total = grid.layoutInfo.totalItemsCount
            if (total > 0 && last >= total - 4) onLoadMore()
        }
    }
    LazyVerticalGrid(
        state = grid,
        columns = GridCells.Fixed(2),
        contentPadding = PaddingValues(
            start = McMetrics.pagePadding,
            end = McMetrics.pagePadding,
            bottom = 32.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(24.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = modifier.fillMaxSize(),
    ) {
        // ── 头（iOS `header`）：TMDB DISCOVER / 筛选结果 / 计数 + 「清空条件」──
        item(span = { GridItemSpan(2) }, key = "filtered-header") {
            Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Column(Modifier.weight(1f)) {
                    Text(
                        "TMDB DISCOVER",
                        fontSize = 15.sp,
                        fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                        letterSpacing = 2.sp,
                        color = io.movieclaw.android.core.designsystem.Accent,
                    )
                    Text("筛选结果", style = McType.title3, color = TextPrimary, modifier = Modifier.padding(top = 4.dp))
                    Text(
                        if (state.filteredTotal > 0) {
                            "找到 ${state.filteredTotal} 部，已加载 ${state.filtered.size} 部"
                        } else {
                            "已启用 ${state.filters.activeCount} 项筛选"
                        },
                        style = McType.sub,
                        color = TextMuted,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
                Text(
                    "清空条件",
                    style = McType.subSemibold,
                    color = TextPrimary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.12f))
                        .clickable(onClick = onClear)
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                )
            }
        }
        // ── 条件胶囊（同一个组件，菜单由外层挂）──
        item(span = { GridItemSpan(2) }, key = "filtered-chips") {
            // 网格里左右页边距已由 contentPadding 让出，这里横向留白传 0
            DiscoverFilterChipsRow(
                filters = state.filters,
                onOpenDim = onOpenDim,
                horizontalPadding = 0.dp,
            )
        }
        // distinctBy：网格按 ref 做 key，重复一条就是 IllegalArgumentException 崩（兜底，防服务端跨页重复）
        items(state.filtered.distinctBy { it.ref }, key = { it.ref }) { item ->
            PosterCard(
                imageUrl = item.posterUrl,
                origin = origin,
                title = item.title,
                meta = listOfNotNull(
                    item.year?.toString(),
                    item.genres.firstOrNull(),
                ).joinToString(" · ").takeIf { it.isNotBlank() },
                rating = item.rating?.takeIf { it > 0f },
                ribbon = if (item.owned) PosterRibbon.OWNED else null,
                modifier = Modifier.fillMaxWidth(),
                onClick = { onOpenTitle(item.ref) },
            )
        }
        if (state.filteredLoading && state.filtered.isEmpty()) {
            items(6) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(228.dp)
                        .clip(RoundedCornerShape(McMetrics.cardRadius))
                        .background(Color.White.copy(alpha = 0.05f)),
                )
            }
        }
        if (!state.filteredLoading && state.filteredError == null && state.filtered.isEmpty()) {
            item(span = { GridItemSpan(2) }) {
                Text(
                    "没有符合条件的影片",
                    style = McType.body,
                    color = TextMuted,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 60.dp),
                )
            }
        }
        state.filteredError?.let { error ->
            item(span = { GridItemSpan(2) }) {
                Column(
                    Modifier.fillMaxWidth().padding(vertical = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(error, style = McType.body, color = TextMuted)
                    Box(Modifier.height(10.dp))
                    TextButton(onClick = onRetry) { Text("重试", color = TextPrimary) }
                }
            }
        }
        if (state.filteredLoading && state.filtered.isNotEmpty()) {
            item(span = { GridItemSpan(2) }) {
                Box(Modifier.fillMaxWidth().padding(14.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(20.dp))
                }
            }
        }
        if (state.filteredPage >= state.filteredTotalPages && state.filtered.isNotEmpty()) {
            item(span = { GridItemSpan(2) }) {
                Text(
                    "已加载全部 ${state.filtered.size} 部影片",
                    style = McType.caption2,
                    color = TextFaint,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                )
            }
        }
    }
}

/** 维度取值面板的浮层（点开条件胶囊时挂在胶囊行正下方；点外关闭由外层的遮罩负责） */
@Composable
fun DiscoveryFilterDimPanel(
    dimKey: String,
    filters: DiscoveryFilter,
    onApply: (DiscoveryFilter) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .width(272.dp)
            .clip(RoundedCornerShape(McMetrics.menuRadius))
            .background(MenuSurface)
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(McMetrics.menuRadius))
            .padding(4.dp),
    ) {
        DiscoveryFilterOptionsPanel(dimKey = dimKey, filter = filters, onApply = onApply)
    }
}
