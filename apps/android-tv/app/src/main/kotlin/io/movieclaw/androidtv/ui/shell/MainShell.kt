package io.movieclaw.androidtv.ui.shell

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.layout
import io.movieclaw.androidtv.ui.LaunchArgs
import io.movieclaw.androidtv.ui.accounts.AboutScreen
import io.movieclaw.androidtv.ui.accounts.AccountsScreen
import io.movieclaw.androidtv.ui.accounts.LicenseScreen
import io.movieclaw.androidtv.ui.detail.ItemDetailScreen
import io.movieclaw.androidtv.ui.detail.PersonScreen
import io.movieclaw.androidtv.ui.home.HomeScreen
import io.movieclaw.androidtv.ui.library.CollectionWallScreen
import io.movieclaw.androidtv.ui.library.LibraryWallScreen
import io.movieclaw.androidtv.ui.library.RowWallScreen
import io.movieclaw.androidtv.ui.player.PlayerScreen
import io.movieclaw.androidtv.ui.search.SearchScreen
import io.movieclaw.androidtv.ui.theme.McColors
import kotlinx.coroutines.delay

/** 页面告诉外壳：左上角「‹ 首页」胶囊要不要显示（页签根页滚到顶时才显示，同 tvOS 往下滚时收起） */
class ShellChrome {
    var pillVisible by mutableStateOf(true)
}

val LocalShellChrome = compositionLocalOf { ShellChrome() }

/** 这一页现在是否在屏幕上（页签根页在压栈期间仍然存活，但不可见） */
val LocalPageVisible = compositionLocalOf { true }

/** 首页数据跟着账号走、主界面共享（详情页挑起始季要读「接下来继续」） */
val LocalHomeStore = compositionLocalOf<io.movieclaw.androidtv.ui.home.HomeStore?> { null }

/** 主界面共享的大图预告（首页与详情页同一个，进详情接着放） */
val LocalStagePreview = compositionLocalOf<io.movieclaw.androidtv.ui.stage.StagePreview?> { null }

/**
 * 主界面外壳（TVMainView）：
 * - 左侧可收起的侧边栏（账号 / 搜索 / 首页）。平时只有左上角一枚「‹ 当前页」胶囊；在页面最左边再按左、
 *   或在页签根页按返回，展开侧边栏并把焦点交给它。侧边栏里上下移动不换页，按确认才切过去；选当前页签退回根页。
 * - 每个页签一个导航栈，各自记住浏览位置；二级页盖满整屏、不显示胶囊。
 * - 返回键：页面里有二级页就退一层；焦点在侧边栏时收起侧边栏、焦点还给页面；页签根页上第一次返回展开侧边栏、
 *   第二次退出 App。
 * - 播放器盖在整个界面之上，有自己的返回键处理。
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun MainShell(args: LaunchArgs) {
    val router = remember { Router() }
    val chrome = remember { ShellChrome() }
    val activity = androidx.activity.compose.LocalActivity.current
    var sidebarOpen by remember { mutableStateOf(false) }
    var focusInSidebar by remember { mutableStateOf(false) }
    val pageFocus = remember { FocusRequester() }
    val sidebarFocus = remember { FocusRequester() }
    val saveable = rememberSaveableStateHolder()
    val graph = io.movieclaw.androidtv.LocalGraph.current
    val session = io.movieclaw.androidtv.LocalSession.current
    val homeStore = remember(session.key) { io.movieclaw.androidtv.ui.home.HomeStore(session.api) }
    val upNextUnit: (Long) -> Pair<Long, Long>? = { id ->
        homeStore.upNext?.firstOrNull { it.mediaItemId == id && it.kind == "tv" }?.let { it.seasonNumber to it.episodeNumber }
    }
    val preview = io.movieclaw.androidtv.ui.stage.rememberStagePreview(session.api, session.server, graph.http, graph.identity.userAgent, graph.appScope)
    // 正片播放器打开时拆掉预告，关掉后重新开始
    LaunchedEffect(router.player) {
        if (router.player != null) preview.interrupt() else { delay(1000); preview.resume() }
    }
    val focusManager = LocalFocusManager.current

    LaunchedEffect(Unit) {
        when (args.tab) {
            "account" -> router.select(MainTab.Account)
            "search" -> router.select(MainTab.Search)
        }
        args.item?.let { (lib, id) -> router.push(Route.Item(lib, id)) }
        args.playMediaItemId?.let { router.play(PlayRequest(it)) }
        args.play?.let(router::play)
    }

    // 「继续观看」/ 深链：续播直接开播放器，条目回到首页页签压上详情
    val pendingLink by graph.deepLinks.collectAsState()
    LaunchedEffect(pendingLink) {
        when (val link = pendingLink ?: return@LaunchedEffect) {
            is io.movieclaw.androidtv.system.DeepLink.Play -> router.play(PlayRequest(link.mediaItemId, link.season, link.episode))
            is io.movieclaw.androidtv.system.DeepLink.Item -> {
                router.select(MainTab.Home)
                router.stack.clear()
                router.push(Route.Item(link.libraryId, link.itemId))
            }
        }
        graph.deepLinks.value = null
    }

    fun openSidebar() {
        sidebarOpen = true
    }

    fun closeSidebar() {
        sidebarOpen = false
        runCatching { pageFocus.requestFocus() }
    }

    LaunchedEffect(sidebarOpen) {
        if (sidebarOpen) {
            delay(30)
            runCatching { sidebarFocus.requestFocus() }
        }
    }

    BackHandler(enabled = router.player == null) {
        when {
            focusInSidebar && router.stack.isNotEmpty() -> closeSidebar()
            focusInSidebar -> activity?.finish()
            router.pop() -> Unit
            else -> openSidebar()
        }
    }

    CompositionLocalProvider(LocalRouter provides router, LocalShellChrome provides chrome, LocalStagePreview provides preview,
        LocalHomeStore provides homeStore,
        io.movieclaw.androidtv.ui.detail.LocalUpNextUnit provides upNextUnit,
    ) {
        Box(Modifier.fillMaxSize().background(McColors.Background)) {
            val stack = router.stack
            val top = stack.lastOrNull()
            Box(
                Modifier
                    .fillMaxSize()
                    .focusRequester(pageFocus)
                    .focusRestorer()
                    .focusProperties { canFocus = !sidebarOpen }
                    // 页面最左边再按左：展开侧边栏。按键冒泡到这里说明页面里没人处理，先试着往左挪焦点，挪不动才展开
                    .onKeyEvent { event ->
                        if (event.type != KeyEventType.KeyDown || event.nativeKeyEvent.keyCode != android.view.KeyEvent.KEYCODE_DPAD_LEFT) {
                            return@onKeyEvent false
                        }
                        if (!focusManager.moveFocus(FocusDirection.Left)) openSidebar()
                        true
                    }
                    .focusGroup(),
            ) {
                // 导航栈里每一页都保持存活（同 tvOS 导航栈）：只摆出栈顶那页，压在下面的不摆放、不参与方向键找焦点，
                // 退回时焦点回到原来那颗（LayerFocusMemory）
                val layers = listOf<Route?>(null) + stack
                layers.forEachIndexed { index, route ->
                    val visible = index == layers.lastIndex
                    val key = if (route == null) "root:${router.tab}" else "${router.tab}:$index:$route"
                    androidx.compose.runtime.key(key) {
                        val layerFocus = remember { FocusRequester() }
                        val memory = remember { io.movieclaw.androidtv.ui.components.LayerFocusMemory() }
                        Box(
                            Modifier
                                .fillMaxSize()
                                .layout { measurable, constraints ->
                                    val placeable = measurable.measure(constraints)
                                    layout(placeable.width, placeable.height) { if (visible) placeable.place(0, 0) }
                                }
                                .focusRequester(layerFocus)
                                .focusRestorer()
                                .focusGroup(),
                        ) {
                            CompositionLocalProvider(
                                LocalPageVisible provides visible,
                                io.movieclaw.androidtv.ui.components.LocalLayerFocusMemory provides memory,
                            ) {
                                saveable.SaveableStateProvider(key) {
                                    when (route) {
                                        null -> when (router.tab) {
                                            MainTab.Home -> HomeScreen()
                                            MainTab.Search -> SearchScreen()
                                            MainTab.Account -> AccountsScreen()
                                        }
                                        is Route.Item -> ItemDetailScreen(route.libraryId, route.itemId)
                                        is Route.Library -> LibraryWallScreen(route.id)
                                        is Route.Collection -> CollectionWallScreen(route.id, route.name)
                                        is Route.Person -> PersonScreen(route)
                                        is Route.RowWall -> RowWallScreen(route.title, route.source)
                                        Route.About -> AboutScreen()
                                        is Route.License -> LicenseScreen(route.componentName)
                                    }
                                }
                            }
                        }
                        // 退回到这一页：焦点回到离开时那颗（新压进来的页自己会要焦点）
                        var shown by remember { mutableStateOf(visible) }
                        LaunchedEffect(visible) {
                            if (visible && !shown) {
                                delay(30)
                                if (!memory.restore()) runCatching { layerFocus.requestFocus() }
                            }
                            shown = visible
                        }
                    }
                }
            }
            // 平时左上角的「‹ 当前页」胶囊：页签根页、滚到顶、侧边栏收起时显示
            AnimatedVisibility(
                visible = !sidebarOpen && top == null && chrome.pillVisible && router.player == null,
                enter = fadeIn(tween(200)),
                exit = fadeOut(tween(200)),
            ) { SidebarPill(router.tab) }
            AnimatedVisibility(sidebarOpen, enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
                Sidebar(
                    current = router.tab,
                    focusRequester = sidebarFocus,
                    modifier = Modifier.onFocusChanged { focusInSidebar = it.hasFocus },
                    onSelect = {
                        router.select(it)
                        closeSidebar()
                    },
                    onClose = ::closeSidebar,
                )
            }
            router.player?.let { request ->
                PlayerScreen(request, onClose = {
                    router.closePlayer()
                    runCatching { pageFocus.requestFocus() }
                })
            }
        }
    }
}
