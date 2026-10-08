package io.movieclaw.android.feature.more

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.SystemUpdateAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.FeedbackTone
import io.movieclaw.android.core.designsystem.FlatCard
import io.movieclaw.android.core.designsystem.FlatRow
import io.movieclaw.android.core.designsystem.GroupLabel
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McNotice
import io.movieclaw.android.core.designsystem.McTabBarContentPadding
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.tabGlassSource
import io.movieclaw.android.core.designsystem.MenuSurface
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.SessionRename
import io.movieclaw.android.core.model.SessionSummary
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.model.visibleNotices
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.BuildInfo
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.LocalPermissions
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** 「我的」页的数据：提醒组（待处理 + 待更新）与最近会话 */
@HiltViewModel
class MoreViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
    /** 底栏形态试用开关（液态玻璃新版 ⇄ 当前形态） */
    private val tabBarPrefs: io.movieclaw.android.core.session.TabBarPrefs,
) : ViewModel() {
    val ui = repository.ui
    val servers = repository.servers

    val liquidTabBar = tabBarPrefs.liquid.stateIn(
        viewModelScope,
        kotlinx.coroutines.flow.SharingStarted.WhileSubscribed(5000),
        false,
    )

    fun setLiquidTabBar(on: Boolean) {
        viewModelScope.launch { tabBarPrefs.setLiquid(on) }
    }

    /** 提醒组的两件事：待处理条数与「新版本 vX / 新识别模型 X」（都只对管理员有意义） */
    data class Reminders(val noticeCount: Int = 0, val updateLabel: String? = null) {
        val visible: Boolean get() = noticeCount > 0 || updateLabel != null
    }

    private val _reminders = MutableStateFlow(Reminders())
    val reminders = _reminders.asStateFlow()

    /** 最近会话（管理员）：每页 20 条，滑到底续载（同 iOS `MorePage.pageSize`） */
    data class Sessions(
        val items: List<SessionSummary> = emptyList(),
        val loading: Boolean = true,
        val loadingMore: Boolean = false,
        val hasMore: Boolean = false,
        val error: String? = null,
    )

    private val _sessions = MutableStateFlow(Sessions())
    val sessions = _sessions.asStateFlow()

    val origin: String? get() = repository.ui.value.origin
    private val isAdmin: Boolean
        get() = io.movieclaw.android.core.session.Permissions
            .of(repository.ui.value.session).isAdmin

    private var pollJob: Job? = null

    init {
        loadReminders()
        loadSessions()
        // 待处理事项与服务端同频 30 秒轮询（iOS `.polling(every: 30, immediately: true)`）
        pollJob = viewModelScope.launch {
            while (true) {
                delay(30_000)
                loadReminders()
            }
        }
    }

    override fun onCleared() {
        pollJob?.cancel()
        super.onCleared()
    }

    fun loadReminders() {
        if (!isAdmin) { _reminders.value = Reminders(); return }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            // 拉取失败保留上次结果，下一轮轮询自愈（同 Web / iOS）
            val notices = runCatching { api.notices().dataOrThrow() }.getOrNull()
            val pending = runCatching { api.pendingUpdate().dataOrThrow() }.getOrNull()
            _reminders.value = Reminders(
                noticeCount = notices?.let { visibleNotices(it).size } ?: _reminders.value.noticeCount,
                // 文案照 Web `app-update-entry` / iOS `ShellBadges.updateLabel`：
                // 应用与模型都有更新时只说应用版本
                updateLabel = when {
                    pending?.appVersion != null -> "新版本 v${pending.appVersion}"
                    pending?.modelTag != null -> "新识别模型 ${pending.modelTag}"
                    else -> null
                },
            )
        }
    }

    fun loadSessions() {
        if (!isAdmin) { _sessions.value = Sessions(loading = false); return }
        viewModelScope.launch {
            val origin = origin ?: run {
                _sessions.value = Sessions(loading = false, error = "尚未连接服务器")
                return@launch
            }
            _sessions.value = _sessions.value.copy(loading = true, error = null)
            runCatching { apiFactory.forOrigin(origin).sessions(limit = PAGE_SIZE, offset = 0).dataOrThrow() }
                .onSuccess { list ->
                    _sessions.value = Sessions(items = list, loading = false, hasMore = list.size == PAGE_SIZE)
                }
                .onFailure { e ->
                    _sessions.value = _sessions.value.copy(loading = false, error = friendlyMessage(e))
                }
        }
    }

    /** 接着取下一页；按 id 去重（翻页期间有新会话插到最前，偏移会错开一条，同 iOS） */
    fun loadMoreSessions() {
        val state = _sessions.value
        if (!state.hasMore || state.loadingMore || state.loading) return
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _sessions.value = state.copy(loadingMore = true)
            runCatching {
                apiFactory.forOrigin(origin).sessions(limit = PAGE_SIZE, offset = state.items.size).dataOrThrow()
            }
                .onSuccess { page ->
                    val known = _sessions.value.items.map { it.id }.toSet()
                    val merged = _sessions.value.items + page.filterNot { it.id in known }
                    _sessions.value = Sessions(items = merged, loading = false, hasMore = page.size == PAGE_SIZE)
                }
                .onFailure { _sessions.value = _sessions.value.copy(loadingMore = false) }
        }
    }

    /** 会话标题：标题 → 最后一句提问 → 未命名会话（iOS `MorePage.title(of:)`） */
    fun titleOf(item: SessionSummary): String =
        item.title?.takeIf { it.isNotEmpty() }
            ?: item.lastPrompt?.takeIf { it.isNotEmpty() }
            ?: "未命名会话"

    fun rename(item: SessionSummary, title: String, onDone: (String?) -> Unit) {
        val name = title.trim().take(80)
        if (name.isEmpty() || name == titleOf(item)) { onDone(null); return }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).renameSession(item.id, SessionRename(name)).dataOrThrow()
            }
                .onSuccess {
                    _sessions.value = _sessions.value.copy(
                        items = _sessions.value.items.map { s -> if (s.id == item.id) s.copy(title = name) else s },
                    )
                    onDone(null)
                }
                .onFailure { e -> onDone(friendlyMessage(e)) }
        }
    }

    fun delete(item: SessionSummary, onDone: (String?) -> Unit) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).deleteSession(item.id) }
                .onSuccess {
                    _sessions.value = _sessions.value.copy(items = _sessions.value.items.filterNot { it.id == item.id })
                    onDone(null)
                }
                .onFailure { e -> onDone(friendlyMessage(e)) }
        }
    }

    /** 在（新会话中）继续：分叉出独立的新会话并直接进去 */
    fun fork(item: SessionSummary, onForked: (String) -> Unit, onFailed: (String) -> Unit) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).forkSession(item.id).dataOrThrow() }
                .onSuccess { transcript -> onForked(transcript.session.id) }
                .onFailure { e -> onFailed(friendlyMessage(e)) }
        }
    }

    private companion object {
        /** 会话列表每页条数（Web agent-conversations / iOS MorePage 同值） */
        const val PAGE_SIZE = 20
    }
}

/** 账号、连接、外观与最近会话；各入口保留原有权限和导航行为。 */
@Composable
fun MoreScreen(
    /** 账户卡 → 个人信息（同 iOS：整张卡点进个人信息，不垫设置列表） */
    onOpenProfile: () -> Unit,
    onOpenNotices: () -> Unit,
    /** 提醒组的更新行 → 设置 → 更新与维护 */
    onOpenUpdate: () -> Unit,
    /** 最近会话首行「新会话」 */
    onOpenNewSession: () -> Unit,
    onOpenAgentSession: (String) -> Unit,
    onOpenSettings: () -> Unit,
    vm: MoreViewModel = hiltViewModel(),
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val servers by vm.servers.collectAsStateWithLifecycle()
    val reminders by vm.reminders.collectAsStateWithLifecycle()
    val sessions by vm.sessions.collectAsStateWithLifecycle()
    // 底栏形态试用开关（开 = 液态玻璃新版，关 = 当前形态）
    val liquidTabBar by vm.liquidTabBar.collectAsStateWithLifecycle()
    val permissions = LocalPermissions.current
    val feedback = LocalFeedback.current

    val listState = rememberLazyListState()
    val scroll = rememberScrollState()
    io.movieclaw.android.core.designsystem.TrackTabBarMinimize(scroll)

    // 悬浮顶栏占的高度（状态栏 + 52dp）：大标题按它让位，否则标题会压到状态栏上
    val topBarTotal = androidx.compose.foundation.layout.WindowInsets.statusBars
        .asPaddingValues()
        .calculateTopPadding() + McMetrics.topBarHeight

    var menuFor by remember { mutableStateOf<SessionSummary?>(null) }
    var renameTarget by remember { mutableStateOf<SessionSummary?>(null) }
    var deleteTarget by remember { mutableStateOf<SessionSummary?>(null) }
    var forkTarget by remember { mutableStateOf<SessionSummary?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }

    // 触底续载（每页 20 条，滑到末尾附近就接着取，同 iOS `.onAppear { loadMore }`）
    LaunchedEffect(listState, sessions.items.size) {
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collect { last ->
                val total = listState.layoutInfo.totalItemsCount
                if (total > 0 && last >= total - 3) vm.loadMoreSessions()
            }
    }

    Box(Modifier.fillMaxSize().background(Bg)) {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(top = topBarTotal + 6.dp, bottom = McTabBarContentPadding),
            modifier = Modifier.fillMaxSize()
                // 液态底栏的背景模糊源（Local 为 null 时原样返回，零代价）
                .tabGlassSource(),
        ) {
            // ── 账户卡（头像 + 昵称 + 身份小字 + 雪佛龙，整卡进「个人信息」）──
            item(key = "profile") {
                Box(Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 8.dp)) {
                    MoreAccountCard(session = ui.session, origin = vm.origin, onClick = onOpenProfile)
                }
            }

            // ── 提醒组（仅管理员，且「有事」才出现；待处理 30 秒轮询）──
            if (permissions.isAdmin && reminders.visible) {
                item(key = "reminders") {
                    Spacer(Modifier.height(18.dp))
                    FlatCard(Modifier.padding(horizontal = McMetrics.pagePadding).fillMaxWidth()) {
                        if (reminders.noticeCount > 0) {
                            FlatRow(
                                title = "待处理",
                                icon = Icons.Rounded.Notifications,
                                titleColor = Danger,
                                trailing = { NoticeCountBadge(reminders.noticeCount) },
                                onClick = onOpenNotices,
                            )
                            if (reminders.updateLabel != null) RowDivider()
                        }
                        reminders.updateLabel?.let { label ->
                            FlatRow(
                                title = label,
                                icon = Icons.Rounded.SystemUpdateAlt,
                                titleColor = Info,
                                onClick = onOpenUpdate,
                            )
                        }
                    }
                }
            }

            // 连接信息只出现一次；外观开关独立分组，客户端版本放到页尾。
            item(key = "server") {
                GroupLabel("连接", modifier = Modifier.padding(top = 16.dp))
                Box(Modifier.padding(horizontal = McMetrics.pagePadding)) {
                    MoreConnectionCard(origin = ui.origin, savedCount = servers.size, onClick = onOpenSettings)
                }
            }
            item(key = "appearance") {
                GroupLabel("显示与外观", modifier = Modifier.padding(top = 20.dp))
                Box(Modifier.padding(horizontal = McMetrics.pagePadding)) {
                    MoreAppearanceCard(liquidTabBar, vm::setLiquidTabBar)
                }
            }

            // ── 最近会话（仅管理员）：首行「新会话」是发起入口，下面是会话列表 ──
            if (permissions.isAdmin) {
                item(key = "sessions") {
                    GroupLabel("最近会话", modifier = Modifier.padding(top = 22.dp))
                    if (sessions.items.isEmpty() && !sessions.loading && sessions.error == null) {
                        Box(Modifier.padding(horizontal = McMetrics.pagePadding)) {
                            MoreEmptySessions(onOpenNewSession)
                        }
                    } else FlatCard(Modifier.padding(horizontal = McMetrics.pagePadding).fillMaxWidth()) {
                        FlatRow(
                            title = "新会话",
                            icon = Icons.Rounded.Add,
                            titleColor = Accent,
                            onClick = onOpenNewSession,
                        )
                        sessions.items.forEach { item ->
                            RowDivider()
                            SessionListRow(
                                title = vm.titleOf(item),
                                running = item.running,
                                onClick = { onOpenAgentSession(item.id) },
                                onLongClick = { menuFor = item },
                            )
                        }
                    }
                    when {
                        sessions.items.isEmpty() && sessions.loading -> Text(
                            "正在读取会话…",
                            style = McType.caption,
                            color = TextFaint,
                            modifier = Modifier.padding(start = McMetrics.pagePadding + 4.dp, top = 12.dp),
                        )
                    }
                    sessions.error?.let { error ->
                        Text(
                            error,
                            style = McType.caption,
                            color = Danger,
                            modifier = Modifier.padding(start = McMetrics.pagePadding + 4.dp, top = 10.dp),
                        )
                    }
                    if (sessions.loadingMore) {
                        Box(Modifier.fillMaxWidth().padding(14.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        }
                    }
                }
            }

            if (ui.cached) {
                item(key = "cached-note") {
                    Text(
                        "正在刷新账号信息…",
                        style = McType.micro,
                        color = TextFaint,
                        modifier = Modifier.padding(start = McMetrics.pagePadding, top = 12.dp),
                    )
                }
            }
            item(key = "tail") {
                Text(
                    "MovieClaw Android · ${BuildInfo.APP_VERSION}",
                    style = McType.micro, color = TextFaint,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 22.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }

        // 顶栏：大标题（同活动页 `largeTitle`），**右上角不再有搜索键**
        McTopBar(
            variant = McTopBarVariant.Root,
            title = "我的",
            largeTitle = true,
            modifier = Modifier.align(Alignment.TopCenter),
        )

        // 会话行的长按菜单：与 iOS 的长按菜单同三项、同顺序（删除前一条分隔线、红色）
        menuFor?.let { item ->
            Box(
                Modifier
                    .fillMaxSize()
                    .clickable(
                        interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                        indication = null,
                    ) { menuFor = null },
            )
            SessionActionMenu(
                onFork = {
                    val target = item
                    menuFor = null
                    forkTarget = target
                },
                onRename = {
                    val target = item
                    menuFor = null
                    renameTarget = target
                },
                onDelete = {
                    val target = item
                    menuFor = null
                    deleteTarget = target
                },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 120.dp),
            )
        }
    }

    // 重命名：默认填当前标题、最多 80 字（iOS `feedback.prompt` 同款）
    renameTarget?.let { target ->
        RenameSessionDialog(
            initial = vm.titleOf(target),
            onDismiss = { renameTarget = null },
            onConfirm = { name ->
                val t = target
                renameTarget = null
                vm.rename(t, name) { err -> if (err != null) actionError = "重命名失败：$err" }
            },
        )
    }
    // 在（新会话中）继续：先确认（同 iOS 文案）
    forkTarget?.let { target ->
        ConfirmDialog(
            title = "在新会话中继续「${vm.titleOf(target)}」？",
            message = "会带上这段对话的上下文开一个新会话接着聊，原会话保留不变。",
            confirmText = "创建新会话",
            onConfirm = {
                val t = target
                forkTarget = null
                vm.fork(
                    t,
                    onForked = { id -> onOpenAgentSession(id) },
                    onFailed = { err -> actionError = "创建续接会话失败：$err" },
                )
            },
            onDismiss = { forkTarget = null },
        )
    }
    // 彻底删除：不可恢复，红色（同 iOS 文案）
    deleteTarget?.let { target ->
        ConfirmDialog(
            title = "彻底删除会话「${vm.titleOf(target)}」？",
            message = "服务器上的完整对话记录将一并删除，此操作不可恢复。",
            confirmText = "彻底删除",
            destructive = true,
            onConfirm = {
                val t = target
                deleteTarget = null
                vm.delete(t) { err -> if (err != null) actionError = "删除失败：$err" }
            },
            onDismiss = { deleteTarget = null },
        )
    }
    actionError?.let { error ->
        LaunchedEffect(error) {
            feedback.show(McNotice(error, FeedbackTone.Error))
            actionError = null
        }
    }
}

/** 待处理条数的红色胶囊（iOS：危险色底 + 白字） */
@Composable
private fun NoticeCountBadge(count: Int) {
    Text(
        "$count",
        style = McType.caption2,
        color = Color.White,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(Danger)
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

/**
 * 会话行：运行中前置一颗信息蓝点，其余是标题 + 雪佛龙。
 * 点开进会话；**长按出菜单**（iOS 是左滑 + 长按两套，Android 没有左滑这个系统惯例，
 * 只取长按——同一个菜单、同样三项）。
 */
@Composable
private fun SessionListRow(
    title: String,
    running: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(49.dp)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (running) {
            Box(Modifier.size(6.dp).clip(CircleShape).background(Info))
            Spacer(Modifier.width(8.dp))
        }
        Text(
            title,
            style = McType.bodyMedium,
            color = TextPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Icon(
            Icons.AutoMirrored.Rounded.KeyboardArrowRight,
            contentDescription = null,
            tint = TextFaint,
            modifier = Modifier.size(15.dp),
        )
    }
}

/** 会话长按菜单（三项：在新会话中继续 / 重命名 / 删除会话，删除红色并前置分隔线） */
@Composable
private fun SessionActionMenu(
    onFork: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .width(210.dp)
            .clip(RoundedCornerShape(McMetrics.menuRadius))
            .background(MenuSurface)
            .border(1.dp, LineSoft, RoundedCornerShape(McMetrics.menuRadius))
            .padding(4.dp),
    ) {
        MenuActionRow("在新会话中继续", onClick = onFork)
        MenuActionRow("重命名", onClick = onRename)
        Box(Modifier.fillMaxWidth().height(1.dp).background(LineSoft))
        MenuActionRow("删除会话", danger = true, onClick = onDelete)
    }
}

@Composable
private fun MenuActionRow(text: String, danger: Boolean = false, onClick: () -> Unit) {
    Text(
        text,
        style = McType.bodyMedium,
        color = if (danger) Danger else TextPrimary,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 11.dp),
    )
}

/** 重命名会话：单行输入 + 保存（默认填当前标题、最多 80 字） */
@Composable
private fun RenameSessionDialog(initial: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var text by remember(initial) { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF1E212B),
        title = { Text("重命名会话", color = TextPrimary) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { if (it.length <= 80) text = it },
                singleLine = true,
                placeholder = { Text("会话标题（最多 80 字）", style = McType.footnote, color = TextFaint) },
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    focusedBorderColor = Accent,
                    unfocusedBorderColor = LineSoft,
                    cursorColor = Accent,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(text) }) { Text("保存", color = Accent) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) }
        },
    )
}

/** 通用确认弹窗（文案与 iOS `feedback.confirm` 一致） */
@Composable
private fun ConfirmDialog(
    title: String,
    message: String,
    confirmText: String,
    destructive: Boolean = false,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF1E212B),
        title = { Text(title, color = TextPrimary, fontSize = 16.sp) },
        text = { Text(message, color = TextMuted, fontSize = 14.sp, lineHeight = 20.sp) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(confirmText, color = if (destructive) Danger else Accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) }
        },
    )
}

/** 平色卡的 6% 白细线（实测 divide-white/[0.06]） */
@Composable
private fun RowDivider() {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(start = 16.dp)
            .height(1.dp)
            .background(LineSoft),
    )
}
