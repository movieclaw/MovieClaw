package io.movieclaw.android.feature.library

import androidx.compose.foundation.layout.statusBarsPadding
import io.movieclaw.android.core.designsystem.MenuSurface
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.graphics.Brush
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.statusBars
import io.movieclaw.android.core.model.KindRow
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.ContinueWatchingCard
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McTabBarContentPadding
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.tabGlassSource
import io.movieclaw.android.core.designsystem.Placeholder
import io.movieclaw.android.core.designsystem.PosterCard
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.SectionHeader
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.FavoriteItemView
import io.movieclaw.android.core.model.HomePrefsBus
import io.movieclaw.android.core.model.HomeRows
import io.movieclaw.android.core.model.LibraryItemView
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.favoriteLevelLabel
import io.movieclaw.android.core.model.UpNextItem
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.playback.PlayTargetFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.launch

/** 媒体库首屏的数据（统计行 / 接下来继续 / 我的收藏 / 每库一行 / 按类型的跨库行） */
@HiltViewModel
class LibraryViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
    private val resumeBarPrefs: io.movieclaw.android.core.playback.ResumeBarPrefs,
    private val preconnect: io.movieclaw.android.core.playback.PlaybackPreconnect,
    private val snapshotStore: io.movieclaw.android.core.session.LibraryHomeSnapshotStore,
    private val feedback: io.movieclaw.android.core.designsystem.FeedbackBus,
    private val playbackEvents: io.movieclaw.android.core.playback.PlaybackDataEvents,
) : ViewModel() {
    private val _state = MutableStateFlow<Loadable<LibraryHome>>(Loadable.Loading)
    val state = _state.asStateFlow()

    /** 下拉刷新转圈（保留旧内容，等到齐才收）：iOS `.refreshable` 的对应物 */
    private val _refreshing = MutableStateFlow(false)
    val refreshing: kotlinx.coroutines.flow.StateFlow<Boolean> = _refreshing.asStateFlow()

    /** 图片基址（RemoteImage 用） */
    val origin: String? get() = repository.ui.value.origin

    private val loadMutex = kotlinx.coroutines.sync.Mutex()
    private var visibleRows: List<HomeRows.Row> = emptyList()

    init {
        // 「接下来继续」多半从这里点：进页就把起播要用的两条连接连好（iOS `LibraryHomeView.onAppear` 同款）
        viewModelScope.launch {
            playbackEvents.changes.collect { change ->
                if (change != null && repository.isCurrentIdentity(change.identity)) {
                    loadMutex.withLock {
                        val upNext = runCatching {
                            apiFactory.forIdentity(change.identity.origin, change.identity).upNext(limit = 24).dataOrThrow().items
                        }.getOrNull() ?: return@withLock
                        if (!repository.isCurrentIdentity(change.identity)) return@withLock
                        val home = (_state.value as? Loadable.Ready)?.value ?: return@withLock
                        val rows = visibleRows.mapNotNull { row ->
                            if (row.kind is HomeRows.Kind.UpNext) {
                                if (upNext.isEmpty()) null else HomeRowData(row)
                            } else home.rows.firstOrNull { it.row.id == row.id }
                        }
                        _state.value = Loadable.Ready(home.copy(upNext = upNext, rows = rows))
                    }
                }
            }
        }
        preconnect.warm()
        load()
        // 自定义首页保存后就地重排（iOS 写 LibraryHomePrefs.shared 同效）
        viewModelScope.launch {
            HomePrefsBus.version.drop(1).collect { load() }
        }
        // 别处打了收藏 / 已看（详情页、刷片页）也重拉：否则这一页还是进页时那份快照，
        // 「点了收藏回首页没有新封面、进「查看全部」却有」（实机反馈）
        viewModelScope.launch {
            io.movieclaw.android.core.model.LibraryMarksBus.version.drop(1).collect { load() }
        }
    }

    fun load() = viewModelScope.launch { loadOnce() }

    /** 下拉刷新：内容和 `load()` 一样，只是多一个「转圈到新数据到齐」的状态 */
    fun refresh() {
        viewModelScope.launch {
            _refreshing.value = true
            try {
                loadOnce()
            } finally {
                _refreshing.value = false
            }
        }
    }

    private suspend fun loadOnce() = loadMutex.withLock { loadOnceUnlocked() }

    private suspend fun loadOnceUnlocked() {
        // coroutineScope（不是 run）：下面要 async 并发拉，见「五路同发」
        val t0 = android.os.SystemClock.elapsedRealtime()
        coroutineScope {
            // 已经有内容时**不要**回到 Loading：那会把整页换成转圈，还会把滚动位置打回顶部
            // （收藏一下、切回首页就「闪一下 + 跳回顶部」）。iOS 的 LibraryHomeStore 同样
            // 保留旧数据，新数据到了再整体替换——只有首次进来才显示转圈。
            if (_state.value !is Loadable.Ready) _state.value = Loadable.Loading
            val origin = repository.ui.value.origin
            if (origin == null) {
                _state.value = Loadable.Failed("尚未连接服务器")
                return@coroutineScope
            }
            // 快照先行（iOS `LibraryHomeStore` 的 stale-while-revalidate）：不是首次进来时先什么都不动；
            // 首次则把上次离开时的完整页面**立刻**画出来，网络只决定「多久换成最新的」
            val owner = "${origin}|${repository.ui.value.session?.username.orEmpty()}"
            if (_state.value !is Loadable.Ready) {
                snapshotStore.read(owner)?.let { snap ->
                    _state.value = Loadable.Ready(homeFromSnapshot(snap))
                    android.util.Log.i(
                        "McPerf",
                        "媒体库首屏：快照先画（库 ${snap.libraries.size} 个 · 行 ${snap.rows.size} 条）",
                    )
                }
            }
            try {
                val api = apiFactory.forOrigin(origin)
                // ── 五路同发（iOS `LibraryHomeStore.load` 同款）：原来是「库 → 接下来继续 →
                //    收藏 → 偏好 → 合集」五跳串行，冷启动每次都在按 RTT 累加；这几份互不依赖，
                //    一起发，RTT 只付一次 ──
                val librariesDeferred = async { api.libraries().dataOrThrow() }
                val upNextDeferred = async {
                    // 「接下来继续」与「我的收藏」取不到就当空行，不挡住首屏其它内容
                    runCatching { api.upNext(limit = 24).dataOrThrow().items }.getOrDefault(emptyList())
                }
                // 「我的收藏」横滚行：前 20 条、没看完的提前（服务端 /playback/favorites 的
                // 首页口径，与 iOS LibraryHomeStore / 网页首页同一组参数）。
                val favoritesDeferred = async {
                    runCatching {
                        api.favorites(limit = 20, offset = 0, unwatchedFirst = true).dataOrThrow()
                    }.getOrNull()
                }
                val prefsDeferred = async { runCatching { api.uiPreferences().dataOrThrow() }.getOrNull() }
                val collectionsDeferred = async { runCatching { api.collections().dataOrThrow() }.getOrDefault(emptyList()) }
                val hiddenUpNext = runCatching { resumeBarPrefs.hiddenIds() }.getOrDefault(emptySet())

                val libraries = librariesDeferred.await()
                val upNext = upNextDeferred.await()
                val favorites = favoritesDeferred.await()
                // ── 行清单（ui.preferences.home.rows）──
                // 合并规则与网页 / iOS 同一份（HomeRows.build）：存过的行按存的顺序在前，
                // 没存过的内置行与每库默认行补在后面；指向已删库 / 不可见合集的行静默丢弃。
                val prefs = prefsDeferred.await()
                val collections = collectionsDeferred.await()
                val rows = HomeRows.build(prefs?.home?.rows.orEmpty(), libraries, collections)
                    .filterNot { it.hidden }
                visibleRows = rows
                // 「按类型找电影 / 剧集」色块（出厂内置行，紧跟「我的媒体库」）：每种有库的类型拉一次
                // /libraries/kinds/{kind}/genres（封面 + 部数），拉不到就当这一行不出现
                // 类型色块、每行条目、跨库行全部**并行**（iOS 同款：各行在库与合集一到就同发）
                val genresDeferred = rows.mapNotNull { r -> (r.kind as? HomeRows.Kind.Genres)?.kind }
                    .distinct()
                    .associateWith { kind ->
                        async { runCatching { api.libraryKindGenres(kind).dataOrThrow() }.getOrDefault(emptyList()) }
                    }
                val genresByKind = genresDeferred.mapValues { it.value.await() }.filterValues { it.isNotEmpty() }
                val rowItems = buildMap {
                    val pending = mutableListOf<Pair<String, kotlinx.coroutines.Deferred<List<LibraryItemView>>>>()
                    rows.forEach { r ->
                        when (val k = r.kind) {
                            is HomeRows.Kind.Library -> {
                                // 「最近观看」行只要播过的（度量档把没播过的沉底，取 20 条时
                                // 看过的排完就轮到没播过的——首页这一行不能这样，w=seen）；
                                // 「只看没看过的」与它互斥，HomeRows 合并时已经保证不会同时成立
                                val watch = when {
                                    k.sort == "last_played" -> "seen"
                                    k.unwatched -> "unwatched"
                                    else -> null
                                }
                                pending += r.id to async {
                                    runCatching {
                                        api.libraryItems(
                                            libraryId = k.library.id,
                                            limit = ROW_ITEM_COUNT,
                                            sort = k.sort,
                                            order = HomeRows.preset(k.sort).direction?.let {
                                                if (!k.reversed) null else if (it.naturalAsc) "desc" else "asc"
                                            },
                                            watch = watch,
                                        ).dataOrThrow()
                                    }.getOrDefault(emptyList())
                                }
                            }
                            is HomeRows.Kind.Collection -> {
                                pending += r.id to async {
                                    runCatching {
                                        api.collectionItems(
                                            id = k.collection.id,
                                            limit = ROW_ITEM_COUNT,
                                            sort = k.sort,
                                            order = HomeRows.preset(k.sort).direction?.let {
                                                if (!k.reversed) null else if (it.naturalAsc) "desc" else "asc"
                                            },
                                        ).dataOrThrow()
                                    }.getOrDefault(emptyList())
                                }
                            }
                            else -> Unit
                        }
                    }
                    // 全部发出去之后才逐个收，行与行之间不再互相等
                    pending.forEach { (id, deferred) -> put(id, deferred.await()) }
                }
                // 行清单里一条都取不到内容时不留空标题：库行 / 合集行只保留有条目的那些
                val rowData = buildRowData(
                    rows = rows,
                    upNext = upNext,
                    favoritesNonEmpty = !favorites?.items.isNullOrEmpty(),
                    libraries = libraries,
                    genresByKind = genresByKind,
                    rowItems = rowItems,
                )
                // ── 按类型的跨库行（「全部电影 · 最近添加」）──
                // 本端自己加的一段（不在行清单里，排在清单之后）：可见 ∩ 该类型 ∩
                // 没被排除出首页的库至少两个才出这一行；再由服务端概况确认有作品（跨库去重）。
                // 照片库不做（另一种形态，见 library-home-perspective.md §8）。
                val kindRows = buildList {
                    val pending = mutableListOf<kotlinx.coroutines.Deferred<KindRow?>>()
                    listOf("movie" to "电影", "tv" to "剧集", "video" to "其他视频").forEach { (kind, label) ->
                        val members = libraries.filter {
                            it.viewerAccess && !it.excludeFromHome && it.kind == kind
                        }
                        if (members.size < 2) return@forEach
                        pending += async {
                            val summary = runCatching { api.libraryKindSummary(kind).dataOrThrow() }.getOrNull()
                                ?: return@async null
                            if (summary.itemCount <= 0) return@async null
                            val items = runCatching {
                                api.libraryKindItems(kind = kind, sort = "added_at", limit = 12).dataOrThrow()
                            }.getOrDefault(emptyList())
                            if (items.isEmpty()) return@async null
                            KindRow(kind = kind, label = label, total = summary.itemCount, libraryCount = members.size, items = items)
                        }
                    }
                    pending.forEach { row -> row.await()?.let { add(it) } }
                }
                // 冷启动分段打点（等价 iOS PerfTrace 的页面数据就绪）：给后续优化做基准
                android.util.Log.i(
                    "McPerf",
                    "媒体库首屏：全部=${android.os.SystemClock.elapsedRealtime() - t0}ms " +
                        "行=${rowData.size} 跨库行=${kindRows.size} 首屏=${_state.value !is Loadable.Ready}",
                )
                _state.value = Loadable.Ready(
                    LibraryHome(
                        libraries = libraries,
                        upNext = upNext,
                        favorites = favorites?.items.orEmpty(),
                        favoriteTotal = favorites?.total ?: 0,
                        rows = rowData,
                        kindRows = kindRows,
                        hiddenUpNext = hiddenUpNext,
                        genresByKind = genresByKind,
                    ),
                )
                // 这次拉成功的数据存成本机快照（下次冷启动先画它；写盘按指纹去重）
                snapshotStore.write(
                    owner,
                    io.movieclaw.android.core.session.LibraryHomeSnapshot(
                        libraries = libraries,
                        collections = collections,
                        upNext = upNext,
                        favorites = favorites?.items.orEmpty(),
                        favoriteTotal = favorites?.total ?: 0,
                        rows = prefs?.home?.rows.orEmpty(),
                        rowItems = rowItems,
                        genresByKind = genresByKind,
                        kindRows = kindRows,
                    ),
                )
            } catch (e: Exception) {
                if (_state.value is Loadable.Ready) {
                    // 断网冷启动：快照照常显示，只挂一句提示（iOS：各页挂自己的「与后端通信失败」）
                    feedback.error("与后端通信失败")
                } else {
                    _state.value = Loadable.Failed(friendlyMessage(e))
                }
            }
        }
    }

    /** 快照 → 首页数据：行清单用 `HomeRows.build` 重建（与在线路径同一份合并口径），行条目按 id 对上 */
    private fun homeFromSnapshot(snap: io.movieclaw.android.core.session.LibraryHomeSnapshot): LibraryHome {
        val rows = HomeRows.build(snap.rows, snap.libraries, snap.collections).filterNot { it.hidden }
        visibleRows = rows
        return LibraryHome(
            libraries = snap.libraries,
            upNext = snap.upNext,
            favorites = snap.favorites,
            favoriteTotal = snap.favoriteTotal,
            rows = buildRowData(
                rows = rows,
                upNext = snap.upNext,
                favoritesNonEmpty = snap.favorites.isNotEmpty(),
                libraries = snap.libraries,
                genresByKind = snap.genresByKind,
                rowItems = snap.rowItems,
            ),
            kindRows = snap.kindRows,
            genresByKind = snap.genresByKind,
        )
    }

    /** 行清单 → 首页要渲染的行（在线与快照两条路共用，避免口径分叉） */
    private fun buildRowData(
        rows: List<HomeRows.Row>,
        upNext: List<UpNextItem>,
        favoritesNonEmpty: Boolean,
        libraries: List<LibraryView>,
        genresByKind: Map<String, List<io.movieclaw.android.core.model.LibraryKindGenreView>>,
        rowItems: Map<String, List<LibraryItemView>>,
    ): List<HomeRowData> = rows.mapNotNull { r ->
        when (r.kind) {
            is HomeRows.Kind.UpNext -> if (upNext.isEmpty()) null else HomeRowData(r)
            is HomeRows.Kind.Favorites -> if (!favoritesNonEmpty) null else HomeRowData(r)
            is HomeRows.Kind.Libraries -> if (libraries.isEmpty()) null else HomeRowData(r)
            is HomeRows.Kind.Genres -> {
                val genres = genresByKind[r.kind.kind].orEmpty()
                if (genres.isEmpty()) null else HomeRowData(r)
            }
            is HomeRows.Kind.Library, is HomeRows.Kind.Collection ->
                rowItems[r.id].orEmpty().takeIf { it.isNotEmpty() }?.let { HomeRowData(r, it) }
        }
    }

    /** ✕ 叉掉一条「接下来继续」（本机偏好；key 带上当时的 lastPlayedAt，这台设备再播一次自然恢复） */
    fun hideUpNext(item: UpNextItem) {
        val key = io.movieclaw.android.core.playback.ResumeBarPrefs.keyOf(
            item.mediaItemId, item.seasonNumber, item.episodeNumber, item.lastPlayedAt,
        )
        viewModelScope.launch {
            resumeBarPrefs.hide(key)
            val current = (_state.value as? Loadable.Ready)?.value ?: return@launch
            _state.value = Loadable.Ready(current.copy(hiddenUpNext = current.hiddenUpNext + key))
        }
    }

    private companion object {
        /** 每个库行 / 合集行取多少条（与网页 RECENT_COUNT 同值） */
        const val ROW_ITEM_COUNT = 20
    }
}


/** 行清单里的一行 + 已经取回来的条目（库行 / 合集行） */
data class HomeRowData(
    val row: HomeRows.Row,
    val items: List<LibraryItemView> = emptyList(),
)

/**
 * 媒体库首屏的数据。
 *
 * 页面 = 标题统计 + 按 `ui.preferences.home.rows` 合并出的行清单：
 * 接下来继续 / 我的收藏 / 我的媒体库 / 每库一行 / 合集行——顺序、显隐、名字、排序
 * 全部来自偏好（`HomeRows.build`，与网页 / iOS 同一份合并逻辑）。
 * 「按类型的跨库行」是本端自己加的一段（不在行清单里，排在清单之后，不参与自定义）。
 */
data class LibraryHome(
    val libraries: List<LibraryView> = emptyList(),
    val upNext: List<UpNextItem> = emptyList(),
    /** 「我的收藏」横滚行（前 20 条、未看完的提前）；空 = 这一行不出现 */
    val favorites: List<FavoriteItemView> = emptyList(),
    val favoriteTotal: Int = 0,
    /** 行清单（已按偏好排序、已滤掉 hidden） */
    val rows: List<HomeRowData> = emptyList(),
    /** 「全部电影 · 最近添加」这类跨库行：同类型可见库 ≥2 个且有作品时才有 */
    val kindRows: List<KindRow> = emptyList(),
    /** 本机叉掉的「接下来继续」条目（ResumeBarPrefs） */
    val hiddenUpNext: Set<String> = emptySet(),
    /** 「按类型找电影 / 剧集」色块行（出厂内置）的数据：kind（movie / tv）→ 类型卡列表 */
    val genresByKind: Map<String, List<io.movieclaw.android.core.model.LibraryKindGenreView>> = emptyMap(),
)

/**
 * 全幅剧照分类卡（v0.32 跨端规范 `docs/design/genre-cinematic-cards.md` 的手机规格）：
 * 卡片 196 × 124.6（保留 236:150），圆角 / 字号 / 边距 = 基准值 × 196/236
 * （Web 手机 / iPhone / macOS 同档）。
 *
 * 「自然通透」——剧照不整体压暗，只在文字所在处压暗：全宽底部一层很轻的底
 * （0.28、跨度 0.54）+ 文字所在的左下椭圆暗区（0.5、直径 1.56×宽 / 1.44×高、
 * 中心横向 12% 底部），两层都走 smoothstep 色标（没有可见的渐变分界）；压暗的
 * 那一截饱和度 ×1.2（读起来是「暗」而不是「灰」）；顶边 0.5dp 内高光往下淡出；
 * 不再有右下角箭头。点的落点是带 g 的跨库墙。
 */
@Composable
private fun GenreTileCard(
    genre: io.movieclaw.android.core.model.LibraryKindGenreView,
    kind: String,
    origin: String?,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    // 各端共用一条缩放规则：手机端 = 196 / 236
    val scale = 196f / 236f
    val corner = 10.dp
    val density = LocalDensity.current
    // 标题投影：黑 32%、半径 4、下移 1（Web `0 1px 4px #00000052` / iOS radius 4, y 1）
    val shadowRadius = with(density) { 4.dp.toPx() }
    val shadowOffsetY = with(density) { 1.dp.toPx() }
    Box(
        modifier
            .width(196.dp)
            .height(124.6.dp)
            .clip(RoundedCornerShape(corner))
            .background(Color(0xFF202023))
            .clickable(onClick = onClick),
    ) {
        RemoteImage(
            url = genre.coverUrl,
            origin = origin,
            contentDescription = genre.label,
            modifier = Modifier.fillMaxSize(),
            // 缺图 / 加载失败：中性深灰渐变 + 胶片符号（Web fallback / iOS 缺图同款）
            fallback = { GenreCoverFallback(scale) },
        )
        // 「压暗区提饱和」：同一张图 ×1.2 叠画（Coil 内存缓存命中，不重复下载），
        // 蒙版限定在底部——0→25% 全生效、60% 处淡出（同 Web mask-image / iOS mask）
        RemoteImage(
            url = genre.coverUrl,
            origin = origin,
            contentDescription = null,
            colorFilter = ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(1.2f) }),
            fallback = {},
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    drawRect(
                        brush = Brush.verticalGradient(
                            0f to Color.Transparent,
                            0.4f to Color.Transparent,
                            0.75f to Color.Black,
                            1f to Color.Black,
                        ),
                        blendMode = BlendMode.DstIn,
                    )
                },
        )
        // 文字保护一：全宽底部一层很轻的底（右上一半保持剧照原本的亮度）
        Box(
            Modifier.fillMaxSize().drawBehind {
                drawRect(Brush.verticalGradient(colorStops = easedBlackStopsFromBottom(0.28f, 0.54f)))
            },
        )
        // 文字保护二：文字所在的左下再叠一团椭圆暗区
        Box(
            Modifier.fillMaxSize().drawBehind {
                val rx = size.width * 1.56f / 2f
                val ry = size.height * 1.44f / 2f
                withTransform({
                    translate(size.width * 0.12f, size.height)
                    scale(1f, ry / rx, pivot = Offset.Zero)
                }) {
                    drawCircle(
                        brush = Brush.radialGradient(
                            colorStops = easedBlackStops(0.5f, 1f),
                            center = Offset.Zero,
                            radius = rx,
                        ),
                        radius = rx,
                        center = Offset.Zero,
                    )
                }
            },
        )
        Text(
            genre.label,
            fontSize = (24f * scale).sp, fontWeight = FontWeight.SemiBold, color = Color.White,
            letterSpacing = 0.2.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = TextStyle(
                shadow = Shadow(
                    color = Color.Black.copy(alpha = 0.32f),
                    offset = Offset(0f, shadowOffsetY),
                    blurRadius = shadowRadius,
                ),
            ),
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(start = 18.dp * scale, end = 36.dp * scale, bottom = 38.dp * scale),
        )
        Text(
            "${genre.count} 部" + if (kind == "tv") "剧集" else "电影",
            fontSize = 11.sp, color = Color.White.copy(alpha = 0.72f),
            // 等宽数字（Web `tabular-nums` / iOS `monospacedDigit`）
            style = TextStyle(fontFeatureSettings = "tnum"),
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(start = 18.dp * scale, bottom = 17.dp * scale),
        )
        // 顶边内高光往下淡出：卡片有厚度，不像贴在黑底上的平图（不再描整圈 7% 白边）
        Box(
            Modifier
                .matchParentSize()
                .drawWithContent {
                    drawContent()
                    val stroke = 0.5.dp.toPx()
                    val half = stroke / 2f
                    drawRoundRect(
                        brush = Brush.verticalGradient(
                            0f to Color.White.copy(alpha = 0.12f),
                            0.5f to Color.White.copy(alpha = 0.025f),
                            1f to Color.White.copy(alpha = 0.025f),
                        ),
                        topLeft = Offset(half, half),
                        size = Size(size.width - stroke, size.height - stroke),
                        cornerRadius = CornerRadius((corner.toPx() - half).coerceAtLeast(0f)),
                        style = Stroke(width = stroke),
                    )
                },
        )
    }
}

/**
 * smoothstep 缓动的黑色色标（与 Web `genre-tile.tsx` 的 `easedStops` / iOS
 * `GenreCardFace.easedStops` 同曲线）：位置 t·span、不透明度 max·(1 − t²(3−2t))，
 * 到 span 处落成全透明。用于径向渐变（0 = 圆心）。
 */
private fun easedBlackStops(maxOpacity: Float, span: Float): Array<Pair<Float, Color>> =
    Array(9) { i ->
        val t = i / 8f
        (t * span) to Color.Black.copy(alpha = maxOpacity * (1f - t * t * (3f - 2f * t)))
    }

/** 同上，但从**底部**算起（转成 Compose 纵向渐变的从顶往下坐标） */
private fun easedBlackStopsFromBottom(maxOpacity: Float, span: Float): Array<Pair<Float, Color>> =
    Array(9) { i ->
        val t = 1f - i / 8f
        (1f - t * span) to Color.Black.copy(alpha = maxOpacity * (1f - t * t * (3f - 2f * t)))
    }

/** 类型卡缺图 / 加载失败的兜底：中性深灰径向渐变 + 右上角胶片符号（Web fallback / iOS 缺图同款） */
@Composable
private fun GenreCoverFallback(scale: Float) {
    Box(
        Modifier
            .fillMaxSize()
            .drawBehind {
                // Web：radial-gradient(ellipse at 80% 0%, #45454b, #1d1d20 65%)
                drawRect(
                    Brush.radialGradient(
                        colors = listOf(Color(0xFF45454B), Color(0xFF1D1D20)),
                        center = Offset(size.width * 0.8f, 0f),
                        radius = size.width * 1.1f,
                    )
                )
            },
        contentAlignment = Alignment.TopEnd,
    ) {
        Icon(
            Icons.Rounded.Movie, contentDescription = null,
            tint = Color.White.copy(alpha = 0.13f),
            modifier = Modifier
                .padding(top = 20.dp * scale, end = 20.dp * scale)
                .size(45.dp * scale),
        )
    }
}

/**
 * 媒体库 —— 按移动端网页实测重排（此前是一个库列表网格，与网页完全不是一页）：
 *   统计行（14px 62%）→「接下来继续」（200×113 卡）→「我的媒体库」（230×110 拼贴卡 +
 *   居中库名 + 徽标）→ 每个库的「最近添加的<库名>」（126×189 海报行）。
 *   分区标题 17/600，行尾动作 14px 62%，箭头只在能滚时出现。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(
    onOpenLibrary: (Long, String) -> Unit,
    onOpenItem: (Long, Long) -> Unit,
    onPlay: (io.movieclaw.android.core.playback.PlayTarget) -> Unit = {},
    onOpenSearch: () -> Unit = {},
    onOpenManage: () -> Unit = {},
    onOpenFavorites: () -> Unit = {},
    onOpenCollections: () -> Unit = {},
    /** 「全部电影」类型行点「查看全部」进跨库墙 */
    onOpenKind: (String) -> Unit = {},
    /** 「按类型找电影 / 剧集」色块点进带类型的跨库墙 */
    onOpenGenre: (String, String) -> Unit = { _, _ -> },
    /** 顶栏最右「▶ 片段」→ 刷片页（docs/design/reels.md） */
    onOpenReels: () -> Unit = {},
    /** ⋯ 菜单「自定义首页」→ 原生行清单编辑器（Web `/library/customize` 的对应页） */
    onOpenCustomize: () -> Unit = {},
    /** 首页合集行点标题 / 卡片进合集详情的落点（ref 传合集 id，与「全部合集」页同一形） */
    onOpenCollection: (Long, String) -> Unit = { _, _ -> },
    vm: LibraryViewModel = hiltViewModel(),
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val refreshing by vm.refreshing.collectAsStateWithLifecycle()
    var moreOpen by remember { mutableStateOf(false) }
    val libScroll = androidx.compose.foundation.rememberScrollState()
    io.movieclaw.android.core.designsystem.TrackTabBarMinimize(libScroll)
    val origin = vm.origin

    Box(Modifier.fillMaxSize().background(Bg)) {
        when (val s = state) {
            Loadable.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            is Loadable.Failed -> ErrorPane(message = s.message, onRetry = vm::load)
            is Loadable.Ready -> {
                val home = s.value
                // 下拉刷新（iOS `.refreshable`）：旧内容留着，转圈到新数据到齐。
                // 指示器下沉到悬浮顶栏之下——默认位置（屏幕最顶）正好被顶栏盖住，看着像「没反应」
                val pullState = androidx.compose.material3.pulltorefresh.rememberPullToRefreshState()
                androidx.compose.material3.pulltorefresh.PullToRefreshBox(
                    isRefreshing = refreshing,
                    onRefresh = { vm.refresh() },
                    state = pullState,
                    modifier = Modifier.fillMaxSize(),
                    indicator = {
                        androidx.compose.material3.pulltorefresh.PullToRefreshDefaults.Indicator(
                            state = pullState,
                            isRefreshing = refreshing,
                            containerColor = androidx.compose.material3.MaterialTheme.colorScheme.surfaceVariant,
                            modifier = Modifier
                                .align(androidx.compose.ui.Alignment.TopCenter)
                                .padding(
                                    top = androidx.compose.foundation.layout.WindowInsets.statusBars
                                        .asPaddingValues().calculateTopPadding() +
                                        McMetrics.topBarHeight + 6.dp,
                                ),
                        )
                    },
                ) {
                Column(
                    Modifier
                        .fillMaxSize()
                        .verticalScroll(libScroll)
                        // 液态底栏的背景模糊源（Local 为 null 时原样返回，零代价）
                        .tabGlassSource()
                        // iOS 根页是 inlineLarge 大标题：标题占 52dp 之后统计行再往下 4dp
                        .padding(top = McMetrics.topBarHeight + 2.dp, bottom = McTabBarContentPadding),
                ) {
                    // 大标题（iOS inlineLarge：34/700，左对齐 16）
                    Text(
                        "媒体库",
                        fontSize = 34.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.4).sp,
                        color = TextPrimary,
                        modifier = Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 2.dp),
                    )
                    StorageStatsLine(home)

                    // 行清单：顺序 / 显隐 / 名字 / 排序全部来自 ui.preferences.home.rows
                    // （自定义首页可改；合并与裁剪见 HomeRows.build）
                    home.rows.forEach { data ->
                        when (val k = data.row.kind) {
                            is HomeRows.Kind.UpNext -> {
                                Spacer(Modifier.height(McMetrics.sectionTop))
                                SectionHeader(data.row.title)
                                Spacer(Modifier.height(McMetrics.sectionBottom))
                                LazyRow(
                                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                                    horizontalArrangement = Arrangement.spacedBy(McMetrics.rowSpacing),
                                ) {
                                    items(
                                        home.upNext.filterNot { up ->
                                            // key 含 lastPlayedAt：这台设备再播一次时间就变，叉掉的自然回来
                                            io.movieclaw.android.core.playback.ResumeBarPrefs.keyOf(
                                                up.mediaItemId, up.seasonNumber, up.episodeNumber, up.lastPlayedAt,
                                            ) in home.hiddenUpNext
                                        },
                                        key = { it.mediaItemId },
                                    ) { item ->
                                        // 分集卡：第二行是「S1E3 · 集名」，电影才是年份（iOS UpNextCard 同款）
                                        val isEpisode = item.kind == "tv"
                                        val context = if (isEpisode) {
                                            listOfNotNull(
                                                "S${item.seasonNumber}E${item.episodeNumber}",
                                                item.episodeTitle?.takeIf { it.isNotBlank() },
                                            ).joinToString(" · ")
                                        } else {
                                            item.year?.toString()
                                        }
                                        val clockText = if (item.positionMs > 0 && item.durationMs > 0) {
                                            "${McFormat.clock(item.positionMs)} / ${McFormat.clock(item.durationMs)}"
                                        } else {
                                            null
                                        }
                                        val ago = McFormat.relativeFromNow(item.lastPlayedAt).orEmpty()
                                        val stateLabel = when {
                                            item.advanced -> "${ago}看完上一集"
                                            // 有「已播/总时长」时那一行已经说明了进度，第三行只留时间
                                            item.positionMs > 0 && item.progressPercent > 0 && clockText == null ->
                                                "${ago}看到 ${item.progressPercent}%"
                                            item.positionMs > 0 -> "${ago}看过一段"
                                            else -> "${ago}打开过"
                                        }
                                        ContinueWatchingCard(
                                            imageUrl = item.episodeStillUrl ?: item.backdropUrl ?: item.posterUrl,
                                            origin = origin,
                                            title = item.title,
                                            context = context,
                                            stateLabel = stateLabel,
                                            clockText = clockText,
                                            progressPercent = item.progressPercent.takeIf { it > 0 && item.positionMs > 0 },
                                            remainingEpisodes = item.unwatchedAheadCount,
                                            onClick = {
                                                onPlay(
                                                    PlayTargetFactory.fromUpNext(
                                                        item = item,
                                                        subtitle = context,
                                                    )
                                                )
                                            },
                                            onClose = { vm.hideUpNext(item) },
                                        )
                                    }
                                }
                            }

                            // ── 我的收藏（iOS LibraryHomeView `.favorites`）──
                            // 每格是海报 + 收藏层级小字（整季 / 单集才解释，整剧与电影不说）；
                            // 行尾动作「查看全部 N 部」进收藏墙（N 是去重后的作品总数，不是这一行的条数）。
                            is HomeRows.Kind.Favorites -> {
                                Spacer(Modifier.height(McMetrics.sectionTop))
                                SectionHeader(
                                    title = data.row.title,
                                    actionText = if (home.favoriteTotal > 0) "查看全部 ${home.favoriteTotal} 部" else "查看全部",
                                    onAction = onOpenFavorites,
                                )
                                Spacer(Modifier.height(McMetrics.sectionBottom))
                                LazyRow(
                                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                                    horizontalArrangement = Arrangement.spacedBy(McMetrics.rowSpacing),
                                ) {
                                    items(home.favorites, key = { it.mediaItemId }) { fav ->
                                        val level = favoriteLevelLabel(
                                            fav.kind,
                                            fav.favoriteSeasonNumber,
                                            fav.favoriteEpisodeNumber,
                                        )
                                        PosterCard(
                                            imageUrl = fav.posterUrl ?: fav.backdropUrl,
                                            origin = origin,
                                            title = fav.title,
                                            meta = listOfNotNull(fav.year?.toString(), level).joinToString(" · ")
                                                .takeIf { it.isNotBlank() },
                                            rating = fav.rating?.takeIf { it > 0f },
                                            modifier = Modifier.width(McMetrics.rowCardWidth),
                                            onClick = { onOpenItem(fav.libraryId ?: -1L, fav.mediaItemId) },
                                        )
                                    }
                                }
                            }

                            is HomeRows.Kind.Libraries -> {
                                Spacer(Modifier.height(McMetrics.sectionTop))
                                SectionHeader("我的媒体库")
                                Spacer(Modifier.height(McMetrics.sectionBottom))
                                LazyRow(
                                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                                    horizontalArrangement = Arrangement.spacedBy(McMetrics.rowSpacing),
                                ) {
                                    items(home.libraries, key = { it.id }) { lib ->
                                        LibraryCollageCard(
                                            library = lib,
                                            // iOS 用服务端合成的「氛围光货架」封面（与 Jellyfin 兼容层同一张图）
                                            coverUrl = origin?.trimEnd('/')?.let { "$it/api/v1/libraries/${lib.id}/cover" },
                                            origin = origin,
                                            onClick = { onOpenLibrary(lib.id, lib.name) },
                                        )
                                    }
                                }
                            }

                            // 库行 / 合集行：卡片形态与按类型行完全一样，标题用行名（可被自定义改名）
                            is HomeRows.Kind.Library, is HomeRows.Kind.Collection -> {
                                Spacer(Modifier.height(McMetrics.sectionTop))
                                val targetLibraryId = (k as? HomeRows.Kind.Library)?.library?.id
                                SectionHeader(
                                    title = data.row.title,
                                    actionText = "查看全部",
                                    onAction = {
                                        when (k) {
                                            is HomeRows.Kind.Library -> onOpenLibrary(k.library.id, k.library.name)
                                            is HomeRows.Kind.Collection -> onOpenCollection(k.collection.id, k.collection.name)
                                            else -> Unit
                                        }
                                    },
                                )
                                Spacer(Modifier.height(McMetrics.sectionBottom))
                                LazyRow(
                                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                                    horizontalArrangement = Arrangement.spacedBy(McMetrics.rowSpacing),
                                ) {
                                    items(data.items, key = { "${data.row.id}-${it.mediaItemId}" }) { item ->
                                        PosterCard(
                                            imageUrl = item.posterUrl ?: item.backdropUrl,
                                            origin = origin,
                                            title = item.title,
                                            meta = item.year?.toString(),
                                            rating = item.rating?.takeIf { it > 0f },
                                            modifier = Modifier.width(McMetrics.rowCardWidth),
                                            onClick = { onOpenItem(item.libraryId ?: targetLibraryId ?: -1L, item.mediaItemId) },
                                        )
                                    }
                                }
                            }

                            // ── 按类型找电影 / 剧集（出厂内置行，紧跟「我的媒体库」）──
                            // 全幅剧照分类卡（Shared GenreCardFace 手机规格）；点进带 g 的跨库墙
                            is HomeRows.Kind.Genres -> {
                                val genres = home.genresByKind[k.kind].orEmpty()
                                if (genres.isNotEmpty()) {
                                    Spacer(Modifier.height(McMetrics.sectionTop))
                                    SectionHeader(data.row.title)
                                    Spacer(Modifier.height(McMetrics.sectionBottom))
                                    LazyRow(
                                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                                    ) {
                                        items(genres, key = { "genre-${k.kind}-${it.value}" }) { genre ->
                                            GenreTileCard(
                                                genre = genre,
                                                kind = k.kind,
                                                origin = origin,
                                                onClick = { onOpenGenre(k.kind, genre.value) },
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 按类型的跨库行（本端自有的一段，不在行清单里）：同类型可见库 ≥2 个且有作品时才有
                    home.kindRows.forEach { row ->
                        Spacer(Modifier.height(McMetrics.sectionTop))
                        SectionHeader(
                            title = "全部${row.label} · 最近添加",
                            actionText = "查看全部",
                            onAction = { onOpenKind(row.kind) },
                        )
                        Spacer(Modifier.height(McMetrics.sectionBottom))
                        LazyRow(
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                            horizontalArrangement = Arrangement.spacedBy(McMetrics.rowSpacing),
                        ) {
                            items(row.items, key = { "kind-${row.kind}-${it.mediaItemId}" }) { item ->
                                PosterCard(
                                    imageUrl = item.posterUrl ?: item.backdropUrl,
                                    origin = origin,
                                    title = item.title,
                                    meta = item.year?.toString(),
                                    rating = item.rating?.takeIf { it > 0f },
                                    modifier = Modifier.width(McMetrics.rowCardWidth),
                                    onClick = { onOpenItem(item.libraryId ?: -1L, item.mediaItemId) },
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                }
                }
            }
        }

        McTopBar(
            variant = McTopBarVariant.Root,
            title = "",   // 大标题在内容区（iOS inlineLarge），顶栏只留两组动作钮
            modifier = Modifier.align(Alignment.TopCenter),
        ) {
            // 顶栏右侧成组（iOS `▶ ⋯ · 搜索` 两组）：先撑开，「▶ ⋯」一颗玻璃胶囊、
            // 每钮位 44 宽拉开间距，再用一段固定间隔接搜索圆钮（2026-10-05 用户反馈：
            // 原先把胶囊放最左、搜索顶最右，两钮太挤、离放大镜又太远）
            Spacer(Modifier.weight(1f))
            Row(
                Modifier
                    .height(36.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(GlassCapsule)
                    .border(1.dp, LineSoft, RoundedCornerShape(999.dp)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier
                        .width(44.dp)
                        .fillMaxHeight()
                        .clip(RoundedCornerShape(999.dp))
                        .clickable { onOpenReels() },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Rounded.PlayCircle,
                        contentDescription = "片段",
                        tint = TextPrimary,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Box(
                    Modifier
                        .width(44.dp)
                        .fillMaxHeight()
                        .clip(RoundedCornerShape(999.dp))
                        .clickable { moreOpen = true },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Rounded.MoreHoriz,
                        contentDescription = "媒体库操作",
                        tint = TextPrimary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            // 搜索（入口口径是「任一搜索分区可用」：影视 / 资源 / 媒体库）；固定间隔成第二组
            if (io.movieclaw.android.core.session.LocalSearchAccess.current.canOpenSearch) {
                Spacer(Modifier.width(10.dp))
                McNavButton(Icons.Rounded.Search, contentDescription = "搜索", onClick = onOpenSearch)
            }
        }

        // ⋯ 菜单：自定义首页 / 全部合集 / 管理媒体库（iOS library-more 三项）
        if (moreOpen) {
            Box(Modifier.fillMaxSize().clickable { moreOpen = false })
            Column(
                Modifier
                    .align(Alignment.TopEnd)
                    .statusBarsPadding()
                    .padding(end = McMetrics.pagePadding, top = 44.dp)
                    .width(190.dp)
                    .clip(RoundedCornerShape(McMetrics.menuRadius))
                    .background(MenuSurface)
                    .border(1.dp, LineSoft, RoundedCornerShape(McMetrics.menuRadius))
                    .padding(4.dp),
            ) {
                MenuItem("自定义首页") {
                    moreOpen = false
                    // 原生行清单编辑器（Web `/library/customize` 的对应页）：
                    // 此前是 ACTION_VIEW 甩给浏览器，用户要的是原生页
                    onOpenCustomize()
                }
                MenuItem("全部合集") { moreOpen = false; onOpenCollections() }
                // 媒体库管理是超管页面（Web accessiblePathFor / iOS .libraryManage 同口径）
                if (io.movieclaw.android.core.session.LocalPermissions.current.canManageLibraries) {
                    MenuItem("管理媒体库") { moreOpen = false; onOpenManage() }
                }
            }
        }
    }
}

@Composable
private fun MenuItem(text: String, onClick: () -> Unit) {
    Text(
        text,
        style = McType.body,
        color = TextPrimary,
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 11.dp),
    )
}

/**
 * 统计行 —— iOS `libraryStatsSummary`：只聚合服务端随库返回的**预算快照**，
 * 不拿「最近添加那几条」去算（那样电影/剧集数与占用空间会全错）。
 * 文案：`N 个媒体库 · X 部电影 · Y 部剧集[ · Z 个其他视频] · 共占用 S 存储空间`
 */
@Composable
private fun StorageStatsLine(home: LibraryHome) {
    val movies = home.libraries.filter { it.kind == "movie" }.sumOf { it.stats.itemCount }
    val series = home.libraries.filter { it.kind == "tv" }.sumOf { it.stats.itemCount }
    val others = home.libraries.filter { it.kind != "movie" && it.kind != "tv" }.sumOf { it.stats.itemCount }
    val totalBytes = home.libraries.sumOf { it.stats.totalSizeBytes }
    val text = buildString {
        if (home.libraries.isEmpty()) {
            append("还没有媒体库，创建后会在这里显示库存统计")
            return@buildString
        }
        append("${home.libraries.size} 个媒体库")
        append(" · ").append("$movies 部电影")
        append(" · ").append("$series 部剧集")
        if (others > 0) append(" · ").append("$others 个其他视频")
        append(" · 共占用 ").append(formatBytes(totalBytes)).append(" 存储空间")
    }
    Text(
        text,
        style = McType.sub,
        color = TextMuted,
        lineHeight = androidx.compose.ui.unit.TextUnit(21f, androidx.compose.ui.unit.TextUnitType.Sp),
        modifier = Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 8.dp),
    )
}

/**
 * 库拼贴卡（实测 230×110 整图 + 居中库名 + 徽标）。
 * 封面直接用服务端合成的那张（`GET /libraries/{id}/cover`，与网页/Jellyfin 同一张图，
 * ETag 走素材指纹所以库没变就 304）。
 * 该库**还没有海报资产**时服务端返回 404，这时退到按类型画的功能占位——
 * 不接的话就是一块空黑，看着像加载失败。
 */
@Composable
private fun LibraryCollageCard(
    library: LibraryView,
    coverUrl: String?,
    origin: String?,
    onClick: () -> Unit,
) {
    Column(
        Modifier.width(230.dp).clickable(onClick = onClick),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(110.dp)
                .clip(RoundedCornerShape(McMetrics.cardRadius))
                .background(Placeholder),
        ) {
            RemoteImage(
                url = coverUrl,
                origin = origin,
                contentDescription = library.name,
                modifier = Modifier.fillMaxSize().aspectRatio(2.1f),
                fallback = { LibraryCoverPlaceholder(library) },
            )
        }
        Spacer(Modifier.height(11.dp))
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(library.name, style = McType.bodySemibold, color = io.movieclaw.android.core.designsystem.TextPrimary)
            Spacer(Modifier.width(8.dp))
            Text(
                "默认",
                style = McType.micro,
                color = TextMuted,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .background(Color.White.copy(alpha = 0.06f))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
    }
}

/** 库封面取不到时的占位：按库类型给图标 + 库名，比空白有用 */
@Composable
private fun LibraryCoverPlaceholder(library: LibraryView) {
    val icon = when (library.kind) {
        "tv" -> androidx.compose.material.icons.Icons.Rounded.Tv
        "music" -> androidx.compose.material.icons.Icons.Rounded.LibraryMusic
        else -> androidx.compose.material.icons.Icons.Rounded.Movie
    }
    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    listOf(Color.White.copy(alpha = 0.07f), Color.White.copy(alpha = 0.02f)),
                )
            ),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, contentDescription = null, tint = TextMuted, modifier = Modifier.size(26.dp))
            Spacer(Modifier.height(4.dp))
            Text(library.name, style = McType.caption2, color = TextMuted, maxLines = 1)
        }
    }
}

internal fun formatBytes(bytes: Long): String {
    if (bytes <= 0) return "0 B"
    val units = listOf("B", "KB", "MB", "GB", "TB")
    var value = bytes.toDouble()
    var i = 0
    while (value >= 1024 && i < units.lastIndex) {
        value /= 1024
        i++
    }
    return if (value >= 100 || i == 0) "%.0f %s".format(value, units[i]) else "%.2f %s".format(value, units[i])
}
