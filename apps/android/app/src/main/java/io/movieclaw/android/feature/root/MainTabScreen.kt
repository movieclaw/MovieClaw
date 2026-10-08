package io.movieclaw.android.feature.root

import androidx.compose.foundation.background
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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

    // 液态底栏的模糊源：开关打开才提供（Local 为 null 时内容层的标记原样返回，零代价）
    val hazeState = dev.chrisbanes.haze.rememberHazeState()

    Box(Modifier.fillMaxSize().background(Bg)) {
        androidx.compose.runtime.CompositionLocalProvider(
            io.movieclaw.android.core.designsystem.LocalTabHazeState provides if (liquidTabBar) hazeState else null,
        ) {
            when (tabs[selected]) {
            MainTab.DISCOVER -> DiscoverScreen(
                onOpenLibrary = onOpenLibrary,
                onOpenItem = onOpenItem,
                onPlay = onPlay,
                onOpenSearch = { onOpenSearch("media") },
                onOpenTitle = onOpenTitle,
                onOpenCollection = onOpenCollection,
                onSubscribeTitle = onSubscribeTitle,
                subscriptions = subscriptions,
            )
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
            )
            MainTab.SUBSCRIPTIONS -> SubsHomeScreen(
                onOpenSubscription = onOpenSubscription,
                onPlay = onPlay,
                onOpenTitle = onOpenTitle,
                // 空态的「去发现剧集」：切到发现页（网页是跳 /discover/tv）
                onOpenDiscover = { current = MainTab.DISCOVER },
                // 「剧集/电影订阅 ›」与「查看全部」→ 订阅海报墙
                onOpenWall = onOpenSubsWall,
            )
            MainTab.ACTIVITY -> ActivityScreen(
                onOpenAgentSession = onOpenAgentSession,
                onOpenActivityDetail = onOpenActivityDetail,
            )
            MainTab.MORE -> MoreScreen(
                onOpenProfile = onOpenProfile,
                onOpenNotices = onOpenNotices,
                onOpenUpdate = onOpenUpdate,
                onOpenNewSession = onOpenNewSession,
                onOpenAgentSession = onOpenAgentSession,
                onOpenSettings = onOpenSettings,
            )
            }
        }

        // 悬浮胶囊底栏：内容从它下面穿过（实测就是这样，底栏不占布局高度）。
        // 「我的」页的试用开关在两套形态间 A/B：开 = 液态玻璃新版，关 = 当前形态
        if (liquidTabBar) {
            io.movieclaw.android.core.designsystem.McLiquidTabBar(
                icons = tabs.map { it.icon },
                labels = tabs.map { it.label },
                selectedIndex = selected,
                onSelect = { current = tabs[it] },
                avatarInitials = ui.session.initials(),
                avatarUrl = ui.session?.avatarUrl,
                origin = ui.origin,
                dots = dots,
                hazeState = hazeState,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(bottom = McMetrics.tabBarBottom),
            )
        } else {
            McCapsuleTabBar(
                icons = tabs.map { it.icon },
                labels = tabs.map { it.label },
                selectedIndex = selected,
                onSelect = { current = tabs[it] },
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
