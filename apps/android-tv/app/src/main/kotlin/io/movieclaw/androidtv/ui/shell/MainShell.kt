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
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
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
import io.movieclaw.androidtv.ui.theme.pt
import kotlinx.coroutines.delay

/** 页面告诉外壳：左上角「‹ 首页」胶囊要不要显示（页签根页滚到顶时才显示，同 tvOS 往下滚时收起） */
class ShellChrome {
    var pillVisible by mutableStateOf(true)
}

val LocalShellChrome = compositionLocalOf { ShellChrome() }

/** 外壳记下的栈顶那页（只在回调里读，不参与界面刷新） */
private class TopLayer {
    var memory: io.movieclaw.androidtv.ui.components.LayerFocusMemory? = null
}

/** 这一页现在是否在屏幕上（页签根页在压栈期间仍然存活，但不可见） */
val LocalPageVisible = compositionLocalOf { true }

/** 首页数据跟着账号走、主界面共享（详情页挑起始季要读「接下来继续」） */
val LocalHomeStore = compositionLocalOf<io.movieclaw.androidtv.ui.home.HomeStore?> { null }

/** 主界面共享的大图预告（首页与详情页同一个，进详情接着放） */
val LocalStagePreview = compositionLocalOf<io.movieclaw.androidtv.ui.stage.StagePreview?> { null }

/**
 * 主界面外壳（TVMainView）：
 * - 左侧可收起的侧边栏（账号 / 搜索 / 首页）。平时只有左上角一枚「‹ 当前页」胶囊；在页面最左边再按左、
 *   展开侧边栏并把焦点交给它。侧边栏里上下移动不换页，按确认才切过去；选当前页签退回根页。
 * - 每个页签一个导航栈，各自记住浏览位置；二级页盖满整屏、不显示胶囊。
 * - 返回键：侧边栏开着先收起它、焦点还给页面（同选当前页签）；页面里有二级页就退一层；账号 / 搜索页签的根页回首页；
 *   首页根页上先提示「再按一次返回键退出」，2 秒内再按才退出 App（[backAction]）。
 * - 播放器盖在整个界面之上，有自己的返回键处理。
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun MainShell(args: LaunchArgs) {
    val router = remember { Router() }
    val chrome = remember { ShellChrome() }
    val activity = androidx.activity.compose.LocalActivity.current
    var sidebarOpen by remember { mutableStateOf(false) }
    val pageFocus = remember { FocusRequester() }
    val sidebarFocus = remember { FocusRequester() }
    val saveable = rememberSaveableStateHolder()
    /** 各页签导航栈里现有各页的保存状态 key：页被弹出时据此清掉 */
    val shownKeys = remember { HashMap<MainTab, List<String>>() }
    val graph = io.movieclaw.androidtv.LocalGraph.current
    val session = io.movieclaw.androidtv.LocalSession.current
    val homeStore = remember(session.key) { io.movieclaw.androidtv.ui.home.HomeStore(session.api) }
    // App 自身更新：进主界面后每天最多自动问一次；有新版弹窗（「谁在看」页底部可手动检查）
    LaunchedEffect(session.key) { graph.appUpdate.autoCheck(session) }
    io.movieclaw.androidtv.ui.update.TvUpdateDialog(graph.appUpdate, session)
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

    // 栈顶那页的焦点记忆：收起侧边栏、关掉播放器时焦点回到离开时那颗，没有记录再交给页面自己挑
    val topLayer = remember { TopLayer() }
    fun focusPage() {
        if (topLayer.memory?.restore() != true) runCatching { pageFocus.requestFocus() }
    }

    fun closeSidebar() {
        sidebarOpen = false
        focusPage()
    }

    LaunchedEffect(sidebarOpen) {
        if (sidebarOpen) {
            delay(30)
            runCatching { sidebarFocus.requestFocus() }
        }
    }

    // 首页根页按过一次返回键的时刻（正显示「再按一次返回键退出」），过了 EXIT_WINDOW_MS 自动清掉
    var exitArmedAt by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(exitArmedAt) {
        if (exitArmedAt != null) {
            delay(EXIT_WINDOW_MS)
            exitArmedAt = null
        }
    }

    BackHandler(enabled = router.player == null) {
        val now = android.os.SystemClock.uptimeMillis()
        val action = backAction(sidebarOpen, router.stack.isEmpty(), router.tab, exitArmedAt, now)
        exitArmedAt = if (action == BackAction.ArmExit) now else null
        when (action) {
            BackAction.CloseSidebar -> closeSidebar()
            BackAction.Pop -> router.pop()
            // 同「谁在看」里选自己回首页：首页根页重新摆出来时自己把焦点放到「继续播放」上
            BackAction.GoHome -> router.select(MainTab.Home)
            BackAction.ArmExit -> Unit
            BackAction.Exit -> activity?.finish()
        }
    }

    // 自动播放预告默认关：不提供预告控制器，首页 / 详情页只放静态剧照（开关在「谁在看」页）
    CompositionLocalProvider(LocalRouter provides router, LocalShellChrome provides chrome, LocalStagePreview provides preview.takeIf { graph.autoPreview },
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
                // 弹出栈的页清掉它保存的状态：同一深度再压进同一页是新的实例（同 tvOS 的导航栈），
                // 不接着用上次的窗口、筛选与焦点。切页签时别的页签的栈不算弹出，保留
                val keys = stack.mapIndexed { index, route -> "${router.tab}:${index + 1}:$route" }
                SideEffect {
                    shownKeys[router.tab].orEmpty().filterNot { it in keys }.forEach(saveable::removeState)
                    shownKeys[router.tab] = keys
                }
                layers.forEachIndexed { index, route ->
                    val visible = index == layers.lastIndex
                    val key = if (route == null) "root:${router.tab}" else "${router.tab}:$index:$route"
                    androidx.compose.runtime.key(key) {
                        val layerFocus = remember { FocusRequester() }
                        val memory = remember { io.movieclaw.androidtv.ui.components.LayerFocusMemory() }
                        if (visible) androidx.compose.runtime.SideEffect { topLayer.memory = memory }
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
                    onSelect = {
                        router.select(it)
                        closeSidebar()
                    },
                    onClose = ::closeSidebar,
                )
            }
            // 首页根页按一次返回键：顶部一句提示（同播放器的提示胶囊），不挡操作、到时自己消失
            AnimatedVisibility(
                visible = exitArmedAt != null,
                modifier = Modifier.align(Alignment.TopCenter).padding(top = 48.pt),
                enter = fadeIn(tween(200)),
                exit = fadeOut(tween(200)),
            ) { io.movieclaw.androidtv.ui.player.NoticeCapsule("再按一次返回键退出") }
            router.player?.let { request ->
                PlayerScreen(request, onClose = {
                    router.closePlayer()
                    focusPage()
                })
            }
        }
    }
}
