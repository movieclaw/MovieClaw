@file:OptIn(ExperimentalFoundationApi::class)

package io.movieclaw.androidtv.ui.library

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.Text
import io.movieclaw.androidtv.core.model.generated.FavoriteItemView
import io.movieclaw.androidtv.core.model.generated.LibraryItemView
import io.movieclaw.androidtv.core.network.generated.McApi
import io.movieclaw.androidtv.ui.components.CaptionMode
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.PosterCard
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.components.imageUrl
import io.movieclaw.androidtv.ui.detail.WallLayout
import io.movieclaw.androidtv.ui.detail.focusSection
import io.movieclaw.androidtv.ui.detail.minimalScroll
import io.movieclaw.androidtv.ui.detail.tryFocus
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.Route
import io.movieclaw.androidtv.ui.stage.BlurredBackdrop
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.max

/** 墙上的一张海报（库存条目、收藏条目都转成它） */
internal data class WallItem(
    val id: Long,
    val libraryId: Long?,
    val title: String,
    val year: Long?,
    val poster: String?,
    val backdrop: String?,
)

internal fun LibraryItemView.toWall() = WallItem(mediaItemId, libraryId, title, year, posterUrl, backdropUrl)
internal fun FavoriteItemView.toWall() = WallItem(mediaItemId, libraryId, title, year, posterUrl, backdropUrl)

/** 按 [WallQuery] 取一页 */
internal suspend fun McApi.fetchWall(q: WallQuery, offset: Long, limit: Long): List<WallItem> = when (q.endpoint) {
    WallQuery.Endpoint.Library -> libraryItemsList(q.id ?: 0, sort = q.sort, order = q.order, limit = limit, offset = offset, w = q.w).map { it.toWall() }
    WallQuery.Endpoint.MediaKind ->
        uiLibraryKindItems(q.kind.orEmpty(), sort = q.sort, order = q.order, limit = limit, offset = offset, g = q.g, w = q.w).map { it.toWall() }
    WallQuery.Endpoint.Collection -> collectionItemsList(q.id ?: 0, limit = limit, offset = offset, sort = q.sort, order = q.order).map { it.toWall() }
    WallQuery.Endpoint.Favorites ->
        playbackFavorites(limit = limit, offset = offset, unwatchedFirst = q.unwatchedFirst, sort = q.sort, order = q.order).items.map { it.toWall() }
}

/**
 * 海报墙的分页加载（TVWallLoader）：一页 60 条，滚到底接着取（按 id 去重）；换了排序 / 筛选整页重来。
 * 按页面实例记住（PageStates），从详情退回来直接是原来那些、焦点落回原处。
 */
@Stable
internal class WallLoader {
    var items by mutableStateOf<List<WallItem>?>(null)
        private set
    var failed by mutableStateOf<String?>(null)
        private set
    /** 现在这些条目是按哪一套参数取的 */
    var loadedKey: String? = null
        private set
    /** 标题与总数（媒体库名、库的部数），页面自己填 */
    var title by mutableStateOf<String?>(null)
    var count by mutableStateOf<Long?>(null)

    private var hasMore = false
    private var loading = false
    private var fetch: (suspend (offset: Long, limit: Long) -> List<WallItem>)? = null

    suspend fun reset(key: String, fetch: suspend (offset: Long, limit: Long) -> List<WallItem>) {
        this.fetch = fetch
        loadedKey = key
        try {
            val page = fetch(0, PAGE_SIZE)
            items = page
            hasMore = page.size.toLong() == PAGE_SIZE
            failed = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (items == null) items = emptyList()
            failed = e.message ?: "网络请求失败"
        }
    }

    suspend fun retry() {
        val f = fetch ?: return
        reset(loadedKey.orEmpty(), f)
    }

    suspend fun loadMore() {
        val f = fetch ?: return
        val current = items ?: return
        if (!hasMore || loading) return
        loading = true
        try {
            val page = try {
                f(current.size.toLong(), PAGE_SIZE)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return
            }
            val known = current.map { it.id }.toSet()
            items = current + page.filter { it.id !in known }
            hasMore = page.size.toLong() == PAGE_SIZE
        } finally {
            loading = false
        }
    }

    companion object {
        const val PAGE_SIZE = 60L
    }
}

/**
 * 海报墙的焦点滚动：第一排（标题行还露着时）一律滚回最顶，标题不被顶出去；其余只滚到露全、上下留边。
 * Lazy 网格没有绝对滚动量，用标题行（第 0 项）在可见区里的位置判断。
 */
private class WallBringIntoViewSpec(private val grid: LazyGridState, private val marginPx: Float, private val snapPx: Float) : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        val info = grid.layoutInfo
        val header = info.visibleItemsInfo.firstOrNull { it.index == 0 }
        if (header != null && offset < header.offset.y + header.size.height + snapPx) {
            return (header.offset.y - info.beforeContentPadding).toFloat()
        }
        return minimalScroll(offset, size, containerSize, marginPx)
    }
}

/**
 * 海报墙（TVPosterWall，媒体库、合集、「查看全部」共用）：大标题 + 灰色总数 + 右边这一页自己的按钮，
 * 下面 5 列海报（不挂片名），背景是焦点那一部的剧照（模糊压暗，停稳 0.2 秒再换）。
 * 选中一部进详情，落点库优先用条目自带的 library_id。
 */
@Composable
internal fun PosterWall(
    title: String,
    loader: WallLoader,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    fallbackLibrary: Long? = null,
    emptyTitle: String = "这里还没有内容",
    accessory: @Composable () -> Unit = {},
    overlay: @Composable BoxScope.() -> Unit = {},
) {
    val router = LocalRouter.current
    val scope = rememberCoroutineScope()
    val ptPx = LocalDensity.current.density * 0.5f
    val grid = rememberLazyGridState()
    val spec = remember(grid) { WallBringIntoViewSpec(grid, 60 * ptPx, 60 * ptPx) }
    var focusedId by rememberSaveable { mutableStateOf<Long?>(null) }
    var pageFocused by remember { mutableStateOf(false) }
    val requesters = remember { HashMap<Long, FocusRequester>() }
    fun req(id: Long) = requesters.getOrPut(id) { FocusRequester() }
    val items = loader.items

    // 背景跟着焦点那一部：停稳 0.2 秒再换，一路划过去时不逐张闪
    var backdrop by remember { mutableStateOf<WallItem?>(null) }
    LaunchedEffect(focusedId) {
        val id = focusedId ?: return@LaunchedEffect
        if (id == backdrop?.id) return@LaunchedEffect
        delay(200)
        backdrop = loader.items?.firstOrNull { it.id == id }
    }
    // 条目出来时焦点还不在页面里：落回记下的那张，没有就第一张；空墙、失败落到状态页上
    val stateFocus = remember { FocusRequester() }
    LaunchedEffect(items != null) {
        val list = items ?: return@LaunchedEffect
        delay(100)
        if (pageFocused) return@LaunchedEffect
        if (list.isEmpty()) {
            stateFocus.tryFocus()
            return@LaunchedEffect
        }
        val saved = focusedId
        if (saved != null && requesters[saved]?.tryFocus() == true) return@LaunchedEffect
        req(list.first().id).tryFocus()
    }

    Box(modifier.fillMaxSize().onFocusChanged { pageFocused = it.hasFocus }) {
        BlurredBackdrop(imageUrl(backdrop?.let { it.backdrop ?: it.poster }, McMetrics.BlurredBackdropWidth.toFloat()))
        CompositionLocalProvider(LocalBringIntoViewSpec provides spec) {
            LazyVerticalGrid(
                columns = GridCells.Fixed(WallLayout.COLUMNS),
                state = grid,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = McMetrics.Edge, end = McMetrics.Edge, top = 20.pt, bottom = 80.pt),
                horizontalArrangement = Arrangement.spacedBy(WallLayout.COLUMN_SPACING.pt),
                verticalArrangement = Arrangement.spacedBy(WallLayout.ROW_SPACING.pt),
            ) {
                item(key = "header", span = { GridItemSpan(maxLineSpan) }) {
                    // 标题行与网格之间 36（网格行距 40，这里收回 4）
                    WallHeader(title, subtitle, Modifier.shrinkBottom((4 * ptPx).toInt()), accessory)
                }
                if (items != null) {
                    itemsIndexed(items, key = { _, item -> item.id }) { index, item ->
                        PosterCard(
                            image = item.poster,
                            title = item.title,
                            subtitle = item.year?.toString(),
                            onClick = {
                                (item.libraryId ?: fallbackLibrary)?.let { router.push(Route.Item(it, item.id)) }
                            },
                            modifier = Modifier.focusRequester(req(item.id)).onFocusChanged { if (it.isFocused) focusedId = item.id },
                            width = WallLayout.POSTER_WIDTH.pt,
                            widthPt = WallLayout.POSTER_WIDTH,
                            caption = CaptionMode.Hidden,
                        )
                        // 滚到最后一排时接着取下一页
                        if (index >= items.size - WallLayout.COLUMNS) {
                            LaunchedEffect(items.size) { loader.loadMore() }
                        }
                    }
                }
                item(key = "state", span = { GridItemSpan(maxLineSpan) }) {
                    val failed = loader.failed
                    when {
                        items == null -> Box(Modifier.fillMaxWidth().padding(top = 120.pt), contentAlignment = Alignment.Center) { Spinner() }
                        failed != null -> StateView(
                            McIcons.WifiError,
                            "加载失败",
                            Modifier.focusRequester(stateFocus).focusGroup(),
                            message = failed,
                            action = "重试",
                            height = 500.pt,
                        ) { scope.launch { loader.retry() } }
                        items.isEmpty() -> StateView(McIcons.Film, emptyTitle, Modifier.focusRequester(stateFocus).focusGroup(), height = 500.pt)
                    }
                }
            }
        }
        overlay()
    }
}

/** 标题行：大标题 52 粗体 + 灰色「N 部」，右边这一页自己的按钮；横贯整屏做成焦点区 */
@Composable
private fun WallHeader(title: String, subtitle: String?, modifier: Modifier, accessory: @Composable () -> Unit) {
    Row(
        modifier.fillMaxWidth().focusSection().focusGroup(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // 标题与「N 部」首行基线对齐
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(20.pt)) {
            Text(
                title,
                style = McType.size(52, FontWeight.Bold),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false).alignByBaseline(),
            )
            subtitle?.let {
                Text(it, style = McType.size(26, FontWeight.Medium), color = Color.White.copy(alpha = 0.6f), maxLines = 1, modifier = Modifier.alignByBaseline())
            }
        }
        Spacer(Modifier.width(40.pt))
        accessory()
    }
}

/** 排版高度少报 [px]（内容照画）：标题行与网格之间的间距比网格行距小一点 */
private fun Modifier.shrinkBottom(px: Int) = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    layout(placeable.width, max(0, placeable.height - px)) { placeable.place(0, 0) }
}
