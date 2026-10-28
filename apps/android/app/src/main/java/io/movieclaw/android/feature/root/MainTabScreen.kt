package io.movieclaw.android.feature.root

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.ShowChart
import androidx.compose.material.icons.rounded.Subscriptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.repeatOnLifecycle
import io.movieclaw.android.core.designsystem.TabDot
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.McCapsuleTabBar
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.core.session.LocalPermissions
import io.movieclaw.android.core.session.initials
import io.movieclaw.android.feature.activity.ActivityScreen
import io.movieclaw.android.feature.discover.DiscoverScreen
import io.movieclaw.android.feature.library.LibraryScreen
import io.movieclaw.android.feature.more.MoreScreen
import io.movieclaw.android.feature.subscriptions.SubsHomeScreen

enum class MainTab(
    val label: String,
    val icon: ImageVector,
) {
    DISCOVER("发现", io.movieclaw.android.core.designsystem.McTabIcons.House),
    LIBRARY("媒体库", io.movieclaw.android.core.designsystem.McTabIcons.Library),
    SUBSCRIPTIONS("订阅", io.movieclaw.android.core.designsystem.McTabIcons.Bookmark),
    ACTIVITY("活动", io.movieclaw.android.core.designsystem.McTabIcons.Wave),
    MORE("我的", Icons.Rounded.Person),
}

/**
 * 从任意页请求切到某个页签（如库内影人页空态的「去媒体库」）。
 * 页签状态在外壳的 `rememberSaveable` 里，外面拿不到，所以走一个小请求总线。
 */
object MainTabBus {
    private val _requested = kotlinx.coroutines.flow.MutableStateFlow<MainTab?>(null)
    val requested: kotlinx.coroutines.flow.StateFlow<MainTab?> = _requested
    fun open(tab: MainTab) { _requested.value = tab }
    fun consume() { _requested.value = null }
    // 状态点按**枚举**发布：底栏索引是按权限过滤后的 tabs，侧栏用的是另一份，
    // 两边索引对不上，只能靠枚举对齐（活动红点 / 我的更新点）。
    private val _tabDots = kotlinx.coroutines.flow.MutableStateFlow<Map<MainTab, io.movieclaw.android.core.designsystem.TabDot>>(emptyMap())
    val tabDots: kotlinx.coroutines.flow.StateFlow<Map<MainTab, io.movieclaw.android.core.designsystem.TabDot>> = _tabDots
    fun publishDots(dots: Map<MainTab, io.movieclaw.android.core.designsystem.TabDot>) { if (_tabDots.value != dots) _tabDots.value = dots }
}

@HiltViewModel
class MainTabViewModel @Inject constructor(
    private val repository: io.movieclaw.android.core.session.SessionRepository,
    /** 底栏页签状态点（活动三色点 / 「我的」有更新蓝点） */
    val badges: ShellBadges,
    /** 落地页稳定后的一次性预热（数据 + 首屏图） */
    val prewarm: io.movieclaw.android.core.session.SessionPrewarm,
    /** 底栏形态试用开关（「我的」页切换；开 = 液态玻璃新版，关 = 当前形态） */
    private val tabBarPrefs: io.movieclaw.android.core.session.TabBarPrefs,
) : ViewModel() {
    val ui = repository.ui

    val liquidTabBar = tabBarPrefs.liquid.stateIn(
        viewModelScope,
        kotlinx.coroutines.flow.SharingStarted.WhileSubscribed(5000),
        false,
    )

    fun setLiquidTabBar(on: Boolean) {
        viewModelScope.launch { tabBarPrefs.setLiquid(on) }
    }
}

/**
 * 五 Tab 主壳 —— 底栏按移动端网页实测重做：
 * 悬浮胶囊 348×54（左右 21、距底 22）、圆角 999、**图标-only**（无文字标签）、
 * 当前格背后一枚白 15% 药丸；最后一格是账号头像（25 圆、白底、深色首字母）。
 * 之前用的是 Material3 的标准 NavigationBar（贴底、带文字、方块指示器），与网页完全不同。
 */
@Composable
fun MainTabScreen(
    onOpenLibrary: (Long, String) -> Unit,
    onOpenItem: (Long, Long) -> Unit,
    onPlay: (PlayTarget) -> Unit,
    /** 放大镜：参数是进来时预选的搜索分区（发现 / 订阅 → 影视，媒体库 → 媒体库，活动 → 资源；「我的」= null 沿用上次） */
    onOpenSearch: (String?) -> Unit,
    onOpenNotices: () -> Unit,
    onOpenSubscription: (Long) -> Unit,
    onOpenTitle: (String) -> Unit,
    onOpenCollection: (String, String) -> Unit,
    onSubscribeTitle: (String, io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.Seed?) -> Unit,
    onOpenManage: () -> Unit,
    /** 「我的」页账户卡 → 个人信息；提醒组的更新行 → 设置 → 更新与维护 */
    onOpenProfile: () -> Unit = {},
    onOpenUpdate: () -> Unit = {},
    /** 「我的」页最近会话的首行「新会话」（点某条会话复用下面的 onOpenAgentSession） */
    onOpenNewSession: () -> Unit = {},
    onOpenFavorites: () -> Unit,
    /** 媒体库 ⋯ 菜单的「全部合集」 */
    onOpenCollections: () -> Unit = {},
    onOpenAgent: () -> Unit,
    /** 活动页「交给 AI 分析」建好会话后直接进那个会话 */
    onOpenAgentSession: (String) -> Unit,
    /** 活动页进二级页（active / history / plays / stats） */
    onOpenActivityDetail: (String) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenAccounts: () -> Unit,
    /** 「我的」页右上角扫码钮：扫码批准设备登录（iOS `open-scanner` 同款） */
    onScanPairing: () -> Unit = {},
    /** 「我的」页「下载」行：离线下载管理 */
    onOpenDownloads: () -> Unit = {},
    /** 「全部电影」类型行点「查看全部」进跨库墙 */
    onOpenKind: (String) -> Unit = {},
    /** 媒体库顶栏「▶ 片段」 */
    onOpenReels: () -> Unit = {},
    /** 媒体库 ⋯ 菜单「自定义首页」→ 原生行清单编辑器 */
    onOpenCustomize: () -> Unit = {},
    /** 「按类型找电影 / 剧集」色块点进带类型的跨库墙 */
    onOpenGenre: (String, String) -> Unit = { _, _ -> },
    /** 首页合集行 / 全部合集的卡片 → 原生合集详情（库内合集，与发现页的 TMDB 合集不是同一种） */
    onOpenLibraryCollection: (Long, String) -> Unit = { _, _ -> },
    /** 订阅首页的「剧集/电影订阅 ›」与「查看全部」→ 订阅海报墙 */
    onOpenSubsWall: (String) -> Unit = {},
    subscriptions: io.movieclaw.android.feature.subscriptions.SubscriptionIndex,
    vm: MainTabViewModel = hiltViewModel(),
    /**
     * 「再点一次当前页签 → 回到该页签的根页面」（`ipad.md` §3：每一项一个导航栈，
     * 切走再切回来还在原来那一层，**再点一次退回根页面**）。
     *
     * 独立导航栈还没做，所以先落地这一条可观察行为：popBackStack 由外壳执行。
     */
    onTabReselect: () -> Unit = {},
    /** 把当前页签播报给外壳，供外壳的侧边栏高亮（`MainTabBus` 只能「请求切换」，读不到当前值） */
    onCurrentTabChanged: (MainTab) -> Unit = {},
) {
    var current by rememberSaveable { mutableStateOf(MainTab.DISCOVER) }
    val ui by vm.ui.collectAsStateWithLifecycle()
    val permissions = LocalPermissions.current

    // 页签按权限裁剪（同网页底栏 / iOS MainTabView.visibleTabs）：
    // 「订阅」要能订阅、「活动」是超管页面（成员手输 URL 也进不去）
    val tabs = MainTab.entries.filter { tab ->
        when (tab) {
            MainTab.SUBSCRIPTIONS -> permissions.canSubscribe
            MainTab.ACTIVITY -> permissions.isAdmin
            else -> true
        }
    }
    // 换账号后当前页签可能已被裁掉（管理员 → 成员正停在「活动」），落回第一格
    val selected = tabs.indexOf(current).takeIf { it >= 0 } ?: 0
    // 选中页签的统一入口：点同一个页签 = 回根
    val selectTab: (Int) -> Unit = { i ->
        if (tabs[i] == current) onTabReselect() else current = tabs[i]
    }

    // 别的页面请求切页签（如影人页空态的「去媒体库」）
    val tabRequest by MainTabBus.requested.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(tabRequest) {
        tabRequest?.let { tab ->
            if (tabs.contains(tab)) current = tab
            MainTabBus.consume()
        }
    }

    // 落地页稳定后预热一次（iOS `MainTabView` 的 idle 预热：数据 + 首屏图，退让 2 秒）
    androidx.compose.runtime.LaunchedEffect(ui.phase) {
        if (ui.phase == io.movieclaw.android.core.session.SessionPhase.READY) vm.prewarm.warmOnce()
    }

    // 底栏状态点（iOS `ShellBadges`）：前台轮询，退后台停、回前台立刻刷
    val activityDot by vm.badges.activityDot.collectAsStateWithLifecycle()
    val moreDot by vm.badges.moreDot.collectAsStateWithLifecycle()
    // 底栏形态试用开关（「我的」页切换）
    val liquidTabBar by vm.liquidTabBar.collectAsStateWithLifecycle()
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.RESUMED) {
            vm.badges.runForegroundPolling()
        }
    }
    val dots: Map<Int, TabDot> = androidx.compose.runtime.remember(activityDot, moreDot, tabs) {
        buildMap {
            activityDot?.let { d -> tabs.indexOf(MainTab.ACTIVITY).takeIf { it >= 0 }?.let { put(it, d) } }
            moreDot?.let { d -> tabs.indexOf(MainTab.MORE).takeIf { it >= 0 }?.let { put(it, d) } }
        }
    }

    // 把同一份状态点按**枚举**发布给外壳：侧栏与底栏都能显示（活动红点 / 我的更新点）
    androidx.compose.runtime.SideEffect {
        MainTabBus.publishDots(
            buildMap {
                activityDot?.let { d -> put(MainTab.ACTIVITY, d) }
                moreDot?.let { d -> put(MainTab.MORE, d) }
            },
        )
    }    // 液态底栏的模糊源：开关打开才提供（Local 为 null 时内容层的标记原样返回，零代价）
    val hazeState = dev.chrisbanes.haze.rememberHazeState()
    // 气泡折射取样源：与模糊同一节点（`tabGlassSource` 里同时记录），开关打开才提供
    val tabGlassHolder = remember { io.movieclaw.android.core.designsystem.TabGlassLayerHolder() }

    // 宽窗口用左侧导航栏，窄窗口仍用悬浮胶囊底栏（iPad 的 `sidebarAdaptable` 同思路：
    // 宽屏不把 5 格底栏拉满 1024dp，窄屏才回到底栏）。
    val wideShell = io.movieclaw.android.core.designsystem.LocalCardMetrics.current.isWide
    androidx.compose.runtime.LaunchedEffect(current) { onCurrentTabChanged(current) }

    Row(
        Modifier
            .fillMaxSize()
            // 宽屏内容区透明，让外壳的 ShellBackdrop 从页面后面透出来（发现页无左边界）。
            .background(if (wideShell) androidx.compose.ui.graphics.Color.Transparent else Bg),
    ) {
        Box(Modifier.weight(1f).fillMaxSize()) {
        KeepAliveTabs(tabs, tabs[selected]) { tab, active ->
                    androidx.compose.runtime.CompositionLocalProvider(
                        // 模糊源只挂前台页签：后台页签也挂的话，同一个 HazeState 会收到几块不在屏上的内容
                        io.movieclaw.android.core.designsystem.LocalTabHazeState provides if (liquidTabBar && active) hazeState else null,
                        // 取样源同理：只挂前台页签，气泡折射的永远是当前这一页
                        io.movieclaw.android.core.designsystem.LocalTabGlassLayer provides if (liquidTabBar && active) tabGlassHolder else null,
                    ) {
            // 离线时订阅、发现、活动都要连服务器：换成占位（「去媒体库」「重新连接」）
            val toLibrary = { current = MainTab.LIBRARY }
            when (tab) {
            MainTab.DISCOVER -> io.movieclaw.android.feature.offline.OfflineGate(toLibrary) { DiscoverScreen(
                onOpenLibrary = onOpenLibrary,
                onOpenItem = onOpenItem,
                onPlay = onPlay,
                onOpenSearch = { onOpenSearch("media") },
                onOpenTitle = onOpenTitle,
                onOpenCollection = onOpenCollection,
                onSubscribeTitle = onSubscribeTitle,
                subscriptions = subscriptions,
            ) }
            MainTab.LIBRARY -> LibraryScreen(
                onOpenLibrary = onOpenLibrary,
                onOpenItem = onOpenItem,
                onPlay = onPlay,
                onOpenSearch = { onOpenSearch("library") },
                onOpenManage = onOpenManage,
                onOpenFavorites = onOpenFavorites,
                onOpenCollections = onOpenCollections,
                onOpenKind = onOpenKind,
                onOpenReels = onOpenReels,
                onOpenCustomize = onOpenCustomize,
                onOpenGenre = onOpenGenre,
                onOpenCollection = onOpenLibraryCollection,
                onOpenDownloads = onOpenDownloads,
            )
            MainTab.SUBSCRIPTIONS -> io.movieclaw.android.feature.offline.OfflineGate(toLibrary) { SubsHomeScreen(
                onOpenSubscription = onOpenSubscription,
                onPlay = onPlay,
                onOpenTitle = onOpenTitle,
                // 空态的「去发现剧集」：切到发现页（网页是跳 /discover/tv）
                onOpenDiscover = { current = MainTab.DISCOVER },
                // 「剧集/电影订阅 ›」与「查看全部」→ 订阅海报墙
                onOpenWall = onOpenSubsWall,
            ) }
            MainTab.ACTIVITY -> io.movieclaw.android.feature.offline.OfflineGate(toLibrary) { ActivityScreen(
                onOpenAgentSession = onOpenAgentSession,
                onOpenActivityDetail = onOpenActivityDetail,
                onOpenItem = onOpenItem,
            ) }
            MainTab.MORE -> MoreScreen(
                onScanPairing = onScanPairing,
                onOpenDownloads = onOpenDownloads,
                onOpenProfile = onOpenProfile,
                onOpenNotices = onOpenNotices,
                onOpenUpdate = onOpenUpdate,
                onOpenNewSession = onOpenNewSession,
                onOpenAgentSession = onOpenAgentSession,
                onOpenSettings = onOpenSettings,
            )
            }
                    }
        }

        // 悬浮胶囊底栏：内容从它下面穿过（实测就是这样，底栏不占布局高度）。
        // 「我的」页的试用开关在两套形态间 A/B：开 = 液态玻璃新版，关 = `McCapsuleTabBar`。
        // **默认关**（低性能平板开玻璃底栏会卡），宽窗口换成左侧栏，这里只在窄窗口生效。
        if (!wideShell && liquidTabBar) {
            io.movieclaw.android.core.designsystem.McLiquidTabBar(
                icons = tabs.map { it.icon },
                labels = tabs.map { it.label },
                selectedIndex = selected,
                onSelect = selectTab,
                avatarInitials = ui.session.initials(),
                avatarUrl = ui.session?.avatarUrl,
                origin = ui.origin,
                dots = dots,
                hazeState = hazeState,
                glassSource = tabGlassHolder,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(bottom = McMetrics.tabBarBottom),
            )
        } else if (!wideShell) {
            McCapsuleTabBar(
                icons = tabs.map { it.icon },
                labels = tabs.map { it.label },
                selectedIndex = selected,
                onSelect = selectTab,
                avatarInitials = ui.session.initials(),
                avatarUrl = ui.session?.avatarUrl,
                origin = ui.origin,
                dots = dots,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(bottom = McMetrics.tabBarBottom),
            )
        }
        }
    }
}

/**
 * 主页签容器：去过的页签都留在组合里，切换只换「摆哪一页」（见 [LocalTabActive]）。
 * 以前 `when (tab)` 每次切换都把整页拆掉重建，那一帧很重，底栏胶囊会顿一下。
 */
@androidx.compose.runtime.Composable
internal fun <T : Any> KeepAliveTabs(
    tabs: List<T>,
    selected: T,
    content: @androidx.compose.runtime.Composable (tab: T, active: Boolean) -> Unit,
) {
    // 普通集合即可：只在组合时追加，而切页签本身就会触发这次组合
    val visited = androidx.compose.runtime.remember { mutableSetOf<T>() }
    visited += selected
    tabs.filter { it in visited }.forEach { tab ->
        val active = tab == selected
        androidx.compose.runtime.key(tab) {
            Box(Modifier.fillMaxSize().then(if (active) Modifier else Modifier.hiddenTab())) {
                androidx.compose.runtime.CompositionLocalProvider(
                    io.movieclaw.android.core.designsystem.LocalTabActive provides active,
                ) { content(tab, active) }
            }
        }
    }
}

/**
 * 后台页签：留在组合里（状态、已组装的列表项、已解码的图都在），但**不测量、不摆放**——
 * 不画、不收触摸、不进布局。切回来只需测量摆放，不用从头组装整页。
 */
private fun Modifier.hiddenTab(): Modifier = this
    .layout { _, constraints -> layout(constraints.maxWidth, constraints.maxHeight) {} }
    // 不摆放的节点仍留在无障碍树里：读屏会读到、聚焦到看不见的后台页签，一并清掉
    .clearAndSetSemantics {}
