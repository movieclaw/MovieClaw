package io.movieclaw.android.routing

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.playback.PlaybackSessionHolder
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.feature.agent.AgentConversationScreen
import io.movieclaw.android.feature.agent.AgentNewSessionScreen
import io.movieclaw.android.feature.agent.AgentSessionsScreen
import io.movieclaw.android.feature.detail.ItemDetailScreen
import io.movieclaw.android.feature.discover.CollectionScreen
import io.movieclaw.android.feature.discover.TitleDetailScreen
import io.movieclaw.android.feature.library.LibraryDetailScreen
import io.movieclaw.android.feature.notices.NoticeCenterScreen
import io.movieclaw.android.feature.settings.DevicesSettingsScreen
import io.movieclaw.android.feature.settings.PlaybackSettingsScreen
import io.movieclaw.android.feature.settings.ProfileSettingsScreen
import io.movieclaw.android.feature.settings.SettingsIndexScreen
import io.movieclaw.android.feature.settings.WebManagedSectionScreen
import io.movieclaw.android.feature.account.AccountSwitcherScreen
import io.movieclaw.android.feature.onboarding.LoginScreen
import io.movieclaw.android.feature.settings.LogsSettingsScreen
import io.movieclaw.android.feature.settings.MaintenanceSettingsScreen
import io.movieclaw.android.feature.settings.NetworkSettingsScreen
import io.movieclaw.android.feature.settings.MembersSettingsScreen
import io.movieclaw.android.feature.player.PlayerScreen
import io.movieclaw.android.feature.root.MainTabScreen
import io.movieclaw.android.feature.search.SearchMode
import io.movieclaw.android.feature.search.SearchScreen
import io.movieclaw.android.feature.subscriptions.SubscribeScreen
import io.movieclaw.android.feature.subscriptions.SubscriptionDetailScreen
import javax.inject.Inject
import io.movieclaw.android.feature.library.FavoritesScreen
import io.movieclaw.android.feature.library.CollectionsScreen
import io.movieclaw.android.feature.library.LibraryCollectionScreen
import io.movieclaw.android.feature.library.LibraryCustomizeScreen
import io.movieclaw.android.feature.library.LibraryFormScreen
import io.movieclaw.android.feature.offline.DownloadsScreen
import io.movieclaw.android.feature.settings.ActivateScreen
import io.movieclaw.android.feature.library.LibraryManageScreen
import io.movieclaw.android.feature.library.LibraryPersonScreen
import io.movieclaw.android.feature.root.MainTab
import io.movieclaw.android.feature.root.MainTabBus
import io.movieclaw.android.feature.discover.PersonScreen
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.BoxWithConstraints
import dev.chrisbanes.haze.hazeSource
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import io.movieclaw.android.core.designsystem.CardMetrics
import io.movieclaw.android.core.designsystem.LocalCardMetrics
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.blur
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.ui.zIndex
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.launch
import io.movieclaw.android.core.network.dataOrThrow
import androidx.navigation.compose.currentBackStackEntryAsState

@HiltViewModel
class NavViewModel @Inject constructor(private val holder: PlaybackSessionHolder) : ViewModel() {
    fun open(target: PlayTarget) = holder.open(target)
}

/** M1 导航:五 Tab 主壳 + 库详情 + 条目详情 + 播放器(全屏,会话在应用级宿主) */
@Composable
fun AppNav() {
    val navController = rememberNavController()
    val navVm: NavViewModel = hiltViewModel()
    val context = androidx.compose.ui.platform.LocalContext.current
    // 分享要拼条目的网页地址：会话仓库经 EntryPoint 取（AppNav 不在 Hilt 注入图里）
    val sessionRepo = androidx.compose.runtime.remember {
        dagger.hilt.android.EntryPointAccessors.fromApplication(
            context.applicationContext,
            SessionRepositoryEntry::class.java,
        ).sessionRepository()
    }

    // 全站订阅索引（单例）：发现页的订阅判断由它统一提供
    val subscriptionsEntry = androidx.compose.runtime.remember {
        dagger.hilt.android.EntryPointAccessors.fromApplication(
            context.applicationContext,
            SubscriptionIndexEntry::class.java,
        )
    }
    val subscriptions = androidx.compose.runtime.remember { subscriptionsEntry.subscriptionIndex() }
    // 订阅在别处被改动（弹层里取消 / 新建）后，索引必须作废并重拉——否则卡片的
    // 「已订阅」会继续挂到 30 秒缓存过期（用户报"取消后卡片还显示已订阅"）。
    androidx.compose.runtime.LaunchedEffect(
        io.movieclaw.android.feature.subscriptions.SubscriptionEvents.revision
    ) {
        if (io.movieclaw.android.feature.subscriptions.SubscriptionEvents.revision > 0) {
            subscriptions.invalidate()
            subscriptions.ensureLoaded()
        }
    }

    // 取消订阅的 VM 通过它把那条从索引里摘掉（比等一次重拉更及时）
    io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.removeFromIndex = { id ->
        subscriptions.remove(id)
    }


    // 通知点按带来的路由（core/notify `NotifyRouteBus`）：直接进那一条详情（条目 / 订阅）
    androidx.compose.runtime.LaunchedEffect(Unit) {
        io.movieclaw.android.core.notify.NotifyRouteBus.requested.collect { route ->
            if (route != null) {
                io.movieclaw.android.core.notify.NotifyRouteBus.consume()
                runCatching { navController.navigate(route) }
            }
        }
    }

    // 窗口宽 → 尺寸 token（`CardMetrics`）。**挂在整个 NavHost 外面**：详情、设置、播放
    // 这些页面是 `tabs` 的**同级路由**，若只挂在 `MainTabScreen` 里，它们读到的永远是
    // 手机那套默认值（`LocalCardMetrics` 的 fallback），平板适配等于没生效。
    BoxWithConstraints(Modifier.fillMaxSize()) {
    val cardMetrics = CardMetrics.forWindow(maxWidth)
    CompositionLocalProvider(LocalCardMetrics provides cardMetrics) {
    // 宽窗口：**侧边栏画在 NavHost 外面**，深层路由（库页 / 详情页 / 设置）不再把它顶掉。
    // 这是 `ipad.md` §3「外壳常驻」的最小实现；每页签独立导航栈还没做，切页签会回到该页签根页。
    val wideShell = LocalCardMetrics.current.isWide
    val shellSidebarVm: io.movieclaw.android.feature.root.SidebarViewModel = hiltViewModel()
    val shellSidebar by shellSidebarVm.data.collectAsStateWithLifecycle()
    val shellPermissions = io.movieclaw.android.core.session.LocalPermissions.current
    var shellTab by rememberSaveable { mutableStateOf(io.movieclaw.android.feature.root.MainTab.DISCOVER) }
    val shellTabs = io.movieclaw.android.feature.root.MainTab.entries.filter { tab ->
        when (tab) {
            io.movieclaw.android.feature.root.MainTab.SUBSCRIPTIONS -> shellPermissions.canSubscribe
            io.movieclaw.android.feature.root.MainTab.ACTIVITY -> shellPermissions.isAdmin
            else -> true
        }
    }
    // ── 每个页签各自一条**导航链**（`ipad.md` §3 `paths[ShellTab]`）──
    // 安卓这里是单 NavHost，`NavController` 不暴露历史条目的实参。所以自己按页签维护
    // 一条路由链：每进一层就把「模式串 + 实参还原成的 URL」追加进当前页签的链；
    // 切走时链自然留在 map 里，切回时先 pop 到 tabs 再按顺序重放整条链——
    // 于是层级、以及「按返回逐层退回」都还原了，而不只是最深一层。
    // **可保存**：用 `remember` 时旋转/进程重建后只剩当前一层，
    // 复现路径「详情页旋转 → 返回」会直接回 tabs 而不是回库墙。
    val tabChains = androidx.compose.runtime.saveable.rememberSaveable(
        saver = androidx.compose.runtime.saveable.Saver(
            save = { m -> m.entries.associate { it.key.name to it.value.toList() } },
            restore = { saved ->
                mutableStateMapOf<io.movieclaw.android.feature.root.MainTab, List<String>>().apply {
                    saved.forEach { (k, v) ->
                        io.movieclaw.android.feature.root.MainTab.entries
                            .firstOrNull { it.name == k }?.let { put(it, v) }
                    }
                }
            },
        ),
    ) { mutableStateMapOf<io.movieclaw.android.feature.root.MainTab, List<String>>() }
    val currentEntry by navController.currentBackStackEntryAsState()
    // 由路由回推「这属于哪个页签」：详情 / 订阅详情 / 活动二级 / 设置这些深层页面不在 `tabs` 这一层，
    // `MainTabScreen` 的 onCurrentTabChanged 收不到通知，侧边栏高亮会停在进页面前那个标签。
    fun tabOf(route: String): io.movieclaw.android.feature.root.MainTab? = when {
        route.startsWith("subscription") -> io.movieclaw.android.feature.root.MainTab.SUBSCRIPTIONS
        route.startsWith("activity") -> io.movieclaw.android.feature.root.MainTab.ACTIVITY
        route.startsWith("settings") || route.startsWith("more") -> io.movieclaw.android.feature.root.MainTab.MORE
        // 搜索页：侧边栏没有「搜索」页签，按浏览动线归到「发现」
        // （比让高亮停在无关页签上合理）
        route.startsWith("search") -> io.movieclaw.android.feature.root.MainTab.DISCOVER
        route.startsWith("library") || route.startsWith("item") ||
            route.startsWith("collection") -> io.movieclaw.android.feature.root.MainTab.LIBRARY
        else -> null
    }
    androidx.compose.runtime.LaunchedEffect(currentEntry) {
        val entry = currentEntry ?: return@LaunchedEffect
        val destRoute = entry.destination.route.orEmpty()
        if (destRoute == "tabs") {
            // 回到根：这条链清空（随后重放时会按顺序重新长出来）
            tabChains[shellTab] = emptyList()
            return@LaunchedEffect
        }
        // **先定标签、再记链**：两段 effect 分开写时，记链那段会用旧的 shellTab，
        // 把「library/日韩剧」这种路由记进当时还停在「发现」的页签链里，
        // 之后点「发现」就会重放它、跳到日韩剧（真机复现过）。合成一段就不会错序。
        val tab = tabOf(destRoute)
        if (tab != null && tab != shellTab) shellTab = tab
        val owner = tab ?: shellTab
        val filled = filledRouteOf(entry) ?: return@LaunchedEffect
        val chain = tabChains[owner].orEmpty()
        // 同一层重复上报（重组/旋转）不重复追加
        if (chain.lastOrNull() != filled) tabChains[owner] = chain + filled
    }
    var shellBackdrop by remember { mutableStateOf<ShellBackdrop?>(null) }
    // 当前所处的库 / 合集 id（路由参数）：侧边栏对应那一行要高亮
    val currentRoute = currentEntry?.destination?.route.orEmpty()
    val routeArgs = currentEntry?.arguments
    val selectedLibraryId = if (currentRoute.startsWith("library/")) routeArgs?.getString("libraryId")?.toLongOrNull() else null
    val selectedCollectionId = if (currentRoute.startsWith("libraryCollection/")) routeArgs?.getString("collectionId")?.toLongOrNull() else null
    // 剧照取样源：侧边栏用它做玻璃模糊（iOS 侧边栏是液态玻璃）
    // 侧栏状态点：与底栏同源（MainTabBus.publishDots），按枚举映射到侧栏自己的索引
    val tabDots by io.movieclaw.android.feature.root.MainTabBus.tabDots.collectAsStateWithLifecycle()
    val sidebarDots: Map<Int, io.movieclaw.android.core.designsystem.TabDot> =
        androidx.compose.runtime.remember(tabDots, shellTabs) {
            buildMap {
                tabDots.forEach { (t, d) ->
                    shellTabs.indexOf(t).takeIf { it >= 0 }?.let { put(it, d) }
                }
            }
        }
    // 剧照背景只该出现在「发现」和详情类页面上。活动 / 我的 / 订阅 / 媒体库是纯黑底，
    // 切过去时发现页仍被 KeepAliveTabs 保活、发布值不会自动清掉 → 侧栏继续透出剧照（真机复现）。
    // 所以在**渲染时**按当前页签判断，而不是依赖页面自己清理。
    val backdropAllowed = shellTab == io.movieclaw.android.feature.root.MainTab.DISCOVER ||
        shellTab == io.movieclaw.android.feature.root.MainTab.SUBSCRIPTIONS ||
        currentRoute.startsWith("item/") || currentRoute.startsWith("title") ||
        currentRoute.startsWith("library/") || currentRoute.startsWith("libraryCollection/")
    val shellHazeState = dev.chrisbanes.haze.rememberHazeState()
    androidx.compose.foundation.layout.Box(Modifier.fillMaxSize()) {
    // 只在宽窗口画：竖屏没有侧边栏，画了纯属浪费，还可能从页面边缘漏出来
    if (cardMetrics.isWide && backdropAllowed && currentRoute != "player") shellBackdrop?.let { bd ->
        val heroHeight = bd.heroHeight
        if (heroHeight != null) {
            val scroll = bd.scrollState
            androidx.compose.foundation.layout.Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black)
                    .hazeSource(shellHazeState),
            ) {
                androidx.compose.foundation.layout.Box(
                    Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            val scrolled = (scroll?.value ?: 0).toFloat()
                            alpha = (1f - scrolled / 900f).coerceIn(0.35f, 1f)
                        }
                        .background(
                            Brush.verticalGradient(
                                0f to bd.tint.copy(alpha = 0.85f),
                                0.42f to bd.tint.copy(alpha = 0.50f),
                                0.72f to bd.tint.copy(alpha = 0.14f),
                                1f to Color.Transparent,
                            )
                        ),
                )
                androidx.compose.foundation.layout.Box(
                    Modifier
                        .fillMaxWidth()
                        .height(heroHeight)
                        .graphicsLayer {
                            translationY = -(scroll?.value ?: 0).toFloat()
                            compositingStrategy = CompositingStrategy.Offscreen
                        }
                        .drawWithContent {
                            drawContent()
                            drawRect(
                                brush = Brush.verticalGradient(
                                    0f to Color.Black,
                                    0.56f to Color.Black,
                                    0.80f to Color.Black.copy(alpha = 0.6f),
                                    1f to Color.Transparent,
                                ),
                                blendMode = BlendMode.DstIn,
                            )
                        },
                ) {
                    androidx.compose.animation.Crossfade(
                        targetState = bd.url,
                        animationSpec = androidx.compose.animation.core.tween(durationMillis = 700),
                        label = "shell-hero",
                    ) { url ->
                        io.movieclaw.android.core.designsystem.RemoteImage(
                            url = url,
                            origin = bd.origin,
                            contentDescription = null,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                    androidx.compose.foundation.layout.Box(
                        Modifier
                            .fillMaxWidth()
                            .height(heroHeight * 0.26f)
                            .background(
                                Brush.verticalGradient(
                                    listOf(Color.Black.copy(alpha = 0.5f), Color.Transparent)
                                )
                            ),
                    )
                    androidx.compose.foundation.layout.Box(
                        Modifier
                            .matchParentSize()
                            .background(
                                Brush.verticalGradient(
                                    0.36f to Color.Transparent,
                                    1f to Color.Black.copy(alpha = 0.5f),
                                )
                            ),
                    )
                }
            }
        } else {
            androidx.compose.foundation.layout.Box(
                Modifier
                    .fillMaxSize()
                    .background(bd.tint)
                    .hazeSource(shellHazeState),
            ) {
                io.movieclaw.android.core.designsystem.RemoteImage(
                    url = bd.url,
                    origin = bd.origin,
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize().blur(20.dp),
                )
                androidx.compose.foundation.layout.Box(
                    Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.45f)),
                )
            }
        }
    }
    }
    androidx.compose.foundation.layout.Box(Modifier.fillMaxSize()) {
    // 沉浸页面（播放器等）不画侧栏：视频要占满整屏，侧栏留着既挡画面又多余。
    // 这些路由本身是全屏的，退出时回到原页面，侧栏自然回来。
    val immersiveRoute = currentRoute == "player" || currentRoute.startsWith("player?")
    val showSidebar = wideShell && !immersiveRoute
    // 发现页根路由：内容整窗铺；其他页面内容仍从侧栏右缘 248dp 开始，不被卡片覆盖。
    val isDiscoverHome = currentRoute == "tabs" &&
        shellTab == io.movieclaw.android.feature.root.MainTab.DISCOVER
    if (showSidebar) {
        val inset = io.movieclaw.android.core.designsystem.McShellInset
        androidx.compose.foundation.layout.Box(
            Modifier
                .align(Alignment.TopStart)
                .zIndex(1f)
                .padding(
                    // 发现页：浮起卡片留 14dp 外边距；其他页面：卡片贴左，内容从 248dp 开始。
                    start = if (isDiscoverHome) inset else 0.dp,
                    top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + inset,
                    bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + inset,
                )
                .width(io.movieclaw.android.core.designsystem.McSidebarWidth)
                .fillMaxHeight(),
        ) {
            io.movieclaw.android.core.designsystem.McSidebar(
            icons = shellTabs.map { it.icon },
            labels = shellTabs.map { it.label },
            selectedIndex = shellTabs.indexOf(shellTab).coerceAtLeast(0),
            onSelect = { i ->
                val target = shellTabs[i]
                if (target == shellTab) {
                    // 再点当前页签 → 回该页签根页
                    navController.popBackStack("tabs", inclusive = false)
                } else {
                    // 先取出目标页签的链（后面 pop 到 tabs 会把它清空，所以必须先存下来）
                    val restore = tabChains[target].orEmpty()
                    shellTab = target
                    io.movieclaw.android.feature.root.MainTabBus.open(target)
                    navController.popBackStack("tabs", inclusive = false)
                    // 按顺序重放，返回栈于是也是多级的
                    restore.forEach { runCatching { navController.navigate(it) } }
                }
            },
            libraries = shellSidebar.libraries.map { it.id to it.name },
            onOpenLibrary = { id, name ->
                shellTab = io.movieclaw.android.feature.root.MainTab.LIBRARY
                io.movieclaw.android.feature.root.MainTabBus.open(io.movieclaw.android.feature.root.MainTab.LIBRARY)
                navController.popBackStack("tabs", inclusive = false)
                navController.navigate("library/$id?name=${Uri.encode(name)}")
            },
            collections = shellSidebar.collections.map { it.id to it.name },
            onOpenCollection = { id, name ->
                shellTab = io.movieclaw.android.feature.root.MainTab.LIBRARY
                io.movieclaw.android.feature.root.MainTabBus.open(io.movieclaw.android.feature.root.MainTab.LIBRARY)
                navController.popBackStack("tabs", inclusive = false)
                navController.navigate("libraryCollection/$id?title=${Uri.encode(name)}")
            },
            onSearch = {
                io.movieclaw.android.feature.root.MainTabBus.open(io.movieclaw.android.feature.root.MainTab.DISCOVER)
                navController.navigate("search?media=1")
            },
            selectedLibraryId = selectedLibraryId,
            selectedCollectionId = selectedCollectionId,
            accountName = shellSidebar.accountName,
            accountInitials = shellSidebar.accountInitials,
            accountAvatarUrl = shellSidebar.accountAvatarUrl,
            accountOrigin = shellSidebar.accountOrigin,
            dots = sidebarDots,
            hazeState = shellHazeState,
            )
        }
    }
    // 发现页内容整窗铺；其他页面仍从侧栏右缘开始（不向左压到卡片下面）。
    androidx.compose.foundation.layout.Box(
        Modifier
            .fillMaxSize()
            .padding(
                start = if (showSidebar && !isDiscoverHome) {
                    io.movieclaw.android.core.designsystem.McSidebarWidth
                } else {
                    0.dp
                },
            ),
    ) {
    // 内容区宽（已扣掉侧边栏）→ 只用来喂 `fitted`（iOS `TabRoot` 的 `.onGeometryChange`）。
    // **宽窄判定必须仍用窗口宽**：iOS 是 `forWindow(regular: 尺寸类别)` 判宽窄、`.fitted(contentWidth:)`
    // 只负责按内容区排整列。这里若写成 `forWindow(内容宽)`，平板横屏内容区只有 776dp < 840dp 断点，
    // 会误判成手机那套——整页版式一起退化（这个错我犯过一次）。
    BoxWithConstraints(Modifier.fillMaxSize()) {
    val contentMetrics = cardMetrics.fitted(maxWidth)
    CompositionLocalProvider(
        LocalCardMetrics provides contentMetrics,
        // 详情页把当前剧照发布上来 → 外壳的全屏背景层跟着变
        LocalShellBackdropSetter provides { shellBackdrop = it },
    ) {
    NavHost(navController = navController, startDestination = "tabs") {
        composable("tabs") {
            MainTabScreen(
                onOpenLibrary = { id, name ->
                    navController.navigate("library/$id?name=${Uri.encode(name)}")
                },
                onOpenItem = { libraryId, itemId ->
                    navController.navigate("item/$libraryId/$itemId")
                },
                onPlay = { target ->
                    navVm.open(target)
                    navController.navigate("player")
                },
                // 放大镜：按来源页签预选搜索分区（tab 参数；null = 沿用上次停留的分区）
                onOpenSearch = { tab ->
                    navController.navigate(if (tab == null) "search" else "search?tab=$tab")
                },
                onOpenNotices = { navController.navigate("notices") },
                onOpenSubscription = { id -> navController.navigate("subscription/$id") },
                onOpenTitle = { ref -> navController.navigate("title?ref=${Uri.encode(ref)}") },
                onOpenCollection = { ref, title ->
                    navController.navigate("collection?ref=${Uri.encode(ref)}&title=${Uri.encode(title)}")
                },
                onSubscribeTitle = { ref, seed ->
                    io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.open(ref, seed)
                },
                onOpenManage = { navController.navigate("libraryManage") },
                // 「我的」页：账户卡进个人信息、提醒组的更新行进「更新与维护」、
                // 最近会话的「新会话」与点某条会话
                onOpenProfile = { navController.navigate("settings/PROFILE") },
                onOpenUpdate = { navController.navigate("settings/MAINTENANCE") },
                onOpenNewSession = { navController.navigate("agentNew") },
                onOpenFavorites = { navController.navigate("favorites") },
                onOpenCollections = { navController.navigate("collections") },
                subscriptions = subscriptions,
                onTabReselect = { navController.popBackStack("tabs", inclusive = false) },
                onCurrentTabChanged = { shellTab = it },
                onOpenAgent = { navController.navigate("agent") },
                // 活动页「交给 AI 分析」：工单已作为首条消息提交，直接进那个会话
                onOpenAgentSession = { sessionId -> navController.navigate("agentConversation/$sessionId") },
                onOpenActivityDetail = { view -> navController.navigate("activityDetail/$view") },
                onOpenSettings = { navController.navigate("settings") },
                onScanPairing = { navController.navigate("activate?scan=1") },
                onOpenDownloads = { navController.navigate("downloads") },
                onOpenAccounts = { navController.navigate("accounts") },
                onOpenKind = { kind -> navController.navigate("kind/$kind") },
                onOpenGenre = { kind, genre -> navController.navigate("kind/$kind?genre=$genre") },
                onOpenReels = { navController.navigate("reels") },
                onOpenCustomize = { navController.navigate("libraryCustomize") },
                onOpenLibraryCollection = { id, name -> navController.navigate("libraryCollection/$id?title=${Uri.encode(name)}") },
                onOpenSubsWall = { kind -> navController.navigate("subsWall/$kind") },
            )
        }
        composable("agent") {
            if (!adminOnly(navController)) return@composable
            // 离线时要连服务器：换成占位（offline-download.md §1）
            OfflineRoute(navController) {
            AgentSessionsScreen(
                onBack = { navController.popBackStack() },
                onOpenSession = { id -> navController.navigate("agentConversation/$id") },
                onNewSession = { navController.navigate("agentNew") },
            )
            }
        }
        composable("agentNew") {
            if (!adminOnly(navController)) return@composable
            // 离线时要连服务器：换成占位（offline-download.md §1）
            OfflineRoute(navController) {
            AgentNewSessionScreen(
                onBack = { navController.popBackStack() },
                onCreated = { id ->
                    navController.navigate("agentConversation/$id") {
                        popUpTo("agent")
                    }
                },
            )
            }
        }
        composable("agentConversation/{sessionId}") {
            if (!adminOnly(navController)) return@composable
            // 离线时要连服务器：换成占位（offline-download.md §1）
            OfflineRoute(navController) {
            AgentConversationScreen(
                onBack = { navController.popBackStack() },
                // 生成式 UI 媒体卡片的跳转（与其余入口同款路由：影片详情/媒体库/条目/订阅/播放器）
                onOpenTitle = { ref -> navController.navigate("title?ref=${Uri.encode(ref)}") },
                onOpenLibrary = { id -> navController.navigate("library/$id") },
                onOpenItem = { libraryId, itemId -> navController.navigate("item/$libraryId/$itemId") },
                onOpenSubscription = { id -> navController.navigate("subscription/$id") },
                onPlay = { target ->
                    navVm.open(target)
                    navController.navigate("player")
                },
            )
            }
        }
        composable("title?ref={ref}") { entry ->
            // 离线时要连服务器：换成占位（offline-download.md §1）
            OfflineRoute(navController) {
            TitleDetailScreen(
                titleRef = entry.arguments?.getString("ref").orEmpty(),
                onBack = { navController.popBackStack() },
                onOpenTitle = { ref -> navController.navigate("title?ref=${Uri.encode(ref)}") },
                // 「搜索资源」带片名进搜索页（tab 缺省 = 资源分区，与网页 /search?q= 同口径）；
                // 电影 / 剧集按类型收窄（v0.32 iOS / Web 同款，见 searchRouteFor）
                onSearch = { keyword, kind -> navController.navigate(searchRouteFor(keyword, kind)) },
                onSubscribe = { ref ->
                    io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.open(ref)
                },
                onOpenItem = { libraryId, itemId -> navController.navigate("item/$libraryId/$itemId") },
                // 演职员 → TMDB 影人页（iOS `.discoveredPerson`）
                onOpenPerson = { tmdbPersonId -> navController.navigate("discoveredPerson/$tmdbPersonId") },
                onPlay = { target ->
                    navVm.open(target)
                    navController.navigate("player")
                },
            )
            }
        }
        composable("collection?ref={ref}&title={title}") { entry ->
            CollectionScreen(
                title = entry.arguments?.getString("title").orEmpty(),
                onBack = { navController.popBackStack() },
                onOpenTitle = { ref -> navController.navigate("title?ref=${Uri.encode(ref)}") },
            )
        }
        composable("favorites") { entry ->
            FavoritesScreen(
                onBack = { navController.popBackStack() },
                onOpenItem = { libId, itemId -> navController.navigate("item/$libId/$itemId") },
            )
        }
        composable("collections") { entry ->
            CollectionsScreen(
                onBack = { navController.popBackStack() },
                // 库内合集走原生合集详情（此前误落到发现页的 TMDB 合集页——那边查的是另一个接口）
                onOpenCollection = { id, name -> navController.navigate("libraryCollection/$id?title=${Uri.encode(name)}") },
            )
        }
        // 库内合集详情（首页合集行 / 全部合集的卡片）
        composable("libraryCollection/{collectionId}?title={title}") { entry ->
            LibraryCollectionScreen(
                collectionId = entry.arguments?.getString("collectionId")?.toLongOrNull() ?: -1L,
                fallbackTitle = entry.arguments?.getString("title").orEmpty(),
                onBack = { navController.popBackStack() },
                onOpenItem = { libId, itemId -> navController.navigate("item/$libId/$itemId") },
            )
        }
        composable(
            "libraryManage?tab={tab}",
            arguments = listOf(androidx.navigation.navArgument("tab") { defaultValue = "" }),
        ) { entry ->
            if (!adminOnly(navController)) return@composable
            LibraryManageScreen(
                onBack = { navController.popBackStack() },
                onOpenLibrary = { id, name -> shellTab = io.movieclaw.android.feature.root.MainTab.LIBRARY; navController.popBackStack("tabs", inclusive = false); navController.navigate("library/$id?name=${Uri.encode(name)}") },
                // 创建 / 编辑媒体库：原生表单（此前 onOpenWebManage 没接线，点了没反应）
                onOpenForm = { libraryId ->
                    if ((libraryId ?: -1L) > 0) navController.navigate("libraryForm?libraryId=$libraryId")
                    else navController.navigate("libraryForm")
                },
                // 详情页文件区「处理重复」带页签进来（iOS `.libraryManage(tab: "duplicates")`）
                initialTab = entry.arguments?.getString("tab")?.toIntOrNull(),
            )
        }
        // 离线下载：我的 → 下载（下载中 / 建议 / 已下载 / 其他账号 / 容量）；播放一律走同一个播放器（本机副本优先）
        composable("downloads") {
            DownloadsScreen(
                onBack = { navController.popBackStack() },
                // 点条目 → 库内详情（iOS NavigationLink：下载页看条目、在海报墙里也能管理）
                onOpenItem = { libraryId, mediaItemId -> navController.navigate("item/$libraryId/$mediaItemId") },
                origin = sessionRepo.ui.value.origin,
            )
        }
        // 设置 → 网络 → 外部访问（iOS `ExternalAccessSettingsView`）
        composable("networkExternal") {
            io.movieclaw.android.feature.settings.ExternalAccessScreen(
                onBack = { navController.popBackStack() },
            )
        }
        // 批准设备登录（v0.31 /activate 的对应页）；code = 扫码/站内链接带来的配对码
        composable("activate?code={code}&scan={scan}") { entry ->
            ActivateScreen(
                onBack = { navController.popBackStack() },
                presetCode = entry.arguments?.getString("code"),
                scanFirst = entry.arguments?.getString("scan") == "1",
            )
        }
        // 媒体库表单（创建 / 编辑两用；编辑带 libraryId）
        composable("libraryForm?libraryId={libraryId}") {
            if (!adminOnly(navController)) return@composable
            LibraryFormScreen(onBack = { navController.popBackStack() })
        }
        // 自定义首页（媒体库 ⋯ 菜单）：行清单编辑器，保存进 ui.preferences.home.rows
        composable("libraryCustomize") {
            LibraryCustomizeScreen(onBack = { navController.popBackStack() })
        }
        // 刷片 / 片段（媒体库顶栏「▶ 片段」）：竖滑流，每条按 segment 起播、到终点停
        composable("reels") { entry ->
            io.movieclaw.android.feature.reels.ReelsScreen(
                onBack = { navController.popBackStack() },
                onOpenItem = { libraryId, itemId ->
                    if (libraryId > 0) navController.navigate("item/$libraryId/$itemId")
                },
                onOpenPerson = { tmdbPersonId -> navController.navigate("person/$tmdbPersonId") },
                // 「看全片」：把这一段交给正片播放器，**从片段里当前放到的那一刻**接着看
                // （长按「从头看」给的是片段起点，两条都由页面算好传进来）
                onOpenFullPlayer = { item, startMs ->
                    navVm.open(
                        PlayTarget(
                            mediaItemId = item.title.mediaItemId,
                            libraryId = item.title.libraryId,
                            kind = item.title.kind,
                            title = item.title.name,
                            seasonNumber = item.title.episode?.season ?: 0,
                            episodeNumber = item.title.episode?.episode ?: 0,
                            startMs = startMs,
                        )
                    )
                    navController.navigate("player")
                },
                // 分享：系统分享带条目的网页地址（与详情页「分享」同一份东西）
                onShare = { item ->
                    val base = sessionRepo.ui.value.origin?.trimEnd('/')
                    val link = base?.let { "$it/library/${item.title.libraryId}/item/${item.title.mediaItemId}" }
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(
                            android.content.Intent.EXTRA_TEXT,
                            listOfNotNull(item.title.name, link).joinToString("\n"),
                        )
                    }
                    runCatching {
                        context.startActivity(android.content.Intent.createChooser(intent, "分享影片"))
                    }
                },
            )
        }
        // 按类型的跨库墙（首页「全部电影」行点「查看全部」进来）
        composable("kind/{kind}?genre={genre}") { entry ->
            io.movieclaw.android.feature.library.KindWallScreen(
                onBack = { navController.popBackStack() },
                onOpenItem = { libraryId, itemId ->
                    if (libraryId > 0) navController.navigate("item/$libraryId/$itemId")
                },
            )
        }
        // 订阅海报墙（订阅首页「剧集/电影订阅 ›」与「查看全部」进来）
        composable("subsWall/{kind}") { entry ->
            io.movieclaw.android.feature.subscriptions.SubscriptionWallScreen(
                onBack = { navController.popBackStack() },
                onOpenSubscription = { id -> navController.navigate("subscription/$id") },
            )
        }
        // 命名对齐 iOS：`discoveredPerson` = TMDB 影人页（完整履历、带已入库/已订阅斜标）
        composable("discoveredPerson/{tmdbPersonId}") { entry ->
            PersonScreen(
                onBack = { navController.popBackStack() },
                onOpenTitle = { ref -> navController.navigate("title?ref=${Uri.encode(ref)}") },
            )
        }
        // `person` = 库内影人页（iOS `PersonDetailView` / `AppRoute.person`）：只列库里的作品，
        // 点作品进库内条目详情。与上面的 TMDB 影人页是两个独立页面。
        composable("person/{tmdbPersonId}") { entry ->
            LibraryPersonScreen(
                onBack = { navController.popBackStack() },
                onOpenItem = { lib, item -> navController.navigate("item/$lib/$item") },
                onOpenLibrary = {
                    MainTabBus.open(MainTab.LIBRARY)
                    navController.popBackStack()
                },
            )
        }
        // 搜索页带 q/tab/cat 深链：详情页「搜索资源」带词进来，tab 缺省 = 资源分区
        // （与网页 /search?q= 同语义：URL 里只有 q 时不带 tab，落在站点资源）；
        // cat = 按影片类型收窄的资源分类（v0.32，电影/剧集，见 searchRouteFor）。
        // 订阅详情「手动选种」用 forSub/forSubTitle 进手动选种模式（网页 /search?for_sub=）
        composable(
            "search?q={q}&tab={tab}&forSub={forSub}&forSubTitle={forSubTitle}&cat={cat}",
            arguments = listOf(
                androidx.navigation.navArgument("q") { defaultValue = "" },
                androidx.navigation.navArgument("tab") { defaultValue = "" },
                androidx.navigation.navArgument("forSub") { defaultValue = "" },
                androidx.navigation.navArgument("forSubTitle") { defaultValue = "" },
                androidx.navigation.navArgument("cat") { defaultValue = "" },
            ),
        ) { entry ->
            // 离线时要连服务器：换成占位（offline-download.md §1）
            OfflineRoute(navController) {
            SearchScreen(
                initialKeyword = entry.arguments?.getString("q").orEmpty(),
                initialMode = when (entry.arguments?.getString("tab")) {
                    "media" -> SearchMode.TITLES
                    "torrent" -> SearchMode.TORRENTS
                    "library" -> SearchMode.LIBRARY
                    else -> null
                },
                initialCategory = io.movieclaw.android.core.model.TorrentCategory
                    .of(entry.arguments?.getString("cat")),
                forSubscriptionId = entry.arguments?.getString("forSub")?.toLongOrNull(),
                forSubscriptionTitle = entry.arguments?.getString("forSubTitle").orEmpty(),
                onBack = { navController.popBackStack() },
                onOpenLibraryItem = { libraryId, itemId ->
                    if (libraryId > 0) navController.navigate("item/$libraryId/$itemId")
                },
                onSubscribe = { titleRef ->
                    io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.open(titleRef)
                },
                onOpenTitle = { ref -> navController.navigate("title?ref=${Uri.encode(ref)}") },
            )
            }
        }
        // 订阅弹层不再是一个导航目标：它由 `SubscribeSheetHost` 在**当前页面之上**渲染
        // （导航过去会让原页面离开组合，弹层的遮罩就压在一片空黑上——用户报的"整页变黑"）。
        // 「手动选种」带 forSub 进搜索页：那一页搜出的种子都投给这条订阅。
        composable("subscription/{subscriptionId}?upgradeRun={upgradeRun}") { entry ->
            // 离线时要连服务器：换成占位（offline-download.md §1）
            OfflineRoute(navController) {
            val subId = entry.arguments?.getString("subscriptionId")?.toLongOrNull()
            // 宽窗口照 `ipad.md` §4「活动二级页、订阅详情：列表 → 详情两栏」：
            // 左栏列出订阅（数据来自全局 `SubscriptionIndex`，不需要新 VM），右栏渲染选中的详情。
            // 窄窗口保持推进式整页。
            val wideSubs = LocalCardMetrics.current.isWide
            val subsAll by subscriptions.all.collectAsStateWithLifecycle()
            val detail: @androidx.compose.runtime.Composable () -> Unit = {
                SubscriptionDetailScreen(
                    onBack = { navController.popBackStack() },
                    // 「手动选种」：带词 + 按订阅类型收窄分类进搜索页（v0.32 iOS / Web 同款）
                    onOpenSearch = { title, kind ->
                        navController.navigate(
                            searchRouteFor(title, kind) +
                                "&forSub=${subId ?: -1L}&forSubTitle=${Uri.encode(title)}"
                        )
                    },
                    // 详情页「洗版…」进来时带上：进页面直接跑一轮洗版
                    autoUpgradeRun = entry.arguments?.getString("upgradeRun") == "true",
                )
            }
            if (wideSubs) {
                Row(Modifier.fillMaxSize()) {
                    Column(
                        Modifier
                            .weight(0.3f)
                            .fillMaxHeight()
                            // 左栏必须有底色：之前是透明的，文字直接飘在页面/侧栏上，看着像浮层
                            .background(androidx.compose.ui.graphics.Color(0xFF0B0C10))
                            .verticalScroll(androidx.compose.foundation.rememberScrollState())
                            .padding(top = 72.dp),
                    ) {
                        // 去重：索引里同一条订阅可能出现两次 → 左栏两个同名项会同时高亮（真机复现）
                        subsAll.forEach { sub ->
                            val selected = sub.id == subId
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 12.dp, vertical = 2.dp)
                                    .clip(androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
                                    .background(
                                        if (selected) androidx.compose.ui.graphics.Color.White.copy(alpha = 0.12f)
                                        else androidx.compose.ui.graphics.Color.Transparent
                                    )
                                    .clickable { navController.navigate("subscription/${sub.id}") }
                                    .padding(horizontal = 12.dp, vertical = 10.dp),
                            ) {
                                androidx.compose.material3.Text(
                                    sub.media.title,
                                    color = if (selected) androidx.compose.ui.graphics.Color.White
                                    else androidx.compose.ui.graphics.Color(0xFF9AA3B2),
                                    maxLines = 1,
                                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                    androidx.compose.foundation.layout.Box(Modifier.weight(0.7f).fillMaxHeight()) {
                        detail()
                    }
                }
            } else {
                detail()
            }
            }
        }
        composable("notices") {
            NoticeCenterScreen(onBack = { navController.popBackStack() })
        }
        // 活动二级页（网页 /activity?view=）：进行中 / 已结束 / 最近播放 / 观看统计
        composable("activityDetail/{view}") { entry ->
            if (!adminOnly(navController)) return@composable
            val initialView = entry.arguments?.getString("view").orEmpty()
            // 宽窗口照 `ipad.md` §4「活动二级页：列表 → 详情两栏」：左边四个视图当列表，
            // 右边渲染选中的那个。窄窗口仍是一页一个视图（推进式）。
            if (LocalCardMetrics.current.isWide) {
                val views = listOf(
                    "active" to "进行中",
                    "history" to "已结束",
                    "plays" to "最近播放",
                    "stats" to "观看统计",
                )
                val picked = androidx.compose.runtime.saveable.rememberSaveable {
                    androidx.compose.runtime.mutableStateOf(initialView)
                }
                androidx.compose.foundation.layout.Row(Modifier.fillMaxSize()) {
                    androidx.compose.foundation.layout.Column(
                        Modifier.weight(0.28f).fillMaxHeight().padding(top = 72.dp),
                    ) {
                        views.forEach { (key, title) ->
                            val selected = picked.value == key
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 12.dp, vertical = 2.dp)
                                    .clip(androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
                                    .background(
                                        if (selected) androidx.compose.ui.graphics.Color.White.copy(alpha = 0.12f)
                                        else androidx.compose.ui.graphics.Color.Transparent
                                    )
                                    .clickable { picked.value = key }
                                    .padding(horizontal = 12.dp, vertical = 10.dp),
                            ) {
                                androidx.compose.material3.Text(
                                    title,
                                    color = if (selected) androidx.compose.ui.graphics.Color.White
                                    else androidx.compose.ui.graphics.Color(0xFF9AA3B2),
                                )
                            }
                        }
                    }
                    androidx.compose.foundation.layout.Box(Modifier.weight(0.72f).fillMaxHeight()) {
                        io.movieclaw.android.feature.activity.ActivityDetailScreen(
                            view = picked.value,
                            onBack = { navController.popBackStack() },
                        )
                    }
                }
            } else {
                io.movieclaw.android.feature.activity.ActivityDetailScreen(
                    view = initialView,
                    onBack = { navController.popBackStack() },
                )
            }
        }
        composable("settings") {
            // 离线时要连服务器：换成占位（offline-download.md §1）
            OfflineRoute(navController) {
            // 宽窗口照 `ipad.md` §4「设置」：**左分区、右内容**（`NavigationSplitView` 的等价物），
            // 选中分区直接在右栏换内容，不再压一层导航；窄窗口仍是推进式（点进 `settings/{section}`）。
            val wideSettings = LocalCardMetrics.current.isWide
            if (!wideSettings) {
                SettingsIndexScreen(
                    onBack = { navController.popBackStack() },
                    onOpen = { section -> navController.navigate("settings/${section.name}") },
                )
            } else {
                val picked = androidx.compose.runtime.saveable.rememberSaveable {
                    androidx.compose.runtime.mutableStateOf(io.movieclaw.android.feature.settings.SettingsSection.PROFILE)
                }
                androidx.compose.foundation.layout.Row(Modifier.fillMaxSize()) {
                    androidx.compose.foundation.layout.Box(
                        Modifier.weight(0.34f).fillMaxHeight(),
                    ) {
                        SettingsIndexScreen(
                            onBack = { navController.popBackStack() },
                            onOpen = { section -> picked.value = section },
                            // 两栏时返回键只留在右侧内容栏，避免两个返回箭头做同一件事
                            showBack = false,
                        )
                    }
                    androidx.compose.foundation.layout.Box(
                        Modifier.weight(0.66f).fillMaxHeight(),
                    ) {
                        // 右栏里返回键不做事：分区切换靠左栏点选
                        SettingsSectionHost(
                            section = picked.value,
                            navController = navController,
                            onBack = { navController.popBackStack() },
                        )
                    }
                }
            }
            }
        }
        composable("accounts") {
            AccountSwitcherScreen(
                onBack = { navController.popBackStack() },
                onAddAccount = { navController.navigate("addAccount") },
                // 点已过期的账号 → 打开预填好地址与账号的登录卡（iOS fullScreenCover 同款，
                // 当前会话不动）；地址含 :// 与端口，导航参数要编码
                onReauth = { origin, username ->
                    val enc = java.net.URLEncoder.encode(origin, "UTF-8")
                    val encU = java.net.URLEncoder.encode(username, "UTF-8")
                    navController.navigate("addAccount?server=$enc&username=$encU")
                },
            )
        }
        composable("addAccount?server={server}&username={username}") { entry ->
            LoginScreen(
                presetUsername = entry.arguments?.getString("username"),
                presetServer = entry.arguments?.getString("server"),
                onDone = { navController.popBackStack() },
            )
        }
        composable("settings/{section}") { entry ->
            val section = entry.arguments?.getString("section")
                ?.let { name -> io.movieclaw.android.feature.settings.SettingsSection.entries.firstOrNull { it.name == name } }
                ?: return@composable
            // 直链守卫：成员深链到超管分区不给开（同 Web accessiblePathFor 的改道）
            val settingsVm: io.movieclaw.android.feature.settings.SettingsViewModel = hiltViewModel()
            if (!settingsVm.canOpen(section)) {
                androidx.compose.runtime.LaunchedEffect(Unit) { navController.popBackStack() }
                return@composable
            }
            // 离线时要连服务器：换成占位（offline-download.md §1）
            OfflineRoute(navController) {
                SettingsSectionHost(
                    section = section,
                    navController = navController,
                    onBack = { navController.popBackStack() },
                )
            }
        }
        composable("library/{libraryId}?name={name}") { entry ->
            val libraryId = entry.arguments?.getString("libraryId")?.toLongOrNull() ?: return@composable
            LibraryDetailScreen(
                libraryId = libraryId,
                title = entry.arguments?.getString("name").orEmpty(),
                onBack = { navController.popBackStack() },
                onOpenItem = { libraryId2, itemId -> navController.navigate("item/$libraryId2/$itemId") },
            )
        }
        composable("item/{libraryId}/{itemId}") { entry ->
            val libraryId = entry.arguments?.getString("libraryId")?.toLongOrNull() ?: return@composable
            val itemId = entry.arguments?.getString("itemId")?.toLongOrNull() ?: return@composable
            ItemDetailScreen(
                libraryId = libraryId,
                itemId = itemId,
                onBack = { navController.popBackStack() },
                onPlay = { target ->
                    navVm.open(target)
                    navController.navigate("player")
                },
                // 演职员 → 库内影人页（iOS `LibraryItemDetailView` 的 `.person`）
                onOpenPerson = { tmdbPersonId -> navController.navigate("person/$tmdbPersonId") },
                // 文件区「处理重复」→ 媒体库管理的「重复文件」页签（iOS `.libraryManage(tab: "duplicates")`）
                onOpenDuplicates = { navController.navigate("libraryManage?tab=2") },
                // 「去接入」→ 设置「模型接入」（iOS `.settingsSection(.llm)`）
                onOpenLlmSettings = { navController.navigate("settings/LLM") },
                // 「交给 Agent 处理」建好会话 → 会话页
                onOpenAgentSession = { id -> navController.navigate("agentConversation/$id") },
                onOpenItem = { lib, id -> navController.navigate("item/$lib/$id") },
                onOpenTitle = { ref -> navController.navigate("title?ref=${Uri.encode(ref)}") },
                // ⋯ 菜单「搜索资源」：带片名与类型（movie/tv）进搜索页
                onSearch = { title, kind -> navController.navigate(searchRouteFor(title, kind)) },
                // ⋯ 菜单「洗版…」：已有订阅 → 去订阅详情页跑一轮洗版；没有 → 打开订阅弹层
                onOpenSubscription = { id, upgradeRun ->
                    navController.navigate("subscription/$id?upgradeRun=$upgradeRun")
                },
                onSubscribe = { ref ->
                    io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.open(ref)
                },
                // 转移完成后「去目标库查看」
                onOpenLibrary = { id -> navController.navigate("library/$id") },
            )
        }
        composable("player") {
            PlayerScreen(onExit = { navController.popBackStack() })
        }
    }
    }   // CompositionLocalProvider（内容区宽 + 剧照发布口）
    }   // BoxWithConstraints（内容区宽）
    }   // Box（内容区）
    }   // Row（侧边栏 + 内容区）
    }   // CompositionLocalProvider（CardMetrics）
    }   // BoxWithConstraints（CardMetrics）

    // 订阅底部抽屉：宿主在这里，浮在当前页面之上（遮罩只压暗当前页，与 HTML 原型一致）
    io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.Render(
        onOpenSubscription = { id -> navController.navigate("subscription/$id") },
    )
}

/** 从 Application 取单例（AppNav 是普通可组合，不在 Hilt 的注入图里） */
@dagger.hilt.EntryPoint
@dagger.hilt.InstallIn(dagger.hilt.components.SingletonComponent::class)
interface SubscriptionIndexEntry {
    fun subscriptionIndex(): io.movieclaw.android.feature.subscriptions.SubscriptionIndex
}

/** ApiFactory 取用口 */
@dagger.hilt.EntryPoint
@dagger.hilt.InstallIn(dagger.hilt.components.SingletonComponent::class)
interface ApiFactoryEntry {
    fun apiFactory(): io.movieclaw.android.core.network.ApiFactory
}


/** 服务器地址 / 会话（刷片分享要拼条目网页地址） */
@dagger.hilt.EntryPoint
@dagger.hilt.InstallIn(dagger.hilt.components.SingletonComponent::class)
interface SessionRepositoryEntry {
    fun sessionRepository(): io.movieclaw.android.core.session.SessionRepository
}

/**
 * 超管专属路由的守卫：成员手输 / 残留返回栈进来时退回上一页（同 Web `accessiblePathFor`、
 * iOS `Permissions.allows`）。返回 false 时调用方 `return@composable`，一帧内容都不渲染。
 */
@Composable
private fun adminOnly(navController: androidx.navigation.NavHostController): Boolean {
    val allowed = io.movieclaw.android.core.session.LocalPermissions.current.isAdmin
    if (!allowed) {
        androidx.compose.runtime.LaunchedEffect(Unit) {
            runCatching { navController.popBackStack() }
        }
    }
    return allowed
}

/**
 * 详情页「搜索资源」的搜索路由：电影 / 剧集按影片类型收窄资源分类
 * （Web `scopeOfMediaKind` / iOS `SearchScope.ofMediaKind` 同款）——同名另一类的种子
 * 不再混进来，结果页分类胶囊会高亮、可一键放宽；其余形态（库里的「其他」/图片）
 * 或查不到类型时不收窄（与网页 URL 只有 q 时同语义）。
 */
private fun searchRouteFor(keyword: String, kind: String?): String {
    val base = "search?q=${Uri.encode(keyword)}"
    return if (kind == "movie" || kind == "tv") "$base&cat=$kind" else base
}



/**
 * 设置分区内容的渲染入口。
 *
 * 从 `settings/{section}` 路由里抽出来的，好让**宽窗口两栏**（`ipad.md` §4「设置」：
 * 左分区、右内容，`/settings/{section}` 落到右栏）与**窄窗口推进式**导航共用同一份分区渲染。
 * `onBack` 由调用方给：窄窗口是 popBackStack，宽窗口右栏里不做事。
 */
@androidx.compose.runtime.Composable
private fun SettingsSectionHost(
    section: io.movieclaw.android.feature.settings.SettingsSection,
    navController: androidx.navigation.NavHostController,
    onBack: () -> Unit,
) {
        when (section) {
            io.movieclaw.android.feature.settings.SettingsSection.PROFILE ->
                ProfileSettingsScreen(
                    onBack = { onBack() },
                    onOpenAccounts = { navController.navigate("accounts") },
                )
            io.movieclaw.android.feature.settings.SettingsSection.NOTIFY ->
                io.movieclaw.android.feature.settings.NotifySettingsScreen(
                    onBack = { onBack() },
                )
            io.movieclaw.android.feature.settings.SettingsSection.DEVICES ->
                DevicesSettingsScreen(
                    onBack = { onBack() },
                    // v0.31 /activate：批准设备登录（Apple TV / 转码器配对码）
                    onOpenActivate = { navController.navigate("activate") },
                )
            io.movieclaw.android.feature.settings.SettingsSection.PLAYBACK ->
                PlaybackSettingsScreen(onBack = { onBack() })
            io.movieclaw.android.feature.settings.SettingsSection.MEMBERS ->
                MembersSettingsScreen(onBack = { onBack() })
            io.movieclaw.android.feature.settings.SettingsSection.LLM ->
                io.movieclaw.android.feature.settings.LlmSettingsScreen(onBack = { onBack() })
            io.movieclaw.android.feature.settings.SettingsSection.MAINTENANCE ->
                MaintenanceSettingsScreen(onBack = { onBack() })
            io.movieclaw.android.feature.settings.SettingsSection.NETWORK ->
                NetworkSettingsScreen(
                    onBack = { onBack() },
                    onOpenExternalAccess = { navController.navigate("networkExternal") },
                )
            io.movieclaw.android.feature.settings.SettingsSection.LOGS ->
                LogsSettingsScreen(onBack = { onBack() })
            // AI 设定：原生实现（GET/PUT /llm/defaults），不再走网页端占位
            io.movieclaw.android.feature.settings.SettingsSection.AI_WEB ->
                io.movieclaw.android.feature.settings.AiDefaultsScreen(onBack = { onBack() })
            // App 推送 / IM 推送：原生实现（/push/channels + /channels/im/push-config）
            io.movieclaw.android.feature.settings.SettingsSection.APP_PUSH_WEB,
            io.movieclaw.android.feature.settings.SettingsSection.IM_PUSH_WEB ->
                io.movieclaw.android.feature.settings.PushSettingsScreen(onBack = { onBack() })
            // MCP 服务：原生实现（/mcp/status 总开关 + 端点清单）
            io.movieclaw.android.feature.settings.SettingsSection.MCP_WEB ->
                io.movieclaw.android.feature.settings.McpSettingsScreen(onBack = { onBack() })
            // Webhook：原生实现（/webhook + 测试发送 + 投递记录）
            io.movieclaw.android.feature.settings.SettingsSection.WEBHOOK_WEB ->
                io.movieclaw.android.feature.settings.WebhookSettingsScreen(onBack = { onBack() })
            // 刮削与整理：原生（照网页移动端真实页面：分组列表 + 摘要 + 自动保存）
            io.movieclaw.android.feature.settings.SettingsSection.SCRAPE_WEB ->
                io.movieclaw.android.feature.settings.ScrapeSettingsScreen(onBack = { onBack() })
            // 下载器：原生（照移动网页端：列表 + 新增/编辑 + 限速与队列 + 行内动作）
            io.movieclaw.android.feature.settings.SettingsSection.DOWNLOADERS_WEB ->
                io.movieclaw.android.feature.settings.DownloadersScreen(onBack = { onBack() })
            // 资源站点：原生（目录选站 → 授权；刷流设置；启停/保护/重验/删除）
            io.movieclaw.android.feature.settings.SettingsSection.SITES_WEB ->
                io.movieclaw.android.feature.settings.SitesScreen(onBack = { onBack() })
            // 订阅规则：原生（规则组列表 + 编辑器：适用范围/分辨率/片源/编码/HDR/平台/体积/洗版）
            io.movieclaw.android.feature.settings.SettingsSection.SUBSCRIPTION_WEB ->
                io.movieclaw.android.feature.settings.RuleSetsScreen(onBack = { onBack() })
            // 自动入库：原生（监听规则 + 新增编辑 + 台账清单的认领/忽略/恢复）
            io.movieclaw.android.feature.settings.SettingsSection.IMPORT_WATCH_WEB ->
                io.movieclaw.android.feature.settings.ImportWatchScreen(onBack = { onBack() })
            io.movieclaw.android.feature.settings.SettingsSection.CLOUD_WEB ->
                io.movieclaw.android.feature.settings.CloudSettingsScreen(onBack = { onBack() })
            else -> WebManagedSectionScreen(section, onBack = { onBack() })
        }
}






/**
 * 把一条返回栈条目还原成**可直接 navigate 的 URL**。
 *
 * `destination.route` 只是模式串（如 `library/{libraryId}?name={name}`），
 * 拿它去 `navigate` 会把花括号当字面量。这里按模式里的占位符从 `arguments` 取值填回去，
 * 可选查询参数缺值就整段丢掉——用于「切回页签时恢复上一次那一层」。
 */
private fun filledRouteOf(entry: androidx.navigation.NavBackStackEntry): String? {
    val pattern = entry.destination.route ?: return null
    if (!pattern.contains('{')) return pattern
    val args = entry.arguments
    val path = pattern.substringBefore('?')
    val query = pattern.substringAfter('?', "")
    val sb = StringBuilder()
    var i = 0
    while (i < path.length) {
        val ch = path[i]
        if (ch == '{') {
            val end = path.indexOf('}', i)
            if (end < 0) return null
            val name = path.substring(i + 1, end)
            val v = args?.getString(name) ?: return null
            sb.append(java.net.URLEncoder.encode(v, "UTF-8"))
            i = end + 1
        } else {
            sb.append(ch)
            i++
        }
    }
    if (query.isEmpty()) return sb.toString()
    val kept = query.split('&').mapNotNull { seg ->
        val name = seg.substringBefore('=')
        val v = args?.getString(name) ?: return@mapNotNull null
        "$name=" + java.net.URLEncoder.encode(v, "UTF-8")
    }
    return if (kept.isEmpty()) sb.toString() else sb.toString() + "?" + kept.joinToString("&")
}

/** 离线时要连服务器的页面：换成「离线中」占位，「去媒体库」回到媒体库页签（iOS `OfflineGate`） */
@Composable
private fun OfflineRoute(navController: androidx.navigation.NavHostController, content: @Composable () -> Unit) {
    io.movieclaw.android.feature.offline.OfflineGate(
        onOpenLibrary = {
            runCatching { navController.popBackStack("tabs", inclusive = false) }
            io.movieclaw.android.feature.root.MainTabBus.open(io.movieclaw.android.feature.root.MainTab.LIBRARY)
        },
        content = content,
    )
}
