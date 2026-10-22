@file:OptIn(ExperimentalFoundationApi::class)

package io.movieclaw.androidtv.ui.library

import android.content.Context
import android.os.SystemClock
import android.view.KeyEvent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import coil3.SingletonImageLoader
import coil3.request.CachePolicy
import coil3.request.ImageRequest
import coil3.size.Size
import io.movieclaw.androidtv.ui.components.CaptionMode
import io.movieclaw.androidtv.ui.components.LocalServer
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.PosterCard
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.components.imageUrl
import io.movieclaw.androidtv.ui.components.imagePixels
import io.movieclaw.androidtv.ui.detail.PillButton
import io.movieclaw.androidtv.ui.detail.WallLayout
import io.movieclaw.androidtv.ui.detail.focusSection
import io.movieclaw.androidtv.ui.detail.minimalScroll
import io.movieclaw.androidtv.ui.detail.tryFocus
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.Route
import io.movieclaw.androidtv.ui.stage.BlurredBackdrop
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.core.model.generated.FavoriteItemView
import io.movieclaw.core.model.generated.LibraryItemView
import io.movieclaw.core.network.ImageUrls
import io.movieclaw.core.network.generated.McApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.max

/** 墙上的一张海报（库存条目、收藏条目都转成它） */
internal data class WallItem(
    val id: Long,
    val libraryId: Long?,
    val title: String,
    val year: Long?,
    val poster: String?,
    val backdrop: String?,
    /** 入库时间（ISO）：按添加时间排序时位置提示写年月 */
    val added: String? = null,
)

internal fun LibraryItemView.toWall() = WallItem(mediaItemId, libraryId, title, year, posterUrl, backdropUrl, addedAt)
internal fun FavoriteItemView.toWall() = WallItem(mediaItemId, libraryId, title, year, posterUrl, backdropUrl)

/** 按 [WallQuery] 取一页 */
internal suspend fun McApi.fetchWall(q: WallQuery, offset: Long, limit: Long): List<WallItem> = when (q.endpoint) {
    WallQuery.Endpoint.Library -> libraryItemsList(
        q.id ?: 0, sort = q.sort, order = q.order, limit = limit, offset = offset, g = q.g, d = q.d, w = q.w, res = q.res, hdr = q.hdr,
    ).map { it.toWall() }
    WallQuery.Endpoint.MediaKind ->
        uiLibraryKindItems(q.kind.orEmpty(), sort = q.sort, order = q.order, limit = limit, offset = offset, g = q.g, w = q.w).map { it.toWall() }
    WallQuery.Endpoint.Collection -> collectionItemsList(q.id ?: 0, limit = limit, offset = offset, sort = q.sort, order = q.order).map { it.toWall() }
    WallQuery.Endpoint.Favorites ->
        playbackFavorites(limit = limit, offset = offset, unwatchedFirst = q.unwatchedFirst, sort = q.sort, order = q.order).items.map { it.toWall() }
}

/**
 * 海报墙的「窗口式」分页（LibraryWallPager，iPhone 与 Apple TV 共用的那一个）：
 * - 墙是整份排序结果上的一个**窗口** `[start, start + items.size)`；
 * - 往下滚到底追加下一页；索引条跳转直接把窗口换成从某个 offset 开始的一页（而不是从头一页页追到那儿），
 *   之后往上走再把上一页补回来；
 * - 请求用序号作废：换排序 / 筛选后，上一轮晚到的响应不会覆盖新窗口。
 * 按页面实例记住（PageStates），从详情退回来直接是原来那个窗口、焦点落回原处。
 */
@Stable
internal class WallPager(val pageSize: Int = PAGE_SIZE) {
    var items by mutableStateOf<List<WallItem>?>(null)
        private set
    /** 窗口在整份排序里的起点 */
    var start by mutableIntStateOf(0)
        private set
    var failed by mutableStateOf<String?>(null)
        private set
    /** 换过几次数据源（排序 / 筛选）：墙据此重新交焦点 */
    var resets by mutableIntStateOf(0)
        private set
    /** 现在这些条目是按哪一套参数取的 */
    var loadedKey: String? = null
        private set
    /** 标题与总数（媒体库名、库的部数），页面自己填 */
    var title by mutableStateOf<String?>(null)
    var count by mutableStateOf<Long?>(null)

    private var hasMore = false
    private var loading = false
    private var loadingPrev = false
    private var generation = 0
    private var fetch: (suspend (offset: Long, limit: Long) -> List<WallItem>)? = null

    /** 换数据源（排序 / 筛选变化）：清空并从头载入第一页 */
    suspend fun reset(key: String, fetch: suspend (offset: Long, limit: Long) -> List<WallItem>) {
        this.fetch = fetch
        loadedKey = key
        generation++
        items = null
        start = 0
        failed = null
        resets++
        jump(0)
    }

    suspend fun retry() {
        if (fetch != null) jump(start)
    }

    /** 窗口换成从 offset 开始的一页 */
    suspend fun jump(offset: Int) {
        val f = fetch ?: return
        val gen = ++generation
        loading = true
        try {
            val page = f(offset.toLong(), pageSize.toLong())
            if (gen != generation) return
            start = offset
            items = page
            hasMore = page.size >= pageSize
            failed = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (gen != generation) return
            if (items == null) {
                items = emptyList()
                failed = e.message ?: "网络请求失败"
            }
        } finally {
            if (gen == generation) loading = false
        }
    }

    /** 墙尾追加一页 */
    suspend fun loadMore() {
        val f = fetch ?: return
        val current = items ?: return
        if (!hasMore || loading) return
        val gen = generation
        val from = start + current.size
        loading = true
        try {
            val page = f(from.toLong(), pageSize.toLong())
            // 按拿到时的窗口拼：等待期间上面可能补进了一页（窗口尾巴不变），拼到最新的列表后面，别用发请求前的那份覆盖掉
            val now = items ?: return
            if (gen != generation || start + now.size != from) return
            val known = now.mapTo(HashSet()) { it.id }
            items = now + page.filter { it.id !in known }
            hasMore = page.size >= pageSize
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (gen == generation) hasMore = false
        } finally {
            if (gen == generation) loading = false
        }
    }

    /** 墙顶还有上文时补上一页（跳转之后仍然能往上走）；返回补进来几部 */
    suspend fun loadPrevious(): Int {
        val f = fetch ?: return 0
        if (items == null || start <= 0 || loadingPrev) return 0
        val gen = generation
        val origin = start
        loadingPrev = true
        try {
            val from = max(0, origin - pageSize)
            val page = try {
                f(from.toLong(), (origin - from).toLong())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return 0
            }
            // 按拿到时的窗口拼：等待期间下面可能接上了一页，前面拼到最新的列表上；窗口起点变了（换了窗口）就作废
            val now = items ?: return 0
            if (gen != generation || start != origin || page.isEmpty()) return 0
            val known = now.mapTo(HashSet()) { it.id }
            val added = page.filter { it.id !in known }
            start -= added.size
            items = added + now
            return added.size
        } finally {
            loadingPrev = false
        }
    }

    /** 某一部在整份排序里的位置 */
    fun offsetOf(id: Long): Int? = items?.indexOfFirst { it.id == id }?.takeIf { it >= 0 }?.let { start + it }

    companion object {
        /** 一页 60 部（12 排）：整排的倍数，往上补页时列位置不错开 */
        const val PAGE_SIZE = 60
    }
}

/** 筛空页上的一个按钮（「去掉“西部”可看 516 部」） */
internal data class WallAction(val id: String, val title: String, val action: () -> Unit)

/** 屏幕中央的位置提示 */
internal data class WallHud(val title: String, val detail: String)

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
 * 海报墙（TVPosterWall，媒体库、合集、「查看全部」共用，docs/design/tvos-app.md §3.4）：
 * - 大标题 + 灰色的条件摘要与部数 + 右边这一页自己的按钮；下面 5 列海报（不挂片名），
 *   焦点所在那张的底部浮出「片名 · 年份」暗带（#942：很多海报只印英文、艺术字甚至没字）；
 * - 背景是焦点那一部的剧照（模糊压暗，停稳 0.2 秒再换；按住方向键一路滚的时候不换）。
 *
 * 大库（几千部）的翻找（§3.1）：
 * - 窗口式分页（[WallPager]）：一页 60 部，离窗口底还有三排就取下一页、并把接下来的海报先下好；
 * - [index] 非空时右侧有索引条（A–Z、年份、分数档）：最右一列再按右键进去，上下选、确认跳过去，左键退出；
 *   跳转把窗口换成从那一档开始的一页，往上走再把前面一页页补回来；
 * - 按住方向键快速滚动时，屏幕中央浮出当前所在的档（「S」「2015」）和第几部。
 * 选中一部进详情，落点库优先用条目自带的 library_id；从详情返回，窗口与焦点都还在原处。
 */
@Composable
internal fun PosterWall(
    title: String,
    pager: WallPager,
    retry: suspend () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    fallbackLibrary: Long? = null,
    /** 整份结果共几部（位置提示「第 1204 部 / 共 3000 部」）；不知道就只写第几部 */
    total: Long? = null,
    /** 右侧索引条；空 = 这种排序没有索引条 */
    index: List<WallIndexEntry> = emptyList(),
    /** 没有索引条时，位置提示的大字写什么（按添加时间排序写「2026 年 8 月」）；null = 不提示 */
    positionTitle: ((WallItem) -> String?)? = null,
    emptyTitle: String = "这里还没有内容",
    emptyMessage: String? = null,
    /** 筛空时的出路（放宽建议、清除条件）；空 = 普通的空态 */
    emptyActions: List<WallAction> = emptyList(),
    /** 标题行右边的按钮；enabled = false 时不可聚焦（跳到库中间、前面还没补上时） */
    accessory: @Composable (enabled: Boolean) -> Unit = {},
    overlay: @Composable BoxScope.() -> Unit = {},
) {
    val router = LocalRouter.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val server = LocalServer.current
    val ptPx = LocalDensity.current.density * 0.5f
    val grid = rememberLazyGridState()
    val spec = remember(grid) { WallBringIntoViewSpec(grid, 60 * ptPx, 60 * ptPx) }
    val cols = WallLayout.COLUMNS
    /** 最近一次获得焦点的海报：从索引条按左键回到它、索引条亮出它所在的档、从详情退回来落回它 */
    var focusedId by rememberSaveable { mutableStateOf<Long?>(null) }
    var pageFocused by remember { mutableStateOf(false) }
    val requesters = remember { HashMap<Long, FocusRequester>() }
    fun req(id: Long) = requesters.getOrPut(id) { FocusRequester() }
    val items = pager.items

    // 快速滚动：连续几次焦点移动挨得很近就是按住了方向键
    var lastMoveAt by remember { mutableLongStateOf(0L) }
    var quickSteps by remember { mutableIntStateOf(0) }
    var hud by remember { mutableStateOf<WallHud?>(null) }
    /** 位置提示正在画的内容：淡出时 [hud] 已经清掉，照旧画最后一次的 */
    var hudShown by remember { mutableStateOf(WallHud("", "")) }
    fun showHud(value: WallHud) {
        hudShown = value
        hud = value
    }
    LaunchedEffect(hud) {
        if (hud == null) return@LaunchedEffect
        delay(1_200)
        hud = null
    }

    // 海报预取：新到的一页先下到磁盘，焦点往下走时把接下来三排解码进内存（同 RemoteImage 的地址，才命中同一条缓存）
    val posterPx = imagePixels(WallLayout.POSTER_WIDTH, McMetrics.FocusZoom)
    fun posterUrl(item: WallItem) = ImageUrls.build(server, item.poster, posterPx)?.toString()
    val prefetched = remember { HashSet<String>() }
    LaunchedEffect(items) {
        val urls = items.orEmpty().mapNotNull(::posterUrl).filter { prefetched.add(it) }
        WallPrefetch.page(context, urls)
    }

    // 背景跟着焦点那一部：停稳再换（快速滚动时多等一会儿），一路划过去时不逐张闪
    var backdrop by remember { mutableStateOf<WallItem?>(null) }
    LaunchedEffect(focusedId) {
        val id = focusedId ?: return@LaunchedEffect
        if (id == backdrop?.id) return@LaunchedEffect
        delay(if (quickSteps >= 2) 450 else 200)
        backdrop = pager.items?.firstOrNull { it.id == id }
    }

    // 条目出来时焦点还不在页面里：落回记下的那张，没有就第一张；空墙、失败落到状态页上
    val stateFocus = remember { FocusRequester() }
    LaunchedEffect(items != null, pager.resets) {
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

    fun positionDetail(offset: Int) = if (total != null) "第 ${offset + 1} 部 / 共 $total 部" else "第 ${offset + 1} 部"

    /** 往上补一页：网格按首个可见条目的 key 保持位置；只有标题行还露着时（它是首个可见项）要自己把补进来的几排高度滚掉 */
    suspend fun loadPrevious() {
        if (pager.start <= 0) return
        val headerFirst = grid.firstVisibleItemIndex == 0
        val added = pager.loadPrevious()
        if (added > 0 && headerFirst) grid.scrollBy(added / cols * WallLayout.ROW_STRIDE * ptPx)
    }

    /** 正在进行的那次跳转 */
    var jumpJob by remember { mutableStateOf<Job?>(null) }

    fun onItemFocused(id: Long) {
        focusedId = id
        val now = SystemClock.uptimeMillis()
        // 连续几次焦点移动都挨得很近，就是在按住方向键快速滚动（门槛同 Apple TV：0.55 秒、连着两次）
        quickSteps = if (now - lastMoveAt < 550) quickSteps + 1 else 0
        lastMoveAt = now
        val list = pager.items ?: return
        val position = list.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return
        val offset = pager.start + position
        if (quickSteps >= 2) {
            val label = if (index.isNotEmpty()) WallIndex.entryAt(offset, index)?.title else positionTitle?.invoke(list[position])
            if (label != null) showHud(WallHud(label, positionDetail(offset)))
        }
        if (position >= list.size - cols * 3) scope.launch { pager.loadMore() }
        if (position < cols * 3 && pager.start > 0) scope.launch { loadPrevious() }
        val ahead = list.subList(minOf(position + cols, list.size), minOf(position + cols * 4, list.size))
        WallPrefetch.ahead(context, ahead.mapNotNull(::posterUrl))
    }

    /** 焦点离开海报（到了索引条、按钮上）：快速滚动的计数清零 */
    fun onOtherFocused() {
        lastMoveAt = 0L
        quickSteps = 0
    }

    /**
     * 跳到某一档：窗口换成从这一档开始的一页（起点按整排对齐，列位置与从头翻下来时一样），先把前面一页也补上，
     * 再把这一档第一张所在的那一排滚到顶上、焦点交给它。
     * 先补前一页是为了让目标上面有内容：往上走时网格按首个可见条目保持位置，窗口第一排在页首时标题行是首个可见项，
     * 补页会把整屏顶下去
     */
    fun jump(entry: WallIndexEntry) {
        val offset = entry.offset ?: return
        // 上一次跳转还没走完（连按确认）：作废它，免得它拿这一次的窗口去交焦点
        jumpJob?.cancel()
        jumpJob = scope.launch {
            pager.jump(offset - offset % cols)
            pager.loadPrevious()
            val list = pager.items?.takeIf { it.isNotEmpty() } ?: return@launch
            val position = (offset - pager.start).coerceIn(0, list.size - 1)
            val target = list[position].id
            focusedId = target
            showHud(WallHud(entry.title, positionDetail(offset)))
            // 等网格按新窗口量过一遍再滚：赶在重新测量之前滚，网格测量时会按旧列表里首个可见条目的 key 把位置挪走——
            // 新旧窗口重叠时（相邻两档离得近），那个 key 在新窗口里换了下标，目标排就被挪出屏幕。
            // 至少等两帧（新列表这一帧才重组、测量），再确认量到的条目数对得上现在的窗口（标题行 + 海报 + 状态行）；最多等一秒
            withTimeoutOrNull(1_000) {
                repeat(2) { withFrameNanos {} }
                snapshotFlow { grid.layoutInfo.totalItemsCount == (pager.items?.size ?: -1) + 2 }.first { it }
            }
            // 网格第 0 项是标题行：海报的下标要加 1
            grid.scrollToItem(1 + position - position % cols)
            // 目标在这一帧才组合出来，请求焦点可能落空：没接住就稍等再交
            repeat(5) {
                delay(60)
                if (req(target).tryFocus()) return@launch
            }
        }
    }

    Box(modifier.fillMaxSize().onFocusChanged { pageFocused = it.hasFocus }) {
        BlurredBackdrop(imageUrl(backdrop?.let { it.backdrop ?: it.poster }, McMetrics.BlurredBackdropWidth.toFloat()))
        CompositionLocalProvider(LocalBringIntoViewSpec provides spec) {
            LazyVerticalGrid(
                columns = GridCells.Fixed(cols),
                state = grid,
                modifier = Modifier.fillMaxSize().testTag("wall-grid"),
                contentPadding = PaddingValues(start = McMetrics.Edge, end = McMetrics.Edge, top = McMetrics.PushedTop + 20.pt, bottom = 80.pt),
                horizontalArrangement = Arrangement.spacedBy(WallLayout.COLUMN_SPACING.pt),
                verticalArrangement = Arrangement.spacedBy(WallLayout.ROW_SPACING.pt),
            ) {
                item(key = "header", span = { GridItemSpan(maxLineSpan) }) {
                    // 标题行与网格之间 36（网格行距 40，这里收回 4）
                    WallHeader(title, subtitle, Modifier.shrinkBottom((4 * ptPx).toInt()).onFocusChanged { if (it.hasFocus) onOtherFocused() }) {
                        // 跳到库中间时，窗口前面的条目还没取回来：此时第一排往上应当原地不动、等前一页补上，
                        // 不能一下子落到页首的按钮上（按钮离真正的「上一部」还隔着几千部）
                        accessory(pager.start == 0)
                    }
                }
                if (items != null) {
                    itemsIndexed(items, key = { _, item -> item.id }) { position, item ->
                        PosterCard(
                            image = item.poster,
                            title = item.title,
                            subtitle = item.year?.toString(),
                            onClick = {
                                (item.libraryId ?: fallbackLibrary)?.let { router.push(Route.Item(it, item.id)) }
                            },
                            modifier = Modifier
                                .focusRequester(req(item.id))
                                .onFocusChanged { if (it.isFocused) onItemFocused(item.id) }
                                .testTag("poster:${item.id}"),
                            width = WallLayout.POSTER_WIDTH.pt,
                            widthPt = WallLayout.POSTER_WIDTH,
                            caption = CaptionMode.Band,
                        )
                        // 离窗口底还有三排就取下一页：按住方向键滚下去时，下一页已经在路上
                        if (position >= items.size - cols * 3) {
                            LaunchedEffect(items.size) { pager.loadMore() }
                        }
                    }
                }
                item(key = "state", span = { GridItemSpan(maxLineSpan) }) {
                    val failed = pager.failed
                    when {
                        items == null -> Box(Modifier.fillMaxWidth().padding(top = 120.pt), contentAlignment = Alignment.Center) { Spinner() }
                        failed != null -> StateView(
                            McIcons.WifiError,
                            "加载失败",
                            Modifier.focusRequester(stateFocus).focusGroup(),
                            message = failed,
                            action = "重试",
                            height = 500.pt,
                        ) { scope.launch { retry() } }
                        items.isEmpty() && emptyActions.isNotEmpty() -> EmptyActions(emptyTitle, emptyMessage, emptyActions, Modifier.focusRequester(stateFocus))
                        items.isEmpty() -> StateView(McIcons.Film, emptyTitle, Modifier.focusRequester(stateFocus).focusGroup(), message = emptyMessage, height = 500.pt)
                    }
                }
            }
        }
        if (index.isNotEmpty() && !items.isNullOrEmpty()) {
            val current = focusedId?.let(pager::offsetOf)?.let { WallIndex.entryAt(it, index) }?.key
                ?: index.firstOrNull { it.count > 0 }?.key
            WallRail(
                index = index,
                current = current,
                onJump = ::jump,
                onLeave = { focusedId?.let { requesters[it]?.tryFocus() } },
                onFocused = ::onOtherFocused,
                modifier = Modifier.align(Alignment.CenterEnd).padding(top = 120.pt, end = 12.pt),
            )
        }
        AnimatedVisibility(
            visible = hud != null,
            modifier = Modifier.align(Alignment.Center),
            enter = fadeIn(tween(200)) + scaleIn(tween(200), initialScale = 0.92f),
            exit = fadeOut(tween(200)) + scaleOut(tween(200), targetScale = 0.92f),
        ) { HudView(hudShown) }
        overlay()
    }
}

/** 标题行：大标题 52 粗体 + 灰色的条件摘要与部数，右边这一页自己的按钮；横贯整屏做成焦点区 */
@Composable
private fun WallHeader(title: String, subtitle: String?, modifier: Modifier, accessory: @Composable () -> Unit) {
    Row(
        modifier.fillMaxWidth().focusSection().focusGroup(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // 标题与摘要首行基线对齐
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(20.pt)) {
            Text(
                title,
                style = McType.size(52, FontWeight.Bold),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false).alignByBaseline(),
            )
            subtitle?.let {
                Text(
                    it,
                    style = McType.size(26, FontWeight.Medium),
                    color = Color.White.copy(alpha = 0.6f),
                    maxLines = 1,
                    modifier = Modifier.alignByBaseline().testTag("wall-subtitle"),
                )
            }
        }
        Spacer(Modifier.width(40.pt))
        // tvOS 整行按首行基线对齐：按钮比居中低 7（模拟器量的）
        Box(Modifier.offset(y = 7.pt)) { accessory() }
    }
}

/** 筛空：不留空墙，给出「去掉哪一条能找回多少部」 */
@Composable
private fun EmptyActions(title: String, message: String?, actions: List<WallAction>, modifier: Modifier) {
    Column(
        Modifier.fillMaxWidth().padding(top = 100.pt),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(24.pt),
    ) {
        Icon(McIcons.Filter, null, tint = McColors.Secondary, modifier = Modifier.size(80.pt))
        Text(title, style = McType.Title2.copy(fontWeight = FontWeight.SemiBold))
        message?.let { Text(it, style = McType.Callout, color = McColors.Secondary, modifier = Modifier.widthIn(max = 1400.pt)) }
        Row(
            modifier.padding(top = 12.pt).focusGroup().testTag("wall-empty-actions"),
            horizontalArrangement = Arrangement.spacedBy(32.pt),
        ) {
            actions.forEach { action ->
                PillButton(onClick = action.action, text = action.title, height = 66.pt)
            }
        }
    }
}

/**
 * 右侧索引条：一档一行，库里没有的档压暗、跳不过去。
 * 进条的落点是「当前所在的那一档」（[current]）：从最右一列按右键进来，焦点组 onEnter 把焦点交给它，
 * 而不是按位置挑到随缘的某个字母。上下键自己挪（顺手跳过空档、到头就停），左键回到刚才那张海报，确认跳过去
 */
@Composable
private fun WallRail(
    index: List<WallIndexEntry>,
    current: String?,
    onJump: (WallIndexEntry) -> Unit,
    onLeave: () -> Unit,
    onFocused: () -> Unit,
    modifier: Modifier,
) {
    val requesters = remember(index) { index.associate { it.key to FocusRequester() } }
    var focusedKey by remember { mutableStateOf<String?>(null) }
    val rowHeight = minOf(30, 820 / max(index.size, 1))
    val narrow = index.any { it.label.length > 2 }

    fun step(delta: Int) {
        var position = index.indexOfFirst { it.key == focusedKey }.takeIf { it >= 0 } ?: return
        do position += delta while (position in index.indices && index[position].count == 0)
        if (position in index.indices) requesters[index[position].key]?.tryFocus()
    }

    Box(modifier.width(64.pt)) {
        Column(
            Modifier
                .width(64.pt)
                .background(if (focusedKey != null) Color(0xFF2A2C33).copy(alpha = 0.85f) else Color.Transparent, RoundedCornerShape(50))
                .padding(vertical = 12.pt)
                .focusProperties { onEnter = { current?.let { requesters[it] }?.tryFocus() } }
                .focusGroup()
                .onFocusChanged { if (it.hasFocus) onFocused() }
                .onPreviewKeyEvent { event ->
                    if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    when (event.key.nativeKeyCode) {
                        KeyEvent.KEYCODE_DPAD_UP -> {
                            step(-1)
                            true
                        }
                        KeyEvent.KEYCODE_DPAD_DOWN -> {
                            step(1)
                            true
                        }
                        KeyEvent.KEYCODE_DPAD_LEFT -> {
                            onLeave()
                            true
                        }
                        KeyEvent.KEYCODE_DPAD_RIGHT -> true
                        else -> false
                    }
                }
                .testTag("wall-rail"),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            index.forEach { entry ->
                RailEntry(
                    entry = entry,
                    current = entry.key == current,
                    height = rowHeight,
                    small = narrow,
                    modifier = Modifier
                        .focusRequester(requesters.getValue(entry.key))
                        .focusProperties { canFocus = entry.count > 0 }
                        .onFocusChanged {
                            if (it.isFocused) focusedKey = entry.key else if (focusedKey == entry.key) focusedKey = null
                        },
                ) { onJump(entry) }
            }
        }
        // 预览气泡：上半截的档往下展开、下半截的往上展开（贴着条顶的几档往上伸会盖住标题行的按钮）
        val focusedIndex = index.indexOfFirst { it.key == focusedKey }
        if (focusedIndex >= 0) {
            val entry = index[focusedIndex]
            val entryTop = 12 + focusedIndex * rowHeight
            val upper = focusedIndex < index.size / 2
            val y = if (upper) entryTop - 12 else entryTop + rowHeight + 12 - 180
            RailBubble(entry, Modifier.offset(x = (-258).pt, y = y.pt).wrapContentSize(Alignment.TopStart, unbounded = true))
        }
    }
}

/** 索引条的一格：平时灰字（当前所在的档白字、空档几乎看不见），获得焦点时白底黑字放大 */
@Composable
private fun RailEntry(entry: WallIndexEntry, current: Boolean, height: Int, small: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = modifier.size(width = (if (small) 58 else 44).pt, height = height.pt).testTag("rail:${entry.key}"),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(50)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            contentColor = Color.White.copy(alpha = if (entry.count == 0) 0.16f else if (current) 1f else 0.5f),
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White.copy(alpha = 0.85f),
            pressedContentColor = Color.Black,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.2f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(entry.label, style = McType.size(if (small) 16 else 20, FontWeight.SemiBold), maxLines = 1)
        }
    }
}

/** 索引条左边的预览气泡：档名大字 + 这一档有几部 */
@Composable
private fun RailBubble(entry: WallIndexEntry, modifier: Modifier) {
    Column(
        modifier
            .size(220.pt, 180.pt)
            .background(Color(0xFF2A2C33).copy(alpha = 0.92f), RoundedCornerShape(36.pt)),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.pt, Alignment.CenterVertically),
    ) {
        Text(entry.title, style = McType.size(if (entry.title.length > 2) 52 else 88, FontWeight.Bold), color = Color.White, maxLines = 1)
        Text("${entry.count} 部", style = McType.size(24), color = McColors.Secondary)
    }
}

/** 屏幕中央的位置提示：所在的档（或添加的年月）+ 第几部 */
@Composable
private fun HudView(hud: WallHud) {
    Column(
        Modifier
            .background(Color(0xFF2A2C33).copy(alpha = 0.92f), RoundedCornerShape(48.pt))
            .layout { measurable, constraints ->
                val minW = (300 * density * 0.5f).toInt()
                val minH = (260 * density * 0.5f).toInt()
                val placeable = measurable.measure(constraints)
                val w = max(minW, placeable.width)
                val h = max(minH, placeable.height)
                layout(w, h) { placeable.place((w - placeable.width) / 2, (h - placeable.height) / 2) }
            }
            .padding(horizontal = 40.pt)
            .testTag("wall-hud"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.pt),
    ) {
        Text(hud.title, style = McType.size(if (hud.title.length > 3) 64 else 120, FontWeight.Bold), color = Color.White, maxLines = 1)
        Text(hud.detail, style = McType.size(24), color = McColors.Secondary, maxLines = 1)
    }
}

/**
 * 海报墙的图片预取（TVWallPrefetch）：
 * - 新到的一页只下到磁盘缓存——一页 60 张都解码进内存太占。Coil 没有「只下载」的模式，不进内存缓存、按很小的尺寸解码，
 *   解码只做降采样，开销可以忽略；
 * - 焦点往下走时接下来三排解码进内存（原图尺寸，同 RemoteImage 的请求命中同一条内存缓存），滚到屏幕上时当场出图、不闪占位底。
 */
private object WallPrefetch {
    fun page(context: Context, urls: List<String>) {
        val loader = SingletonImageLoader.get(context)
        urls.forEach { url ->
            loader.enqueue(ImageRequest.Builder(context).data(url).memoryCachePolicy(CachePolicy.DISABLED).size(Size(32, 48)).build())
        }
    }

    fun ahead(context: Context, urls: List<String>) {
        val loader = SingletonImageLoader.get(context)
        urls.forEach { url ->
            loader.enqueue(ImageRequest.Builder(context).data(url).size(Size.ORIGINAL).build())
        }
    }
}

/** 排版高度少报 [px]（内容照画）：标题行与网格之间的间距比网格行距小一点 */
private fun Modifier.shrinkBottom(px: Int) = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    layout(placeable.width, max(0, placeable.height - px)) { placeable.place(0, 0) }
}
