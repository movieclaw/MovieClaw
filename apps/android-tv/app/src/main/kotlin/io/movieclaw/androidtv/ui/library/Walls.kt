package io.movieclaw.androidtv.ui.library

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.Surface
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.detail.PageStates
import io.movieclaw.androidtv.ui.detail.PillButton
import io.movieclaw.androidtv.ui.detail.attempt
import io.movieclaw.androidtv.ui.detail.tryFocus
import io.movieclaw.androidtv.ui.shell.WallSource
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.core.model.generated.FacetValueView
import io.movieclaw.core.model.generated.LibraryFacetsView
import io.movieclaw.core.model.generated.RelaxSuggestionView
import io.movieclaw.core.network.generated.McApi
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import java.util.UUID

/** 这一页按页面实例记住的状态：从详情退回来不重取，窗口、条件、焦点都还在 */
@Composable
private fun <T : Any> rememberPageState(kind: String, create: () -> T): T {
    val session = LocalSession.current
    val token = rememberSaveable { UUID.randomUUID().toString() }
    return remember(token) { PageStates.getOrPut("wall:$kind:${session.key}:$token", create) }
}

/** 媒体库墙这一次的状态：类型 / 年代 / 画质是这一次的意图，离开页面就清空（排序是偏好，记在本机） */
@Stable
private class LibraryWallState {
    val pager = WallPager()
    var picks by mutableStateOf(WallPicks())
    var facets by mutableStateOf<LibraryFacetsView?>(null)
    var facetsFor: WallFilter? = null
    var index by mutableStateOf<List<WallIndexEntry>>(emptyList())
    var relax by mutableStateOf<List<RelaxSuggestionView>>(emptyList())
}

/** 筛选面板候选值与计数：二级维度（画质）的计数要 tier=all 才有 */
private suspend fun McApi.wallFacets(libraryId: Long, f: WallFilter) =
    libraryItemsFacets(libraryId, tier = "all", g = f.g, d = f.d, w = f.w, res = f.res, hdr = f.hdr)

/** 跳转索引：order 必须与取墙时同一个值，offset 才对得上；按上映排序要按年分档（旧服务端不认这个参数，回月份档，照样按年并起来） */
private suspend fun McApi.wallIndex(libraryId: Long, sort: WallSort, f: WallFilter) = uiLibraryItemsIndex(
    libraryId,
    sort = sort.sort,
    order = WallLogic.orderParam(sort.sort, sort.reversed),
    granularity = if (sort.sort == "release_date") "year" else null,
    g = f.g, d = f.d, w = f.w, res = f.res, hdr = f.hdr,
)

/**
 * 一个媒体库的海报墙（TVLibraryView）：库名 + 条件摘要与部数 + 「排序与筛选」+ 海报墙。
 *
 * 电视上的筛选只留四样，都收在标题行右边那一枚按钮里：排序（最近添加 / 最近上映 / 评分 / 片名）、「只看没看过的」、
 * 类型 / 年代 / 画质三个二级菜单（每项写部数、0 部置灰，口径与墙同一套参数）。排序与「只看没看过的」按库记在本机，
 * 类型 / 年代 / 画质离开页面就清空。筛空时给出放宽建议，不留空墙。
 */
@Composable
fun LibraryWallScreen(libraryId: Long) {
    val session = LocalSession.current
    val store = LocalGraph.current.store
    val state = rememberPageState("library") { LibraryWallState() }
    val pager = state.pager
    val key = WallLogic.sortKey(libraryId)
    var sort by remember { mutableStateOf(WallLogic.decodeSort(store.string(key))) }
    var unwatched by remember { mutableStateOf(store.string("$key.unwatched") == "true") }
    var menuOpen by remember { mutableStateOf(false) }
    val buttonFocus = remember { FocusRequester() }
    // 面板关着焦点出不去：等它从树上撤掉再把焦点还给按钮
    var menuShown by remember { mutableStateOf(false) }
    LaunchedEffect(menuOpen) {
        if (!menuOpen && menuShown) {
            delay(16)
            buttonFocus.tryFocus()
        }
        menuShown = menuOpen
    }

    LaunchedEffect(libraryId) {
        if (pager.title != null) return@LaunchedEffect
        attempt { session.api.libraryList(scope = "all") }?.firstOrNull { it.id == libraryId }?.let {
            pager.title = it.name
            pager.count = it.stats.itemCount
        }
    }

    val picks = state.picks
    val filter = WallFilters.of(picks, unwatched)
    val queryKey = "${sort.sort}-${sort.reversed}-$filter"

    suspend fun reload() {
        val query = WallLogic.libraryQuery(libraryId, sort, filter)
        val sortNow = sort
        state.index = emptyList()
        state.relax = emptyList()
        coroutineScope {
            // 索引与第一页一起取
            val raw = async { if (WallIndex.supports(sortNow.sort)) attempt { session.api.wallIndex(libraryId, sortNow, filter) }.orEmpty() else emptyList() }
            pager.reset(queryKey) { offset, limit -> session.api.fetchWall(query, offset, limit) }
            state.index = WallIndex.entries(sortNow.sort, sortNow.reversed, raw.await())
        }
        if (pager.items?.isEmpty() == true && !filter.isEmpty) {
            state.relax = attempt { session.api.libraryItemsRelax(libraryId, g = filter.g, d = filter.d, w = filter.w, res = filter.res, hdr = filter.hdr) }
                ?.suggestions.orEmpty()
        }
    }

    LaunchedEffect(queryKey) {
        if (pager.loadedKey == queryKey && pager.items != null) return@LaunchedEffect
        reload()
    }
    // 计数只跟条件走、与排序无关
    LaunchedEffect(filter) {
        if (state.facetsFor == filter && state.facets != null) return@LaunchedEffect
        state.facets = null
        state.facets = attempt { session.api.wallFacets(libraryId, filter) }
        state.facetsFor = filter
    }

    val facets = state.facets
    val conditions = WallFilters.conditions(picks, unwatched, facets)
    // 当前条件下共几部：用 facet 的命中数（与墙同一套参数）；还没回来时，没加条件先用库的统计顶上
    val total = facets?.total ?: if (filter.isEmpty) pager.count else null
    val emptyActions = if (!filter.isEmpty && pager.items?.isEmpty() == true) {
        state.relax.map { suggestion ->
            WallAction("${suggestion.dim}:${suggestion.value}", "去掉“${WallFilters.relaxLabel(suggestion)}”可看 ${suggestion.count} 部") {
                val (p, u) = WallFilters.remove(suggestion.dim, state.picks, unwatched)
                state.picks = p
                if (u != unwatched) {
                    unwatched = u
                    store.putString("$key.unwatched", u.toString())
                }
            }
        } + WallAction("clear", "清除全部条件") {
            state.picks = WallPicks()
            unwatched = false
            store.putString("$key.unwatched", "false")
        }
    } else {
        emptyList()
    }

    PosterWall(
        title = pager.title ?: "媒体库",
        pager = pager,
        retry = { reload() },
        subtitle = WallFilters.summary(conditions, total),
        fallbackLibrary = libraryId,
        total = total,
        index = state.index,
        positionTitle = if (sort.sort == "added_at") ({ WallFilters.addedMonth(it.added) }) else null,
        emptyTitle = if (filter.isEmpty) "这个库里还没有内容" else "没有符合条件的影片",
        emptyMessage = if (filter.isEmpty) null else "「${conditions.joinToString(" · ")}」下没有影片，换一个条件试试",
        emptyActions = emptyActions,
        accessory = { enabled ->
            WallMenuButton(WallLogic.sortButtonLabel(sort.sort), enabled, Modifier.focusRequester(buttonFocus).testTag("wall-menu-button")) { menuOpen = true }
        },
        overlay = {
            if (menuOpen) {
                LibraryMenu(
                    sort = sort.sort,
                    unwatched = unwatched,
                    picks = picks,
                    facets = facets,
                    onSort = {
                        sort = WallSort(it)
                        store.putString(key, WallLogic.encodeSort(sort))
                    },
                    onToggleUnwatched = {
                        unwatched = !unwatched
                        store.putString("$key.unwatched", unwatched.toString())
                    },
                    onPicks = { state.picks = it },
                    onDismiss = { menuOpen = false },
                )
            }
        },
    )
}

/** 合集墙（TVCollectionView）：同一套海报墙，条目来自合集接口；排序按合集记在本机，默认是合集自己的顺序 */
@Composable
fun CollectionWallScreen(collectionId: Long, name: String) {
    val session = LocalSession.current
    val store = LocalGraph.current.store
    val pager = rememberPageState("collection") { WallPager() }
    val key = WallLogic.collectionSortKey(collectionId)
    var sort by remember {
        mutableStateOf(WallLogic.decodeSort(store.string(key), WallLogic.COLLECTION_SORTS, WallSort(WallLogic.COLLECTION_ORDER)))
    }
    var menuOpen by remember { mutableStateOf(false) }
    val buttonFocus = remember { FocusRequester() }
    var menuShown by remember { mutableStateOf(false) }
    LaunchedEffect(menuOpen) {
        if (!menuOpen && menuShown) {
            delay(16)
            buttonFocus.tryFocus()
        }
        menuShown = menuOpen
    }
    val queryKey = "${sort.sort}-${sort.reversed}"
    suspend fun reload() {
        val query = WallLogic.collectionQuery(collectionId, sort)
        pager.reset(queryKey) { offset, limit -> session.api.fetchWall(query, offset, limit) }
    }
    LaunchedEffect(queryKey) {
        if (pager.loadedKey == queryKey && pager.items != null) return@LaunchedEffect
        reload()
    }
    PosterWall(
        title = name,
        pager = pager,
        retry = { reload() },
        emptyTitle = "合集里还没有内容",
        accessory = { enabled ->
            WallMenuButton("排序 · ${WallLogic.collectionLabel(sort.sort)}", enabled, Modifier.focusRequester(buttonFocus)) { menuOpen = true }
        },
        overlay = {
            if (menuOpen) {
                MenuPanels<Unit>(
                    onDismiss = { menuOpen = false },
                    main = { first ->
                        WallLogic.COLLECTION_SORTS.forEachIndexed { i, option ->
                            MenuRow(
                                WallLogic.collectionLabel(option),
                                checked = option == sort.sort,
                                modifier = if (i == 0) Modifier.focusRequester(first) else Modifier,
                            ) {
                                sort = WallSort(option)
                                store.putString(key, WallLogic.encodeSort(sort))
                                menuOpen = false
                            }
                        }
                    },
                )
            }
        },
    )
}

/** 首页一行的「查看全部」/ 按类型墙（TVRowWallView）：取数参数与那一行完全一样，排序跟着行走 */
@Composable
fun RowWallScreen(title: String, source: WallSource) {
    val session = LocalSession.current
    val pager = rememberPageState("row") { WallPager() }
    suspend fun reload() {
        val query = WallLogic.rowQuery(source)
        pager.reset("row") { offset, limit -> session.api.fetchWall(query, offset, limit) }
    }
    LaunchedEffect(source) {
        if (pager.items != null) return@LaunchedEffect
        reload()
    }
    // 媒体库那一行没带部数时，按库的统计补上（只在没加筛选时写）
    LaunchedEffect(source) {
        if (source !is WallSource.Library || source.count != null || pager.count != null) return@LaunchedEffect
        if (WallLogic.rowCount(source, 0) == null) return@LaunchedEffect
        attempt { session.api.libraryList(scope = "all") }?.firstOrNull { it.id == source.id }?.let { pager.count = it.stats.itemCount }
    }
    val total = WallLogic.rowCount(source, pager.count)
    PosterWall(
        title = title,
        pager = pager,
        retry = { reload() },
        subtitle = total?.let { "$it 部" },
        fallbackLibrary = (source as? WallSource.Library)?.id,
        total = total,
    )
}

/** 标题行右边的按钮（tvOS 的系统 Menu 按钮）：图标「line.3.horizontal.decrease」+ 字 */
@Composable
private fun WallMenuButton(text: String, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    PillButton(
        onClick = onClick,
        text = text,
        icon = McIcons.Filter,
        // tvOS 默认按钮在标题行里矮一号（65），图标也比详情页的宽
        height = 65.pt,
        iconSize = 34.pt,
        modifier = modifier.focusProperties { canFocus = enabled },
    )
}

/** 媒体库墙的二级菜单 */
private enum class FacetMenu(val title: String) { Genre("类型"), Decade("年代"), Quality("画质") }

/**
 * 「排序与筛选」菜单（tvOS 的系统 Menu）：排序（当前档打勾）、「只看没看过的」，「筛选」一节里类型 / 年代 / 画质三个二级菜单
 * （写着当前选的值，进去每项写部数，0 部的置灰但照样列出）、选了条件时再加「清除筛选」。选一项就收起。
 */
@Composable
private fun BoxScope.LibraryMenu(
    sort: String,
    unwatched: Boolean,
    picks: WallPicks,
    facets: LibraryFacetsView?,
    onSort: (String) -> Unit,
    onToggleUnwatched: () -> Unit,
    onPicks: (WallPicks) -> Unit,
    onDismiss: () -> Unit,
) {
    var open by remember { mutableStateOf<FacetMenu?>(null) }
    val rowFocus = remember { FacetMenu.entries.associateWith { FocusRequester() } }
    /** 各个二级菜单那一行在屏幕上的 y：二级菜单的上沿对着它 */
    val rowY = remember { mutableStateMapOf<FacetMenu, Int>() }
    val genres = facets?.genres
    val decades = WallFilters.decadeOptions(facets)
    val qualities = WallFilters.qualityOptions(facets)
    fun selected(menu: FacetMenu): String? = when (menu) {
        FacetMenu.Genre -> picks.genre?.toString()
        FacetMenu.Decade -> picks.decade
        FacetMenu.Quality -> picks.quality
    }
    fun options(menu: FacetMenu): List<FacetValueView>? = when (menu) {
        FacetMenu.Genre -> genres
        FacetMenu.Decade -> decades
        FacetMenu.Quality -> qualities
    }
    fun selectedLabel(menu: FacetMenu): String {
        val value = selected(menu) ?: return "全部"
        if (menu == FacetMenu.Quality) return WallFilters.qualityLabel(value, facets)
        return options(menu)?.firstOrNull { it.value == value }?.label ?: if (menu == FacetMenu.Decade) WallFilters.decadeLabel(value) else value
    }
    fun pick(menu: FacetMenu, value: String?) {
        onPicks(
            when (menu) {
                FacetMenu.Genre -> picks.copy(genre = value?.toLongOrNull())
                FacetMenu.Decade -> picks.copy(decade = value)
                FacetMenu.Quality -> picks.copy(quality = value)
            },
        )
        onDismiss()
    }

    MenuPanels(
        onDismiss = onDismiss,
        sub = open,
        anchorY = open?.let { rowY[it] } ?: 0,
        onCloseSub = { open = null },
        subFocus = { rowFocus.getValue(it) },
        main = { first ->
            WallLogic.LIBRARY_SORTS.forEachIndexed { i, option ->
                MenuRow(
                    WallLogic.shortLabel(option),
                    checked = option == sort,
                    enabled = open == null,
                    modifier = if (i == 0) Modifier.focusRequester(first) else Modifier,
                ) {
                    onSort(option)
                    onDismiss()
                }
            }
            MenuDivider()
            MenuRow("只看没看过的", checked = unwatched, enabled = open == null) {
                onToggleUnwatched()
                onDismiss()
            }
            MenuDivider()
            MenuSection("筛选")
            FacetMenu.entries.forEach { menu ->
                MenuRow(
                    menu.title,
                    subtitle = selectedLabel(menu),
                    chevron = true,
                    enabled = open == null,
                    highlighted = open == menu,
                    modifier = Modifier
                        .focusRequester(rowFocus.getValue(menu))
                        .onGloballyPositioned { rowY[menu] = it.positionInRoot().y.toInt() }
                        .testTag("menu:${menu.name}"),
                ) { open = menu }
            }
            if (!picks.isEmpty) {
                MenuRow("清除筛选", icon = McIcons.ClearCircle, enabled = open == null) {
                    onPicks(WallPicks())
                    onDismiss()
                }
            }
        },
        subContent = { menu, first ->
            val current = selected(menu)
            MenuRow("全部", checked = current == null, modifier = Modifier.focusRequester(first)) { pick(menu, null) }
            val list = options(menu)
            if (list == null) {
                MenuRow("正在统计…", enabled = false) {}
            } else {
                list.forEach { option ->
                    MenuRow(
                        option.label,
                        subtitle = "${option.count} 部",
                        checked = current == option.value,
                        enabled = option.count > 0 || current == option.value,
                        modifier = Modifier.testTag("option:${option.value}"),
                    ) { pick(menu, option.value) }
                }
            }
        },
    )
}

/**
 * 菜单面板（tvOS 的系统 Menu）：按钮下方浮一块 450 宽的深色面板；打开时焦点落在第一项，返回键收起，焦点关在面板里。
 * 二级菜单（[sub]）浮在主面板左边、上沿对着它那一行：打开时主面板各项不可选（焦点只在二级菜单里），返回键回到那一行。
 * 面板太高时自己滚。尺寸照 tvOS 27 模拟器量的：一项 66 高（带副标题的 96）、左右各缩 17，勾在 26、字在 66。
 */
@Composable
private fun <S : Any> BoxScope.MenuPanels(
    onDismiss: () -> Unit,
    main: @Composable ColumnScope.(first: FocusRequester) -> Unit,
    sub: S? = null,
    /** 二级菜单要对着的那一行在屏幕上的 y（像素） */
    anchorY: Int = 0,
    onCloseSub: () -> Unit = {},
    subFocus: (S) -> FocusRequester = { FocusRequester.Default },
    subContent: @Composable ColumnScope.(S, first: FocusRequester) -> Unit = { _, _ -> },
) {
    val first = remember { FocusRequester() }
    val subFirst = remember { FocusRequester() }
    BackHandler(onBack = onDismiss)
    LaunchedEffect(Unit) {
        // 等面板排好再交焦点
        repeat(5) {
            delay(16)
            if (first.tryFocus()) return@LaunchedEffect
        }
    }
    // 二级菜单开了把焦点交进去；收起后还给它那一行（等主面板各项重新可选）
    var lastSub by remember { mutableStateOf<S?>(null) }
    LaunchedEffect(sub) {
        val previous = lastSub
        lastSub = sub
        repeat(5) {
            delay(16)
            val target = if (sub != null) subFirst else previous?.let(subFocus) ?: return@LaunchedEffect
            if (target.tryFocus()) return@LaunchedEffect
        }
    }
    var mainTop by remember { mutableFloatStateOf(0f) }

    Layout(
        content = {
            MenuPanel(Modifier.width(450.pt).onGloballyPositioned { mainTop = it.positionInRoot().y }) {
                main(first)
            }
            if (sub != null) {
                BackHandler(onBack = onCloseSub)
                MenuPanel(Modifier.width(420.pt).testTag("submenu")) { subContent(sub, subFirst) }
            }
        },
        modifier = Modifier
            .matchParentSize()
            .focusProperties { onExit = { cancelFocusChange() } }
            .focusGroup(),
    ) { measurables, constraints ->
        val ptPx = density * 0.5f
        val top = (165 * ptPx).toInt()
        val end = McMetrics.Edge.roundToPx()
        val maxHeight = constraints.maxHeight - top - (40 * ptPx).toInt()
        val loose = Constraints(maxHeight = maxHeight)
        val mainPanel = measurables[0].measure(loose)
        val subPanel = measurables.getOrNull(1)?.measure(loose)
        layout(constraints.maxWidth, constraints.maxHeight) {
            val mainX = constraints.maxWidth - end - mainPanel.width
            mainPanel.place(mainX, top)
            subPanel?.let {
                val y = (anchorY - mainTop.toInt() - (20 * ptPx).toInt()).coerceIn(0, maxOf(0, maxHeight - it.height))
                it.place(mainX - (24 * ptPx).toInt() - it.width, top + y)
            }
        }
    }
}

/** 一块菜单面板：深色圆角、细边、投影；内容超高时自己滚 */
@Composable
private fun MenuPanel(modifier: Modifier, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(44.pt)
    Column(
        modifier
            .shadow(40.pt, shape, ambientColor = Color.Black, spotColor = Color.Black.copy(alpha = 0.6f))
            // tvOS 是模糊玻璃；这里没有背后模糊，压深一些免得后面海报上的字透出来
            .background(Color(0xFF23252C).copy(alpha = 0.94f), shape)
            .border(1.pt, Color.White.copy(alpha = 0.12f), shape)
            .verticalScroll(rememberScrollState())
            .padding(vertical = 20.pt)
            .focusGroup(),
        content = content,
    )
}

/** 菜单里的分隔线 */
@Composable
private fun MenuDivider() {
    Box(Modifier.padding(vertical = 14.pt, horizontal = 33.pt).fillMaxWidth().height(1.pt).background(Color.White.copy(alpha = 0.16f)))
}

/** 菜单里一节的小标题（「筛选」） */
@Composable
private fun MenuSection(title: String) {
    Text(title, style = McType.size(22, FontWeight.Medium), color = Color.White.copy(alpha = 0.45f), modifier = Modifier.padding(start = 66.pt, top = 4.pt, bottom = 8.pt))
}

/**
 * 菜单里的一项：左边打勾的位置（或图标），字在 66；[subtitle] 写在字下面（二级菜单的当前值、选项的部数）；
 * [chevron] 是进二级菜单的箭头。获得焦点白底黑字；[enabled] = false 时不可选、字压暗（0 部的选项），
 * [highlighted] 是二级菜单开着时它那一行的浅底
 */
@Composable
private fun MenuRow(
    text: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    checked: Boolean = false,
    icon: ImageVector? = null,
    chevron: Boolean = false,
    enabled: Boolean = true,
    highlighted: Boolean = false,
    onClick: () -> Unit,
) {
    val height: Dp = if (subtitle != null) 96.pt else 66.pt
    Surface(
        onClick = onClick,
        modifier = modifier
            .padding(horizontal = 17.pt)
            .fillMaxWidth()
            .height(height)
            .focusProperties { canFocus = enabled },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(if (subtitle != null) 28.pt else 33.pt)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (highlighted) Color.White.copy(alpha = 0.12f) else Color.Transparent,
            contentColor = Color.White.copy(alpha = if (enabled || highlighted) 1f else 0.35f),
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White.copy(alpha = 0.85f),
            pressedContentColor = Color.Black,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.06f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Row(Modifier.padding(start = 24.pt, end = 24.pt).height(height), horizontalArrangement = Arrangement.spacedBy(10.pt), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(32.pt), contentAlignment = Alignment.Center) {
                when {
                    checked -> Icon(McIcons.Check, null, modifier = Modifier.size(28.pt))
                    icon != null -> Icon(icon, null, modifier = Modifier.size(28.pt))
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.pt)) {
                Text(text, style = McType.size(26), maxLines = 1)
                subtitle?.let { Text(it, style = McType.size(20), color = LocalContentColor.current.copy(alpha = 0.6f), maxLines = 1) }
            }
            if (chevron) Icon(McIcons.Forward, null, modifier = Modifier.size(30.pt))
        }
    }
}
