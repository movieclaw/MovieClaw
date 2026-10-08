package io.movieclaw.android.feature.discover

import androidx.compose.ui.unit.Dp
import io.movieclaw.android.core.designsystem.SkeletonBlock
import io.movieclaw.android.core.designsystem.PosterRowSkeleton
import io.movieclaw.android.core.designsystem.PosterRibbon
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.tabGlassSource
import io.movieclaw.android.core.designsystem.McRow
import io.movieclaw.android.core.designsystem.McMetrics
import androidx.compose.ui.text.TextStyle
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import io.movieclaw.android.core.designsystem.statusLabel
import io.movieclaw.android.feature.subscriptions.SubscriptionIndex
import io.movieclaw.android.core.model.SubscriptionView
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.ContinueWatchingCard
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.PosterCard
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.border
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.HeroAmbientBackdrop
import io.movieclaw.android.core.designsystem.HeroCarousel
import io.movieclaw.android.core.designsystem.HeroSlide
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McTabBarContentPadding
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.discovery.rememberAmbientColor
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.SectionHeader
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.DiscoveredTitle
import io.movieclaw.android.core.model.DiscoverySection
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.UpNextItem
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.intOrNull
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import io.movieclaw.android.core.designsystem.LocalPosterReveal

data class DiscoverRow(val section: DiscoverySection, val titles: List<DiscoveredTitle>)

@HiltViewModel
class DiscoverViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val mediaType: String = "movie",
        val source: String = "tmdb",
        val filters: DiscoveryFilter = DiscoveryFilter(),
        val upNext: List<UpNextItem> = emptyList(),
        val libraries: List<LibraryView> = emptyList(),
        val rows: List<DiscoverRow> = emptyList(),
        // ── 筛选结果网格（条件生效时正文换成它，见 DiscoverFilteredGrid.kt）──
        val filtered: List<DiscTitle> = emptyList(),
        val filteredLoading: Boolean = false,
        val filteredError: String? = null,
        val filteredPage: Int = 1,
        val filteredTotalPages: Int = 1,
        val filteredTotal: Int = 0,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    /** 条件是否生效：只有 TMDB 源有筛选（豆瓣源的按钮不出现），且至少一项条件（iOS `filtering` 同口径） */
    val filtering: Boolean get() = isFiltering(_ui.value)

    private fun isFiltering(s: UiState): Boolean =
        s.source.equals("tmdb", ignoreCase = true) && s.filters.activeCount > 0

    init {
        load()
    }

    val source: String get() = _ui.value.source
    val filters: DiscoveryFilter get() = _ui.value.filters

    /** 切源清空筛选条件（iOS「切类型保留数据源、切数据源保留类型，**都清空筛选**，同 Web」） */
    fun switchSource(source: String) {
        if (_ui.value.source == source) return
        _ui.update { it.copy(source = source, filters = DiscoveryFilter(), rows = emptyList()) }
        refresh()
    }

    /**
     * 选一项筛选条件即生效（没有「查看结果」这一步）：条件生效时正文换成结果网格并原地重查；
     * 条件被清空则回到常规首页板块。
     */
    fun applyFilters(filters: DiscoveryFilter) {
        _ui.update { it.copy(filters = filters) }
        refresh()
    }

    /** 下拉刷新转圈（iOS `.refreshable` 的对应物） */
    private val _refreshing = MutableStateFlow(false)
    val refreshing: kotlinx.coroutines.flow.StateFlow<Boolean> = _refreshing.asStateFlow()

    /** 下拉刷新：首页板块或筛选网格各自重拉一份，转圈到页面自己的加载态落下去 */
    fun pullRefresh() {
        if (_refreshing.value) return
        viewModelScope.launch {
            _refreshing.value = true
            try {
                refresh()
                // 筛选态有 300ms 防抖：让它先过去，加载态立起来再等
                kotlinx.coroutines.delay(450)
                kotlinx.coroutines.withTimeoutOrNull(12_000) {
                    _ui.first { !it.loading && !it.filteredLoading }
                }
            } finally {
                _refreshing.value = false
            }
        }
    }

    /** 媒体类型 / 数据源 / 条件变化后的统一入口：按是否处于筛选态决定拉哪一份数据 */
    private fun refresh() {
        if (isFiltering(_ui.value)) {
            // 网格上还是空的（首次进入筛选态）就不必等防抖
            loadFiltered(skipDebounce = _ui.value.filtered.isEmpty())
        } else {
            _ui.update { it.copy(filtered = emptyList(), filteredError = null) }
            load()
        }
    }

    /** 筛选结果的单页查询序号：只允许最后一次请求写回（条件连改时不发散） */
    private var filteredSeq = 0
    private var filteredDebounce: Job? = null

    /**
     * 结果网格重查：条件变了先等 300 毫秒防抖（连勾几个类型只查最后一次），
     * 首次进入不必等（iOS `DiscoverFilteredGrid.task(id: filters)` 同款）。
     */
    fun loadFiltered(skipDebounce: Boolean = false) {
        filteredDebounce?.cancel()
        filteredDebounce = viewModelScope.launch {
            if (!skipDebounce) kotlinx.coroutines.delay(300)
            val s = _ui.value
            val origin = origin ?: run {
                _ui.update { it.copy(filteredLoading = false, filteredError = "尚未连接服务器") }
                return@launch
            }
            val seq = ++filteredSeq
            _ui.update { it.copy(filteredLoading = true, filteredError = null, filtered = emptyList(), filteredPage = 1) }
            runCatching {
                apiFactory.forOrigin(origin).discoverTitles(
                    mediaType = s.mediaType,
                    genreIds = s.filters.genreIds.takeIf { it.isNotEmpty() },
                    originCountry = s.filters.originCountry,
                    year = s.filters.year,
                    ratingGte = s.filters.ratingGte,
                    runtimeLte = s.filters.runtimeLte,
                    sort = s.filters.sort,
                    page = 1,
                ).dataOrThrow().jsonObject
            }
                .onSuccess { raw ->
                    if (seq != filteredSeq) return@onSuccess
                    _ui.update {
                        it.copy(
                            filteredLoading = false,
                            // 按 ref 去重：网格用 ref 当 key，重复一条就会崩（服务端排序不稳时也可能重复）
                            filtered = parseTitles(raw).distinctBy { it.ref },
                            filteredPage = raw["page"]?.jsonPrimitive?.intOrNull ?: 1,
                            filteredTotalPages = raw["total_pages"]?.jsonPrimitive?.intOrNull ?: 1,
                            filteredTotal = raw["total_results"]?.jsonPrimitive?.intOrNull ?: 0,
                        )
                    }
                }
                .onFailure { e ->
                    if (seq != filteredSeq) return@onFailure
                    _ui.update { it.copy(filteredLoading = false, filteredError = friendlyMessage(e)) }
                }
        }
    }

    fun loadMoreFiltered() {
        val s = _ui.value
        if (s.filteredLoading || s.filteredPage >= s.filteredTotalPages || !isFiltering(s)) return
        // 记下这一轮的条件代号：换筛选条件（loadFiltered 会 ++filteredSeq 并清空列表）后，
        // 在飞的这一页回来必须作废——原来没有这道守卫，旧条件的一页会混进新列表，
        // 撞上重复 ref 就是「Key … was already used」闪退（实机抓到过）
        val seq = filteredSeq
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val next = s.filteredPage + 1
            _ui.update { it.copy(filteredLoading = true) }
            runCatching {
                apiFactory.forOrigin(origin).discoverTitles(
                    mediaType = s.mediaType,
                    genreIds = s.filters.genreIds.takeIf { it.isNotEmpty() },
                    originCountry = s.filters.originCountry,
                    year = s.filters.year,
                    ratingGte = s.filters.ratingGte,
                    runtimeLte = s.filters.runtimeLte,
                    sort = s.filters.sort,
                    page = next,
                ).dataOrThrow().jsonObject
            }
                .onSuccess { raw ->
                    if (seq != filteredSeq) return@onSuccess
                    _ui.update {
                        it.copy(
                            filteredLoading = false,
                            filteredPage = next,
                            filtered = (it.filtered + parseTitles(raw)).distinctBy { t -> t.ref },
                        )
                    }
                }
                .onFailure { e ->
                    if (seq != filteredSeq) return@onFailure
                    _ui.update { it.copy(filteredLoading = false, filteredError = friendlyMessage(e)) }
                }
        }
    }

    /** 切类型也清空筛选条件（见 [switchSource]） */
    fun switchMediaType(mediaType: String) {
        if (_ui.value.mediaType == mediaType) return
        _ui.update {
            it.copy(mediaType = mediaType, filters = DiscoveryFilter(), rows = emptyList(), filtered = emptyList())
        }
        refresh()
    }

    fun load() {
        // 筛选态下正文是结果网格，首页板块整块不在画面上：不必白拉一趟
        if (isFiltering(_ui.value)) return
        viewModelScope.launch {
            val origin = origin
            if (origin == null) {
                _ui.update { it.copy(loading = false, error = "尚未连接服务器") }
                return@launch
            }
            _ui.update { it.copy(loading = true, error = null) }
            val api = apiFactory.forOrigin(origin)
            try {
                // 首页数据并行拉取:继续观看、资料库、服务端编排的发现页板块
                // （板块接口只认 provider；筛选不走这里，见 McApi.discoveryPage）
                val pageDeferred = async { runCatching { api.discoveryPage(
                        mediaType = _ui.value.mediaType,
                        source = _ui.value.source,
                    ).dataOrThrow() }.getOrNull() }

                val rows = pageDeferred.await()?.sections?.let { sections ->
                    coroutineScope {
                        sections
                            .filter { it.collectionRef.isNotEmpty() }
                            .map { section ->
                                async {
                                    val titles = runCatching {
                                        api.collectionTitles(
                                            section.collectionRef,
                                            limit = section.previewLimit.coerceIn(6, 30),
                                        ).dataOrThrow().titles
                                    }.getOrDefault(emptyList())
                                    DiscoverRow(section, titles)
                                }
                            }
                            .awaitAll()
                            .filter { it.titles.isNotEmpty() }
                    }
                }.orEmpty()

                _ui.update {
                    it.copy(
                        loading = false,
                        rows = rows,
                    )
                }
            } catch (e: Exception) {
                _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
            }
        }
    }
}

/** 发现页:搜索入口 + 电影/剧集 + 服务端板块 + 继续观看 + 资料库 */
@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
fun DiscoverScreen(
    onOpenLibrary: (Long, String) -> Unit,
    onOpenItem: (Long, Long) -> Unit,
    onPlay: (PlayTarget) -> Unit,
    onOpenSearch: () -> Unit,
    onOpenTitle: (String) -> Unit,
    onOpenCollection: (String, String) -> Unit,
    /** 未订阅 → 订阅弹层；已订阅 → 订阅管理（与网页「订阅影片 / 已订阅」同语义） */
    onSubscribeTitle: (String, io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.Seed?) -> Unit,
    subscriptions: SubscriptionIndex,
    vm: DiscoverViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val refreshing by vm.refreshing.collectAsStateWithLifecycle()
    val origin = vm.origin
    // 全站订阅索引：hero 与每张卡片的「订阅影片 / 已订阅 · 状态」都由它判断，
    // 不再拿"是否在库里"冒充"是否已订阅"
    val subscriptionIndex by subscriptions.byKey.collectAsStateWithLifecycle()
    LaunchedEffect(origin, subscriptionIndex) { subscriptions.ensureLoaded() }

    // 条件生效时正文整块换成结果网格（iOS `filtering` 同口径：TMDB 源 + 至少一项条件）
    val filtering = state.source.equals("tmdb", ignoreCase = true) && state.filters.activeCount > 0

    val scroll = rememberScrollState()
    io.movieclaw.android.core.designsystem.TrackTabBarMinimize(scroll)
    // 英雄轮播的数据来自 presentation == "hero" 那一行（六屏）
    val heroRow = remember(state.rows) { state.rows.firstOrNull { it.section.presentation == "hero" } }
    val heroSlides = remember(heroRow, origin, subscriptionIndex) {
        heroRow?.titles.orEmpty().map { title ->
            title.toHeroSlide(
                origin,
                subscriptions.findIn(subscriptionIndex, title.provider, title.externalId, title.mediaType),
            )
        }
    }
    var heroPage by remember { mutableIntStateOf(0) }
    // 氛围底色 = 当前这一屏剧照的主色（同一套取色算法）
    val ambient = rememberAmbientColor(heroSlides.getOrNull(heroPage)?.backdropUrl, origin)
    // 悬浮顶栏实际占的高度（状态栏 + 52dp）：筛选态下胶囊行与维度菜单都按它让位
    val topBarTotal = androidx.compose.foundation.layout.WindowInsets.statusBars
        .asPaddingValues()
        .calculateTopPadding() + McMetrics.topBarHeight
    var showSourceMenu by remember { mutableStateOf(false) }
    var showFilterMenu by remember { mutableStateOf(false) }
    /** 结果页条件胶囊点开的那一维（null = 没开；浮层挂在胶囊行正下方） */
    var chipDim by remember { mutableStateOf<String?>(null) }

    // 展开层宿主：同一时刻只展开一张海报卡（网页 hover 层在触摸端的等价物）
    val posterReveal = remember { mutableStateOf<String?>(null) }

    androidx.compose.runtime.CompositionLocalProvider(LocalPosterReveal provides posterReveal) {
    Box(Modifier.fillMaxSize()) {
        // 氛围底在页面根、滚动容器之外（实测如此），随滚动退淡
        HeroAmbientBackdrop(
            color = ambient,
            scrollPx = scroll.value.toFloat(),
            modifier = Modifier.fillMaxSize(),
        )
        // 下拉刷新（iOS `.refreshable`）：**必须用官方 PullToRefreshBox 包在滚动之外**——
        // 之前把 `Modifier.pullToRefresh` 挂在滚动同一个节点上，划了没反应（实机反馈）。
        // 指示器再加一段 offset：这一页的顶栏是悬浮的（盖在内容上），默认位置的转圈正好被它挡住，
        // 「刷新了但屏幕上什么都看不见」也是看起来没反应的来源之一。
        val pullState = rememberPullToRefreshState()
        androidx.compose.material3.pulltorefresh.PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { vm.pullRefresh() },
            state = pullState,
            modifier = Modifier.fillMaxSize(),
            indicator = {
                androidx.compose.material3.pulltorefresh.PullToRefreshDefaults.Indicator(
                    state = pullState,
                    isRefreshing = refreshing,
                    containerColor = androidx.compose.material3.MaterialTheme.colorScheme.surfaceVariant,
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = topBarTotal + 6.dp),
                )
            },
        ) {
        Column(
            Modifier
                .fillMaxSize()
                // 筛选态下正文是懒加载网格：外层不能再套垂直滚动（无限高约束会崩），
                // 网格自己滚；常规态仍是整页一个滚动容器（实测形态）
                .then(if (filtering) Modifier else Modifier.verticalScroll(scroll))
                // 液态底栏的背景模糊源（Local 为 null 时原样返回，零代价）
                .tabGlassSource()
                .padding(bottom = McTabBarContentPadding),
        ) {
            if (filtering) {
                // ── 条件生效：正文整块换成结果网格（iOS DiscoverFilteredGrid）──
                // 头（TMDB DISCOVER / 筛选结果 / 计数 + 清空条件）与条件胶囊都在网格里
                // 跟着滚（iOS 就是这样，见 DiscoverFilteredGrid.kt）；顶栏那颗「全部」
                // 任何时候都能改条件。让位的是**状态栏 + 顶栏**（悬浮顶栏占的那一段）。
                Spacer(Modifier.height(topBarTotal))
                DiscoverFilteredGridBody(
                    state = state,
                    origin = origin,
                    onOpenTitle = onOpenTitle,
                    onOpenDim = { chipDim = it },
                    onClear = { vm.applyFilters(DiscoveryFilter()) },
                    onLoadMore = { vm.loadMoreFiltered() },
                    onRetry = { vm.loadFiltered(skipDebounce = true) },
                )
                return@Column
            }
            if (heroSlides.isNotEmpty()) {
                HeroCarousel(
                    slides = heroSlides,
                    currentPage = heroPage,
                    onPageChange = { heroPage = it },
                    onOpenSlide = { onOpenTitle(it.id) },
                    onAction = { slide ->
                        onSubscribeTitle(
                            slide.id,
                            io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.Seed(
                                title = slide.title,
                                posterUrl = slide.backdropUrl,
                                year = slide.year?.toIntOrNull(),
                                kind = if (state.mediaType == "tv") "tv" else "movie",
                            ),
                        )
                    },
                    // iOS ImmersiveHero：图随滚动 0.4× 下移（只下不上）
                    parallaxPx = maxOf(0f, scroll.value.toFloat()) * 0.4f,
                    // 文字与指示器在 260pt 内淡尽
                    contentFade = (1f - scroll.value / 260f).coerceIn(0f, 1f),
                )
            }
            // 非沉浸档：服务端没给 hero（豆瓣源）或 hero 还没到（骨架态）时，正文让出悬浮顶栏
            // 占的那一段——否则首行标题会顶到状态栏、被顶栏压住（豆瓣源的实机反馈）。
            // 有 hero 才是沉浸式（大图从屏幕顶边铺下来），与 iOS `immersive` 同一判据；
            // 这一条同时覆盖骨架态（`rows` 空）与 hero 行没内容被滤掉的情况（装载是 awaitAll
            // 一次性赋值，不存在「声明了 hero 但 slides 未到」的中间态，所以不必再画骨架）。
            if (heroSlides.isEmpty()) Spacer(Modifier.height(topBarTotal))

        when {
            state.loading && state.rows.isEmpty() -> Column {
                SkeletonBlock(
                    Modifier
                        .padding(horizontal = 16.dp)
                        .fillMaxWidth()
                        .height(190.dp),
                    radius = 18.dp,
                )
                Spacer(Modifier.height(20.dp))
                PosterRowSkeleton("正在加载")
                Spacer(Modifier.height(20.dp))
                PosterRowSkeleton(" ")
            }
            state.error != null -> ErrorPane(
                message = state.error!!,
                onRetry = vm::load,
                modifier = Modifier.fillMaxWidth().height(360.dp),
            )
            else -> {
                // iOS 发现页只有「英雄 + 服务端板块」：继续观看属于媒体库首页，这里不再重复

                state.rows.forEach { row ->
                    if (row.section.presentation == "hero") return@forEach
                    Spacer(Modifier.height(if (row === state.rows.first { it.section.presentation != "hero" }) 0.dp else McMetrics.sectionTop))
                    SectionHeader(
                        title = row.section.title,
                        // iOS：行右侧是「查看完整榜单」（subheadline/600、textMuted），不是「全部」
                        actionText = if (row.section.supportsFullListing) "查看完整榜单" else null,
                        onAction = if (row.section.supportsFullListing) {
                            { onOpenCollection(row.section.collectionRef, row.section.title) }
                        } else {
                            null
                        },
                    )
                    Spacer(Modifier.height(McMetrics.sectionBottom))
                    run {
                        McRow {
                            itemsIndexed(row.titles, key = { idx, it -> "${row.section.title}#$idx#" + it.titleRef.ifEmpty { it.title } }) { idx, item ->
                                // 用**收集成 Compose 状态**的 map 查（见 SubscriptionIndex.findIn 的说明）
                                val subscribed = subscriptions.findIn(
                                    subscriptionIndex,
                                    item.provider,
                                    item.externalId,
                                    item.mediaType,
                                ) != null
                                PosterCard(
                                    imageUrl = item.posterUrl,
                                    origin = origin,
                                    title = item.title,
                                    meta = posterMeta(item),
                                    rating = item.providerRating.takeIf { it > 0f },
                                    // 常显斜标：已入库优先（绿），否则已订阅（蓝）——网页同口径
                                    ribbon = when {
                                        item.libraryStatus != null -> PosterRibbon.OWNED
                                        subscribed -> PosterRibbon.SUBSCRIBED
                                        else -> null
                                    },
                                    modifier = Modifier.width(McMetrics.rowCardWidth),
                                    // 卡片动作键（移动端网页实测）：已订阅 = 中性底 + 绿勾 +「已订阅」；
                                    // 未订阅 = 强调色 +「订阅影片/订阅剧集」（**在库但未订阅照样给订阅键**，
                                    // 卡片右上另有「在库」徽标）。两种状态的点击都打开订阅弹层。
                                    actionLabel = if (subscribed) {
                                        "已订阅"
                                    } else if (state.mediaType == "tv") {
                                        "订阅剧集"
                                    } else {
                                        "订阅影片"
                                    },
                                    actionIcon = if (subscribed) Icons.Rounded.Check else Icons.Rounded.Add,
                                    actionNeutral = subscribed,
                                    onAction = {
                                        onSubscribeTitle(
                                            item.titleRef,
                                            io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.Seed(
                                                title = item.title,
                                                posterUrl = item.posterUrl,
                                                year = item.releaseYear,
                                                kind = item.mediaType,
                                            ),
                                        )
                                    },
                                    onClick = { onOpenTitle(item.titleRef) },
                                    // 展开层的唯一标识：同一部片可能同时出现在「今日热榜」和「正在热映」，
                                    // 只按片名做 key 会让一处展开、处处展开（用户报的现象）
                                    instanceKey = "${row.section.title}#$idx#${item.titleRef}", 
                                )
                            }
                        }
                    }
                }

                if (state.libraries.isNotEmpty()) {
                    Spacer(Modifier.height(20.dp))
                    SectionHeader("我的资料库")
                    Spacer(Modifier.height(11.dp))
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        items(state.libraries, key = { it.id }) { library ->
                            LibraryMiniCard(library = library) { onOpenLibrary(library.id, library.name) }
                        }
                    }
                }

                if (state.rows.isEmpty()) {
                    Spacer(Modifier.height(20.dp))
                    GlassCard(Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
                        Text("发现页暂无板块", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "服务端未配置发现页板块(或未配置 TMDB)。可在服务器网页端「设置 → 发现页」检查。",
                            fontSize = 11.5.sp,
                            color = TextMuted,
                            lineHeight = 18.sp,
                        )
                    }
                }
            }
        }
        }
    }

    // 顶栏：大标题 30/700 + 数据源小字(可弹) + 右侧「全部」胶囊(可弹)与搜索圆钮。
    McTopBar(
        variant = McTopBarVariant.Discover,
        title = if (state.mediaType == "tv") "剧集" else "电影",
        sourceLabel = if (state.source.equals("douban", ignoreCase = true)) "豆瓣" else "TMDB",
        onSourceClick = { showFilterMenu = false; chipDim = null; showSourceMenu = !showSourceMenu },
        mistStrength = 0.5f,
        mistHeight = 135.dp,
        modifier = Modifier.align(Alignment.TopCenter),
    ) {
        // 「全部」筛选键（iOS DiscoverFilterMenu）：点开是六个维度各一个二级菜单 + 「清空条件」，
        // 选一项即生效——**不压栈新页**，也没有「查看结果」这一步。豆瓣源没有筛选，键不出现。
        if (state.source.equals("tmdb", ignoreCase = true)) {
            Text(
                state.filters.label(),
                style = McType.subSemibold,
                color = Color.White.copy(alpha = 0.92f),
                modifier = Modifier
                    .height(36.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(GlassCapsule)
                    .border(1.dp, LineSoft, RoundedCornerShape(999.dp))
                    .clickable {
                        showSourceMenu = false
                        chipDim = null
                        showFilterMenu = !showFilterMenu
                    }
                    .padding(horizontal = 14.dp)
                    .wrapContentHeight(),
            )
            Spacer(Modifier.width(8.dp))
        }
        // 入口口径是「任一搜索分区可用」（影视 / 资源 / 媒体库，见 SearchAccess.canOpenSearch）
        if (io.movieclaw.android.core.session.LocalSearchAccess.current.canOpenSearch) {
            McNavButton(Icons.Rounded.Search, contentDescription = "搜索", onClick = onOpenSearch)
        }
    }

    // 菜单层。网页的 page-scrim 在 z-5、.app-shell 在 z-10，
    // 遮罩永远被盖住——所以弹出时背景不模糊也不变暗，
    // 只有一层透明的点外关闭区。
    if (showSourceMenu || showFilterMenu || chipDim != null) {
        Box(
            Modifier
                .fillMaxSize()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) {
                    showSourceMenu = false
                    showFilterMenu = false
                    chipDim = null
                },
        )
    }

    if (showSourceMenu) {
        SourceMenu(
            mediaType = state.mediaType,
            source = state.source,
            onPickMediaType = { vm.switchMediaType(it); showSourceMenu = false },
            onPickSource = { vm.switchSource(it); showSourceMenu = false },
            modifier = Modifier
                .align(Alignment.TopStart)
                .statusBarsPadding()
                .padding(start = McMetrics.topBarInsetRoot, top = McMetrics.topBarHeight),
        )
    }
    if (showFilterMenu) {
        DiscoveryFilterMenu(
            filter = state.filters,
            // 选一项即生效并收起（同 iOS）；条件被清空后正文本就回到首页板块
            onApply = { vm.applyFilters(it); showFilterMenu = false },
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(end = McMetrics.topBarInsetRoot, top = McMetrics.topBarHeight),
        )
    }
    // 结果页条件胶囊点开的那一维：浮层挂在顶栏右下（与「全部」菜单同一处）。
    // iOS 是把菜单锚在胶囊本身上；安卓这边胶囊在滚动容器里，锚点跟着滚会跑偏，
    // 统一挂在固定的右上角——同一个取值菜单、同一份文案，只是位置固定可预期。
    chipDim?.let { dim ->
        DiscoveryFilterDimPanel(
            dimKey = dim,
            filters = state.filters,
            onApply = { vm.applyFilters(it); chipDim = null },
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(end = McMetrics.topBarInsetRoot, top = topBarTotal),
        )
    }
    }
    }
}

/**
 * DiscoveredTitle → 轮播一屏。
 *
 * [sub] 是这部作品的**真实订阅**（来自全站订阅索引）。以前这里用 `libraryStatus != null`
 * 判断，等于把"已入库"当成"已订阅"——库里已有的片哪怕从没订阅过也显示「已订阅 ·
 * 追踪中」（用户报的正是这个）。入库看 library_status，订阅只能看订阅本身。
 */
private fun DiscoveredTitle.toHeroSlide(origin: String?, sub: SubscriptionView?) = HeroSlide(
    id = titleRef,
    backdropUrl = backdropUrl ?: posterUrl,
    origin = origin,
    label = "今日精选 · " + if (mediaType == "tv") "剧集" else "电影",
    title = title,
    originalTitle = originalTitle.takeIf { it.isNotBlank() && it != title },
    rating = providerRating.takeIf { it > 0f },
    year = releaseYear?.toString(),
    genres = genres.take(3).joinToString(" / ").takeIf { it.isNotBlank() },
    synopsis = overview.takeIf { it.isNotBlank() },
    // 用户指定：电影「订阅影片」、剧集「订阅剧集」（iOS 本身统一叫「订阅影片」，此处按用户要求切换）；
    // 已订阅时显示真实状态（追踪中 / 已暂停 / 已收齐），与详情页说的是同一套词
    actionLabel = if (sub != null) {
        "已订阅 · ${sub.statusLabel()}"
    } else if (mediaType == "tv") {
        "订阅剧集"
    } else {
        "订阅影片"
    },
    subscribed = sub != null,
)

@Composable
private fun HeroTitle(title: DiscoveredTitle, origin: String?, onClick: (DiscoveredTitle) -> Unit) {
    Box(
        Modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .height(190.dp)
            .clip(RoundedCornerShape(18.dp))
            .clickable { onClick(title) },
    ) {
        RemoteImage(
            url = title.backdropUrl ?: title.posterUrl,
            origin = origin,
            contentDescription = title.title,
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    androidx.compose.ui.graphics.Brush.verticalGradient(
                        listOf(Color.Transparent, Color.Black.copy(alpha = 0.8f))
                    )
                ),
        )
        Column(Modifier.align(Alignment.BottomStart).padding(14.dp)) {
            Text(
                title.title,
                style = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.Bold),
                color = Color.White,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                listOfNotNull(
                    title.releaseYear?.toString(),
                    title.genres.take(2).joinToString(" / ").takeIf { it.isNotEmpty() },
                    title.providerRating.takeIf { it > 0f }?.let { "★ ${"%.1f".format(it)}" },
                ).joinToString(" · "),
                fontSize = 11.5.sp,
                color = Color.White.copy(alpha = 0.7f),
            )
        }
    }
}

@Composable
private fun MediaTypeSwitcher(current: String, onSelect: (String) -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        listOf("movie" to "电影", "tv" to "剧集").forEach { (id, label) ->
            Text(
                label,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (id == current) Color(0xFF0A0E12) else TextMuted,
                modifier = Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (id == current) Accent else Color.White.copy(alpha = 0.05f))
                    .clickable { onSelect(id) }
                    .padding(horizontal = 16.dp, vertical = 7.dp),
            )
        }
    }
}

internal fun upNextSubtitle(item: UpNextItem): String {
    val remaining = ((item.durationMs - item.positionMs).coerceAtLeast(0)) / 60000
    return when {
        item.kind == "tv" && item.seasonNumber > 0 ->
            "S%02dE%02d · 还剩 %d 分钟".format(item.seasonNumber, item.episodeNumber, remaining)
        else -> "还剩 $remaining 分钟"
    }
}

@Composable
private fun SearchBarHint(onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .height(42.dp)
            .clip(RoundedCornerShape(21.dp))
            .background(Color.White.copy(alpha = 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Rounded.Search, contentDescription = null, tint = TextFaint, modifier = Modifier.size(17.dp))
        Spacer(Modifier.width(9.dp))
        Text("搜索标题、种子、媒体库…", fontSize = 13.5.sp, color = TextFaint)
    }
}

@Composable
private fun LibraryMiniCard(library: LibraryView, onClick: () -> Unit) {
    Column(
        modifier = Modifier
            .width(150.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.05f))
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        Text(library.name, fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        Spacer(Modifier.height(4.dp))
        Text(kindLabel(library.kind), fontSize = 11.sp, color = TextFaint)
        if (!library.viewerAccess) {
            Spacer(Modifier.height(6.dp))
            Text("仅管理权限", fontSize = 10.sp, color = Warning)
        }
    }
}

internal fun kindLabel(kind: String): String = when (kind) {
    "movie" -> "电影库"
    "tv" -> "剧集库"
    else -> "其他"
}

/** 海报卡元信息行:"2024 · 2 小时 8 分"(iOS 同款格式) */
internal fun posterMeta(item: DiscoveredTitle): String = listOfNotNull(
    item.releaseYear?.toString(),
    item.extentLabel.takeIf { it.isNotEmpty() },
).joinToString(" · ")
