package io.movieclaw.androidtv.ui.home

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
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
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.tv.material3.Button
import androidx.tv.material3.ButtonDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.core.model.generated.UpNextItemView
import io.movieclaw.androidtv.ui.components.CaptionMode
import io.movieclaw.androidtv.ui.components.LandscapeCard
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.SeeAllCard
import io.movieclaw.androidtv.ui.components.Shelf
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.components.NoAutoScroll
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.LocalShellChrome
import io.movieclaw.androidtv.ui.shell.LocalStagePreview
import io.movieclaw.androidtv.ui.stage.StagePreview
import io.movieclaw.androidtv.ui.stage.StagePreviewLayer
import io.movieclaw.androidtv.ui.stage.UseStagePreview
import io.movieclaw.androidtv.ui.shell.PlayRequest
import io.movieclaw.androidtv.ui.shell.Route
import io.movieclaw.androidtv.ui.shell.WallSource
import io.movieclaw.androidtv.ui.stage.CrossfadeInfo
import io.movieclaw.androidtv.ui.stage.StageBackdrop
import io.movieclaw.androidtv.ui.stage.StageBlock
import io.movieclaw.androidtv.ui.stage.StageInfo
import io.movieclaw.androidtv.ui.stage.episodeLine
import io.movieclaw.androidtv.ui.theme.Formatters
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/** 首屏的焦点位置（TVHomeFocus） */
private sealed interface HomeFocus {
    data object Play : HomeFocus
    data object Details : HomeFocus
    data class Card(val id: Long) : HomeFocus
}

/**
 * 首页（TVHomeView）：首屏是跟着焦点走的「接下来继续」大图区，下面接用户在网页自定义的行。
 * - 大图、片名、简介永远讲焦点所在的那一部（焦点停稳 160 毫秒再换，按住方向键划过不逐张闪），不自动轮播；
 * - 默认焦点在「继续播放」；从按钮往下落在大图正讲的那张卡上；进卡片行时列表滚到 334 点、回到按钮滚回顶部；
 * - 「我的媒体库」是进各个库的唯一入口，网页上藏了这一行电视上照样画。
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun HomeScreen() {
    val session = LocalSession.current
    val router = LocalRouter.current
    val chrome = LocalShellChrome.current
    val store = io.movieclaw.androidtv.ui.shell.LocalHomeStore.current ?: remember(session.key) { HomeStore(session.api) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    var focus by remember { mutableStateOf<HomeFocus?>(null) }
    var stageId by remember { mutableStateOf<Long?>(null) }
    var menuFor by remember { mutableStateOf<UpNextItemView?>(null) }
    val playFocus = remember { FocusRequester() }
    val cardFocus = remember { mutableStateMapOf<Long, FocusRequester>() }
    var launchFocusPending by remember { mutableStateOf(true) }
    // 卡片行给大图预告让位（沉到屏幕底边、只露焦点那张的一截）
    var rowYielded by remember { mutableStateOf(false) }
    var previewSince by remember { mutableStateOf(0L) }
    var lastInput by remember { mutableStateOf(System.currentTimeMillis()) }
    var wakes by remember { mutableStateOf(0) }
    var cardTopPx by remember { mutableStateOf<Float?>(null) }

    LaunchedEffect(store, router.playbackClosed) { store.reload() }
    // 接下来继续变了就同步到系统首页的「继续观看」
    val graph = io.movieclaw.androidtv.LocalGraph.current
    LaunchedEffect(store.upNext) { store.upNext?.let { graph.watchNext.publish(it, session.server, session.token) } }
    LaunchedEffect(store) {
        while (true) {
            delay(60_000)
            store.reload()
        }
    }

    val libraries = store.libraries
    if (libraries == null) {
        if (store.failed) {
            StateView(McIcons.WifiError, "连不上服务器", message = "首页加载失败，请检查网络后重试。", action = "重试") { scope.launch { store.reload() } }
        } else {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Spinner() }
        }
        return
    }
    val rows = store.rows.filter { !it.hidden || it.kind == HomeRows.Kind.Libraries }
    val browsable = libraries.filter { it.viewerAccess && it.kind != "photo" }
    val pinnedCollections = HomeRows.pinnedCollections(rows)
    val upNext = if (rows.any { it.kind == HomeRows.Kind.UpNext }) store.upNext.orEmpty() else emptyList()
    val stage = upNext.firstOrNull { it.mediaItemId == stageId } ?: upNext.firstOrNull()

    fun rowEmpty(row: HomeRows.Row): Boolean = when (val k = row.kind) {
        HomeRows.Kind.UpNext -> upNext.isEmpty()
        is HomeRows.Kind.Favorites -> store.favorites?.items.isNullOrEmpty()
        HomeRows.Kind.Libraries -> browsable.isEmpty() && pinnedCollections.isEmpty()
        is HomeRows.Kind.Genres -> store.genresByKind[k.kind].isNullOrEmpty()
        else -> store.itemsByKey[HomeRows.fetchKey(row)].isNullOrEmpty()
    }
    if (rows.all(::rowEmpty)) {
        StateView(McIcons.FilmStack, "媒体库里还没有内容", message = "在网页或手机上添加媒体库并扫描后，影片会出现在这里。")
        return
    }

    fun resume(item: UpNextItemView) {
        val episode = item.kind == "tv"
        router.play(PlayRequest(item.mediaItemId, if (episode) item.seasonNumber else null, if (episode) item.episodeNumber else null))
    }

    val preview = LocalStagePreview.current
    // 大图停稳在一部片上就预约它的预告：从上次停下的地方往前倒 30 秒，放到停下的地方
    if (preview != null) {
        UseStagePreview(preview, stage?.let { StagePreview.Request(it.mediaItemId, "resume", it.seasonNumber, it.episodeNumber) })
    }
    val ptPx = density.density * 0.5f
    val previewing = preview != null && stage != null && preview.showing && preview.key == stage.mediaItemId
    LaunchedEffect(previewing) { if (previewing) previewSince = System.currentTimeMillis() }
    LaunchedEffect(previewing, focus, stage?.mediaItemId, wakes) {
        val onStageCard = stage != null && focus == HomeFocus.Card(stage.mediaItemId)
        if (!previewing || !onStageCard || cardTopPx == null) {
            rowYielded = false
            return@LaunchedEffect
        }
        // 视频淡入之后再让（先看清换成了视频），还要离上一次操作 4 秒（刚进这一行的人正在挑卡）
        val until = maxOf(previewSince + 1_200, lastInput + 4_000)
        delay(maxOf(0L, until - System.currentTimeMillis()))
        rowYielded = true
    }
    val screenPx = 1080 * ptPx
    val yieldTarget = if (rowYielded) maxOf(0f, screenPx - 56 * ptPx - (cardTopPx ?: screenPx)) else 0f
    // 沉下去慢而柔，叫回来要快
    val yieldOffset by animateFloatAsState(
        yieldTarget,
        if (rowYielded) spring(dampingRatio = 1f, stiffness = 48.7f) else spring(dampingRatio = 0.9f, stiffness = 246f),
        label = "row-yield",
    )
    val yieldAlpha by animateFloatAsState(if (rowYielded) 0f else 1f, if (rowYielded) spring(1f, 48.7f) else spring(0.9f, 246f), label = "row-yield-alpha")
    val scrollPx = if (listState.firstVisibleItemIndex == 0) listState.firstVisibleItemScrollOffset.toFloat() else 100_000f
    LaunchedEffect(listState) {
        snapshotFlow { listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < 4 }
            .distinctUntilChanged()
            .collect { chrome.pillVisible = it }
    }
    // 焦点停稳 0.16 秒再换大图
    LaunchedEffect(focus) {
        val card = focus as? HomeFocus.Card ?: return@LaunchedEffect
        if (card.id == stageId) return@LaunchedEffect
        delay(160)
        stageId = card.id
    }
    // 开机落在首页：第一次有内容就把焦点放到「继续播放」上（只这一次）
    LaunchedEffect(stage?.mediaItemId) {
        if (stage == null || !launchFocusPending) return@LaunchedEffect
        for (wait in listOf(0L, 50, 100, 200, 400, 800)) {
            delay(wait)
            if (router.player != null || focus != null) break
            runCatching { playFocus.requestFocus() }
        }
        launchFocusPending = false
    }

    fun onFocusChange(new: HomeFocus?) {
        val old = focus
        focus = new
        lastInput = System.currentTimeMillis()
        when {
            new is HomeFocus.Card && old !is HomeFocus.Card ->
                scope.launch { listState.animateScrollToItem(0, (334 * ptPx).toInt()) }
            old is HomeFocus.Card && (new == HomeFocus.Play || new == HomeFocus.Details) ->
                scope.launch { listState.animateScrollToItem(0, 0) }
        }
    }

    Box(
        Modifier.fillMaxSize().onPreviewKeyEvent { event ->
            // 让位时遥控器的第一下只把卡片行叫回来，不挪焦点（TVWakeCatcher）
            if (!rowYielded || event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
            lastInput = System.currentTimeMillis()
            wakes++
            rowYielded = false
            true
        },
    ) {
        StageBackdrop(
            stage?.let { it.backdropUrl ?: it.episodeStillUrl ?: it.posterUrl },
            scrollPx = scrollPx,
            preview = if (preview != null && stage != null) { visible -> StagePreviewLayer(preview, stage.mediaItemId, visible) } else null,
        )
        NoAutoScroll {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(McMetrics.RowSpacing),
            contentPadding = PaddingValues(bottom = 80.pt),
        ) {
            item("stage") {
                if (stage == null) {
                    Spacer(Modifier.height((157 + 30).pt))
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(20.pt)) {
                        StageBlock(
                            info = {
                                CrossfadeInfo(stage) { s ->
                                    StageInfo(
                                        title = s.title,
                                        logo = s.logoUrl,
                                        headline = if (s.kind == "tv") episodeLine(s.seasonNumber, s.episodeNumber, s.episodeTitle) else null,
                                        meta = stageMeta(s),
                                        overview = s.overview,
                                    )
                                }
                            },
                            actions = {
                                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(24.pt)) {
                                    HeroButton(
                                        if (stage.positionMs > 0) "继续播放" else "播放",
                                        McIcons.Play,
                                        Modifier.focusRequester(playFocus).onFocusChanged { if (it.isFocused) onFocusChange(HomeFocus.Play) },
                                    ) { resume(stage) }
                                    HeroButton(
                                        "详情",
                                        McIcons.Info,
                                        Modifier.onFocusChanged { if (it.isFocused) onFocusChange(HomeFocus.Details) },
                                    ) { router.push(Route.Item(stage.libraryId, stage.mediaItemId)) }
                                }
                            },
                        )
                        Shelf(
                            "接下来继续",
                            // 从按钮往下回到这一行：落在大图正讲的那张卡上
                            modifier = Modifier
                                .graphicsLayer { translationY = yieldOffset }
                                .focusProperties { enter = { cardFocus[stage.mediaItemId] ?: FocusRequester.Default } },
                            titleAlpha = yieldAlpha,
                        ) {
                            items(upNext, key = { it.mediaItemId }) { item ->
                                val requester = cardFocus.getOrPut(item.mediaItemId) { FocusRequester() }
                                val current = item.mediaItemId == stage.mediaItemId
                                Box(
                                    Modifier
                                        .graphicsLayer { alpha = if (current) 1f else yieldAlpha }
                                        .onGloballyPositioned { if (!rowYielded) cardTopPx = it.positionInRoot().y },
                                ) {
                                if (current && rowYielded && preview != null) PreviewProgressLine(preview, Modifier.offset(y = (-26).pt))
                                LandscapeCard(
                                    image = if (item.kind == "tv") item.episodeStillUrl ?: item.backdropUrl else item.backdropUrl ?: item.posterUrl,
                                    title = item.title,
                                    onClick = { resume(item) },
                                    modifier = Modifier.focusRequester(requester),
                                    caption = CaptionMode.Always,
                                    badge = if (item.advanced) "下一集" else null,
                                    progress = (item.progressPercent ?: 0L) / 100f,
                                    detail = upNextBand(item),
                                    onLongClick = { menuFor = item },
                                    onFocus = { if (it) onFocusChange(HomeFocus.Card(item.mediaItemId)) },
                                )
                                }
                            }
                        }
                    }
                }
            }
            items(rows.filter { it.kind != HomeRows.Kind.UpNext }, key = { it.id }) { row ->
                Box(Modifier.graphicsLayer { translationY = yieldOffset; alpha = yieldAlpha }) {
                HomeRow(row, store, browsable, pinnedCollections) { focused ->
                    if (focused) {
                        onFocusChange(null)
                        val index = 1 + rows.filter { it.kind != HomeRows.Kind.UpNext }.indexOfFirst { it.id == row.id }
                        scope.launch {
                            // 选中展开的海报行滚到屏幕上方（下面的类型、简介才露得全）；
                            // 库卡、类型卡这种普通行同 tvOS：只滚到整行露全、上下各留一截
                            if (row.kind is HomeRows.Kind.Libraries || row.kind is HomeRows.Kind.Genres) {
                                ensureVisible(listState, index, (120 * ptPx).toInt())
                            } else {
                                // tvOS 的「滚到顶」对齐的是系统安全区下沿：行标题字形落在屏幕下约 140 点（两台模拟器截图量出，扣掉文字行高的上边距取 115）
                                listState.animateScrollToItem(index, -(115 * ptPx).toInt())
                            }
                        }
                    }
                }
                }
            }
        }
        }
    }
    menuFor?.let { item ->
        ActionMenu(
            listOf(
                MenuAction(if (item.positionMs > 0) "继续播放" else "播放", McIcons.Play) { resume(item) },
                MenuAction("查看详情", McIcons.Info) { router.push(Route.Item(item.libraryId, item.mediaItemId)) },
            ),
            onDismiss = { menuFor = null },
        )
    }
}

/** 卡片行让位时露在焦点卡上方的预告进度：416×4 的细线，每 0.25 秒读一次播放位置 */
@Composable
private fun PreviewProgressLine(preview: StagePreview, modifier: Modifier) {
    var progress by remember { mutableStateOf(preview.progress) }
    LaunchedEffect(preview) {
        while (true) {
            progress = preview.progress
            delay(250)
        }
    }
    val animated by animateFloatAsState(progress, tween(250, easing = LinearEasing), label = "preview-progress")
    Box(modifier.width(McMetrics.LandscapeWidth).height(4.pt).background(Color.White.copy(alpha = 0.25f), RoundedCornerShape(50))) {
        Box(Modifier.fillMaxWidth(animated).height(4.pt).background(Color.White.copy(alpha = 0.9f), RoundedCornerShape(50)))
    }
}

/** 只滚到第 [index] 项完整露出、离上下边各留 [margin] 像素（已经露全就不动） */
private suspend fun ensureVisible(state: androidx.compose.foundation.lazy.LazyListState, index: Int, margin: Int) {
    val info = state.layoutInfo
    val item = info.visibleItemsInfo.firstOrNull { it.index == index }
    if (item == null) {
        state.animateScrollToItem(index)
        return
    }
    val bottom = info.viewportEndOffset - margin
    val delta = when {
        item.offset < margin -> (item.offset - margin).toFloat()
        item.offset + item.size > bottom -> minOf(item.offset + item.size - bottom, item.offset - margin).toFloat()
        else -> 0f
    }
    if (delta != 0f) state.animateScrollBy(delta)
}

/** 大图区按钮（tvOS 默认按钮样式：焦点时白底黑字、略放大） */
@Composable
private fun HeroButton(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = modifier,
        contentPadding = PaddingValues(horizontal = 36.pt, vertical = 18.pt),
        scale = ButtonDefaults.scale(focusedScale = 1.06f),
        colors = ButtonDefaults.colors(
            containerColor = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.16f),
            contentColor = androidx.compose.ui.graphics.Color.White,
            focusedContainerColor = androidx.compose.ui.graphics.Color.White,
            focusedContentColor = androidx.compose.ui.graphics.Color.Black,
        ),
    ) {
        // tvOS 默认按钮：字约 29 点（body）、整颗高约 75 点（2026-10-08 两台模拟器截图量出）
        Icon(icon, null, modifier = Modifier.size(28.pt))
        Spacer(Modifier.size(12.pt))
        Text(title, style = McType.Body.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Medium))
    }
}

/** 「2023 · 古装 · 喜剧」，电影再加片长 */
private fun stageMeta(item: UpNextItemView): String {
    val parts = mutableListOf<String>()
    item.year?.let { parts += it.toString() }
    parts += item.genres.orEmpty().take(2)
    val duration = item.durationMs
    if (item.kind != "tv" && duration != null && duration >= 60_000) parts += Formatters.runtime(Math.round(duration / 60_000.0).toInt())
    return parts.joinToString(" · ")
}

/** 卡片底部暗带：「S2 E6 · 剩 18 分钟」「剩 1 小时 5 分」；还没开始看的写全长 */
fun upNextBand(item: UpNextItemView): String? {
    val parts = mutableListOf<String>()
    if (item.kind == "tv") parts += "S${item.seasonNumber} E${item.episodeNumber}"
    val duration = item.durationMs
    if (item.positionMs > 0 && duration != null && duration > 0) {
        val minutes = maxOf(1L, (duration - item.positionMs) / 60_000)
        parts += if (minutes >= 60) "剩 ${minutes / 60} 小时 ${minutes % 60} 分" else "剩 $minutes 分钟"
    } else if (duration != null && duration >= 60_000) {
        parts += Formatters.duration(duration)
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

/** 其余各行 */
@Composable
private fun HomeRow(
    row: HomeRows.Row,
    store: HomeStore,
    browsable: List<io.movieclaw.androidtv.core.model.generated.LibraryView>,
    pinnedCollections: List<io.movieclaw.androidtv.core.model.generated.CollectionView>,
    onRowFocus: (Boolean) -> Unit,
) {
    val router = LocalRouter.current
    when (val kind = row.kind) {
        HomeRows.Kind.UpNext -> Unit
        is HomeRows.Kind.Favorites -> {
            val favorites = store.favorites?.items.orEmpty()
            if (favorites.isEmpty()) return
            val entries = favorites.map {
                ShowcaseEntry(it.mediaItemId, it.title, it.kind, it.year, it.posterUrl, it.backdropUrl, it.seasons.count { s -> s > 0 }, it.libraryId)
            }
            LaunchedEffect(entries.map { it.id }) { store.loadShowcase(entries.map { it.id }) }
            ShowcaseShelf(row.title, entries, store.showcase, onOpen = { e -> e.libraryId?.let { router.push(Route.Item(it, e.id)) } }, onRowFocus = onRowFocus) {
                item("see-all") {
                    SeeAllCard(store.favorites?.total?.toInt(), onClick = {
                        router.push(Route.RowWall(row.title, WallSource.Favorites(kind.sort, kind.reversed, store.favorites?.total)))
                    })
                }
            }
        }
        HomeRows.Kind.Libraries -> {
            if (browsable.isEmpty() && pinnedCollections.isEmpty()) return
            Shelf(row.title, modifier = Modifier.onFocusChanged { onRowFocus(it.hasFocus) }) {
                items(browsable, key = { "lib${it.id}" }) { library ->
                    LibraryCard(library.name, "/libraries/${library.id}/cover", onClick = { router.push(Route.Library(library.id)) })
                }
                items(pinnedCollections, key = { "col${it.id}" }) { collection ->
                    LibraryCard(
                        collection.name,
                        if (collection.covers.isEmpty()) null else "/collections/${collection.id}/cover",
                        onClick = { router.push(Route.Collection(collection.id, collection.name)) },
                        collection = true,
                    )
                }
            }
        }
        is HomeRows.Kind.Genres -> {
            val genres = store.genresByKind[kind.kind].orEmpty()
            if (genres.isEmpty()) return
            Shelf(row.title, modifier = Modifier.onFocusChanged { onRowFocus(it.hasFocus) }) {
                items(genres, key = { it.value }) { genre ->
                    val id = genre.value.toLongOrNull() ?: return@items
                    GenreCard(genre.label, genre.count, kind.kind, genre.coverUrl, onClick = {
                        router.push(Route.RowWall(genre.label, WallSource.Genre(kind.kind, id, genre.count)))
                    })
                }
            }
        }
        is HomeRows.Kind.Library, is HomeRows.Kind.MediaKind, is HomeRows.Kind.Collection -> {
            val items = store.itemsByKey[HomeRows.fetchKey(row)].orEmpty()
            if (items.isEmpty()) return
            val fallbackLibrary = (kind as? HomeRows.Kind.Library)?.library?.id
            val entries = items.map {
                ShowcaseEntry(it.mediaItemId, it.title, it.kind, it.year, it.posterUrl, it.backdropUrl, it.seasons.count { s -> s > 0 }, it.libraryId ?: fallbackLibrary)
            }
            LaunchedEffect(entries.map { it.id }) { store.loadShowcase(entries.map { it.id }) }
            val source = when (kind) {
                is HomeRows.Kind.Library -> WallSource.Library(kind.library.id, kind.sort, kind.reversed, kind.unwatched, kind.library.stats.itemCount)
                is HomeRows.Kind.MediaKind -> WallSource.MediaKind(kind.kind, kind.sort, kind.reversed, kind.unwatched)
                is HomeRows.Kind.Collection -> WallSource.Collection(kind.collection.id, kind.sort, kind.reversed)
                else -> null
            }
            // 「查看全部」上写的总数：只在确切知道时写（媒体库没加筛选时用库的统计）
            val total = (kind as? HomeRows.Kind.Library)?.takeIf { !it.unwatched && it.sort != "last_played" }?.library?.stats?.itemCount
            ShowcaseShelf(row.title, entries, store.showcase, onOpen = { e -> e.libraryId?.let { router.push(Route.Item(it, e.id)) } }, onRowFocus = onRowFocus) {
                if (source != null) {
                    item("see-all") { SeeAllCard(total?.toInt(), onClick = { router.push(Route.RowWall(row.title, source)) }) }
                }
            }
        }
    }
}
