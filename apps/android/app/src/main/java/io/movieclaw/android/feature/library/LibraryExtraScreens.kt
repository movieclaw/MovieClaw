package io.movieclaw.android.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.pulltorefresh.pullToRefresh
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.material3.Icon
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.PhotoLibrary
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.TextButton
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridItemSpan
import androidx.compose.foundation.lazy.staggeredgrid.itemsIndexed
import androidx.compose.foundation.lazy.staggeredgrid.rememberLazyStaggeredGridState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.mutableStateOf
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.FavoritesSortOptions
import io.movieclaw.android.core.designsystem.ImageWidth
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.WallSortDirection
import io.movieclaw.android.core.designsystem.WallSortMenu
import io.movieclaw.android.core.designsystem.WallSortState
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.designsystem.effectiveSort
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.CollectionCover
import io.movieclaw.android.core.model.CollectionView
import io.movieclaw.android.core.model.LibraryGalleryGroupView
import io.movieclaw.android.core.model.LibraryMarksBus
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.PlaybackMarksRequest
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.core.session.WallPrefs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import javax.inject.Inject

/* ══════════ 我的收藏（iOS FavoritesView） ══════════ */

data class FavoritesState(
    val loading: Boolean = true,
    val error: String? = null,
    val items: List<io.movieclaw.android.core.model.FavoriteItemView> = emptyList(),
    /** 去重后的收藏作品总数（行首那句「N 部作品」用它，不是当前加载到的条数） */
    val total: Int = 0,
    // ── 排序（iOS WallSortState，键名同 Web 的 localStorage，记在本机）──
    val sort: WallSortState = WallSortState(),
    // ── 图床浏览（iOS GalleryPrefs：模式 / 分组 / 密度，都记在本机）──
    val galleryMode: Boolean = false,
    val galleryGrouped: Boolean = true,
    /** compact / standard / loose */
    val galleryDensity: String = "standard",
    val galleryGroups: List<LibraryGalleryGroupView> = emptyList(),
    val galleryLoading: Boolean = false,
    val galleryLoadingMore: Boolean = false,
    val galleryHasMore: Boolean = true,
)

@HiltViewModel
class FavoritesViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val wallPrefs: WallPrefs,
) : ViewModel() {
    private val _ui = MutableStateFlow(FavoritesState())
    val ui = _ui.asStateFlow()
    val origin: String? get() = repository.ui.value.origin

    init {
        // 本机偏好先落上（排序 / 图廊模式），再拉数据——免得先按默认拉一遍再重拉
        viewModelScope.launch {
            val prefs = wallPrefs.read()
            _ui.update {
                it.copy(
                    sort = WallSortState(prefs.sort, prefs.reversed),
                    galleryMode = prefs.galleryMode,
                    galleryGrouped = prefs.galleryGrouped,
                    galleryDensity = prefs.galleryDensity,
                )
            }
            load()
            if (_ui.value.galleryMode) loadGallery(reset = true)
        }
        // 在条目详情里点了收藏 / 取消：收藏墙也要跟着重拉
        viewModelScope.launch {
            LibraryMarksBus.version.drop(1).collect {
                load()
                if (_ui.value.galleryMode) loadGallery(reset = true)
            }
        }
    }

    /** 下拉刷新转圈（iOS `.refreshable` 的对应物） */
    private val _refreshing = MutableStateFlow(false)
    val refreshing: kotlinx.coroutines.flow.StateFlow<Boolean> = _refreshing.asStateFlow()

    fun refresh() {
        if (_refreshing.value) return
        viewModelScope.launch {
            _refreshing.value = true
            try {
                if (_ui.value.galleryMode) loadGallery(reset = true) else load()
                kotlinx.coroutines.withTimeoutOrNull(12_000) { _ui.first { !it.loading && !it.galleryLoading } }
            } finally {
                _refreshing.value = false
            }
        }
    }

    /** 换排序（或翻方向）：iOS 换排序要回墙首，所以两处都从头拉 */
    fun applySort(next: WallSortState) {
        if (next == _ui.value.sort) return
        _ui.update { it.copy(sort = next) }
        viewModelScope.launch {
            wallPrefs.saveSort(next.sort, next.reversed)
            load()
            if (_ui.value.galleryMode) loadGallery(reset = true)
        }
    }

    fun setGalleryMode(on: Boolean) {
        _ui.update { it.copy(galleryMode = on) }
        viewModelScope.launch {
            wallPrefs.saveGalleryMode(on)
            if (on && _ui.value.galleryGroups.isEmpty()) loadGallery(reset = true) else if (!on) load()
        }
    }

    fun setGalleryGrouped(on: Boolean) {
        _ui.update { it.copy(galleryGrouped = on) }
        viewModelScope.launch { wallPrefs.saveGalleryGrouped(on) }
    }

    fun setGalleryDensity(value: String) {
        _ui.update { it.copy(galleryDensity = value) }
        viewModelScope.launch { wallPrefs.saveGalleryDensity(value) }
    }

    /** 请求参数：默认档在服务端叫 `favorited_at`，只有反转了自然方向才带 order（与 Web 同一规矩） */
    private fun sortParams(): Pair<String, String?> {
        val s = _ui.value.sort
        val effective = s.effectiveSort()
        return effective to WallSortDirection.of(effective)?.orderParam(s.reversed)
    }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: run { _ui.update { it.copy(loading = false, error = "尚未连接服务器") }; return@launch }
            // 已有内容时不回到转圈：点收藏会被信号叫醒重拉，转圈会让整墙闪一下
            if (_ui.value.items.isEmpty()) _ui.update { it.copy(loading = true, error = null) }
            try {
                val (sort, order) = sortParams()
                val page = apiFactory.forOrigin(origin)
                    .favorites(limit = 60, offset = 0, sort = sort, order = order)
                    .dataOrThrow()
                _ui.update { it.copy(loading = false, items = page.items, total = page.total) }
            } catch (e: Exception) {
                _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
            }
        }
    }

    /** 图廊的一页 = 24 部作品（服务端按作品分页；同 iOS `LibraryGalleryWall.pageSize`） */
    fun loadGallery(reset: Boolean) {
        viewModelScope.launch {
            val origin = origin ?: run { _ui.update { it.copy(galleryLoading = false, galleryLoadingMore = false) }; return@launch }
            if (!reset && (_ui.value.galleryLoadingMore || !_ui.value.galleryHasMore)) return@launch
            val offset = if (reset) 0 else _ui.value.galleryGroups.size
            _ui.update { it.copy(galleryLoading = reset, galleryLoadingMore = !reset, error = null) }
            try {
                val (sort, order) = sortParams()
                val groups = apiFactory.forOrigin(origin)
                    .favoritesGallery(limit = GALLERY_PAGE, offset = offset, sort = sort, order = order)
                    .dataOrThrow()
                _ui.update {
                    it.copy(
                        galleryLoading = false,
                        galleryLoadingMore = false,
                        galleryHasMore = groups.size >= GALLERY_PAGE,
                        galleryGroups = if (reset) groups else it.galleryGroups + groups,
                    )
                }
            } catch (e: Exception) {
                _ui.update { it.copy(galleryLoading = false, galleryLoadingMore = false, error = friendlyMessage(e)) }
            }
        }
    }

    /** 灯箱里取消收藏：收藏的是**整部作品**，成功后就把它从墙上摘掉（iOS 同口径） */
    fun unfavorite(mediaItemId: Long) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            try {
                apiFactory.forOrigin(origin)
                    .setPlaybackMarks(PlaybackMarksRequest(mediaItemId = mediaItemId, favorite = false))
                    .dataOrThrow()
                _ui.update { s ->
                    s.copy(
                        galleryGroups = s.galleryGroups.filterNot { it.mediaItemId == mediaItemId },
                        items = s.items.filterNot { it.mediaItemId == mediaItemId },
                        total = (s.total - 1).coerceAtLeast(0),
                    )
                }
            } catch (_: Exception) {
                // 失败就当没点：那颗心原本是实心的，会弹回来
            }
        }
    }

    private companion object {
        const val GALLERY_PAGE = 24
    }
}

@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
fun FavoritesScreen(
    onBack: () -> Unit,
    onOpenItem: (Long, Long) -> Unit,
    vm: FavoritesViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val refreshing by vm.refreshing.collectAsStateWithLifecycle()
    var lightbox by remember { mutableStateOf<Pair<io.movieclaw.android.core.model.LibraryGalleryGroupView, Int>?>(null) }
    var prefsMenu by remember { mutableStateOf(false) }
    val empty = state.items.isEmpty()
    Column(Modifier.fillMaxSize().background(Bg)) {
        SubTopBar("我的收藏", onBack) {
            if (!empty) {
                // 图床浏览 / 回到海报墙（iOS FavoritesView 顶栏那颗）
                io.movieclaw.android.core.designsystem.McNavButton(
                    if (state.galleryMode) Icons.Rounded.GridView else Icons.Rounded.PhotoLibrary,
                    contentDescription = if (state.galleryMode) "回到海报墙" else "图床浏览",
                    onClick = { vm.setGalleryMode(!state.galleryMode) },
                )
                if (state.galleryMode) {
                    Box {
                        io.movieclaw.android.core.designsystem.McNavButton(
                            Icons.Rounded.Tune,
                            contentDescription = "浏览设置",
                            onClick = { prefsMenu = true },
                        )
                        DropdownMenu(
                            expanded = prefsMenu,
                            onDismissRequest = { prefsMenu = false },
                            shape = RoundedCornerShape(14.dp),
                            containerColor = Color(0xFF15161A),
                        ) {
                            // 按作品分组（同 Web WallPrefItems；照片库没有分组一说，这里只有图床）
                            DropdownMenuItem(
                                text = { Text("按作品分组", fontSize = 14.sp, color = TextMuted) },
                                trailingIcon = {
                                    Text(if (state.galleryGrouped) "开" else "关", fontSize = 13.sp, color = Accent)
                                },
                                onClick = { vm.setGalleryGrouped(!state.galleryGrouped); prefsMenu = false },
                            )
                            HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
                            listOf("compact" to "紧凑", "standard" to "标准", "loose" to "宽松").forEach { (value, label) ->
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            label, fontSize = 14.sp,
                                            color = if (state.galleryDensity == value) TextPrimary else TextMuted,
                                        )
                                    },
                                    leadingIcon = if (state.galleryDensity == value) {
                                        { Icon(Icons.Rounded.Check, contentDescription = null, tint = Accent, modifier = Modifier.size(18.dp)) }
                                    } else null,
                                    onClick = { vm.setGalleryDensity(value); prefsMenu = false },
                                )
                            }
                        }
                    }
                }
            }
        }
        when {
            state.loading && empty -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = TextMuted) }
            state.error != null -> EmptyHint(state.error!!)
            empty -> EmptyHint("还没有收藏。在影片页点心，或在 Jellyfin 客户端里收藏，都会出现在这里。")
            state.galleryMode -> {
                GalleryWall(
                    state = state,
                    origin = vm.origin,
                    refreshing = refreshing,
                    onRefresh = { vm.refresh() },
                    onLoadMore = { vm.loadGallery(reset = false) },
                    onOpenGroup = { group -> onOpenItem(group.libraryId, group.mediaItemId) },
                    onOpenImage = { group, index -> lightbox = group to index },
                )
            }
            else -> {
                Column(Modifier.padding(horizontal = McMetrics.pagePadding)) {
                    Text(
                        "${if (state.total > 0) state.total else state.items.size} 部作品 · 与 Jellyfin 客户端里点的心同一份",
                        fontSize = 15.sp, color = TextMuted,
                        modifier = Modifier.padding(vertical = 8.dp),
                    )
                    // 排序（iOS WallSortMenu 的对应物）：默认「最近收藏」，当前档再点一次翻方向
                    WallSortMenu(
                        options = FavoritesSortOptions,
                        state = state.sort,
                        onPick = { vm.applySort(it) },
                        modifier = Modifier.padding(bottom = 10.dp),
                    )
                }
                LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    contentPadding = PaddingValues(horizontal = McMetrics.pagePadding, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                    modifier = Modifier.fillMaxSize().pullToRefresh(
                        isRefreshing = refreshing,
                        state = rememberPullToRefreshState(),
                        onRefresh = { vm.refresh() },
                    ),
                ) {
                    items(state.items, key = { it.mediaItemId }) { item ->
                        val libraryName = ""
                        Column(Modifier.clickable { onOpenItem(item.libraryId ?: -1L, item.mediaItemId) }) {
                            Box(
                                Modifier.fillMaxWidth().aspectRatio(2f / 3f)
                                    .clip(RoundedCornerShape(McMetrics.posterRadius))
                                    .border(1.dp, LineSoft, RoundedCornerShape(McMetrics.posterRadius))
                                    .background(Color(0xFF101219)),
                            ) {
                                RemoteImage(item.posterUrl, vm.origin, Modifier.fillMaxSize(), contentDescription = item.title)
                            }
                            Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(item.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, false))
                            }
                            Text(
                                // iOS 收藏格副行是「库名 · 年份」
                                listOfNotNull(
                                    if ((item.libraryId ?: 0L) > 0) "库 · $libraryName" else null,
                                    item.year?.toString(),
                                ).joinToString(" · "),
                                fontSize = 12.sp, color = TextMuted, modifier = Modifier.padding(top = 2.dp),
                            )
                        }
                    }
                }
            }
        }
    }

    lightbox?.let { (group, index) ->
        val images = group.images.map {
            // lightbox 用宽高比排版缩略图条：图廊直接给了 aspect，折成等价的宽高
            io.movieclaw.android.core.model.MediaImage(
                previewUrl = it.url,
                fullUrl = it.url,
                width = (it.aspect.coerceIn(0.5f, 2f) * 1000).toInt(),
                height = 1000,
            )
        }
        io.movieclaw.android.core.designsystem.Lightbox(
            images = images,
            title = group.title,
            initialIndex = index,
            origin = vm.origin,
            favorite = group.isFavorite,
            onToggleFavorite = {
                // 取消收藏 = 整部作品退出收藏墙（与详情页那颗心同一颗）
                vm.unfavorite(group.mediaItemId)
                lightbox = null
            },
            onOpenDetail = { onOpenItem(group.libraryId, group.mediaItemId); lightbox = null },
            onDismiss = { lightbox = null },
        )
    }
}

/** 瀑布流密度三档（iOS `GalleryDensity`，同 Web photo-wall.tsx）：列数 = max(最少列数, 按目标列宽算的列数) */
private data class GalleryDensitySpec(val column: Float, val minColumns: Int, val gap: Float)

private fun galleryDensitySpec(value: String): GalleryDensitySpec = when (value) {
    "compact" -> GalleryDensitySpec(column = 150f, minColumns = 3, gap = 3f)
    "loose" -> GalleryDensitySpec(column = 340f, minColumns = 1, gap = 10f)
    else -> GalleryDensitySpec(column = 230f, minColumns = 2, gap = 6f)
}

/** 图床浏览：按作品分组的瀑布流（iOS `LibraryGalleryWall`）；关掉分组就是一整面平铺 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun GalleryWall(
    state: FavoritesState,
    origin: String?,
    refreshing: Boolean,
    onRefresh: () -> Unit,
    onLoadMore: () -> Unit,
    onOpenGroup: (io.movieclaw.android.core.model.LibraryGalleryGroupView) -> Unit,
    onOpenImage: (io.movieclaw.android.core.model.LibraryGalleryGroupView, Int) -> Unit,
) {
    val spec = galleryDensitySpec(state.galleryDensity)
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    val gridState = rememberLazyStaggeredGridState()
    // 滑近底部自动要下一页（iOS 在墙面里同样按作品分页续拉）
    LaunchedEffect(gridState, state.galleryGroups.size, state.galleryHasMore) {
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collect { last ->
                val total = gridState.layoutInfo.totalItemsCount
                if (state.galleryHasMore && total > 0 && last >= total - 6) onLoadMore()
            }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val widthDp = maxWidth.value
        val columns = maxOf(
            spec.minColumns,
            ((widthDp + spec.gap) / (spec.column + spec.gap)).toInt(),
        )
        LazyVerticalStaggeredGrid(
            columns = StaggeredGridCells.Fixed(columns),
            contentPadding = PaddingValues(horizontal = McMetrics.pagePadding, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(spec.gap.dp),
            verticalItemSpacing = spec.gap.dp,
            modifier = Modifier.fillMaxSize().pullToRefresh(
                isRefreshing = refreshing,
                state = rememberPullToRefreshState(),
                onRefresh = onRefresh,
            ),
        ) {
            state.galleryGroups.forEach { group ->
                if (state.galleryGrouped) {
                    // 段标题通栏：作品名 + 年份（可点进详情），iOS `LibraryGalleryWall` 的分组头
                    item(key = "h-${group.mediaItemId}", span = StaggeredGridItemSpan.FullLine) {
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .padding(top = 12.dp, bottom = 4.dp)
                                .clickable { onOpenGroup(group) },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(group.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            group.year?.let { year ->
                                Spacer(Modifier.width(6.dp))
                                Text("$year", fontSize = 13.sp, color = TextMuted)
                            }
                            Spacer(Modifier.weight(1f))
                            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = TextFaint, modifier = Modifier.size(16.dp))
                        }
                    }
                }
                itemsIndexed(group.images) { index, image ->
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .aspectRatio(image.aspect.takeIf { it > 0f }?.coerceIn(0.5f, 2f) ?: 1f)
                            .clip(RoundedCornerShape(6.dp))
                            .background(Color(0xFF101219))
                            .clickable { onOpenImage(group, index) },
                    ) {
                        RemoteImage(
                            url = image.url,
                            origin = origin,
                            // 瓦片按实际显示宽取图（列宽 × 屏幕倍率），缩略图条与灯箱共用同一地址
                            widthHint = ImageWidth.pixels(
                                (widthDp - McMetrics.pagePadding.value * 2 - spec.gap * (columns - 1)) / columns,
                                density,
                            ),
                            contentDescription = image.label,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
            }
            if (state.galleryLoadingMore || state.galleryLoading) {
                item(key = "loading-more", span = StaggeredGridItemSpan.FullLine) {
                    Box(Modifier.fillMaxWidth().padding(vertical = 18.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    }
                }
            }
            item(key = "hint", span = StaggeredGridItemSpan.FullLine) {
                Text(
                    "${if (state.total > 0) state.total else state.galleryGroups.size} 部作品的图 · 点心取消收藏",
                    fontSize = 12.sp, color = TextFaint,
                    modifier = Modifier.padding(vertical = 10.dp),
                )
            }
        }
    }
}

/* ══════════ 全部合集（iOS AllCollectionsView） ══════════ */

/** 类型筛选档（iOS kindOptions）：按**所属库的 kind** 分，跨库合集只在「全部」里 */
private val collectionKindOptions = listOf("all" to "全部", "tv" to "剧集", "movie" to "电影")

/** 来源筛选档（iOS sourceOptions）：自建 = 用户创建；自动 = 系列 + 内置收藏 */
private val collectionSourceOptions = listOf("all" to "全部", "user" to "自建", "auto" to "自动")

/**
 * 「全部合集」的数据：合集数组 + 库表（类型筛选要按库的 kind 判）。
 *
 * `/collections` 的 data **是数组**，不是 `{items: [...]}`——早先按 `items` 字段解，
 * 对数组取 `jsonObject` 直接抛异常、被 catch 吞掉，整页因此空白
 * （实机反馈「全部合集里面竟然是空的」）。
 */
@HiltViewModel
class CollectionsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {
    data class Ui(
        val loading: Boolean = true,
        val collections: List<CollectionView> = emptyList(),
        val libraries: List<LibraryView> = emptyList(),
        val failed: Boolean = false,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui = _ui.asStateFlow()
    val origin: String? get() = repository.ui.value.origin
    init { load() }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.value = _ui.value.copy(loading = true, failed = false)
            try {
                val api = apiFactory.forOrigin(origin)
                val cols = api.collections().dataOrThrow()
                val libs = runCatching { api.libraries().dataOrThrow() }.getOrDefault(_ui.value.libraries)
                _ui.value = Ui(loading = false, collections = cols, libraries = libs)
            } catch (_: Exception) {
                _ui.value = _ui.value.copy(loading = false, failed = true)
            }
        }
    }
}

@Composable
fun CollectionsScreen(
    onBack: () -> Unit,
    onOpenCollection: (Long, String) -> Unit,
    vm: CollectionsViewModel = hiltViewModel(),
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    var kindFilter by remember { mutableStateOf("all") }
    var sourceFilter by remember { mutableStateOf("all") }
    val origin = vm.origin

    // 类型按**所属库**的 kind 判；跨库合集没有库，只在「全部」档里出现（iOS matchesKind 同口径）
    val kindOf = remember(ui.libraries) { ui.libraries.associate { it.id to it.kind } }
    fun matchesKind(c: CollectionView, kind: String): Boolean =
        kind == "all" || (c.libraryId?.let { kindOf[it] } == kind)
    fun matchesSource(c: CollectionView, source: String): Boolean =
        source == "all" || (if (source == "user") c.kind == "user" else c.kind != "user")
    // 组内排序：自建 → 内置 → 系列，同档保持服务端给的先后（iOS bySource）
    fun bySource(list: List<CollectionView>): List<CollectionView> =
        list.withIndex().sortedWith(compareBy({ rankOf(it.value.kind) }, { it.index })).map { it.value }

    val all = ui.collections
    val shown = all.filter { matchesKind(it, kindFilter) && matchesSource(it, sourceFilter) }
    val cross = bySource(shown.filter { it.libraryId == null })
    val grouped = ui.libraries
        .map { lib -> lib to bySource(shown.filter { it.libraryId == lib.id }) }
        .filter { it.second.isNotEmpty() }
    val filtered = kindFilter != "all" || sourceFilter != "all"

    Column(Modifier.fillMaxSize().background(Bg)) {
        SubTopBar("全部合集", onBack)
        Text(
            when {
                ui.loading && all.isEmpty() -> "正在读取合集…"
                all.isEmpty() -> "还没有合集"
                filtered -> "${shown.size} / ${all.size} 个合集 · 按库分组"
                else -> "${all.size} 个合集 · 按库分组"
            },
            fontSize = 15.sp, color = TextMuted,
            modifier = Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 8.dp),
        )
        when {
            ui.loading && all.isEmpty() ->
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted)
                }
            all.isEmpty() -> EmptyHint(
                if (ui.failed) "合集读取失败，返回重进再试。"
                else "还没有合集。在某个库里筛出一批片，点「存为合集」就能把这组条件留下来。"
            )
            else -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                // 两组带计数的筛选（计数按 faceted 口径：带上另一个维度当前的筛选）
                Column(Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 6.dp)) {
                    CollectionChipGroup(
                        label = "类型",
                        options = collectionKindOptions,
                        selection = kindFilter,
                        onSelect = { kindFilter = it },
                        count = { value -> all.count { matchesSource(it, sourceFilter) && matchesKind(it, value) } },
                    )
                    Spacer(Modifier.height(8.dp))
                    CollectionChipGroup(
                        label = "来源",
                        options = collectionSourceOptions,
                        selection = sourceFilter,
                        onSelect = { sourceFilter = it },
                        count = { value -> all.count { matchesKind(it, kindFilter) && matchesSource(it, value) } },
                    )
                }
                Spacer(Modifier.height(6.dp))
                if (cross.isNotEmpty()) {
                    CollectionGroupHeader("跨库", "不属于任何一个库的手动名单")
                    CollectionGrid(cross, origin, onOpenCollection)
                }
                grouped.forEach { (lib, items) ->
                    Spacer(Modifier.height(10.dp))
                    CollectionGroupHeader(lib.name, null)
                    CollectionGrid(items, origin, onOpenCollection)
                }
                Spacer(Modifier.height(28.dp))
            }
        }
    }
}

private fun rankOf(kind: String): Int = when (kind) {
    "user" -> 0
    "builtin" -> 1
    else -> 2
}

/** 一行「标签 + 若干带计数胶囊」；计数为 0 且未选中时压暗且点不动（同 iOS「永不空货架」） */
@Composable
private fun CollectionChipGroup(
    label: String,
    options: List<Pair<String, String>>,
    selection: String,
    onSelect: (String) -> Unit,
    count: (String) -> Int,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 12.sp, color = TextFaint, modifier = Modifier.padding(end = 6.dp))
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            options.forEach { (value, title) ->
                val n = count(value)
                val on = selection == value
                val usable = n > 0 || on
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .height(28.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = if (on) 0.16f else 0.05f))
                        .clickable(enabled = usable) { onSelect(value) }
                        .padding(horizontal = 10.dp),
                ) {
                    Text(
                        title, fontSize = 12.sp,
                        color = if (!usable) Color.White.copy(alpha = 0.3f)
                        else if (on) Color.White else Color.White.copy(alpha = 0.7f),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "$n", fontSize = 11.sp,
                        color = Color.White.copy(alpha = if (!usable) 0.2f else 0.4f),
                    )
                }
            }
        }
    }
}

@Composable
private fun CollectionGroupHeader(title: String, subtitle: String?) {
    Column(Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 6.dp)) {
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
        if (subtitle != null) {
            Text(subtitle, fontSize = 12.sp, color = TextFaint, modifier = Modifier.padding(top = 2.dp))
        }
    }
}

/** 一个分组里的合集卡网格：两列；「我的合集」/「系列」两段小标题只在两段都有时出现 */
@Composable
private fun CollectionGrid(
    collections: List<CollectionView>,
    origin: String?,
    onOpen: (Long, String) -> Unit,
) {
    val mine = collections.filter { it.kind != "series" }
    val series = collections.filter { it.kind == "series" }
    val both = mine.isNotEmpty() && series.isNotEmpty()
    Column(Modifier.padding(horizontal = McMetrics.pagePadding)) {
        if (mine.isNotEmpty()) {
            if (both) CollectionSegmentLabel("我的合集")
            CollectionCells(mine, origin, onOpen)
        }
        if (series.isNotEmpty()) {
            if (both) CollectionSegmentLabel("系列")
            CollectionCells(series, origin, onOpen)
        }
    }
}

@Composable
private fun CollectionSegmentLabel(text: String) {
    Text(
        text, fontSize = 13.sp, color = TextFaint,
        modifier = Modifier.padding(top = 10.dp, bottom = 6.dp),
    )
}

/** 两列网格。合集不多，用 chunked 手排：LazyVerticalGrid 塞不进纵向滚动的 Column（实测坑） */
@Composable
private fun CollectionCells(
    items: List<CollectionView>,
    origin: String?,
    onOpen: (Long, String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        items.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                pair.forEach { c ->
                    Box(Modifier.weight(1f)) { CollectionCell(c, origin) { onOpen(c.id, c.name) } }
                }
                // 单数补一个空位，卡片不会被拉成半宽
                if (pair.size == 1) Box(Modifier.weight(1f))
            }
        }
    }
}

/** 合集卡：最多 3 张海报错开叠放的封面 + 名字 + 「N 部 · 来源 · 私有 · 已隐藏」 */
@Composable
private fun CollectionCell(c: CollectionView, origin: String?, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick).alpha(if (c.hidden) 0.45f else 1f)) {
        CollectionCoverStack(c.covers, origin)
        Text(
            c.name,
            fontSize = 15.sp, fontWeight = FontWeight.Medium, color = TextPrimary,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp),
        )
        Text(
            listOfNotNull(
                "${c.itemCount} 部",
                if (c.kind == "series") "系列" else if (c.ruleDriven) "自动收录" else null,
                if (c.visibility == "private") "只有我" else null,
                if (c.hidden) "已隐藏" else null,
            ).joinToString(" · "),
            fontSize = 13.sp, color = TextFaint,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 2.dp),
        )
    }
}

/** 封面：最多 3 张海报依次向右错开叠放，后面的压暗（数值照 iOS LibraryCollectionCover） */
@Composable
internal fun CollectionCoverStack(covers: List<CollectionCover>, origin: String?) {
    Box(
        Modifier
            .fillMaxWidth()
            .aspectRatio(2f / 3f)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .border(1.dp, LineSoft, RoundedCornerShape(12.dp)),
    ) {
        val shown = covers.take(3)
        if (shown.isEmpty()) {
            Text(
                "暂无封面", fontSize = 13.sp, color = TextFaint,
                modifier = Modifier.align(Alignment.Center),
            )
        } else {
            androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
                val w = maxWidth
                val h = maxHeight
                val step = w * 0.07f
                val inset = h * 0.025f
                val frontWidth = w - step * (shown.size - 1)
                // 倒着画：下标 0 在最前
                shown.indices.reversed().forEach { index ->
                    Box(
                        Modifier
                            .offset(x = step * index, y = inset * index)
                            .width(frontWidth)
                            .height(h - inset * index * 2)
                            .clip(RoundedCornerShape(12.dp)),
                    ) {
                        RemoteImage(
                            url = shown[index].url,
                            origin = origin,
                            modifier = Modifier.fillMaxSize(),
                            contentDescription = null,
                        )
                        if (index > 0) {
                            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.3f)))
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun SubTopBar(
    title: String,
    onBack: () -> Unit,
    actions: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = {},
) {
    io.movieclaw.android.core.designsystem.McTopBar(
        variant = io.movieclaw.android.core.designsystem.McTopBarVariant.Sub,
        title = title,
        actions = actions,
        onBack = onBack,
    )
}

@Composable
private fun EmptyHint(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, fontSize = 15.sp, color = TextMuted, modifier = Modifier.padding(horizontal = 40.dp), lineHeight = 22.sp)
    }
}

/* ══════════ 媒体库管理（iOS `LibraryManageView`：页头摘要 + 四页签 + 一库一行） ══════════ */

/**
 * 管理页要回答的第一个问题是「有没有事要我管」：页头摘要只挂两枚带色胶囊——
 * 在跑任务 / 有待处理文件，点即筛选；两样都没有就写「一切正常」。
 * 数据全部来自 `GET /libraries`（随库下发的状态与统计快照已经够用，不用另开接口）。
 */
data class ManageState(
    val loading: Boolean = true,
    val error: String? = null,
    val tab: Int = 0,
    val libraries: List<io.movieclaw.android.core.model.LibraryView> = emptyList(),
    /** 只看在跑任务的库（摘要胶囊的筛选态） */
    val focusBusy: Boolean = false,
    /** 只看有待处理文件的库 */
    val focusAttention: Boolean = false,
    val trashed: List<Triple<String, String, String>> = emptyList(),   // 文件名 / 库名 / 原因
    val duplicates: List<Pair<String, Int>> = emptyList(),             // 标题 / 重复数
    val busy: Boolean = false,
    val notice: String? = null,
) {
    /** 一个库在跑任务：扫描 / 整理 / 元数据刷新 / 生成章节任一在跑 */
    fun libraryBusy(lib: io.movieclaw.android.core.model.LibraryView): Boolean =
        lib.scanning || lib.organizing || lib.metadataRefresh != null || lib.chapterJob != null

    val busyCount: Int get() = libraries.count { libraryBusy(it) }
    val attentionCount: Int get() = libraries.count { it.stats.missingCount > 0 }
    val facts: String
        get() {
            val movies = libraries.filter { it.kind == "movie" }
            val tvs = libraries.filter { it.kind == "tv" }
            val others = libraries.filter { it.kind != "movie" && it.kind != "tv" }
            val size = libraries.sumOf { it.stats.totalSizeBytes }
            return buildString {
                append("${libraries.size} 个媒体库")
                if (movies.isNotEmpty()) append(" · ${movies.sumOf { it.stats.itemCount }} 部电影")
                if (tvs.isNotEmpty()) append(" · ${tvs.sumOf { it.stats.itemCount }} 部剧集")
                if (others.isNotEmpty()) append(" · ${others.sumOf { it.stats.itemCount }} 个其他条目")
                if (size > 0) append(" · ").append(formatBytesLocal(size))
            }
        }
}

@HiltViewModel
class LibraryManageViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {
    private val _ui = MutableStateFlow(ManageState())
    val ui = _ui.asStateFlow()
    val origin: String? get() = repository.ui.value.origin
    init { load() }

    fun setTab(i: Int) {
        _ui.update { it.copy(tab = i) }
        if (i == 1 && _ui.value.trashed.isEmpty()) loadTrash()
        if (i == 2) loadDuplicates()
    }

    fun toggleFocusBusy() = _ui.update {
        it.copy(focusBusy = !it.focusBusy, focusAttention = false)
    }

    fun toggleFocusAttention() = _ui.update {
        it.copy(focusAttention = !it.focusAttention, focusBusy = false)
    }

    fun consumeNotice() = _ui.update { it.copy(notice = null) }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            try {
                // scope=all：超管连同自己摘出浏览范围的库一起列（管理页要管的就是全部）
                val libs = apiFactory.forOrigin(origin).libraries().dataOrThrow()
                _ui.update { it.copy(loading = false, error = null, libraries = libs) }
            } catch (e: Exception) {
                _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
            }
        }
    }

    /** 一库一行的动作：每个都打完接口再重拉列表（状态列立刻跟上） */
    private fun act(block: suspend (io.movieclaw.android.core.api.McApi) -> String) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            try {
                val msg = block(apiFactory.forOrigin(origin))
                _ui.update { it.copy(notice = msg) }
                load()
            } catch (e: Exception) {
                _ui.update { it.copy(notice = friendlyMessage(e)) }
            }
        }
    }

    fun toggleScan(lib: io.movieclaw.android.core.model.LibraryView) = act { api ->
        if (lib.scanning) {
            api.stopLibraryScan(lib.id)
            "已请求停止扫描「${lib.name}」"
        } else {
            api.scanLibrary(lib.id)
            "已开始扫描「${lib.name}」"
        }
    }

    fun toggleMetadataRefresh(lib: io.movieclaw.android.core.model.LibraryView) = act { api ->
        if (lib.metadataRefresh != null) {
            api.stopLibraryMetadataRefresh(lib.id)
            "已请求停止刷新「${lib.name}」"
        } else {
            api.refreshLibraryMetadata(lib.id)
            "已开始刷新「${lib.name}」的元数据"
        }
    }

    fun organize(lib: io.movieclaw.android.core.model.LibraryView) = act { api ->
        api.organizeLibrary(lib.id)
        "已开始整理「${lib.name}」的文件名"
    }

    /** 生成章节：force = 已有的也重新生成（入口先用一次确认弹窗问清楚） */
    fun generateChapters(lib: io.movieclaw.android.core.model.LibraryView, force: Boolean) = act { api ->
        api.generateLibraryChapters(lib.id, force)
        if (force) "已开始重新生成「${lib.name}」的全部章节" else "已开始生成「${lib.name}」的章节"
    }

    fun setDefault(lib: io.movieclaw.android.core.model.LibraryView) = act { api ->
        api.setDefaultLibrary(lib.id)
        "已把「${lib.name}」设为默认库"
    }

    fun toggleHome(lib: io.movieclaw.android.core.model.LibraryView) = act { api ->
        api.updateSubscription(
            lib.id,
            kotlinx.serialization.json.buildJsonObject { },
        )
        if (lib.excludeFromHome) "已让「${lib.name}」回到首页" else "已把「${lib.name}」从首页移除"
    }

    fun delete(lib: io.movieclaw.android.core.model.LibraryView) = act { api ->
        api.deleteLibrary(lib.id)
        "已删除媒体库「${lib.name}」（磁盘文件未动）"
    }

    /** 调整顺序：面板里上下挪好、确认后整单提交（服务端要求给全所有 id） */
    fun commitOrder(ordered: List<Long>) = act { api ->
        api.reorderLibraries(
            kotlinx.serialization.json.buildJsonObject {
                put(
                    "ordered_ids",
                    kotlinx.serialization.json.JsonArray(ordered.map { kotlinx.serialization.json.JsonPrimitive(it) }),
                )
            },
        )
        "已更新媒体库顺序"
    }

    private fun loadTrash() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            try {
                val raw = apiFactory.forOrigin(origin).trashedFiles().dataOrThrow()
                val arr = raw.jsonObject["items"]?.jsonArray ?: (raw as? kotlinx.serialization.json.JsonArray) ?: return@launch
                val rows = arr.map { el ->
                    val o = el.jsonObject
                    Triple(
                        o["file_name"]?.jsonPrimitive?.contentOrNull ?: o["path"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        o["library_name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        o["reason"]?.jsonPrimitive?.contentOrNull ?: "手动删除",
                    )
                }
                _ui.update { it.copy(trashed = rows) }
            } catch (_: Exception) { }
        }
    }

    private fun loadDuplicates() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(busy = true) }
            try {
                val raw = apiFactory.forOrigin(origin).duplicateFiles().dataOrThrow()
                val arr = raw.jsonObject["groups"]?.jsonArray ?: (raw as? kotlinx.serialization.json.JsonArray) ?: return@launch
                val rows = arr.mapNotNull { el ->
                    val o = el.jsonObject
                    val title = o["title"]?.jsonPrimitive?.contentOrNull ?: o["media_title"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                    title to (o["files"]?.jsonArray?.size ?: o["file_count"]?.jsonPrimitive?.intOrNull ?: 0)
                }
                _ui.update { it.copy(duplicates = rows, busy = false) }
            } catch (_: Exception) { _ui.update { it.copy(busy = false) } }
        }
    }

    fun scanDuplicates() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(busy = true) }
            runCatching { apiFactory.forOrigin(origin).scanDuplicates() }
            loadDuplicates()
        }
    }
}

@Composable
fun LibraryManageScreen(
    onBack: () -> Unit,
    onOpenLibrary: (Long, String) -> Unit,
    /** 创建（"create"）/ 编辑（"edit:<id>"）→ 原生媒体库表单 */
    onOpenForm: (Long?) -> Unit = {},
    /** 进页时预选的页签（详情页文件区「处理重复」= 2 重复文件；null = 默认第一页） */
    initialTab: Int? = null,
    vm: LibraryManageViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val feedback = io.movieclaw.android.core.designsystem.LocalFeedback.current
    var deleteTarget by remember { mutableStateOf<io.movieclaw.android.core.model.LibraryView?>(null) }
    var chaptersTarget by remember { mutableStateOf<io.movieclaw.android.core.model.LibraryView?>(null) }
    var reordering by remember { mutableStateOf(false) }

    // 带页签进来（详情页文件区「处理重复」）：只落一次，进来之后由用户点
    LaunchedEffect(initialTab) { if (initialTab != null) vm.setTab(initialTab) }

    LaunchedEffect(state.notice) {
        state.notice?.let {
            feedback.show(io.movieclaw.android.core.designsystem.McNotice(it))
            vm.consumeNotice()
        }
    }

    Column(Modifier.fillMaxSize().background(Bg)) {
        // 标题只在顶栏（与「我的收藏 / 全部合集」同一规矩，页内不再重复一遍）；
        // 「＋ 创建媒体库」放到顶栏右侧（iOS 把它摆在大标题那一行的右边）
        SubTopBar("媒体库管理", onBack) {
            Box(
                Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))))
                    .clickable { onOpenForm(null) }
                    .padding(horizontal = 12.dp, vertical = 7.dp),
            ) {
                Text("＋ 创建媒体库", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF141821))
            }
        }
        LazyColumn(
            contentPadding = PaddingValues(bottom = 24.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            // ── 页头：活的摘要（规模事实 + 在跑任务 / 待处理两枚胶囊）──
            item(key = "manage-head") {
                Column(Modifier.padding(horizontal = McMetrics.pagePadding)) {
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(state.facts, fontSize = 13.sp, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        if (state.busyCount > 0) {
                            ManageCapsule(
                                dot = Info,
                                text = "${state.busyCount} 个在跑任务",
                                active = state.focusBusy,
                                onClick = vm::toggleFocusBusy,
                            )
                        }
                        if (state.attentionCount > 0) {
                            ManageCapsule(
                                dot = Danger,
                                text = "${state.attentionCount} 个库有待处理文件",
                                active = state.focusAttention,
                                onClick = vm::toggleFocusAttention,
                            )
                        }
                        if (!state.loading && state.busyCount == 0 && state.attentionCount == 0) {
                            Text("一切正常", fontSize = 13.sp, color = TextFaint)
                        }
                    }
                }
            }

            // ── 四页签（计数为 0 时页签照常渲染，只是不带数字） ──
            item(key = "manage-tabs") {
                Row(
                    Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 14.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    val tabs = listOf(
                        "媒体库" to state.libraries.size,
                        "回收站" to state.trashed.size,
                        "重复文件" to state.duplicates.size,
                        "分享" to 0,
                    )
                    tabs.forEachIndexed { i, (label, count) ->
                        val on = state.tab == i
                        Row(
                            Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .background(if (on) Color.White.copy(alpha = 0.14f) else Color.Transparent)
                                .clickable { vm.setTab(i) }
                                .padding(horizontal = 14.dp, vertical = 7.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(label, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = if (on) Color.White else TextMuted)
                            if (count > 0) {
                                Spacer(Modifier.width(6.dp))
                                Text("$count", fontSize = 14.sp, color = if (on) Color.White.copy(alpha = 0.7f) else TextFaint)
                            }
                        }
                    }
                }
            }

            when (state.tab) {
                0 -> {
                    val rows = state.libraries.filter { lib ->
                        when {
                            state.focusBusy -> state.libraryBusy(lib)
                            state.focusAttention -> lib.stats.missingCount > 0
                            else -> true
                        }
                    }
                    item(key = "manage-error") {
                        state.error?.let { error ->
                            Text(error, fontSize = 13.sp, color = Danger, modifier = Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 4.dp))
                        }
                    }
                    if (!state.loading && rows.isEmpty()) {
                        item(key = "manage-empty") {
                            Column(
                                Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 56.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(
                                    if (state.libraries.isEmpty()) "为收藏准备一个家" else "这些库都清闲着",
                                    fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary,
                                )
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    if (state.libraries.isEmpty()) "创建电影库或剧集库，选好根目录后，订阅完成的内容会自动整理到这里。"
                                    else "取消上方胶囊的筛选就能看到全部媒体库。",
                                    fontSize = 13.sp, color = TextMuted, lineHeight = 19.sp,
                                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                                )
                                if (state.libraries.isEmpty()) {
                                    Spacer(Modifier.height(16.dp))
                                    Box(
                                        Modifier
                                            .clip(RoundedCornerShape(999.dp))
                                            .background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))))
                                            .clickable { onOpenForm(null) }
                                            .padding(horizontal = 18.dp, vertical = 9.dp),
                                    ) { Text("创建第一个媒体库", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF141821)) }
                                }
                            }
                        }
                    }
                    items(rows, key = { "manage-lib-${it.id}" }) { lib ->
                        ManageLibraryRow(
                            library = lib,
                            origin = vm.origin,
                            busy = state.libraryBusy(lib),
                            onOpen = { onOpenLibrary(lib.id, lib.name) },
                            onScan = { vm.toggleScan(lib) },
                            onMetadata = { vm.toggleMetadataRefresh(lib) },
                            onOrganize = { vm.organize(lib) },
                            onChapters = { chaptersTarget = lib },
                            onEdit = { onOpenForm(lib.id) },
                            onSetDefault = { vm.setDefault(lib) },
                            onToggleHome = { vm.toggleHome(lib) },
                            onReorder = { reordering = true },
                            onDelete = { deleteTarget = lib },
                        )
                    }
                }
                1 -> {
                    if (state.trashed.isEmpty()) {
                        item { EmptyHint("回收站是空的") }
                    }
                    items(state.trashed) { (name, lib, reason) ->
                        Column(
                            Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding, vertical = 6.dp)
                                .clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.05f)).padding(12.dp),
                        ) {
                            Text(name, fontSize = 14.sp, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("$lib · $reason", fontSize = 12.sp, color = TextFaint, modifier = Modifier.padding(top = 2.dp))
                        }
                    }
                }
                2 -> {
                    item(key = "dup-head") {
                        Row(Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                if (state.busy) "扫描中…" else "一共 ${state.duplicates.size} 个单元有重复",
                                fontSize = 15.sp, color = TextMuted,
                            )
                            Spacer(Modifier.weight(1f))
                            Text("重新扫描", fontSize = 14.sp, color = TextPrimary, modifier = Modifier.clickable { vm.scanDuplicates() })
                        }
                    }
                    items(state.duplicates) { (title, n) ->
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(title, fontSize = 15.sp, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Text("$n 个文件", fontSize = 13.sp, color = TextFaint)
                        }
                    }
                }
                else -> item { EmptyHint("分享管理只在管理员网页端提供") }
            }
        }
    }

    // 生成章节：问清楚要不要连已有的也重做（同 iOS 的系统 alert）
    chaptersTarget?.let { lib ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { chaptersTarget = null },
            containerColor = Color(0xFF1E212B),
            title = { Text("为「${lib.name}」生成章节？", color = TextPrimary, fontSize = 16.sp) },
            text = {
                Text(
                    "按人物出现与场景切换抓取场景图，耗时随片数增长；已有的章节会保留。",
                    color = TextMuted, fontSize = 14.sp, lineHeight = 20.sp,
                )
            },
            confirmButton = {
                TextButton(onClick = { vm.generateChapters(lib, false); chaptersTarget = null }) {
                    Text("开始生成", color = Accent)
                }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = { vm.generateChapters(lib, true); chaptersTarget = null }) {
                        Text("已有的也重生成", color = TextMuted)
                    }
                    TextButton(onClick = { chaptersTarget = null }) { Text("取消", color = TextMuted) }
                }
            },
        )
    }

    // 删除：不可逆（不动磁盘文件，但订阅回落到默认库）
    deleteTarget?.let { lib ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { deleteTarget = null },
            containerColor = Color(0xFF1E212B),
            title = { Text("删除媒体库「${lib.name}」？", color = TextPrimary, fontSize = 16.sp) },
            text = {
                Text(
                    "只删这个库的配置与台账，磁盘上的文件不动；它的订阅会回落到同类型的默认库。扫描或整理进行中时不能删。",
                    color = TextMuted, fontSize = 14.sp, lineHeight = 20.sp,
                )
            },
            confirmButton = {
                TextButton(onClick = { vm.delete(lib); deleteTarget = null }) { Text("删除", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("取消", color = TextMuted) } },
        )
    }

    // 调整顺序：上下按钮面板，确认后整单提交（手机上没有拖拽）
    if (reordering) {
        ManageReorderSheet(
            libraries = state.libraries,
            onConfirm = { vm.commitOrder(it); reordering = false },
            onDismiss = { reordering = false },
        )
    }
}

/** 页头摘要里的带色胶囊（在跑任务 / 待处理文件）：点即筛选 */
@Composable
private fun ManageCapsule(dot: Color, text: String, active: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(if (active) Color.White.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.05f))
            .border(1.dp, if (active) Color.Transparent else LineSoft, RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).clip(RoundedCornerShape(999.dp)).background(dot))
        Spacer(Modifier.width(6.dp))
        Text(text, fontSize = 12.sp, color = if (active) Color.White else TextMuted)
    }
}

/**
 * 一库一行（iOS `ManageLibraryRow` 的手机卡片形态）：一行只有两个视觉重心——
 * 库名与状态（有事才带色）；类型 / 库存 / 配置备注是库名下的小字；根目录独占一整行。
 * 行内不放独立按钮，操作全收进右上 ⋯；唯一例外是「待识别 / 缺失」胶囊本身可点。
 */
@Composable
private fun ManageLibraryRow(
    library: io.movieclaw.android.core.model.LibraryView,
    origin: String?,
    busy: Boolean,
    onOpen: () -> Unit,
    onScan: () -> Unit,
    onMetadata: () -> Unit,
    onOrganize: () -> Unit,
    onChapters: () -> Unit,
    onEdit: () -> Unit,
    onSetDefault: () -> Unit,
    onToggleHome: () -> Unit,
    onReorder: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = McMetrics.pagePadding, vertical = 6.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF1E212B).copy(alpha = 0.74f))
            .border(1.dp, LineSoft, RoundedCornerShape(16.dp))
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // 库封面（服务端合成的氛围光货架，与首页卡片同一张）
            Box(Modifier.width(46.dp).height(46.dp).clip(RoundedCornerShape(10.dp)).background(Color.White.copy(alpha = 0.06f))) {
                RemoteImage(
                    url = origin?.trimEnd('/')?.let { "$it/api/v1/libraries/${library.id}/cover" },
                    origin = origin,
                    contentDescription = library.name,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        library.name,
                        fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.clickable(onClick = onOpen),
                    )
                    if (library.isDefault) {
                        Spacer(Modifier.width(6.dp))
                        ManageBadge("默认")
                    }
                    if (library.accessMode == "selected") {
                        Spacer(Modifier.width(6.dp))
                        ManageBadge(if (library.viewerAccess) "指定成员" else "仅管理", locked = !library.viewerAccess)
                    }
                }
                Text(
                    buildString {
                        append(if (library.kind == "tv") "剧集" else if (library.kind == "movie") "电影" else "其他")
                        append(" · ")
                        if (library.kind == "photo") append("${library.stats.fileCount} 张") else append("${library.stats.itemCount} 个条目")
                        append(" · ${library.stats.fileCount} 个文件")
                        if (library.stats.unidentifiedCount > 0) append(" · ${library.stats.unidentifiedCount} 个待识别")
                        if (library.networkMount) append(" · 网络挂载")
                        if (library.excludeFromHome) append(" · 不在首页")
                    },
                    fontSize = 12.sp, color = TextFaint, maxLines = 2,
                    modifier = Modifier.padding(top = 3.dp),
                )
            }
            Spacer(Modifier.width(6.dp))
            // 状态列：有事才带色（在跑任务 / 缺失）。点缺失胶囊 → 交给网页端的待处理清单
            when {
                library.scanning -> ManageStatus("扫描中", Info)
                library.organizing -> ManageStatus("整理中", Info)
                library.metadataRefresh != null -> ManageStatus("刷新元数据", Info)
                library.chapterJob != null -> ManageStatus("生成章节", Info)
                library.stats.missingCount > 0 -> ManageStatus("缺 ${library.stats.missingCount} 个", Danger)
                else -> Unit
            }
            Spacer(Modifier.width(6.dp))
            Box {
                Icon(
                    Icons.Rounded.MoreHoriz,
                    contentDescription = "更多操作",
                    tint = TextMuted,
                    modifier = Modifier.size(28.dp).clip(RoundedCornerShape(999.dp)).clickable { menu = true }.padding(5.dp),
                )
                androidx.compose.material3.DropdownMenu(
                    expanded = menu,
                    onDismissRequest = { menu = false },
                    containerColor = Color(0xFF1E212B),
                ) {
                    ManageMenuItem(if (library.scanning) "停止扫描" else "开始扫描") { menu = false; onScan() }
                    ManageMenuItem(if (library.metadataRefresh != null) "取消刷新元数据" else "刷新元数据") { menu = false; onMetadata() }
                    ManageMenuItem("整理文件") { menu = false; onOrganize() }
                    ManageMenuItem("生成章节") { menu = false; onChapters() }
                    ManageMenuItem("编辑媒体库…") { menu = false; onEdit() }
                    if (!library.isDefault) ManageMenuItem("设为默认") { menu = false; onSetDefault() }
                    ManageMenuItem(if (library.excludeFromHome) "显示在首页" else "从首页移除") { menu = false; onToggleHome() }
                    ManageMenuItem("调整顺序…") { menu = false; onReorder() }
                    Box(Modifier.fillMaxWidth().height(1.dp).background(LineSoft))
                    ManageMenuItem("删除媒体库", danger = true) { menu = false; onDelete() }
                }
            }
        }
        // 根目录独占一整行（拿到整个宽度，不必早早截尾）
        Text(
            library.primaryRoot ?: library.rootPaths.firstOrNull().orEmpty(),
            fontSize = 12.sp, color = TextFaint, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp),
        )
        if (busy && library.scanning) {
            Spacer(Modifier.height(6.dp))
            io.movieclaw.android.core.designsystem.ProgressBar(fraction = 0f, tint = Info)
        }
    }
}

@Composable
private fun ManageBadge(text: String, locked: Boolean = false) {
    Text(
        text,
        fontSize = 11.sp,
        color = if (locked) Warning else TextMuted,
        modifier = Modifier
            .clip(RoundedCornerShape(5.dp))
            .border(1.dp, LineSoft, RoundedCornerShape(5.dp))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    )
}

@Composable
private fun ManageStatus(text: String, tint: Color) {
    Text(
        text,
        fontSize = 12.sp,
        color = tint,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(tint.copy(alpha = 0.12f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

@Composable
private fun ManageMenuItem(text: String, danger: Boolean = false, onClick: () -> Unit) {
    androidx.compose.material3.DropdownMenuItem(
        text = { Text(text, fontSize = 14.sp, color = if (danger) Danger else TextPrimary) },
        onClick = onClick,
    )
}

/** 调整顺序面板：上下按钮挪位，确认后整单提交（服务端要求给全所有 id） */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun ManageReorderSheet(
    libraries: List<io.movieclaw.android.core.model.LibraryView>,
    onConfirm: (List<Long>) -> Unit,
    onDismiss: () -> Unit,
) {
    var order by remember { mutableStateOf(libraries.map { it.id }) }
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text("调整媒体库顺序", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text("越靠前展示越靠前；这决定首页卡片与「最近添加」分区的排列。", fontSize = 12.sp, color = TextFaint)
            Spacer(Modifier.height(12.dp))
            order.forEachIndexed { index, id ->
                val lib = libraries.firstOrNull { it.id == id }
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(lib?.name ?: "#$id", fontSize = 14.sp, color = TextPrimary, modifier = Modifier.weight(1f))
                    Icon(
                        Icons.Rounded.KeyboardArrowUp,
                        contentDescription = "上移",
                        tint = if (index == 0) TextFaint else TextMuted,
                        modifier = Modifier.size(28.dp)
                            .clip(RoundedCornerShape(999.dp))
                            .clickable(enabled = index > 0) {
                                order = order.toMutableList().also { it.add(index - 1, it.removeAt(index)) }
                            }
                            .padding(4.dp),
                    )
                    Icon(
                        Icons.Rounded.KeyboardArrowDown,
                        contentDescription = "下移",
                        tint = if (index == order.lastIndex) TextFaint else TextMuted,
                        modifier = Modifier.size(28.dp)
                            .clip(RoundedCornerShape(999.dp))
                            .clickable(enabled = index < order.lastIndex) {
                                order = order.toMutableList().also { it.add(index + 1, it.removeAt(index)) }
                            }
                            .padding(4.dp),
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    Modifier.weight(1f).height(42.dp).clip(RoundedCornerShape(999.dp))
                        .background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))))
                        .clickable { onConfirm(order) },
                    contentAlignment = Alignment.Center,
                ) { Text("保存顺序", fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF141821)) }
                Box(
                    Modifier.width(110.dp).height(42.dp).clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.1f))
                        .clickable(onClick = onDismiss),
                    contentAlignment = Alignment.Center,
                ) { Text("取消", fontSize = 14.5.sp, color = TextPrimary) }
            }
        }
    }
}

private fun formatBytesLocal(bytes: Long): String {
    if (bytes <= 0) return "0 B"
    val units = listOf("B", "KB", "MB", "GB", "TB")
    var v = bytes.toDouble(); var i = 0
    while (v >= 1024 && i < units.lastIndex) { v /= 1024; i++ }
    return if (i == 0) "${bytes} B" else "%.2f %s".format(v, units[i])
}
