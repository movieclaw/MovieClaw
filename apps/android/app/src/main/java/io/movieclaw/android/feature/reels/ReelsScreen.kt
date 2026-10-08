@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package io.movieclaw.android.feature.reels

import android.content.Context
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Fullscreen
import androidx.compose.material.icons.rounded.FullscreenExit
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.SmartDisplay
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.model.FacetValue
import io.movieclaw.android.core.model.PlaybackMarksRequest
import io.movieclaw.android.core.playback.ExoEngine
import io.movieclaw.android.core.playback.PlaybackNetwork
import io.movieclaw.android.core.playback.mpv.MpvEngine
import io.movieclaw.android.core.model.ReelEventBatch
import io.movieclaw.android.core.model.ReelEventView
import io.movieclaw.android.core.model.ReelFacetsView
import io.movieclaw.android.core.model.ReelFilter
import io.movieclaw.android.core.model.ReelItemView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.playback.QualityMemory
import io.movieclaw.android.core.playback.ReelsQuality
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/* ══════════════════════ 视图模型 ══════════════════════ */

/**
 * 刷片 / 片段（`docs/design/reels.md`）：上下整页滑动，每页从一部电影或一部剧里
 * 挑出的 30~60 秒。
 *
 * 服务端负责挑点（零解码读容器索引：MKV 的 Cues / MP4 的 moov 样本表；按码率信号或
 * 章节起点定起点、找台词空隙收尾），客户端只管按 `segment.start_ms` 起播、
 * 到 `segment.end_ms` 停下、把事件攒批上报。
 *
 * **不写观看记录**：播放走 `ReelsPlayers`（不经过 `PlaybackController`，它会上报进度、
 * 写续播点与播放次数）；`/reels/events` 只落 `reel_event` 表。收藏与「已看」是用户
 * 明确点的，走 `playback/marks`（与详情页同一套）。
 *
 * 画质（本端独有，iOS 一律原画直出）：局域网默认直出原片；外网默认借正片的转码会话
 * 出 720p。档位按**网络环境**记一份（`QualityMemory.reelsCap`），在筛选面板里换。
 */
@HiltViewModel
class ReelsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val qualityMemory: QualityMemory,
    @dagger.hilt.android.qualifiers.ApplicationContext private val appContext: Context,
) : ViewModel() {

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        /** 服务器版本比 App 旧（/reels 404）：提示升级服务器，不报「加载失败」 */
        val serverOutdated: Boolean = false,
        val items: List<ReelItemView> = emptyList(),
        val filter: ReelFilter = ReelFilter(),
        val facets: ReelFacetsView? = null,
        val favorites: Map<String, Boolean> = emptyMap(),
        val playeds: Map<String, Boolean> = emptyMap(),
        /** 片段自己的画质档位（ReelsQuality.AUTO = 自动） */
        val qualityCap: Int = ReelsQuality.AUTO,
        val network: PlaybackNetwork = PlaybackNetwork.UNKNOWN,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    /** 播放器池：当前条 + 预起的下一条，含字节预取与转码会话 */
    val players = ReelsPlayers(
        context = appContext,
        apiFactory = apiFactory,
        scope = viewModelScope,
        originProvider = { repository.ui.value.origin },
        deviceIdProvider = { runCatching { repository.deviceId() }.getOrNull() },
        onEvent = { item, kind, watchedMs, waitMs, positionMs, detail ->
            event(item, kind, watchedMs, waitMs, positionMs, detail)
        },
    )

    private var seed: Long? = null
    private var nextOffset = 0
    private var hasMore = true
    private var loadingMore = false
    private var feedGeneration = 0
    private var feedJob: kotlinx.coroutines.Job? = null
    private var moreJob: kotlinx.coroutines.Job? = null

    /** 事件攒批：满 10 条或离开页面时上报（失败即丢，只是统计，不重试） */
    private val pendingEvents = mutableListOf<ReelEventView>()

    init {
        val host = origin?.let { runCatching { java.net.URI(it).host }.getOrNull() }
        val network = PlaybackNetwork.of(host)
        _ui.update { it.copy(network = network) }
        players.setNetwork(network)
        viewModelScope.launch {
            val cap = qualityMemory.reelsCap(network) ?: ReelsQuality.AUTO
            _ui.update { it.copy(qualityCap = cap) }
            players.setQuality(cap)
        }
        loadFirstPage()
        loadFacets()
    }

    /** 换画质档位：记下来（按网络环境），并按新档位重开当前这条 */
    fun setQuality(cap: Int) {
        _ui.update { it.copy(qualityCap = cap) }
        players.setQuality(cap)
        viewModelScope.launch { qualityMemory.rememberReels(_ui.value.network, cap) }
        players.reloadCurrent()
    }

    /** 这一档在当前网络下实际会用什么（界面小字用） */
    fun qualityLabel(cap: Int): String = ReelsQuality.label(cap, _ui.value.network)

    fun loadFirstPage() {
        feedGeneration += 1
        val generation = feedGeneration
        feedJob?.cancel()
        moreJob?.cancel()
        loadingMore = false
        feedJob = viewModelScope.launch {
            val origin = origin ?: run {
                _ui.update { it.copy(loading = false, error = "尚未连接服务器") }
                return@launch
            }
            _ui.update { it.copy(loading = true, error = null, serverOutdated = false) }
            seed = null
            nextOffset = 0
            hasMore = true
            val f = _ui.value.filter
            try {
                val page = apiFactory.forOrigin(origin).reels(
                    seed = null, offset = 0, limit = PAGE_SIZE,
                    kind = f.kind, genres = f.genres, countries = f.countries,
                    decades = f.decades, ratingGte = f.ratingGte, runtimes = f.runtimes, watch = f.watch,
                ).dataOrThrow()
                if (generation != feedGeneration) return@launch
                seed = page.seed
                nextOffset = page.nextOffset
                hasMore = page.hasMore
                players.setItems(page.items)
                _ui.update { it.copy(loading = false, items = page.items) }
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                if (generation != feedGeneration) return@launch
                val message = friendlyMessage(e)
                val outdated = message.contains("404") || message.contains("Not Found", true) ||
                    message.contains("找不到", false)
                _ui.update {
                    it.copy(loading = false, serverOutdated = outdated, error = if (outdated) null else message)
                }
            }
        }
    }

    /** 滑到末尾前几条时取下一页（同一种子顺序固定，服务端无状态） */
    fun loadMoreIfNeeded(currentIndex: Int) {
        val state = _ui.value
        if (loadingMore || !hasMore || state.loading) return
        if (currentIndex < state.items.size - 3) return
        loadingMore = true
        val generation = feedGeneration
        moreJob = viewModelScope.launch {
            val origin = origin ?: return@launch
            val f = state.filter
            runCatching {
                apiFactory.forOrigin(origin).reels(
                    seed = seed, offset = nextOffset, limit = PAGE_SIZE,
                    kind = f.kind, genres = f.genres, countries = f.countries,
                    decades = f.decades, ratingGte = f.ratingGte, runtimes = f.runtimes, watch = f.watch,
                ).dataOrThrow()
            }
                .onSuccess { page ->
                    if (generation != feedGeneration) return@onSuccess
                    nextOffset = page.nextOffset
                    hasMore = page.hasMore
                    val known = _ui.value.items.map { it.id }.toSet()
                    val merged = _ui.value.items + page.items.filterNot { item -> item.id in known }
                    players.setItems(merged)
                    _ui.update { it.copy(items = merged) }
                }
                .onFailure { /* 下一页拉不到就停在这儿；用户滑回来会再试 */ }
            if (generation == feedGeneration) loadingMore = false
        }
    }

    fun loadFacets() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val f = _ui.value.filter
            runCatching {
                apiFactory.forOrigin(origin).reelFacets(
                    kind = f.kind, genres = f.genres, countries = f.countries,
                    decades = f.decades, ratingGte = f.ratingGte, runtimes = f.runtimes, watch = f.watch,
                ).dataOrThrow()
            }.onSuccess { facets -> _ui.update { it.copy(facets = facets) } }
        }
    }

    /** 换筛选：整个信息流重来（新种子、从头抽），同 iOS */
    fun applyFilter(filter: ReelFilter) {
        players.release()
        _ui.update { it.copy(filter = filter, items = emptyList(), loading = true) }
        loadFirstPage()
        loadFacets()
    }

    /** 清掉全部条件（空态里的「看全部」） */
    fun clearFilter() = applyFilter(ReelFilter())

    /* ---------------- 事件 ---------------- */

    fun event(
        item: ReelItemView,
        kind: String,
        watchedMs: Long? = null,
        waitMs: Long? = null,
        positionMs: Long? = null,
        detail: String? = null,
    ) {
        pendingEvents += ReelEventView(
            reelId = item.id,
            kind = kind,
            mode = item.play.mode,
            mediaItemId = item.title.mediaItemId.takeIf { it > 0 },
            fileId = item.segment.fileId.takeIf { it > 0 },
            positionMs = positionMs,
            watchedMs = watchedMs,
            waitMs = waitMs,
            detail = detail,
        )
        if (pendingEvents.size >= 10) flushEvents()
    }

    fun flushEvents() {
        if (pendingEvents.isEmpty()) return
        val batch = pendingEvents.toList()
        pendingEvents.clear()
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).reportReelEvents(ReelEventBatch(batch)) }
        }
    }

    /* ---------------- 收藏 / 已看（与详情页同一套 marks 接口） ---------------- */

    fun toggleFavorite(item: ReelItemView) {
        val t = item.title
        val next = !(_ui.value.favorites[item.id] ?: t.favorite)
        _ui.update { it.copy(favorites = it.favorites + (item.id to next)) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            // 收藏落在整部（电影 / 整剧）
            val ok = runCatching {
                apiFactory.forOrigin(origin)
                    .setPlaybackMarks(PlaybackMarksRequest(mediaItemId = t.mediaItemId, favorite = next))
                    .dataOrThrow()
            }.isSuccess
            if (!ok) {
                _ui.update { it.copy(favorites = it.favorites + (item.id to !next)) }   // 失败改回去
            } else {
                // 收藏变了：媒体库首页的「我的收藏」行与收藏墙立刻重拉
                io.movieclaw.android.core.model.LibraryMarksBus.bump()
            }
        }
    }

    fun togglePlayed(item: ReelItemView) {
        val t = item.title
        val next = !(_ui.value.playeds[item.id] ?: t.played)
        _ui.update { it.copy(playeds = it.playeds + (item.id to next)) }
        val season = t.episode?.season
        val episode = t.episode?.episode
        viewModelScope.launch {
            val origin = origin ?: return@launch
            // 剧集记这一集，电影记整部（同 iOS）
            val ok = runCatching {
                apiFactory.forOrigin(origin).setPlaybackMarks(
                    PlaybackMarksRequest(
                        mediaItemId = t.mediaItemId,
                        seasonNumber = season,
                        episodeNumber = episode,
                        played = next,
                    )
                ).dataOrThrow()
            }.isSuccess
            if (!ok) {
                _ui.update { it.copy(playeds = it.playeds + (item.id to !next)) }
            } else {
                // 「已看」影响首页「接下来继续」与各行进度，一起让首页重拉
                io.movieclaw.android.core.model.LibraryMarksBus.bump()
            }
        }
    }

    fun isFavorite(item: ReelItemView): Boolean = _ui.value.favorites[item.id] ?: item.title.favorite
    fun isPlayed(item: ReelItemView): Boolean = _ui.value.playeds[item.id] ?: item.title.played

    override fun onCleared() {
        players.release()
        flushEvents()
        super.onCleared()
    }

    private companion object {
        /** 每页条数（服务端上限 20；iOS 第一页 5、之后 10） */
        const val PAGE_SIZE = 10
    }
}

/* ══════════════════════ 屏幕 ══════════════════════ */

/**
 * 刷片页（iOS `ReelsView` 的对应物）：纯黑底、竖滑整页、每页一条 16:9 横带。
 *
 * 版式照 iOS / 抖音：左上返回箭头与标题「片段」（28/700）、右上「全部 ⌄」筛选胶囊；
 * 横带中心在屏高 46% 处；之下「全屏观看」描边小胶囊；右下四个无底色图标
 * （收藏 / 播放 / 已看 / 分享）；左下四行（导演 · 片名 · 年份评分类型 · 一行简介）；
 * 最底下一条细进度线 + 「在整片里放到哪 / 整片多长」，常显。
 *
 * 手势：点空白暂停 / 继续、双击左右三分之一 ∓10 秒、长按 2 倍速（与正片播放器同一套口径）。
 */
@Composable
fun ReelsScreen(
    onBack: () -> Unit,
    onOpenItem: (Long, Long) -> Unit,
    onOpenPerson: (Int) -> Unit,
    onOpenFullPlayer: (ReelItemView, Long) -> Unit,
    onShare: (ReelItemView) -> Unit,
    vm: ReelsViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val origin = vm.origin
    val players = vm.players
    val pagerState = rememberPagerState(pageCount = { state.items.size })
    var filterOpen by remember { mutableStateOf(false) }
    var fullscreen by remember { mutableStateOf(false) }
    val context = LocalContext.current
    // 全屏收系统栏要用到宿主 View（WindowInsetsController 的锚点）
    val view = androidx.compose.ui.platform.LocalView.current

    val currentIndex = pagerState.currentPage
    val current = state.items.getOrNull(currentIndex)

    // 进页锁竖屏（iOS：信息流这一页锁竖屏，转手机不会把整页转横）；离开时解开
    DisposableEffect(Unit) {
        val activity = context as? android.app.Activity
        activity?.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        onDispose {
            activity?.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            // 兜底：全屏没退就直接离开这一页时，把状态栏 / 手势条还回去
            activity?.let {
                androidx.core.view.WindowCompat.getInsetsController(it.window, view)
                    .show(androidx.core.view.WindowInsetsCompat.Type.systemBars())
            }
            players.release()
        }
    }

    // 全屏：整页转横看这一段（画面不换播放器），并把状态栏 / 手势条一起收掉
    // （iOS `statusBarHidden` + `persistentSystemOverlays(.hidden)` 的对应物：
    //   实机反馈「全屏播放页面手机状态栏没有隐藏」）
    LaunchedEffect(fullscreen) {
        val activity = context as? android.app.Activity ?: return@LaunchedEffect
        activity.requestedOrientation = if (fullscreen) {
            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        } else {
            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        val controller = androidx.core.view.WindowCompat.getInsetsController(activity.window, view)
        if (fullscreen) {
            controller.hide(androidx.core.view.WindowInsetsCompat.Type.systemBars())
            // 边缘划一下临时唤出，随即自动隐去——不挡「手势返回」
            controller.systemBarsBehavior =
                androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        } else {
            controller.show(androidx.core.view.WindowInsetsCompat.Type.systemBars())
        }
    }

    // 返回键 / 手势返回：全屏时先退出全屏，再退才离开片段页（iOS 也这样——全屏是一层浮层）
    androidx.activity.compose.BackHandler(enabled = fullscreen) { fullscreen = false }

    // 滑动停稳才换播放器（拖动途中每变一次就起引擎会连开好几个）
    LaunchedEffect(pagerState.isScrollInProgress, state.items, pagerState.currentPage) {
        if (state.items.isEmpty() || pagerState.isScrollInProgress) return@LaunchedEffect
        val index = pagerState.currentPage
        val item = state.items.getOrNull(index) ?: return@LaunchedEffect
        players.setItems(state.items)
        players.settle(item, index, state.items)
    }

    LaunchedEffect(currentIndex, state.items.size) {
        if (state.items.isNotEmpty()) vm.loadMoreIfNeeded(currentIndex)
    }
    DisposableEffect(Unit) { onDispose { vm.flushEvents() } }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when {
            state.serverOutdated -> CenterNote(
                title = "服务器还不支持刷片",
                message = "「片段」需要 MovieClaw v0.30.0 及以上；升级服务器后再进来。",
            )
            state.loading && state.items.isEmpty() -> CenterNote(
                title = "正在挑片段…", message = null, spinner = true,
            )
            state.error != null && state.items.isEmpty() -> CenterNote(
                title = state.error ?: "片段加载失败",
                message = null,
                actionText = "重试",
                onAction = { vm.loadFirstPage() },
            )
            state.items.isEmpty() && state.filter.activeCount > 0 -> CenterNote(
                title = "「${filterLabel(state.filter, state.facets)}」里还没有能刷的片子",
                message = null,
                actionText = "看全部",
                onAction = { vm.clearFilter() },
            )
            state.items.isEmpty() -> CenterNote(
                title = "片库里还没有能刷的片子",
                message = "目前支持 MKV / MP4 的电影与剧集",
            )
            else -> VerticalPager(
                state = pagerState,
                beyondViewportPageCount = 0,
                userScrollEnabled = !fullscreen,
                modifier = Modifier.fillMaxSize(),
            ) { page ->
                val item = state.items[page]
                ReelPage(
                    item = item,
                    isCurrent = page == currentIndex,
                    fullscreen = fullscreen && page == currentIndex,
                    origin = origin,
                    players = players,
                    favorite = vm.isFavorite(item),
                    played = vm.isPlayed(item),
                    qualityCap = state.qualityCap,
                    qualityLabel = { vm.qualityLabel(it) },
                    onQuality = { vm.setQuality(it) },
                    onEvent = { kind, watched, wait, pos, detail ->
                        vm.event(item, kind, watchedMs = watched, waitMs = wait, positionMs = pos, detail = detail)
                    },
                    onToggleFavorite = { vm.toggleFavorite(item) },
                    onTogglePlayed = { vm.togglePlayed(item) },
                    onOpenDetail = {
                        vm.event(item, "detail")
                        onOpenItem(item.title.libraryId, item.title.mediaItemId)
                    },
                    onOpenPerson = onOpenPerson,
                    // 「看全片」= 转正片播放器，从**当前位置**接着看（同 iOS）；长按「从头看」给片段起点
                    onPlayFull = { fromStart ->
                        vm.event(item, "open")
                        val startMs = if (fromStart) item.segment.startMs else players.filePositionMs()
                        onOpenFullPlayer(item, startMs)
                    },
                    onFullscreen = { vm.event(item, "fullscreen"); fullscreen = true },
                    onExitFullscreen = { fullscreen = false },
                    onShare = { onShare(item) },
                )
            }
        }

        // 顶栏（iOS `ReelTitle`）：左上玻璃返回键、正中「在播片名 + 年份」的玻璃胶囊
        //（点了去详情页；加载中 / 空态只写「片段」、不能点）、右上筛选胶囊（全屏时收掉）。
        // 胶囊占满返回键与筛选键之间：宽度固定，换条只换文字，长片名在里面截断
        if (!fullscreen) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                McNavButton(
                    icon = Icons.AutoMirrored.Rounded.ArrowBack,
                    contentDescription = "返回",
                    onClick = { vm.flushEvents(); onBack() },
                )
                Spacer(Modifier.width(8.dp))
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .height(44.dp)
                            .clip(RoundedCornerShape(999.dp))
                            .background(Color.White.copy(alpha = 0.16f))
                            .clickable(enabled = current != null) {
                                current?.let { item ->
                                    vm.event(item, "detail")
                                    onOpenItem(item.title.libraryId, item.title.mediaItemId)
                                }
                            },
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(
                                current?.title?.name ?: "片段",
                                fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                            )
                            current?.title?.year?.let {
                                Text("$it", fontSize = 11.sp, color = Color.White.copy(alpha = 0.6f))
                            }
                        }
                    }
                }
                Spacer(Modifier.width(8.dp))
                Row(
                    Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.16f))
                        .clickable { filterOpen = true }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        filterLabel(state.filter, state.facets),
                        fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                    )
                    Spacer(Modifier.width(5.dp))
                    Icon(
                        Icons.Rounded.UnfoldMore,
                        contentDescription = "筛选",
                        tint = Color.White.copy(alpha = 0.85f),
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }
    }

    if (filterOpen) {
        ReelFilterSheet(
            filter = state.filter,
            facets = state.facets,
            onApply = { vm.applyFilter(it); filterOpen = false },
            onDismiss = { filterOpen = false },
        )
    }
}

/** 顶栏筛选键的文字：没条件「全部」、一个条件写它的值、多个写「已筛选 N 项」（同 iOS） */
private fun filterLabel(filter: ReelFilter, facets: ReelFacetsView?): String {
    if (filter.activeCount == 0) return "全部"
    val labels = buildList {
        filter.kind?.let { k -> add(facets?.kinds?.firstOrNull { it.value == k }?.label ?: k) }
        filter.watch?.let { add("没看过") }
        filter.genres?.let { g -> add(facets?.genres?.firstOrNull { it.value == g }?.label ?: g) }
        filter.countries?.let { c -> add(facets?.countries?.firstOrNull { it.value == c }?.label ?: c) }
        filter.decades?.let { add(it) }
        filter.ratingGte?.let { add("$it 分以上") }
        filter.runtimes?.let { r -> add(facets?.runtimes?.firstOrNull { it.value == r }?.label ?: r) }
    }
    return filter.summary(labels)
}

/** 空态 / 提示：主行 15、副行 12（iOS subheadline / caption），可带一颗玻璃按钮 */
@Composable
private fun CenterNote(
    title: String,
    message: String?,
    spinner: Boolean = false,
    actionText: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Column(
        Modifier.fillMaxSize().padding(horizontal = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (spinner) {
            androidx.compose.material3.CircularProgressIndicator(
                color = Color.White.copy(alpha = 0.6f),
                modifier = Modifier.size(26.dp),
                strokeWidth = 2.5.dp,
            )
            Spacer(Modifier.height(14.dp))
        }
        Text(title, fontSize = 15.sp, color = Color.White.copy(alpha = 0.62f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        message?.let {
            Spacer(Modifier.height(6.dp))
            Text(
                it, fontSize = 12.sp, color = Color.White.copy(alpha = 0.36f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center, lineHeight = 18.sp,
            )
        }
        if (actionText != null && onAction != null) {
            Spacer(Modifier.height(16.dp))
            Box(
                Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .border(1.dp, Color.White.copy(alpha = 0.28f), RoundedCornerShape(999.dp))
                    .clickable(onClick = onAction)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Text(actionText, fontSize = 14.sp, color = Color.White)
            }
        }
    }
}

/* ══════════════════════ 一页 ══════════════════════ */

/**
 * 一条：16:9 横带（满宽、中心屏高 46%）+ 手势 + 右下图标列 + 左下四行信息 + 底部进度行。
 *
 * 全屏时**同一块画面**铺满整屏（同一个 `AndroidView`，只改尺寸与位置——不用像 iOS 那样
 * 在两个容器之间搬 `UIView`，也就没有「谁抢画面」的问题），并换成全屏控制层。
 */
@Composable
private fun ReelPage(
    item: ReelItemView,
    isCurrent: Boolean,
    fullscreen: Boolean,
    origin: String?,
    players: ReelsPlayers,
    favorite: Boolean,
    played: Boolean,
    /** 片段自己的画质档位（原画 / 720p，按家里 / 外网各记一份） */
    qualityCap: Int,
    qualityLabel: (Int) -> String,
    onQuality: (Int) -> Unit,
    onEvent: (String, Long?, Long?, Long?, String?) -> Unit,
    onToggleFavorite: () -> Unit,
    onTogglePlayed: () -> Unit,
    onOpenDetail: () -> Unit,
    onOpenPerson: (Int) -> Unit,
    onPlayFull: (Boolean) -> Unit,
    onFullscreen: () -> Unit,
    onExitFullscreen: () -> Unit,
    onShare: () -> Unit,
) {
    val frameReady = players.frameReadyId == item.id
    val playing = players.playing
    val ended = players.ended
    val positionMs = players.positionMs
    val failMessage = players.failMessage
    var plotExpanded by remember(item.id) { mutableStateOf(false) }
    var controlsVisible by remember(fullscreen) { mutableStateOf(true) }

    // 全屏：放着的时候 3 秒后自动隐去控制层；暂停 / 放完一直显示（同 iOS）
    LaunchedEffect(fullscreen, playing, controlsVisible) {
        if (!fullscreen || !controlsVisible) return@LaunchedEffect
        if (!playing) return@LaunchedEffect
        kotlinx.coroutines.delay(3000)
        if (fullscreen && playing) controlsVisible = false
    }

    Box(Modifier.fillMaxSize()) {
        androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
            val bandWidth = maxWidth
            val bandHeight = bandWidth * 9f / 16f
            val bandCenter = maxHeight * 0.46f
            val bandTop = (bandCenter - bandHeight / 2).coerceAtLeast(0.dp)

            // ── 画面槽：竖屏是 16:9 横带（中心 46%），全屏时铺满 ──
            Box(
                Modifier
                    .then(
                        if (fullscreen) Modifier.fillMaxSize()
                        else Modifier
                            .fillMaxWidth()
                            .height(bandHeight)
                            .offset(y = bandTop),
                    )
                    .background(Color.Black)
                    // 手势挂在**画面**上（iOS 同款：`videoBand(...).onTapGesture`）：
                    // 点画面暂停 / 继续、双击左右三分之一 ∓10 秒、长按 2 倍速（同正片口径）。
                    // 挂在整页上时，点「全屏观看」「收藏」这些按钮会连带触发暂停——
                    // 实测反馈的「进了全屏却在暂停」就是从这儿来的
                    .pointerInput(item.id, isCurrent, fullscreen) {
                        detectTapGestures(
                            onTap = {
                                if (!isCurrent) return@detectTapGestures
                                if (fullscreen) controlsVisible = !controlsVisible else players.togglePause()
                            },
                            onDoubleTap = { offset ->
                                if (!isCurrent) return@detectTapGestures
                                val third = size.width / 3f
                                when {
                                    offset.x < third -> players.seekBy(-10_000)
                                    offset.x > size.width - third -> players.seekBy(10_000)
                                }
                            },
                            onLongPress = { if (isCurrent) players.setSpeed(2f) },
                            onPress = {
                                awaitRelease()
                                players.setSpeed(1f)
                            },
                        )
                    },
                contentAlignment = Alignment.Center,
            ) {
                // 这一页挂着的引擎：当前条，或**预起的下一条**（预起那条把首帧先渲染出来，
                // 滑过去就是「立刻动」，同 iOS `store.player(for:)`）
                val slotEngine = players.engineFor(item.id)
                val slotReady = players.frameReadyId == item.id || players.standbyReadyId == item.id
                if (slotEngine != null) {
                    // 画面槽分两种引擎：Exo 走 PlayerView；mpv（光盘镜像专用，v0.32 disc=image）
                    // 走引擎自带的 SurfaceView（直渲，与正片播放页同一套）。key 住引擎实例——
                    // 换条时 engineFor 返回的实例会变，key 变了 AndroidView 才会重建、
                    // 换成对的那块画面（Exo 靠 update 重绑 player，mpv 必须换 view）
                    key(slotEngine) {
                        if (slotEngine is MpvEngine) {
                            AndroidView(
                                factory = { slotEngine.surfaceView },
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            AndroidView(
                                factory = { ctx ->
                                    androidx.media3.ui.PlayerView(ctx).apply {
                                        useController = false
                                        setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
                                    }
                                },
                                // 引擎是池里的状态（换条 / 预起转正时会变），重组时重绑
                                update = { view -> view.player = (players.engineFor(item.id) as? ExoEngine)?.player },
                                onRelease = { view -> view.player = null },
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                    }
                }
                if (!slotReady) {
                    RemoteImage(
                        url = item.coverUrl ?: item.title.backdropUrl ?: item.title.posterUrl,
                        origin = origin,
                        contentDescription = item.title.name,
                        modifier = Modifier.fillMaxSize(),
                        // iOS 用 .fit：横带里整张封面完整可见，两侧留黑
                        contentScale = ContentScale.Fit,
                    )
                    // iOS：等画面时封面压暗 0.3（出画后整块收掉，免得从视频黑边里透出来）
                    if (isCurrent && failMessage == null) {
                        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.3f)))
                    }
                    if (isCurrent && failMessage == null) {
                        // 转圈 + 实时加载速度（iOS `loadingIndicator`：`↓ 3.2 MB/s`，等同一路读数）
                        var speedBps by remember(item.id) { mutableStateOf<Long?>(null) }
                        LaunchedEffect(item.id) {
                            while (true) {
                                speedBps = players.bandwidthBps()
                                kotlinx.coroutines.delay(800)
                            }
                        }
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            androidx.compose.material3.CircularProgressIndicator(
                                color = Color.White.copy(alpha = 0.7f),
                                modifier = Modifier.size(26.dp),
                                strokeWidth = 2.5.dp,
                            )
                            speedBps?.takeIf { it > 0 }?.let { bps ->
                                Text(
                                    "↓ ${"%.1f".format(bps / 8.0 / 1024.0 / 1024.0)} MB/s",
                                    fontSize = 11.sp,
                                    color = Color.White.copy(alpha = 0.7f),
                                    fontFamily = FontFamily.Monospace,
                                )
                            }
                        }
                    }
                }
                // 字幕：窗口抽取的那一小段，本地解析后按与正片同一套叠层画
                if (isCurrent && players.cues.isNotEmpty()) {
                    io.movieclaw.android.feature.player.SubtitleOverlayLayer(
                        currentPositionMs = { positionMs },
                        videoSize = androidx.compose.ui.unit.IntSize(1920, 1080),
                        cues = players.cues,
                        enabled = true,
                        style = io.movieclaw.android.core.playback.SubtitleStyle(),
                        offsetMs = 0L,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                // 画面正中的状态键（iOS `ReelPage.overlay`）：
                //  · 点了暂停 → 播放三角（点它继续）——原先只有全屏才有，竖屏点了暂停**一点提示都没有**
                //  · 放到片段终点停下 → 重播圈（原先也用播放三角，看着像「暂停」）
                if (isCurrent && ended) {
                    CenterGlyph(
                        icon = Icons.Rounded.Replay,
                        label = "重播",
                        size = 56.dp,
                        iconSize = 26.dp,
                        onClick = { players.replay() },
                    )
                } else if (
                    isCurrent && !playing && failMessage == null &&
                    players.frameReadyId == item.id
                ) {
                    CenterGlyph(
                        icon = Icons.Rounded.PlayArrow,
                        label = "继续",
                        size = if (fullscreen) 64.dp else 56.dp,
                        iconSize = if (fullscreen) 30.dp else 26.dp,
                        onClick = { players.togglePause() },
                    )
                }
                if (isCurrent && failMessage != null) {
                    Column(
                        Modifier.padding(horizontal = 20.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text("这一段放不出来，往下滑换一条", fontSize = 13.sp, color = Color.White.copy(alpha = 0.62f))
                        Text(
                            failMessage, fontSize = 11.sp, color = Color.White.copy(alpha = 0.36f),
                            maxLines = 2, overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                if (fullscreen && !playing && !ended) {
                    Box(
                        Modifier
                            .size(64.dp)
                            .clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.42f))
                            .clickable { players.togglePause() },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Rounded.PlayArrow, contentDescription = "继续", tint = Color.White, modifier = Modifier.size(30.dp))
                    }
                }
            }

            if (!fullscreen) {
                // ── 横带下方一行（iOS 同序）：画质胶囊在左、「全屏观看」在右，间隔 10、
                //    行中心落在横带下沿约 28dp 处。播放 / 起播 / 缓冲时整行调暗到 30%
                //    （iOS `controlsAlpha`：只有暂停、放完、放不出才恢复全亮）──
                val rowDim = isCurrent && (playing || (!ended && failMessage == null && !frameReady))
                val rowAlpha = if (rowDim) 0.3f else 1f
                Row(
                    Modifier
                        .align(Alignment.TopCenter)
                        .offset(y = bandTop + bandHeight + 14.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // 画质胶囊：与「全屏观看」同一种描边样式，写着当前档（原画 / 720p）；
                    // 按家里 / 外网各记一份、竖屏与全屏共用，选了当前这条按新画质重开
                    var qualityMenu by remember { mutableStateOf(false) }
                    Box {
                        Row(
                            Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .border(1.dp, Color.White.copy(alpha = 0.35f * rowAlpha), RoundedCornerShape(999.dp))
                                .clickable { qualityMenu = true }
                                .padding(horizontal = 14.dp, vertical = 7.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                qualityLabel(qualityCap),
                                fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                                color = Color.White.copy(alpha = 0.92f * rowAlpha),
                            )
                            Spacer(Modifier.width(4.dp))
                            Icon(
                                Icons.Rounded.UnfoldMore, contentDescription = "画质",
                                tint = Color.White.copy(alpha = 0.85f * rowAlpha),
                                modifier = Modifier.size(13.dp),
                            )
                        }
                        androidx.compose.material3.DropdownMenu(
                            expanded = qualityMenu,
                            onDismissRequest = { qualityMenu = false },
                            containerColor = Color(0xFF22252C),
                        ) {
                            ReelsQuality.options.forEach { (cap, label) ->
                                androidx.compose.material3.DropdownMenuItem(
                                    text = { Text(label, fontSize = 14.sp, color = Color.White) },
                                    onClick = { qualityMenu = false; onQuality(cap) },
                                )
                            }
                        }
                    }
                    // 「全屏观看」：描边小胶囊；这一段交给整屏的片段模式，从当前位置接着放
                    Row(
                        Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .border(1.dp, Color.White.copy(alpha = 0.35f * rowAlpha), RoundedCornerShape(999.dp))
                            .clickable(enabled = isCurrent) { onFullscreen() }
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Rounded.Fullscreen, contentDescription = null,
                            tint = Color.White.copy(alpha = 0.92f * rowAlpha), modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "全屏观看", fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                            color = Color.White.copy(alpha = 0.92f * rowAlpha),
                        )
                    }
                }

                // ── 底部（iOS 同序）：左下导演 + 简介、右侧图标列、最底一条细进度线。
                //    进度线平时不显示、只在暂停时淡入，也不写时间（2026-09-30 用户要求，同抖音；
                //    全屏的片段模式才有完整时间轴）──
                val showProgress = isCurrent && !playing && !ended && failMessage == null && frameReady
                Column(
                    Modifier
                        .align(Alignment.BottomStart)
                        .fillMaxWidth()
                        .padding(bottom = 10.dp),
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.Bottom,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        ReelInfo(
                            item = item,
                            origin = origin,
                            expanded = plotExpanded,
                            onToggleExpanded = { plotExpanded = !plotExpanded },
                            onOpenPerson = onOpenPerson,
                            modifier = Modifier.weight(1f),
                        )
                        ReelActions(
                            favorite = favorite,
                            played = played,
                            onOpenDetail = onOpenDetail,
                            onToggleFavorite = onToggleFavorite,
                            onTogglePlayed = onTogglePlayed,
                            onShare = onShare,
                        )
                    }
                    Spacer(Modifier.height(12.dp))
                    ReelProgressRow(
                        positionMs = positionMs,
                        durationMs = item.segment.durationMs,
                        progress = clipProgress(item, positionMs),
                        showTime = false,
                        visible = showProgress,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
            } else {
                // ── 全屏控制层：左上退出与片名、底部播放 / 暂停 + 进度 + 「看全片」──
                if (controlsVisible) {
                    Column(Modifier.fillMaxSize()) {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .background(
                                    Brush.verticalGradient(
                                        listOf(Color.Black.copy(alpha = 0.55f), Color.Transparent),
                                    )
                                )
                                // 控制层自己把点击吞掉：点到条子上（哪怕差几像素没点中按钮）
                                // 也不能把整层切走——那看起来就是「点了没反应、按钮消失了」
                                .pointerInput(Unit) { detectTapGestures { } }
                                .padding(horizontal = 20.dp)
                                .padding(top = 8.dp, bottom = 40.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                // 退出全屏：52 的触控区 + 24 的图标（原先 44/20，实机反馈「太小、点不动」；
                                // 图标再配一层底，免得在亮画面上看不出是按钮）
                                Box(
                                    Modifier
                                        .size(52.dp)
                                        .clip(CircleShape)
                                        .background(Color.Black.copy(alpha = 0.35f))
                                        .clickable { onExitFullscreen() },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(
                                        Icons.Rounded.FullscreenExit,
                                        contentDescription = "退出全屏",
                                        tint = Color.White,
                                        modifier = Modifier.size(24.dp),
                                    )
                                }
                                Spacer(Modifier.width(10.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        item.title.name,
                                        fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color.White,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                                    )
                                    fullscreenSubtitle(item)?.let {
                                        Text(
                                            it, fontSize = 13.sp, color = Color.White.copy(alpha = 0.7f),
                                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                            }
                        }
                        Spacer(Modifier.weight(1f))
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .background(
                                    Brush.verticalGradient(
                                        listOf(Color.Transparent, Color.Black.copy(alpha = 0.55f)),
                                    )
                                )
                                .pointerInput(Unit) { detectTapGestures { } }
                                .padding(horizontal = 20.dp)
                                .padding(top = 40.dp, bottom = 10.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(
                                    Modifier
                                        .size(44.dp)
                                        .clip(CircleShape)
                                        .clickable { players.togglePause() },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(
                                        if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                        contentDescription = if (playing) "暂停" else "播放",
                                        tint = Color.White,
                                        modifier = Modifier.size(22.dp),
                                    )
                                }
                                Spacer(Modifier.width(16.dp))
                                ReelProgressRow(
                                    positionMs = positionMs,
                                    durationMs = item.segment.durationMs,
                                    progress = clipProgress(item, positionMs),
                                    modifier = Modifier.weight(1f),
                                )
                                Spacer(Modifier.width(16.dp))
                                Row(
                                    Modifier
                                        .clip(RoundedCornerShape(999.dp))
                                        .border(1.dp, Color.White.copy(alpha = 0.4f), RoundedCornerShape(999.dp))
                                        .clickable { onPlayFull(false) }
                                        .padding(horizontal = 12.dp, vertical = 7.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(
                                        Icons.Rounded.SmartDisplay, contentDescription = null,
                                        tint = Color.White, modifier = Modifier.size(14.dp),
                                    )
                                    Spacer(Modifier.width(6.dp))
                                    Text("看全片", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 片段内进度 0~1（按这一段算） */
private fun clipProgress(item: ReelItemView, positionMs: Long): Float {
    val span = (item.segment.endMs - item.segment.startMs).coerceAtLeast(1L)
    return ((positionMs - item.segment.startMs).toFloat() / span.toFloat()).coerceIn(0f, 1f)
}

/** 全屏控制层副行：年份 · 第 N 季第 N 集（同 iOS `ReelFullscreenView.subtitle`） */
private fun fullscreenSubtitle(item: ReelItemView): String? {
    val parts = buildList {
        item.title.year?.let { add("$it") }
        item.title.episode?.let { ep ->
            var code = "第 ${ep.season} 季第 ${ep.episode} 集"
            ep.name?.takeIf { it.isNotBlank() }?.let { code += " · $it" }
            add(code)
        }
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

/** 画面正中的状态键（iOS ）：只有点了才有反应，不参与控制层的显隐 */
@Composable
private fun CenterGlyph(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    size: androidx.compose.ui.unit.Dp,
    iconSize: androidx.compose.ui.unit.Dp,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .size(size)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.45f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = Color.White, modifier = Modifier.size(iconSize))
    }
}

/* ══════════════════════ 左下信息 / 右下图标 / 进度行 ══════════════════════ */

/**
 * 左下信息（iOS `ReelsView.info`）：**只放导演与简介**——片名、年份在顶部的标题胶囊里，
 * 评分与类型不再显示在这一页（类型在右上角的筛选里）。
 * ① 导演（剧集是主创）：32dp 圆头像 + 15 半粗名字 + 15 的「导演 / 主创」
 *    （32dp 是 iOS 2026-09-30 实测定稿：24dp 只比名字那行字高一点、显小），点了进人物页
 * ② 简介（13, 85%）：剧集前面半粗「第 N 季第 N 集「集名」」；收起 3 行、放不下给「展开」，
 *    点开最多 8 行
 */
@Composable
private fun ReelInfo(
    item: ReelItemView,
    origin: String?,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    onOpenPerson: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val title = item.title
    val shadow = Shadow(color = Color.Black.copy(alpha = 0.55f), offset = androidx.compose.ui.geometry.Offset(0f, 1f), blurRadius = 3f)
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        title.directors.firstOrNull()?.let { lead ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .clickable(enabled = lead.tmdbPersonId != null) { lead.tmdbPersonId?.let(onOpenPerson) },
            ) {
                RemoteImage(
                    url = lead.avatarUrl,
                    origin = origin,
                    modifier = Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .border(0.5.dp, Color.White.copy(alpha = 0.25f), CircleShape),
                    contentDescription = null,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    title.directors.joinToString(" / ") { it.name },
                    fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = TextStyle(shadow = shadow),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    if (title.kind == "tv") "主创" else "导演",
                    fontSize = 15.sp, color = Color.White.copy(alpha = 0.65f),
                    style = TextStyle(shadow = shadow),
                )
            }
        }
        // 简介（iOS `caption`）：剧集前面是「第 N 季第 N 集「集名」」（季集放在这里，
        // 顶部胶囊只写片名和年份），优先用分集简介
        val body = (title.episode?.overview ?: title.overview)?.takeIf { it.isNotBlank() }
        val episode = title.episode
        val head = episode?.let { ep ->
            "第 ${ep.season} 季第 ${ep.episode} 集" +
                (ep.name?.takeIf { it.isNotBlank() }?.let { "「$it」" } ?: "")
        }
        if (head != null || body != null) {
            var overflowed by remember(item.id) { mutableStateOf(false) }
            val caption = remember(item.id, head, body, expanded) {
                buildAnnotatedString {
                    if (head != null) {
                        withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(head) }
                    }
                    body?.let { append(it) }
                    if (expanded) {
                        withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append("  收起") }
                    }
                }
            }
            Box(
                Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { onToggleExpanded() },
            ) {
                Text(
                    text = caption,
                    fontSize = 13.sp, color = Color.White.copy(alpha = 0.85f),
                    maxLines = if (expanded) 8 else 3,
                    overflow = TextOverflow.Ellipsis,
                    lineHeight = 19.sp,
                    style = TextStyle(shadow = shadow),
                    onTextLayout = { overflowed = it.hasVisualOverflow },
                )
                if (!expanded && overflowed) {
                    Text(
                        "展开", fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                        color = Color.White, modifier = Modifier.align(Alignment.BottomEnd),
                    )
                }
            }
        }
    }
}

/**
 * 右下角一列无底色图标（图标 26、标签 11，同 iOS `ReelActionLabel`）：收藏 / 详情 / 已看 / 分享。
 * iOS 2026-09-30 起「详情」替换了原来的「播放」——刷到感兴趣的片最常做的是看详细信息，
 * 想看整部走全屏里的「看全片」。胶片图标是宽矩形，同字号下显大，缩到 21 才与其余视觉等重（iOS 同款）。
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ReelActions(
    favorite: Boolean,
    played: Boolean,
    onOpenDetail: () -> Unit,
    onToggleFavorite: () -> Unit,
    onTogglePlayed: () -> Unit,
    onShare: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(18.dp),
        modifier = Modifier.padding(bottom = 4.dp),
    ) {
        ReelIcon(
            if (favorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
            "收藏",
            tint = if (favorite) Color(0xFFFF4459) else Color.White,
            onClick = onToggleFavorite,
        )
        ReelIcon(Icons.Rounded.Movie, "详情", iconSize = 21.dp, onClick = onOpenDetail)
        ReelIcon(
            Icons.Rounded.CheckCircle,
            "已看",
            tint = if (played) Color(0xFF4ADE80) else Color.White,
            onClick = onTogglePlayed,
        )
        ReelIcon(Icons.Rounded.Share, "分享", onClick = onShare)
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ReelIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    tint: Color = Color.White,
    /** 图标字号：宽扁的符号要小一号，一列按钮视觉上才一样重（iOS 同款） */
    iconSize: androidx.compose.ui.unit.Dp = 26.dp,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .width(52.dp)
                .height(30.dp)
                .combinedClickable(onClick = onClick, onLongClick = onLongClick),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon, contentDescription = label, tint = tint,
                modifier = Modifier.size(iconSize),
            )
        }
        Spacer(Modifier.height(4.dp))
        Text(
            label, fontSize = 11.sp, fontWeight = FontWeight.Medium, color = tint,
            style = TextStyle(
                shadow = Shadow(
                    color = Color.Black.copy(alpha = 0.5f),
                    offset = androidx.compose.ui.geometry.Offset(0f, 1f),
                    blurRadius = 3f,
                ),
            ),
        )
    }
}

/**
 * 进度行：细线 + 可选时间（iOS `ReelProgressRow`）。
 * 竖屏（本页）**只留一条 2dp 细线、不写时间**，而且平时不显示、只在暂停时淡入
 * （2026-09-30 用户要求，同抖音——原来右边写着「这一段放到哪 / 多长」，后来整段去掉）；
 * 全屏的片段模式照旧有完整时间轴（`showTime = true`）。
 */
@Composable
private fun ReelProgressRow(
    positionMs: Long,
    durationMs: Long?,
    progress: Float,
    showTime: Boolean = true,
    visible: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val rowAlpha by animateFloatAsState(if (visible) 1f else 0f, tween(200), label = "reelProgress")
    Row(modifier = modifier.fillMaxWidth().alpha(rowAlpha), verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .weight(1f)
                .height(2.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(Color.White.copy(alpha = 0.22f)),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(progress)
                    .height(2.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(Color.White.copy(alpha = 0.9f)),
            )
        }
        if (showTime) {
            Spacer(Modifier.width(10.dp))
            Text(
                timeText(positionMs, durationMs),
                fontSize = 11.sp, fontWeight = FontWeight.Medium,
                fontFamily = FontFamily.Monospace,
                color = Color.White.copy(alpha = 0.78f),
                style = TextStyle(
                    shadow = Shadow(
                        color = Color.Black.copy(alpha = 0.5f),
                        offset = androidx.compose.ui.geometry.Offset(0f, 1f),
                        blurRadius = 2f,
                    ),
                ),
            )
        }
    }
}

/** 「1:36:17 / 45:08」：一小时以上的片子两边都带小时位，对齐不跳 */
private fun timeText(positionMs: Long, durationMs: Long?): String {
    val position = positionMs / 1000.0
    val total = durationMs?.let { it / 1000.0 }
    val long = (total ?: position) >= 3600
    return if (total == null || total <= 0) {
        clock(position, long)
    } else {
        "${clock(position, long)} / ${clock(total, long)}"
    }
}

private fun clock(seconds: Double, long: Boolean): String {
    val total = maxOf(0, seconds.toInt())
    val h = total / 3600
    val m = total % 3600 / 60
    val s = total % 60
    return if (long) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

/* ══════════════════════ 筛选面板 ══════════════════════ */

/**
 * 筛选面板：候选值与计数都来自 `/reels/facets`（**每维计数排除本维自身条件**——
 * 否则勾了「动画」其他类型全变 0，多选就废了），为 0 的档置灰不可点（「永不空货架」）。
 * 「其他」池子（`filterable=false`）收起类型 / 题材 / 地区 / 年代 / 评分 / 片长，只留观看状态。
 *
 * 画质不在这张面板里：它是横带下方「全屏观看」左边的独立胶囊（iOS 2026-09-30 的位置）。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun ReelFilterSheet(
    filter: ReelFilter,
    facets: ReelFacetsView?,
    onApply: (ReelFilter) -> Unit,
    onDismiss: () -> Unit,
) {
    var draft by remember { mutableStateOf(filter) }
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = Color.White,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text("筛选片段", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            facets?.let {
                Text("当前条件下能刷到 ${it.total} 部", fontSize = 12.sp, color = Color.White.copy(alpha = 0.5f))
            }
            Spacer(Modifier.height(6.dp))

            DimensionRow("类型", facets?.kinds.orEmpty(), draft.kind) { draft = draft.copy(kind = it) }
            if (facets?.filterable != false) {
                DimensionRow("题材", facets?.genres.orEmpty(), draft.genres) { draft = draft.copy(genres = it) }
                DimensionRow("地区", facets?.countries.orEmpty(), draft.countries) { draft = draft.copy(countries = it) }
                DimensionRow("年代", facets?.decades.orEmpty(), draft.decades) { draft = draft.copy(decades = it) }
                DimensionRow("评分", facets?.ratings.orEmpty(), draft.ratingGte?.toString()) {
                    draft = draft.copy(ratingGte = it?.toFloatOrNull())
                }
                DimensionRow("片长", facets?.runtimes.orEmpty(), draft.runtimes) { draft = draft.copy(runtimes = it) }
            }
            DimensionRow("观看", facets?.watch.orEmpty(), draft.watch) { draft = draft.copy(watch = it) }

            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    Modifier
                        .weight(1f)
                        .height(42.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))))
                        .clickable { onApply(draft) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text("选好了", fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF141821))
                }
                Box(
                    Modifier
                        .width(120.dp)
                        .height(42.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.1f))
                        .clickable { onApply(ReelFilter()) },
                    contentAlignment = Alignment.Center,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.Close, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("清空条件", fontSize = 13.sp, color = Color.White)
                    }
                }
            }
        }
    }
}

/** 一维筛选：横向 chips，单选（再点一次取消）；计数为 0 且未选中的置灰不可点 */
@Composable
private fun DimensionRow(
    label: String,
    options: List<FacetValue>,
    selected: String?,
    onPick: (String?) -> Unit,
) {
    if (options.isEmpty()) return
    Text(
        label,
        fontSize = 12.sp, color = Color.White.copy(alpha = 0.5f),
        modifier = Modifier.padding(top = 10.dp, bottom = 6.dp),
    )
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(options) { option ->
            val on = selected == option.value
            val dim = option.count == 0 && !on
            Box(
                Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (on) Color.White.copy(alpha = 0.18f) else Color.White.copy(alpha = 0.06f))
                    .clickable(enabled = !dim) { onPick(if (on) null else option.value) }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            ) {
                Text(
                    "${option.label} ${option.count}",
                    fontSize = 12.5.sp,
                    color = if (dim) Color.White.copy(alpha = 0.3f) else Color.White,
                )
            }
        }
    }
}
