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
import io.movieclaw.android.feature.settings.ActivateScreen
import io.movieclaw.android.feature.library.LibraryManageScreen
import io.movieclaw.android.feature.library.LibraryPersonScreen
import io.movieclaw.android.feature.root.MainTab
import io.movieclaw.android.feature.root.MainTabBus
import io.movieclaw.android.feature.discover.PersonScreen

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
                onOpenAgent = { navController.navigate("agent") },
                // 活动页「交给 AI 分析」：工单已作为首条消息提交，直接进那个会话
                onOpenAgentSession = { sessionId -> navController.navigate("agentConversation/$sessionId") },
                onOpenActivityDetail = { view -> navController.navigate("activityDetail/$view") },
                onOpenSettings = { navController.navigate("settings") },
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
            AgentSessionsScreen(
                onBack = { navController.popBackStack() },
                onOpenSession = { id -> navController.navigate("agentConversation/$id") },
                onNewSession = { navController.navigate("agentNew") },
            )
        }
        composable("agentNew") {
            if (!adminOnly(navController)) return@composable
            AgentNewSessionScreen(
                onBack = { navController.popBackStack() },
                onCreated = { id ->
                    navController.navigate("agentConversation/$id") {
                        popUpTo("agent")
                    }
                },
            )
        }
        composable("agentConversation/{sessionId}") {
            if (!adminOnly(navController)) return@composable
            AgentConversationScreen(onBack = { navController.popBackStack() })
        }
        composable("title?ref={ref}") { entry ->
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
                onOpenLibrary = { id, name -> navController.navigate("library/$id?name=${Uri.encode(name)}") },
                // 创建 / 编辑媒体库：原生表单（此前 onOpenWebManage 没接线，点了没反应）
                onOpenForm = { libraryId ->
                    if ((libraryId ?: -1L) > 0) navController.navigate("libraryForm?libraryId=$libraryId")
                    else navController.navigate("libraryForm")
                },
                // 详情页文件区「处理重复」带页签进来（iOS `.libraryManage(tab: "duplicates")`）
                initialTab = entry.arguments?.getString("tab")?.toIntOrNull(),
            )
        }
        // 批准设备登录（v0.31 /activate 的对应页）
        composable("activate") {
            ActivateScreen(onBack = { navController.popBackStack() })
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
        // 订阅弹层不再是一个导航目标：它由 `SubscribeSheetHost` 在**当前页面之上**渲染
        // （导航过去会让原页面离开组合，弹层的遮罩就压在一片空黑上——用户报的"整页变黑"）。
        // 「手动选种」带 forSub 进搜索页：那一页搜出的种子都投给这条订阅。
        composable("subscription/{subscriptionId}") {
            val subId = it.arguments?.getString("subscriptionId")?.toLongOrNull()
            SubscriptionDetailScreen(
                onBack = { navController.popBackStack() },
                // 「手动选种」：带词 + 按订阅类型收窄分类进搜索页（v0.32 iOS / Web 同款）
                onOpenSearch = { title, kind ->
                    navController.navigate(
                        searchRouteFor(title, kind) +
                            "&forSub=${subId ?: -1L}&forSubTitle=${Uri.encode(title)}"
                    )
                },
            )
        }
        composable("notices") {
            NoticeCenterScreen(onBack = { navController.popBackStack() })
        }
        // 活动二级页（网页 /activity?view=）：进行中 / 已结束 / 最近播放 / 观看统计
        composable("activityDetail/{view}") { entry ->
            if (!adminOnly(navController)) return@composable
            io.movieclaw.android.feature.activity.ActivityDetailScreen(
                view = entry.arguments?.getString("view").orEmpty(),
                onBack = { navController.popBackStack() },
            )
        }
        composable("settings") {
            SettingsIndexScreen(
                onBack = { navController.popBackStack() },
                onOpen = { section -> navController.navigate("settings/${section.name}") },
            )
        }
        composable("accounts") {
            AccountSwitcherScreen(
                onBack = { navController.popBackStack() },
                onAddAccount = { navController.navigate("addAccount") },
            )
        }
        composable("addAccount") {
            LoginScreen(
                presetUsername = null,
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
            when (section) {
                io.movieclaw.android.feature.settings.SettingsSection.PROFILE ->
                    ProfileSettingsScreen(
                        onBack = { navController.popBackStack() },
                        onOpenAccounts = { navController.navigate("accounts") },
                    )
                io.movieclaw.android.feature.settings.SettingsSection.NOTIFY ->
                    io.movieclaw.android.feature.settings.NotifySettingsScreen(
                        onBack = { navController.popBackStack() },
                    )
                io.movieclaw.android.feature.settings.SettingsSection.DEVICES ->
                    DevicesSettingsScreen(
                        onBack = { navController.popBackStack() },
                        // v0.31 /activate：批准设备登录（Apple TV / 转码器配对码）
                        onOpenActivate = { navController.navigate("activate") },
                    )
                io.movieclaw.android.feature.settings.SettingsSection.PLAYBACK ->
                    PlaybackSettingsScreen(onBack = { navController.popBackStack() })
                io.movieclaw.android.feature.settings.SettingsSection.MEMBERS ->
                    MembersSettingsScreen(onBack = { navController.popBackStack() })
                io.movieclaw.android.feature.settings.SettingsSection.LLM ->
                    io.movieclaw.android.feature.settings.LlmSettingsScreen(onBack = { navController.popBackStack() })
                io.movieclaw.android.feature.settings.SettingsSection.MAINTENANCE ->
                    MaintenanceSettingsScreen(onBack = { navController.popBackStack() })
                io.movieclaw.android.feature.settings.SettingsSection.NETWORK ->
                    NetworkSettingsScreen(onBack = { navController.popBackStack() })
                io.movieclaw.android.feature.settings.SettingsSection.LOGS ->
                    LogsSettingsScreen(onBack = { navController.popBackStack() })
                else -> WebManagedSectionScreen(section, onBack = { navController.popBackStack() })
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
            )
        }
        composable("player") {
            PlayerScreen(onExit = { navController.popBackStack() })
        }
    }

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
