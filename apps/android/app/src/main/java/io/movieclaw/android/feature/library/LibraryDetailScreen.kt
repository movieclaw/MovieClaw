package io.movieclaw.android.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.Sort
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.FeedbackBus
import io.movieclaw.android.core.designsystem.FeedbackTone
import io.movieclaw.android.core.designsystem.GridSkeleton
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.McNotice
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.LibraryItemCard
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.SurfaceRaised
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.FacetValue
import io.movieclaw.android.core.model.LibraryFacets
import io.movieclaw.android.core.model.LibraryFilter
import io.movieclaw.android.core.model.LibraryIndexEntry
import io.movieclaw.android.core.model.LibraryItemView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

private const val PAGE_SIZE = 60

@HiltViewModel
class LibraryDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    val libraryId: Long = savedStateHandle.get<String>("libraryId")?.toLongOrNull() ?: -1L

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val items: List<LibraryItemView> = emptyList(),
        val filter: LibraryFilter = LibraryFilter(),
        val loadingMore: Boolean = false,
        val hasMore: Boolean = true,
        /** 当前窗口起点(索引跳转会重设窗口,所以不能假设从 0 开始) */
        val windowStart: Int = 0,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    private val _facets = MutableStateFlow<Loadable<LibraryFacets>>(Loadable.Loading)
    val facets = _facets.asStateFlow()

    private val _index = MutableStateFlow<List<LibraryIndexEntry>>(emptyList())
    val index = _index.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    init {
        reload()
    }

    fun consumeNotice() = _ui.update { it.copy(error = null) }

    fun reload() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null, windowStart = 0) }
            runCatching { apiFactory.forOrigin(origin).libraryPage(libraryId, 0, _ui.value.filter) }
                .onSuccess { items ->
                    _ui.update {
                        it.copy(
                            loading = false,
                            items = items,
                            hasMore = items.size >= PAGE_SIZE,
                        )
                    }
                }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
            loadIndex()
        }
    }

    fun loadMore() {
        val state = _ui.value
        if (state.loadingMore || !state.hasMore || state.loading) return
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loadingMore = true) }
            val nextOffset = state.windowStart + state.items.size
            runCatching { apiFactory.forOrigin(origin).libraryPage(libraryId, nextOffset, state.filter) }
                .onSuccess { more ->
                    _ui.update {
                        it.copy(
                            loadingMore = false,
                            items = it.items + more,
                            hasMore = more.size >= PAGE_SIZE,
                        )
                    }
                }
                .onFailure { _ui.update { it.copy(loadingMore = false) } }
        }
    }

    /** 应用筛选:重新拉第一页 + 刷新索引 */
    fun applyFilter(filter: LibraryFilter) {
        _ui.update { it.copy(filter = filter) }
        reload()
    }

    fun clearFilter() = applyFilter(_ui.value.filter.cleared())

    fun setSort(sort: String, order: String?) = applyFilter(_ui.value.filter.copy(sort = sort, order = order))

    /**
     * 取候选值与计数。**要按面板里的草稿条件取**,否则勾选后计数不更新;
     * 服务端算某一维时会排除该维自身的条件(所以多选不会互相清零)。
     */
    fun loadFacets(filter: LibraryFilter = _ui.value.filter, showLoading: Boolean = true) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            if (showLoading && _facets.value !is Loadable.Ready) _facets.value = Loadable.Loading
            runCatching { apiFactory.forOrigin(origin).libraryFacets(libraryId, filter) }
                .onSuccess { view -> _facets.value = Loadable.Ready(view) }
                .onFailure { e ->
                    if (_facets.value !is Loadable.Ready) _facets.value = Loadable.Failed(friendlyMessage(e))
                }
        }
    }

    private suspend fun loadIndex() {
        val origin = origin ?: return
        val filter = _ui.value.filter
        if (filter.sort != "title") {
            _index.value = emptyList()
            return
        }
        runCatching { apiFactory.forOrigin(origin).libraryItemIndex(libraryId, filter) }
            .onSuccess { entries -> _index.value = entries }
            .onFailure { _index.value = emptyList() }
    }

    /** 跳转到首字母档:以该档 offset 为窗口起点重取一页(offset 与排序口径由服务端保证一致) */
    fun jumpTo(entry: LibraryIndexEntry) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, windowStart = entry.offset) }
            runCatching { apiFactory.forOrigin(origin).libraryPage(libraryId, entry.offset, _ui.value.filter) }
                .onSuccess { items ->
                    _ui.update {
                        it.copy(
                            loading = false,
                            items = items,
                            hasMore = items.size >= PAGE_SIZE,
                        )
                    }
                }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
        }
    }
}

private suspend fun io.movieclaw.android.core.api.McApi.libraryPage(
    libraryId: Long,
    offset: Int,
    filter: LibraryFilter,
) = libraryItems(
    libraryId = libraryId,
    limit = PAGE_SIZE,
    offset = offset,
    sort = filter.sort,
    order = filter.order,
    genres = filter.genres.takeIf { it.isNotEmpty() }?.joinToString(","),
    countries = filter.countries.takeIf { it.isNotEmpty() }?.joinToString(","),
    decades = filter.decades.takeIf { it.isNotEmpty() }?.joinToString(","),
    watch = filter.watch.takeIf { it.isNotEmpty() }?.joinToString(","),
    ratingGte = filter.ratingGte,
    runtimes = filter.runtimes.takeIf { it.isNotEmpty() }?.joinToString(","),
    languages = filter.languages.takeIf { it.isNotEmpty() }?.joinToString(","),
    resolutions = filter.resolutions.takeIf { it.isNotEmpty() }?.joinToString(","),
    hdr = filter.hdr,
    stock = filter.stock.takeIf { it.isNotEmpty() }?.joinToString(","),
).dataOrThrow()

private suspend fun io.movieclaw.android.core.api.McApi.libraryFacets(
    libraryId: Long,
    filter: LibraryFilter,
) = libraryFacets(
    libraryId = libraryId,
    sort = filter.sort,
    order = filter.order,
    genres = filter.genres.takeIf { it.isNotEmpty() }?.joinToString(","),
    countries = filter.countries.takeIf { it.isNotEmpty() }?.joinToString(","),
    decades = filter.decades.takeIf { it.isNotEmpty() }?.joinToString(","),
    watch = filter.watch.takeIf { it.isNotEmpty() }?.joinToString(","),
    ratingGte = filter.ratingGte,
    runtimes = filter.runtimes.takeIf { it.isNotEmpty() }?.joinToString(","),
    languages = filter.languages.takeIf { it.isNotEmpty() }?.joinToString(","),
    resolutions = filter.resolutions.takeIf { it.isNotEmpty() }?.joinToString(","),
    hdr = filter.hdr,
    stock = filter.stock.takeIf { it.isNotEmpty() }?.joinToString(","),
).dataOrThrow()

private suspend fun io.movieclaw.android.core.api.McApi.libraryItemIndex(
    libraryId: Long,
    filter: LibraryFilter,
) = libraryItemIndex(
    libraryId = libraryId,
    sort = filter.sort,
    order = filter.order,
    genres = filter.genres.takeIf { it.isNotEmpty() }?.joinToString(","),
    countries = filter.countries.takeIf { it.isNotEmpty() }?.joinToString(","),
    decades = filter.decades.takeIf { it.isNotEmpty() }?.joinToString(","),
    watch = filter.watch.takeIf { it.isNotEmpty() }?.joinToString(","),
    ratingGte = filter.ratingGte,
    runtimes = filter.runtimes.takeIf { it.isNotEmpty() }?.joinToString(","),
    languages = filter.languages.takeIf { it.isNotEmpty() }?.joinToString(","),
    resolutions = filter.resolutions.takeIf { it.isNotEmpty() }?.joinToString(","),
    hdr = filter.hdr,
    stock = filter.stock.takeIf { it.isNotEmpty() }?.joinToString(","),
).dataOrThrow()

/* ---------------- UI ---------------- */

/** 库详情:海报墙 + 排序 + 筛选面板 + A–Z 索引条 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryDetailScreen(
    libraryId: Long,
    title: String,
    onBack: () -> Unit,
    onOpenItem: (Long, Long) -> Unit,
    vm: LibraryDetailViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val facets by vm.facets.collectAsStateWithLifecycle()
    val index by vm.index.collectAsStateWithLifecycle()
    val origin = vm.origin
    var showFilter by remember { mutableStateOf(false) }
    val gridState = rememberLazyGridState()
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    LaunchedEffect(gridState, state.items.size) {
        androidx.compose.runtime.snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collect { last ->
                val total = gridState.layoutInfo.totalItemsCount
                if (total > 0 && last >= total - 8) vm.loadMore()
            }
    }

    Box(Modifier.fillMaxSize().background(Bg)) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(top = McMetrics.topBarHeight),
        ) {
            // 库头（实测：名字 20/700 + 「默认」标签 13/600 白12% 底 + 一行统计 14/62%）
            Column(Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 14.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(title, style = McType.title3, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "默认",
                        style = McType.captionSemibold,
                        color = TextPrimary.copy(alpha = 0.9f),
                        modifier = Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .background(Color.White.copy(alpha = 0.12f))
                            .padding(horizontal = 10.dp, vertical = 2.dp),
                    )
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    buildString {
                        append("共 ${state.items.size} 部作品")
                        if (!state.filter.isEmpty()) append(" · 已筛选")
                    },
                    style = McType.sub,
                    color = TextMuted,
                )
            }

            // 筛选 / 排序行（实测：「筛选」76×32 圆角 14 白 4%；「按标题 ⌄」13/600）
            Row(
                Modifier.padding(horizontal = McMetrics.pagePadding).padding(bottom = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                FilterButton(activeCount = state.filter.activeCount) { vm.loadFacets(); showFilter = true }
                SortMenu(current = state.filter) { sort, order -> vm.setSort(sort, order) }
            }
        Box(Modifier.fillMaxSize()) {
            when {
                state.loading -> GridSkeleton(cols = 3, rows = 3, modifier = Modifier.padding(top = 8.dp))
                state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::reload)
                state.items.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("这个条件下没有作品", style = McType.subheadlineSemibold)
                        Spacer(Modifier.height(6.dp))
                        Text("试着放宽筛选条件", style = McType.footnote, color = TextFaint)
                        Spacer(Modifier.height(12.dp))
                        TextButton(onClick = vm::clearFilter) { Text("清空筛选", color = Accent) }
                    }
                }
                else -> Column {
                    if (!state.filter.isEmpty()) {
                        ActiveFilterSummary(state.filter) { vm.clearFilter() }
                    }
                    LazyVerticalGrid(
                        state = gridState,
                        columns = GridCells.Fixed(2),
                        contentPadding = PaddingValues(
                            start = McMetrics.pagePadding,
                            end = if (index.isNotEmpty()) 40.dp else McMetrics.pagePadding,
                            top = 0.dp,
                            bottom = 24.dp,
                        ),
                        verticalArrangement = Arrangement.spacedBy(18.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(state.items, key = { it.mediaItemId }) { item ->
                            LibraryItemCard(
                                item = item,
                                origin = origin,
                                onClick = { onOpenItem(libraryId, item.mediaItemId) },
                            )
                        }
                        if (state.loadingMore) {
                            item(span = { GridItemSpan(3) }) {
                                Box(Modifier.fillMaxWidth().padding(14.dp), contentAlignment = Alignment.Center) {
                                    CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(20.dp))
                                }
                            }
                        }
                    }
                }
            }

            // A–Z 索引条(iOS WallIndexBar:拖动选档 + 气泡预览)
            if (index.isNotEmpty() && !state.loading) {
                AlphabetBar(
                    entries = index,
                    currentOffset = state.windowStart,
                    onJump = { entry ->
                        vm.jumpTo(entry)
                        scope.launch { gridState.scrollToItem(0) }
                    },
                    modifier = Modifier.align(Alignment.CenterEnd),
                )
            }
        }
        }
    }

    if (showFilter) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
        ModalBottomSheet(
            onDismissRequest = { showFilter = false },
            sheetState = sheetState,
            containerColor = Color(0xFF171A23),
        ) {
            FilterSheetContent(
                facets = facets,
                filter = state.filter,
                onDraftChanged = { draft -> vm.loadFacets(draft, showLoading = false) },
                onApply = { filter ->
                    vm.applyFilter(filter)
                    showFilter = false
                },
                onRetry = { vm.loadFacets(showLoading = true) },
            )
        }
    }
}

@Composable
private fun SortMenu(current: LibraryFilter, onSelect: (String, String?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val label = when (current.sort) {
        "release_date" -> "按时间"
        "rating" -> "按评分"
        else -> "按标题"
    }
    Box {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(SurfaceRaised)
                .border(1.dp, LineColor, RoundedCornerShape(999.dp))
                .clickable { expanded = true }
                .padding(horizontal = 12.dp, vertical = 6.dp),
        ) {
            Icon(Icons.Rounded.Sort, contentDescription = null, tint = TextMuted, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(5.dp))
            Text(label, style = McType.caption, color = TextMuted)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            listOf(
                Triple("title", "按标题", null),
                Triple("release_date", "按时间(新→旧)", "desc"),
                Triple("release_date", "按时间(旧→新)", "asc"),
                Triple("rating", "按评分(高→低)", "desc"),
            ).forEach { (sort, text, order) ->
                DropdownMenuItem(
                    text = {
                        Text(
                            text,
                            style = McType.subheadline,
                            color = if (current.sort == sort && current.order == order) Accent else Color.Unspecified,
                        )
                    },
                    onClick = { expanded = false; onSelect(sort, order) },
                )
            }
        }
    }
    Spacer(Modifier.width(8.dp))
}

@Composable
private fun FilterButton(activeCount: Int, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(end = 8.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(if (activeCount > 0) AccentSoft else SurfaceRaised)
            .border(1.dp, LineColor, RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Icon(
            Icons.Rounded.FilterList,
            contentDescription = "筛选",
            tint = if (activeCount > 0) Accent else TextMuted,
            modifier = Modifier.size(14.dp),
        )
        Spacer(Modifier.width(5.dp))
        Text(
            if (activeCount > 0) "筛选 · $activeCount" else "筛选",
            style = McType.caption,
            color = if (activeCount > 0) Accent else TextMuted,
        )
    }
}

@Composable
private fun ActiveFilterSummary(filter: LibraryFilter, onClear: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Text("已应用 ${filter.activeCount} 个条件", style = McType.caption, color = TextMuted)
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onClear) { Text("清空", style = McType.caption, color = Accent) }
    }
}

/* ---------------- 筛选面板 ---------------- */

@Composable
private fun FilterSheetContent(
    facets: Loadable<LibraryFacets>,
    filter: LibraryFilter,
    onDraftChanged: (LibraryFilter) -> Unit,
    onApply: (LibraryFilter) -> Unit,
    onRetry: () -> Unit,
) {
    var draft by remember(filter) { mutableStateOf(filter) }
    // 勾选后 180ms 去抖重算计数,与 iOS「面板显示的是当前条件下的数量」一致
    LaunchedEffect(draft) {
        delay(180)
        onDraftChanged(draft)
    }

    when (facets) {
        Loadable.Loading -> Box(Modifier.fillMaxWidth().height(240.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = TextMuted)
        }
        is Loadable.Failed -> ErrorPane(
            message = facets.message,
            onRetry = onRetry,
            modifier = Modifier.height(240.dp),
        )
        is Loadable.Ready -> {
            val data = facets.value
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("筛选", style = McType.title3)
                    Spacer(Modifier.width(8.dp))
                    Text("点「查看」前不会改变海报墙", style = McType.caption, color = TextFaint)
                }
                Column(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(max = 460.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    FacetGroup("类型", data.genres, draft.genres) { draft = draft.copy(genres = it) }
                    FacetGroup("年代", data.decades, draft.decades) { draft = draft.copy(decades = it) }
                    FacetGroup("地区", data.countries, draft.countries) { draft = draft.copy(countries = it) }
                    FacetGroup("观看", data.watch, draft.watch) { draft = draft.copy(watch = it) }
                    SheetDivider()
                    FacetSingle("评分", data.ratings, draft.ratingGte?.let { gte -> "%.0f".format(gte) }) { value ->
                        draft = draft.copy(ratingGte = value?.toFloatOrNull())
                    }
                    FacetGroup("片长", data.runtimes, draft.runtimes) { draft = draft.copy(runtimes = it) }
                    FacetGroup("原始语言", data.languages, draft.languages) { draft = draft.copy(languages = it) }
                    SheetDivider()
                    FacetGroup("分辨率", data.resolutions, draft.resolutions) { draft = draft.copy(resolutions = it) }
                    FacetTriState("动态范围", data.hdr, draft.hdr) { draft = draft.copy(hdr = it) }
                    FacetGroup("库存状态", data.stock, draft.stock) { draft = draft.copy(stock = it) }
                    Spacer(Modifier.height(12.dp))
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                ) {
                    TextButton(onClick = { draft = draft.cleared() }) {
                        Text("清空", style = McType.subheadline, color = TextMuted)
                    }
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = { onApply(draft) }) {
                        Text(
                            "查看 ${data.total} 部",
                            style = McType.subheadlineSemibold,
                            color = Accent,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SheetDivider() {
    HorizontalDivider(color = LineColor, modifier = Modifier.padding(vertical = 10.dp))
}

@Composable
private fun FacetGroup(
    title: String,
    values: List<FacetValue>,
    selected: Set<String>,
    onChange: (Set<String>) -> Unit,
) {
    if (values.isEmpty()) return
    Spacer(Modifier.height(10.dp))
    Text(title, style = McType.caption, color = TextFaint)
    Spacer(Modifier.height(6.dp))
    FlowChips(values) { value ->
        val on = value.value in selected
        FacetChip(
            label = value.label,
            count = value.count,
            on = on,
            enabled = value.count > 0 || on,
        ) {
            onChange(if (on) selected - value.value else selected + value.value)
        }
    }
}

/** 评分走接口的 gte 语义,所以是单选 */
@Composable
private fun FacetSingle(
    title: String,
    values: List<FacetValue>,
    selectedValue: String?,
    onSelect: (String?) -> Unit,
) {
    if (values.isEmpty()) return
    Spacer(Modifier.height(10.dp))
    Text("$title(单选)", style = McType.caption, color = TextFaint)
    Spacer(Modifier.height(6.dp))
    FlowChips(values) { value ->
        val on = value.value == selectedValue
        FacetChip(label = value.label, count = value.count, on = on, enabled = value.count > 0 || on) {
            onSelect(if (on) null else value.value)
        }
    }
}

/** 动态范围接口是单个布尔,所以是三态 */
@Composable
private fun FacetTriState(
    title: String,
    values: List<FacetValue>,
    selected: Boolean?,
    onChange: (Boolean?) -> Unit,
) {
    if (values.isEmpty()) return
    Spacer(Modifier.height(10.dp))
    Text(title, style = McType.caption, color = TextFaint)
    Spacer(Modifier.height(6.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FacetChip("不限", null, selected == null, enabled = true) { onChange(null) }
        values.forEach { value ->
            val asBool = value.value.equals("true", ignoreCase = true) || value.value == "hdr"
            FacetChip(value.label, value.count, selected == asBool, enabled = value.count > 0 || selected == asBool) {
                onChange(asBool)
            }
        }
    }
}

@Composable
private fun FlowChips(values: List<FacetValue>, content: @Composable (FacetValue) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        values.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                row.forEach { value -> Box(Modifier.weight(1f)) { content(value) } }
                repeat(3 - row.size) { Box(Modifier.weight(1f)) {} }
            }
        }
    }
}

@Composable
private fun FacetChip(
    label: String,
    count: Int?,
    on: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(999.dp))
            .background(if (on) Color.White.copy(alpha = 0.14f) else Color.Transparent)
            .border(
                1.dp,
                if (on) Color.White.copy(alpha = 0.4f) else Color.White.copy(alpha = 0.14f),
                RoundedCornerShape(999.dp),
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.Center,
    ) {
        Text(
            label,
            style = if (on) McType.caption.copy(fontWeight = FontWeight.SemiBold) else McType.caption,
            color = Color.White.copy(alpha = if (!enabled) 0.3f else if (on) 0.95f else 0.7f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (count != null) {
            Spacer(Modifier.width(5.dp))
            Text("$count", fontSize = 10.sp, color = Color.White.copy(alpha = if (!enabled) 0.2f else 0.35f))
        }
    }
}

/* ---------------- A–Z 索引条 ---------------- */

/** iOS WallIndexBar:22 宽、拖动选档、气泡预览「字母 + N 部」、空档降透明度不可跳 */
@Composable
private fun AlphabetBar(
    entries: List<LibraryIndexEntry>,
    currentOffset: Int,
    onJump: (LibraryIndexEntry) -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptic = LocalHapticFeedback.current
    val density = LocalDensity.current
    var preview by remember { mutableStateOf<LibraryIndexEntry?>(null) }
    val activeIndex = entries.indexOfLast { it.offset <= currentOffset }.coerceAtLeast(0)

    Box(modifier.fillMaxHeight()) {
        Column(
            verticalArrangement = Arrangement.Center,
            modifier = Modifier
                .width(22.dp)
                .fillMaxHeight()
                .pointerInput(entries) {
                    detectVerticalDragGestures(
                        onDragStart = { offset ->
                            preview = entryAt(offset.y, size.height.toFloat(), entries)
                        },
                        onDragEnd = {
                            preview?.let { if (it.count > 0) onJump(it) }
                            preview = null
                        },
                        onDragCancel = { preview = null },
                    ) { change, _ ->
                        val entry = entryAt(change.position.y, size.height.toFloat(), entries)
                        if (entry != null && entry.initial != preview?.initial) {
                            preview = entry
                            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        }
                    }
                }
                .padding(vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            entries.forEachIndexed { index, entry ->
                Text(
                    entry.initial,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = when {
                        preview?.initial == entry.initial -> Color.Black
                        index == activeIndex -> Color.White
                        entry.count == 0 -> TextFaint.copy(alpha = 0.5f)
                        else -> TextMuted
                    },
                    modifier = Modifier
                        .width(16.dp)
                        .padding(vertical = 1.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(
                            when {
                                preview?.initial == entry.initial -> AccentStrong
                                index == activeIndex -> AccentStrong.copy(alpha = 0.35f)
                                else -> Color.Transparent
                            }
                        )
                        .clickable(enabled = entry.count > 0) { onJump(entry) }
                        .padding(vertical = 1.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }

        preview?.let { entry ->
            Box(
                Modifier
                    .align(Alignment.CenterEnd)
                    .padding(end = with(density) { 26.dp.toPx() }.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(SurfaceRaised)
                    .border(1.dp, LineColor, RoundedCornerShape(12.dp))
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(entry.initial, style = McType.title, color = AccentStrong)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        if (entry.count > 0) "${entry.count} 部" else "无作品",
                        style = McType.caption,
                        color = TextMuted,
                    )
                }
            }
        }
    }
}

/** 按纵向位置换算字母档(等分) */
private fun entryAt(y: Float, height: Float, entries: List<LibraryIndexEntry>): LibraryIndexEntry? {
    if (entries.isEmpty() || height <= 0f) return null
    val ratio = (y / height).coerceIn(0f, 0.9999f)
    val index = (ratio * entries.size).toInt().coerceIn(0, entries.size - 1)
    return entries[index]
}
