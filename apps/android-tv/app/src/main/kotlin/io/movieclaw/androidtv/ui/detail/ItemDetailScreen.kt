@file:OptIn(ExperimentalFoundationApi::class)

package io.movieclaw.androidtv.ui.detail

import io.movieclaw.androidtv.ui.stage.StagePreviewLayer
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.core.model.generated.CollectionSeriesView
import io.movieclaw.androidtv.core.model.generated.LibraryItemDetailView
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.PosterCard
import io.movieclaw.androidtv.ui.components.Shelf
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.PlayRequest
import io.movieclaw.androidtv.ui.shell.Route
import io.movieclaw.androidtv.ui.stage.StageBackdrop
import io.movieclaw.androidtv.ui.stage.StageBlock
import io.movieclaw.androidtv.ui.stage.StageInfo
import io.movieclaw.androidtv.ui.stage.TitleArt
import io.movieclaw.androidtv.ui.stage.episodeLine
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID
import kotlin.math.max

/**
 * 条目详情（TVItemDetailView）：两截。
 * - 首屏：剧照原图铺满（StageBackdrop fullImage），左下片名 Logo、一行信息 + 片源标签、剧集的「第 N 季 第 M 集 · 名」、三行简介，
 *   下面一排按钮（播放 / 从头播放 / 收藏 / 标为已看），右下角浮导演与两位主演；
 * - 往下按整页吸到下半截：顶上居中片名 + 选季 → 分集横排 → 作品系列（电影）→ 演职员 → 所属合集。
 * 两截之间不停在半中间（DetailSnapSpec）；从下半截最上面一行再往上回首屏，焦点落主按钮。
 */
@Composable
fun ItemDetailScreen(libraryId: Long, itemId: Long) {
    val session = LocalSession.current
    val graph = LocalGraph.current
    val router = LocalRouter.current
    val upNextOf = LocalUpNextUnit.current
    // 页面实例的牌子：从上层退回来时同一块，状态从 PageStates 拿回来
    val token = rememberSaveable { UUID.randomUUID().toString() }
    val state = remember(token) {
        PageStates.getOrPut("detail:${session.key}:$token") { DetailState(session.api, libraryId, itemId, graph.store.playbackDeviceId) }
    }
    var pageFocused by remember { mutableStateOf(false) }

    LaunchedEffect(state) { state.reload(upNextOf(itemId)) }
    LaunchedEffect(state) { state.loadFavorite() }
    val unitKey = state.unitKey
    LaunchedEffect(state, unitKey) { state.loadResumeFor(unitKey) }

    // 播放器打开的是这一部的某一集：记下来，播完首屏改讲它（TVItemDetailView 的 playedElsewhere）
    val player = router.player
    LaunchedEffect(player) {
        val s = player?.seasonNumber
        val e = player?.episodeNumber
        if (player?.mediaItemId == itemId && s != null && e != null) state.playedElsewhere = s to e
    }
    // 播放器关掉：重拉分集进度与续播点（服务端收「停止」要一点时间，稍等再拉）
    val closed = router.playbackClosed
    val seenClosed = remember { mutableIntStateOf(closed) }
    LaunchedEffect(closed) {
        if (closed == seenClosed.intValue) return@LaunchedEffect
        seenClosed.intValue = closed
        if (router.lastPlayed?.mediaItemId != itemId) return@LaunchedEffect
        delay(800)
        state.afterPlayback()
    }

    val scroll = rememberScrollState()
    // testTagsAsResourceId：端到端验收用 uiautomator 按 testTag 找控件
    Box(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }.onFocusChanged { pageFocused = it.hasFocus }) {
        DetailBackdrop(itemId, state.detail, scroll)
        val detail = state.detail
        when {
            state.failed -> {
                val focus = remember { FocusRequester() }
                StateView(
                    McIcons.MissingFolder,
                    "未能加载该条目",
                    Modifier.focusRequester(focus).focusGroup(),
                    message = "条目可能已被删除或重新识别为其他作品。",
                    action = "返回",
                ) { router.pop() }
                LaunchedEffect(Unit) {
                    delay(200)
                    if (!pageFocused) focus.tryFocus()
                }
            }
            detail != null -> DetailContent(state, detail, scroll, pageFocused = { pageFocused })
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Spinner() }
        }
    }
}

/** 整页背景：剧照按屏宽取，往下滑时跟着内容滚走、露出同一张图的模糊版（滚动量只在它的图层里读） */
@Composable
private fun DetailBackdrop(itemId: Long, detail: LibraryItemDetailView?, scroll: ScrollState) {
    // 大图预告：详情页放「高光」片段；从首页进来是同一部就接着放（TVStagePreview 按条目 id 认）
    val preview = io.movieclaw.androidtv.ui.shell.LocalStagePreview.current
    if (preview != null) {
        io.movieclaw.androidtv.ui.stage.UseStagePreview(preview, io.movieclaw.androidtv.ui.stage.StagePreview.Request(itemId, "highlight"))
    }
    StageBackdrop(
        image = detail?.backdropUrl ?: detail?.posterUrl,
        fullImage = true,
        scrollPx = { scroll.value.toFloat() },
        pinnedPt = 0f,
        fadePt = 900f,
        preview = if (preview != null && detail != null) { visible -> StagePreviewLayer(preview, itemId, visible) } else null,
    )
}

/** 焦点在哪一截（给吸附规则读，不参与界面刷新） */
private class ZoneHolder {
    var zone = DetailZone.Stage
}

@Composable
private fun DetailContent(state: DetailState, detail: LibraryItemDetailView, scroll: ScrollState, pageFocused: () -> Boolean) {
    val router = LocalRouter.current
    val scope = rememberCoroutineScope()
    val ptPx = LocalDensity.current.density * 0.5f
    val isMovie = state.isMovie
    val series = state.series
    // 分段的长季（> 50 集）：选季下面一排集段页签，横排仍是整季
    val ranges = remember(state.browseEpisodes) { EpisodeRanges.ranges(state.browseEpisodes) }
    val screenTop = DetailLogic.lowerScreenTop(state.hasSeasonTabs, ranges.isNotEmpty())
    val gap = DetailLogic.lowerGap(isMovie, series != null)
    val lowerPx by rememberUpdatedState((918 + gap - screenTop) * ptPx)

    val zone = remember { ZoneHolder() }
    // 焦点记在哪（从影人页、别的详情退回来时落回原处）
    var focusKey by rememberSaveable { mutableStateOf<String?>(null) }
    val requesters = remember { HashMap<String, FocusRequester>() }
    fun req(key: String) = requesters.getOrPut(key) { FocusRequester() }
    fun Modifier.track(key: String, inZone: DetailZone) = focusRequester(req(key)).onFocusChanged {
        if (it.isFocused) {
            focusKey = key
            zone.zone = inZone
        }
    }
    val stageKey = if (state.canPlay) "play" else "favorite"
    fun backToStage() {
        zone.zone = DetailZone.Stage
        req(stageKey).tryFocus()
    }

    val snap = remember(scroll) {
        DetailSnapSpec(
            zone = { zone.zone },
            scrollValue = { scroll.value.toFloat() },
            maxScroll = { scroll.maxValue.toFloat() },
            lowerPx = { lowerPx },
            marginPx = 60 * ptPx,
        )
    }
    val rowSpec = remember(ptPx) { MarginBringIntoViewSpec(80 * ptPx) }
    val lowerShown = { scroll.value >= lowerPx * 0.5f }
    // 换季后集段页签出现 / 消失，下半截的顶跟着挪：焦点在顶上那一截时直接吸到新位置
    LaunchedEffect(screenTop) {
        if (zone.zone == DetailZone.Top) scroll.animateScrollTo(lowerPx.toInt())
    }

    val rowState = rememberLazyListState()
    // 在哪个段页签上按确认打开了「全部分集」面板；null 是没开
    var panelFrom by remember { mutableStateOf<Int?>(null) }
    // 横排直接定位到某一集（换段、从面板选集、锚点变了）：不播一长段滚动动画；[focus] 时焦点跟过去
    fun jumpRow(number: Long, focus: Boolean) {
        state.rowEpisode = number
        val index = state.browseEpisodes.indexOfFirst { it.episodeNumber == number }
        if (index < 0) return
        scope.launch {
            rowState.scrollToItem(index)
            if (focus) {
                repeat(5) {
                    delay(16)
                    if (req("ep:$number").tryFocus()) return@launch
                }
            }
        }
    }

    // 内容出来 0.2 秒后焦点还不在页面里：落回记下的那一处，没有就放到主按钮（不能播就放收藏）
    LaunchedEffect(Unit) {
        delay(200)
        if (pageFocused()) return@LaunchedEffect
        val saved = focusKey
        if (saved != null && saved != stageKey && requesters[saved]?.tryFocus() == true) return@LaunchedEffect
        backToStage()
    }

    // 下半截有哪几行：第一行（及选季）算「顶」，滑下来停在下半截的顶
    val hasEpisodes = !isMovie && detail.seasons.isNotEmpty()
    val people = remember(detail) { DetailLogic.castPeople(detail) }
    val collections = detail.collections.filter { series == null || it.id != detail.seriesCollectionId }
    val rowOrder = listOfNotNull(
        "episodes".takeIf { hasEpisodes },
        "series".takeIf { series != null },
        "cast".takeIf { people.isNotEmpty() },
        "collections".takeIf { collections.isNotEmpty() },
    )
    fun zoneOf(row: String) = if (rowOrder.firstOrNull() == row) DetailZone.Top else DetailZone.Below

    CompositionLocalProvider(LocalBringIntoViewSpec provides snap) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
            CompositionLocalProvider(LocalBringIntoViewSpec provides rowSpec) {
                // 首屏：滑走时淡出（progress 到 0.6 淡完）
                Box(
                    Modifier.fillMaxWidth().height(918.pt).graphicsLayer {
                        alpha = max(0f, 1 - (scroll.value / lowerPx) / 0.6f)
                    },
                ) {
                    StageBlock(
                        bottomPt = 918,
                        info = {
                            val episode = state.selectedEpisode
                            val season = state.season
                            StageInfo(
                                title = detail.title,
                                logo = detail.logoUrl,
                                headline = if (!isMovie && episode != null && season != null) episodeLine(season, episode.episodeNumber, episode.name) else null,
                                meta = DetailLogic.metaLine(detail),
                                badges = remember(detail) { DetailLogic.mediaBadges(detail) },
                                overview = if (isMovie) detail.localMeta?.plot else (episode?.overview ?: detail.localMeta?.plot),
                                overviewLines = 3,
                            )
                        },
                        actions = { StageActions(state, detail, Modifier, { k -> Modifier.track(k, DetailZone.Stage) }, stageKey = { req(stageKey) }) },
                    )
                    val (director, actors) = remember(detail) { DetailLogic.stageCredits(detail) }
                    StageCredits(director, actors, Modifier.align(Alignment.BottomEnd).padding(end = McMetrics.Edge, bottom = 34.pt))
                }
                Spacer(Modifier.height(gap.pt))
                Box(Modifier.fillMaxWidth().heightIn(min = (1080 - screenTop).pt)) {
                    Column(verticalArrangement = Arrangement.spacedBy(44.pt)) {
                        if (hasEpisodes) {
                            EpisodeRow(
                                state = state,
                                detail = detail,
                                listState = rowState,
                                segmented = ranges.isNotEmpty(),
                                fromStage = { zone.zone == DetailZone.Stage },
                                jumpRow = ::jumpRow,
                                // 页签还没随下半截滑出来（不接焦点）时按几何就近，照旧回首屏
                                above = {
                                    if (!lowerShown()) FocusRequester.Default
                                    else req("range:${max(0, EpisodeRanges.position(state.rowEpisode ?: state.entryEpisode, ranges))}")
                                },
                                track = { k -> Modifier.track(k, zoneOf("episodes")) },
                                req = { req(it) },
                            )
                        }
                        if (series != null) {
                            SeriesRow(
                                series = series,
                                itemId = state.itemId,
                                track = { k -> Modifier.track(k, zoneOf("series")) },
                                req = { req(it) },
                                onCurrent = ::backToStage,
                                onOpen = { router.push(Route.Item(state.libraryId, it)) },
                            )
                        }
                        if (people.isNotEmpty()) {
                            Shelf(
                                "演职员",
                                Modifier.focusSection { req("person:0") }.focusGroup(),
                            ) {
                                itemsIndexed(people) { index, person ->
                                    PersonCard(
                                        person,
                                        onClick = {
                                            // 没有 TMDB 影人 id 的（NFO 里只有姓名的导演）没有影人页
                                            person.personId?.let { router.push(Route.Person(it, person.name, person.avatar, state.itemId)) }
                                        },
                                        modifier = Modifier.track("person:$index", zoneOf("cast")),
                                    )
                                }
                            }
                        }
                        if (collections.isNotEmpty()) {
                            Column(Modifier.padding(horizontal = McMetrics.Edge), verticalArrangement = Arrangement.spacedBy(20.pt)) {
                                Text("所属合集", style = McType.size(32, FontWeight.SemiBold))
                                Row(Modifier.fillMaxWidth().focusSection().focusGroup(), horizontalArrangement = Arrangement.spacedBy(24.pt)) {
                                    collections.forEach { row ->
                                        PillButton(
                                            onClick = { router.push(Route.Collection(row.id, row.name)) },
                                            text = row.name,
                                            modifier = Modifier.track("col:${row.id}", zoneOf("collections")),
                                        )
                                    }
                                }
                            }
                        }
                    }
                    // 片名与选季挂在下半截顶上、跟着内容滚，但不占排版位置（下沿离下半截 36）；滑过一半才淡入、才接焦点
                    LowerHeader(
                        state = state,
                        detail = detail,
                        modifier = Modifier
                            .fillMaxWidth()
                            .floatAbove((36 * ptPx).toInt())
                            .graphicsLayer { alpha = max(0f, (scroll.value / lowerPx) - 0.5f) * 2 },
                        canFocus = lowerShown,
                        track = { k -> Modifier.track(k, DetailZone.Top) },
                        req = { req(it) },
                        scope = { block -> scope.launch { block() } },
                        ranges = ranges,
                        onRangeFocus = { jumpRow(EpisodeRanges.entry(ranges[it], state.browseAnchor), focus = false) },
                        onRangeOpen = { panelFrom = it },
                    )
                }
                Spacer(Modifier.height(80.pt))
            }
        }
    }
    // 全部分集：盖满整屏，焦点关在里面；返回键回到打开它的段页签，选一集回到横排的那一集
    val from = panelFrom
    if (from != null && ranges.isNotEmpty()) {
        EpisodePanel(
            title = state.browseSeason?.let(DetailLogic::seasonLabel),
            episodes = state.browseEpisodes,
            ranges = ranges,
            anchor = state.browseAnchor,
            startRange = from,
            onPick = { number ->
                panelFrom = null
                jumpRow(number, focus = true)
            },
            onClose = {
                panelFrom = null
                scope.launch {
                    repeat(5) {
                        delay(16)
                        if (req("range:$from").tryFocus()) return@launch
                    }
                }
            },
        )
    }
}

/** 不占排版高度，整块挂在自己上沿之上 [gapPx] 处（下半截顶上的片名与选季） */
private fun Modifier.floatAbove(gapPx: Int) = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints.copy(minHeight = 0, maxHeight = Constraints.Infinity))
    layout(placeable.width, 0) { placeable.place(0, -placeable.height - gapPx) }
}

/** 首屏的一排按钮 + 上方提示（TVItemDetailView.actions） */
@Composable
private fun StageActions(
    state: DetailState,
    detail: LibraryItemDetailView,
    modifier: Modifier,
    track: (String) -> Modifier,
    stageKey: () -> FocusRequester,
) {
    val router = LocalRouter.current
    val scope = rememberCoroutineScope()
    val canPlay = state.canPlay
    val position = state.watched?.positionMs ?: 0
    val finished = state.watched?.played ?: false
    val resumable = canPlay && position > 0
    val unit = if (state.isMovie) null else DetailLogic.unitLabel(state.season, state.selectedEpisode?.episodeNumber)
    val label = DetailLogic.mainButtonLabel(canPlay, position, finished, unit)
    fun play(start: Long?) {
        router.play(
            PlayRequest(
                mediaItemId = state.itemId,
                seasonNumber = if (state.isMovie) null else state.season,
                episodeNumber = if (state.isMovie) null else state.selectedEpisode?.episodeNumber,
                startSeconds = start,
            ),
        )
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(18.pt)) {
        DetailLogic.noteLine(detail, canPlay, state.episodes)?.let {
            Text(it, style = McType.size(25), color = Color.White.copy(alpha = 0.7f))
        }
        // 横贯整屏的焦点区：从下半截往上进来落在主按钮（不能播就是收藏）
        Row(
            Modifier.fillMaxWidth().focusSection(stageKey).focusGroup(),
            horizontalArrangement = Arrangement.spacedBy(28.pt),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (canPlay) {
                PillButton(onClick = { play(null) }, text = label, icon = McIcons.Play, extraPadding = true, modifier = track("play"))
            }
            if (resumable) {
                PillButton(onClick = { play(0) }, text = "从头播放", icon = McIcons.Restart, modifier = track("restart"))
            }
            val fav = state.favorite == true
            PillButton(
                onClick = { scope.launch { state.toggleFavorite() } },
                icon = if (fav) McIcons.HeartFill else McIcons.Heart,
                circle = true,
                contentDescription = if (fav) "已收藏" else "收藏",
                modifier = track("favorite"),
            )
            if (canPlay) {
                PillButton(
                    onClick = { scope.launch { state.togglePlayed() } },
                    icon = if (finished) McIcons.CheckCircle else McIcons.Check,
                    circle = true,
                    contentDescription = if (finished) "已看完" else "标为已看",
                    modifier = track("played"),
                )
            }
        }
    }
}

/** 下半截顶上：居中的片名（620×110，文字 52），多季时下面一排选季，分段的长季再一排集段页签 */
@Composable
private fun LowerHeader(
    state: DetailState,
    detail: LibraryItemDetailView,
    modifier: Modifier,
    canFocus: () -> Boolean,
    track: (String) -> Modifier,
    req: (String) -> FocusRequester,
    scope: (suspend () -> Unit) -> Unit,
    ranges: List<EpisodeRange>,
    onRangeFocus: (Int) -> Unit,
    onRangeOpen: (Int) -> Unit,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(36.pt)) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.BottomCenter) {
            TitleArt(detail.title, detail.logoUrl, maxWidthPt = 620, maxHeightPt = 110, textSizePt = 52, alignment = Alignment.BottomCenter)
        }
        // 选季与集段页签贴在一起（各自上下 12 的内边就是两排的间距）
        Column {
            if (state.hasSeasonTabs) {
                // 焦点停在哪一季 0.25 秒，下面就换成哪一季（一路划过去不逐季加载）
                var focusedSeason by remember { mutableStateOf<Long?>(null) }
                LaunchedEffect(focusedSeason) {
                    val number = focusedSeason ?: return@LaunchedEffect
                    if (number == state.browseSeason) return@LaunchedEffect
                    delay(250)
                    state.loadBrowse(number)
                }
                Row(
                    Modifier
                        .fillMaxWidth()
                        .focusSection { state.browseSeason?.let { req("season:$it") } }
                        .focusGroup()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = McMetrics.Edge, vertical = 12.pt),
                    horizontalArrangement = Arrangement.spacedBy(16.pt),
                ) {
                    detail.seasons.forEach { number ->
                        SeasonTab(
                            label = DetailLogic.seasonLabel(number),
                            selected = number == state.browseSeason,
                            onClick = { scope { state.loadBrowse(number) } },
                            modifier = track("season:$number")
                                .testTag("season-tab:$number")
                                .focusProperties {
                                    this.canFocus = canFocus()
                                    // 有集段页签时往下直接到当前段（理由同集段页签往上）
                                    if (ranges.isNotEmpty()) {
                                        down = req("range:${max(0, EpisodeRanges.position(state.rowEpisode ?: state.entryEpisode, ranges))}")
                                    }
                                }
                                .onFocusChanged {
                                    if (it.isFocused) focusedSeason = number else if (focusedSeason == number) focusedSeason = null
                                },
                        )
                    }
                }
            }
            if (ranges.isNotEmpty()) {
                RangeTabs(state, ranges, canFocus, track, req, onRangeFocus, onRangeOpen) {
                    state.browseSeason?.takeIf { state.hasSeasonTabs }?.let { req("season:$it") }
                }
            }
        }
    }
}

/**
 * 集段页签（「1–50」「1151–1186」）：当前段（横排停在的那一集所在的段）垫白底，锚点所在的段带橙点。
 * 焦点移到哪一段，横排就跳到那一段的入口集（同「焦点移到哪一季，下面就换成哪一季」）；在页签上按确认打开「全部分集」
 */
@Composable
private fun RangeTabs(
    state: DetailState,
    ranges: List<EpisodeRange>,
    canFocus: () -> Boolean,
    track: (String) -> Modifier,
    req: (String) -> FocusRequester,
    onRangeFocus: (Int) -> Unit,
    onRangeOpen: (Int) -> Unit,
    above: () -> FocusRequester?,
) {
    val current = EpisodeRanges.position(state.rowEpisode ?: state.entryEpisode, ranges)
    val anchorRange = EpisodeRanges.position(state.browseAnchor, ranges)
    val tabsState = rememberLazyListState()
    var tabsFocused by remember { mutableStateOf(false) }
    // 焦点不在页签上时（横排往右走跨了段）当前段跟着滚进来
    LaunchedEffect(current) {
        if (!tabsFocused && current >= 0) tabsState.scrollToItem(max(0, current - 3))
    }
    LazyRow(
        state = tabsState,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("range-tabs")
            .onFocusChanged { tabsFocused = it.hasFocus }
            .focusSection { req("range:${max(0, current)}") }
            .focusGroup(),
        contentPadding = PaddingValues(horizontal = McMetrics.Edge, vertical = 12.pt),
        horizontalArrangement = Arrangement.spacedBy(16.pt),
    ) {
        itemsIndexed(ranges, key = { _, range -> range.index }) { index, range ->
            SeasonTab(
                label = range.label,
                selected = index == current,
                dot = index == anchorRange,
                onClick = { onRangeOpen(index) },
                modifier = track("range:$index")
                    .testTag("range-tab:$index")
                    .semantics { selected = index == current }
                    .focusProperties {
                        this.canFocus = canFocus()
                        // 有选季时往上直接到当前季（首屏按钮滑走后在几何上和两排胶囊叠着，就近会越过选季回首屏）
                        above()?.let { up = it }
                    }
                    // 从横排往上进来落在当前段，不跳；左右换到别的段才跳
                    .onFocusChanged { if (it.isFocused && index != current) onRangeFocus(index) },
            )
        }
    }
}

/**
 * 分集横排：剧照 + 第几集、集名、四行简介、首播日期；进来落在接着看的那一集，并把它排在行首边距处。
 * 锚点卡标「接着看」（本季有观看记录时）。分段的长季（[segmented]）横排仍是整季连续的：从首屏下来落在锚点（或指定集），
 * 从上面的页签下来落在横排停在的那一集；那一集滚出去没组合时先直接定位再给焦点
 */
@Composable
private fun EpisodeRow(
    state: DetailState,
    detail: LibraryItemDetailView,
    listState: LazyListState,
    segmented: Boolean,
    fromStage: () -> Boolean,
    jumpRow: (Long, Boolean) -> Unit,
    above: () -> FocusRequester,
    track: (String) -> Modifier,
    req: (String) -> FocusRequester,
) {
    val router = LocalRouter.current
    val scope = rememberCoroutineScope()
    val episodes = state.browseEpisodes
    // 只在换季（或首次读到分集）时滚；从上层退回来时保留原来的滚动位置
    var handledRequest by rememberSaveable { mutableIntStateOf(-1) }
    LaunchedEffect(state.browseScrollRequest) {
        if (state.browseScrollRequest == handledRequest) return@LaunchedEffect
        handledRequest = state.browseScrollRequest
        val entry = state.entryEpisode ?: return@LaunchedEffect
        state.rowEpisode = entry
        val index = state.browseEpisodes.indexOfFirst { it.episodeNumber == entry }
        if (index >= 0) listState.scrollToItem(index)
    }
    // 播完 / 标记后锚点变了（看完 1050 → 1051）：横排跳到新锚点，焦点在横排里就跟过去
    var rowFocused by remember { mutableStateOf(false) }
    var handledJump by rememberSaveable { mutableIntStateOf(state.browseJumpRequest) }
    LaunchedEffect(state.browseJumpRequest) {
        if (state.browseJumpRequest == handledJump) return@LaunchedEffect
        handledJump = state.browseJumpRequest
        state.browseJumpTarget?.let { jumpRow(it, rowFocused) }
    }
    val tagged = EpisodeRanges.resumeTag(episodes, state.browseResume)
    // 长季：从首屏下来落在锚点（或指定集），从上面的页签、下面的行进来落在横排停在的那一集
    fun entryTarget(): Long? = if (fromStage()) state.entryEpisode else state.rowEpisode ?: state.entryEpisode
    LazyRow(
        state = listState,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("episode-row")
            .onFocusChanged { rowFocused = it.hasFocus }
            .then(
                if (!segmented) {
                    Modifier.focusSection { state.entryEpisode?.let { req("ep:$it") } }
                } else {
                    // 同 focusSection，另外：要落的那一集滚出去没组合出来（长季里先跳去别的段了），取消这次几何就近，先直接定位再给焦点
                    Modifier.focusProperties {
                        onEnter = {
                            val vertical = requestedFocusDirection == FocusDirection.Up || requestedFocusDirection == FocusDirection.Down
                            val target = entryTarget()
                            if (vertical && target != null && !req("ep:$target").tryFocus()) {
                                cancelFocusChange()
                                jumpRow(target, true)
                            }
                        }
                        onExit = { if (requestedFocusDirection == FocusDirection.Right) cancelFocusChange() }
                    }
                },
            )
            .focusGroup(),
        contentPadding = PaddingValues(horizontal = McMetrics.Edge, vertical = 20.pt),
        horizontalArrangement = Arrangement.spacedBy(McMetrics.CardSpacing),
        verticalAlignment = Alignment.Top,
    ) {
        items(episodes, key = { it.episodeNumber }) { episode ->
            EpisodeCard(
                episode = episode,
                runtimeMinutes = detail.localMeta?.runtimeMinutes,
                onClick = {
                    val season = state.browseSeason
                    if (episode.owned && season != null) router.play(PlayRequest(state.itemId, season, episode.episodeNumber))
                },
                onLongClick = {
                    // tvOS 是长按弹「标为已看 / 标为未看」一项菜单，这里长按直接切换
                    if (episode.owned) scope.launch { state.markEpisode(episode, !episode.played) }
                },
                modifier = track("ep:${episode.episodeNumber}")
                    .testTag("ep:${episode.episodeNumber}")
                    // 长季往上直接到当前段页签：首屏按钮滑走后在几何上和页签叠着，就近会越过页签回首屏
                    .then(if (segmented) Modifier.focusProperties { up = above() } else Modifier),
                onFocus = { if (it) state.rowEpisode = episode.episodeNumber },
                resume = episode.episodeNumber == tagged,
            )
        }
    }
}

/** 作品系列一行（电影）：整个系列按上映顺序，这一部标「本片」、库里没有的置灰标「未入库」 */
@Composable
private fun SeriesRow(
    series: CollectionSeriesView,
    itemId: Long,
    track: (String) -> Modifier,
    req: (String) -> FocusRequester,
    onCurrent: () -> Unit,
    onOpen: (Long) -> Unit,
) {
    val current = series.parts.firstOrNull { it.mediaItemId == itemId }
    Shelf(
        series.seriesName ?: "系列",
        Modifier.focusSection { current?.let { req("series:${it.tmdbId}") } }.focusGroup(),
        detail = "已有 ${series.ownedCount} / 共 ${series.total}",
    ) {
        items(series.parts, key = { it.tmdbId }) { part ->
            val isCurrent = part.mediaItemId == itemId
            val missing = part.mediaItemId == null
            PosterCard(
                image = part.posterUrl,
                title = part.title,
                subtitle = part.releaseDate?.take(4),
                badge = if (isCurrent) "本片" else if (missing) "未入库" else null,
                onClick = {
                    val id = part.mediaItemId
                    if (isCurrent) onCurrent() else if (id != null) onOpen(id)
                },
                modifier = track("series:${part.tmdbId}").alpha(if (missing) 0.45f else 1f),
            )
        }
    }
}
