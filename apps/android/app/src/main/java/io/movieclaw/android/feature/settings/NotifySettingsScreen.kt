package io.movieclaw.android.feature.settings

import android.Manifest
import android.content.Context
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import io.movieclaw.android.core.designsystem.StatusDot
import io.movieclaw.android.core.designsystem.Warn
import io.movieclaw.android.core.designsystem.Danger
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.FillCard
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.Ok
import io.movieclaw.android.core.designsystem.TextPrimary
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.core.app.NotificationManagerCompat
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.PushEventPref
import io.movieclaw.android.core.model.PushPreferencesBody
import io.movieclaw.android.core.model.PushRegistrationBody
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.notify.NotifyPrefs
import io.movieclaw.android.core.notify.NotifyScheduler
import io.movieclaw.android.core.push.BackgroundGuide
import io.movieclaw.android.core.push.OngoingMode
import io.movieclaw.android.core.push.OngoingNotice
import io.movieclaw.android.core.push.OngoingView
import io.movieclaw.android.core.push.PushStreamController
import io.movieclaw.android.core.push.PushStreamKeepAlive
import io.movieclaw.android.core.push.PushStreamPrefs
import io.movieclaw.android.core.push.PushStreamState
import io.movieclaw.android.core.push.PushStreamStatus
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import android.app.Application
import retrofit2.HttpException
import io.movieclaw.android.core.designsystem.formSheetScroll

/**
 * 「通知」设置（iOS 是「账号 → 通知」，但那条链路走 APNs + 服务端云中继；
 * 本项目**不动服务端**，所以这里是纯客户端实现：系统本机每 15 分钟检查一次
 * 下载 / 入库 / 今日预告的变化，只在状态真的翻转时发本地通知）。
 *
 * 界面上如实写明机制与代价（最长 15 分钟延迟、依赖系统调度、不做服务端推送），
 * 4 个开关对应 4 条通知渠道（下载 / 入库 / 订阅更新 / 系统与任务）。
 *
 * 另有「实时通知（保持连接）」（core/push）：前台服务一直连着自己的服务器，服务器的通知即时送达，
 * 不依赖谷歌 / 厂商推送；代价是一条常驻的静音通知和多一点耗电，界面上同样如实写明。
 */
data class NotifySettingsState(
    val loaded: Boolean = false,
    val enabled: Boolean = false,
    val download: Boolean = true,
    val arrival: Boolean = true,
    val subscription: Boolean = true,
    val task: Boolean = true,
    /** 实时通知（保持连接） */
    val stream: Boolean = false,
    val streamBusy: Boolean = false,
    val testing: Boolean = false,
    /** 开关 / 测试通知的结果提示 */
    val streamMessage: String? = null,
    /** 刚开启：弹出后台运行引导 */
    val showGuide: Boolean = false,
    /** 服务器推送哪些事（账号级，与 iOS、网页共用）；null = 还没取到 */
    val events: List<PushEventPref>? = null,
    val eventsError: String? = null,
    /** 常驻通知显示什么（本机设置） */
    val ongoingMode: OngoingMode = OngoingMode.SMART,
    val ongoingTemplate: String = "",
)

@HiltViewModel
class NotifySettingsViewModel @Inject constructor(
    private val app: Application,
    private val session: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {
    private val prefs = NotifyPrefs(app)
    private val streamPrefs = PushStreamPrefs(app)
    private val _ui = MutableStateFlow(NotifySettingsState())
    val ui = _ui.asStateFlow()
    val streamStatus = PushStreamState.status

    init {
        viewModelScope.launch {
            val s = prefs.read()
            _ui.value = NotifySettingsState(
                loaded = true,
                enabled = s.enabled,
                download = s.download,
                arrival = s.arrival,
                subscription = s.subscription,
                task = s.task,
                stream = streamPrefs.enabled(),
                ongoingMode = streamPrefs.ongoingMode.first(),
                ongoingTemplate = streamPrefs.ongoingTemplate.first(),
            )
            // 已开启却没排程（重装 / 清数据 / 系统撤销）时补上
            if (s.enabled) NotifyScheduler.schedule(app)
            PushStreamController.startIfEnabled(app)
            if (_ui.value.stream) loadEvents()
        }
    }

    /** 读服务器上这个账号的推送偏好（实时通知按它筛，与 iOS 一致） */
    fun loadEvents() {
        viewModelScope.launch {
            val api = api() ?: return@launch
            runCatching { api.pushMe().dataOrThrow() }.fold(
                onSuccess = { _ui.value = _ui.value.copy(events = it.events, eventsError = null) },
                onFailure = { _ui.value = _ui.value.copy(eventsError = serverMessage(it)) },
            )
        }
    }

    /** 改一项：界面先变，服务器失败再改回去 */
    fun setEvent(key: String, on: Boolean) {
        val before = _ui.value.events ?: return
        _ui.value = _ui.value.copy(
            events = before.map { if (it.key == key) it.copy(enabled = on) else it },
            eventsError = null,
        )
        viewModelScope.launch {
            val api = api() ?: return@launch
            runCatching { api.pushPreferences(PushPreferencesBody(mapOf(key to on))).dataOrThrow() }.fold(
                onSuccess = { _ui.value = _ui.value.copy(events = it.events) },
                onFailure = { _ui.value = _ui.value.copy(events = before, eventsError = serverMessage(it)) },
            )
        }
    }

    /** 当前账号的 API（没登录时 null） */
    private fun api() = session.ui.value.origin?.let { origin ->
        session.requestIdentity(origin)?.let { apiFactory.forIdentity(origin, it) }
    }

    /**
     * 开：先在服务器登记成实时通知设备（顺带确认服务器版本支持），再起前台服务、弹后台引导。
     * 关：停服务，告诉服务器不再写发件箱（失败也照样关，服务器那边最多攒几条用不上的）。
     */
    fun setStream(on: Boolean) {
        if (_ui.value.streamBusy) return
        _ui.value = _ui.value.copy(streamBusy = true, streamMessage = null)
        viewModelScope.launch {
            val api = api()
            if (on) {
                val failure = when {
                    api == null -> "请先登录账号"
                    else -> runCatching {
                        val permission = if (NotificationManagerCompat.from(app).areNotificationsEnabled()) "authorized" else "denied"
                        api.pushRegister(PushRegistrationBody(permission = permission, stream = true)).dataOrThrow()
                    }.fold(
                        onSuccess = { view ->
                            if (view.channelName == PushStreamState.STREAM_CHANNEL) null
                            else "服务器版本不支持实时通知，请先更新 MovieClaw 服务器"
                        },
                        onFailure = { serverMessage(it) },
                    )
                }
                if (failure != null) {
                    _ui.value = _ui.value.copy(streamBusy = false, stream = false, streamMessage = failure)
                    return@launch
                }
                streamPrefs.setEnabled(true)
                PushStreamKeepAlive.schedule(app)
                PushStreamController.start(app)
                _ui.value = _ui.value.copy(streamBusy = false, stream = true, showGuide = true)
                loadEvents()
            } else {
                streamPrefs.setEnabled(false)
                PushStreamKeepAlive.cancel(app)
                PushStreamController.stop(app)
                _ui.value = _ui.value.copy(streamBusy = false, stream = false)
                api?.let { runCatching { it.pushRegister(PushRegistrationBody(permission = "authorized", stream = false)) } }
            }
        }
    }

    fun sendTest() {
        if (_ui.value.testing) return
        _ui.value = _ui.value.copy(testing = true, streamMessage = null)
        viewModelScope.launch {
            val api = api()
            val message = if (api == null) "请先登录账号" else runCatching { api.pushTest().dataOrThrow() }.fold(
                onSuccess = { view ->
                    if (view.results.isEmpty()) "这个账号还没有能收通知的设备"
                    else view.results.joinToString("\n") { r ->
                        "${r.deviceName}：${r.message.ifBlank { r.result }}"
                    }
                },
                onFailure = { serverMessage(it) },
            )
            _ui.value = _ui.value.copy(testing = false, streamMessage = message)
        }
    }

    fun setOngoing(mode: OngoingMode = _ui.value.ongoingMode, template: String = _ui.value.ongoingTemplate) {
        _ui.value = _ui.value.copy(ongoingMode = mode, ongoingTemplate = template)
        viewModelScope.launch { streamPrefs.setOngoing(mode, template) }
    }

    fun dismissGuide() {
        _ui.value = _ui.value.copy(showGuide = false)
    }

    fun openGuide() {
        _ui.value = _ui.value.copy(showGuide = true)
    }

    /** 服务器的中文报错（如「刚发过一条测试通知，请稍等几秒再试」）优先 */
    private fun serverMessage(e: Throwable): String {
        if (e is HttpException) {
            val body = runCatching { e.response()?.errorBody()?.string() }.getOrNull()
            val message = body?.let { Regex("\"message\"\\s*:\\s*\"([^\"]+)\"").find(it)?.groupValues?.get(1) }
            if (!message.isNullOrBlank()) return message
            if (e.code() == 404) return "服务器版本不支持实时通知，请先更新 MovieClaw 服务器"
        }
        return friendlyMessage(e)
    }

    fun setEnabled(on: Boolean) {
        _ui.value = _ui.value.copy(enabled = on)
        viewModelScope.launch {
            prefs.setEnabled(on)
            if (on) NotifyScheduler.schedule(app) else NotifyScheduler.cancel(app)
        }
        // 首轮基线交给 Worker 自己落：开启后第一次只记状态不轰炸
    }

    fun setChannels(download: Boolean, arrival: Boolean, subscription: Boolean, task: Boolean) {
        _ui.value = _ui.value.copy(
            download = download, arrival = arrival, subscription = subscription, task = task,
        )
        viewModelScope.launch { prefs.setChannel(download, arrival, subscription, task) }
    }
}

@Composable
fun NotifySettingsScreen(
    onBack: () -> Unit,
    vm: NotifySettingsViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsState()
    val context = LocalContext.current
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        // 用户拒了权限就保持开关不变（下次点开还会再问一次），并在下面那行提示里说明
        if (!granted) vm.setEnabled(false)
    }

    val streamPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { _ ->
        // 没给通知权限也照样开：连接保持着，服务器在「我的设备」里提示「系统通知已关闭」
        vm.setStream(true)
    }

    Column(Modifier.fillMaxSize()) {
        SettingsTopBar(title = "通知", onBack = onBack) { }
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(6.dp))
            NotifyRow(
                title = "开启通知",
                subtitle = if (state.stream) "实时连接断开较久时，在本机定时检查兜底提醒"
                else "在本机检查下载、入库与今日更新，有变化时提醒",
                checked = state.enabled,
                onChange = { on ->
                    if (on && Build.VERSION.SDK_INT >= 33 &&
                        !NotificationManagerCompat.from(context).areNotificationsEnabled()
                    ) {
                        permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        vm.setEnabled(on)
                    }
                },
            )
            // 开着实时通知时推什么由服务器偏好决定（见下方「推送哪些事」），本机分类开关只在兜底时用，收起免得混淆
            if (state.enabled && !state.stream) {
                NotifyRow(
                    title = "下载",
                    subtitle = "下载完成或失败时",
                    checked = state.download,
                    onChange = { vm.setChannels(it, state.arrival, state.subscription, state.task) },
                )
                NotifyRow(
                    title = "入库",
                    subtitle = "整理完成、新内容进库时",
                    checked = state.arrival,
                    onChange = { vm.setChannels(state.download, it, state.subscription, state.task) },
                )
                NotifyRow(
                    title = "订阅更新",
                    subtitle = "订阅的作品今天有可看的时",
                    checked = state.subscription,
                    onChange = { vm.setChannels(state.download, state.arrival, it, state.task) },
                )
                NotifyRow(
                    title = "系统与任务",
                    subtitle = "下载失败等需要处理的提醒",
                    checked = state.task,
                    onChange = { vm.setChannels(state.download, state.arrival, state.subscription, it) },
                )
            }
            Spacer(Modifier.height(18.dp))
            StreamSection(vm = vm, state = state, onEnable = { on ->
                if (on && Build.VERSION.SDK_INT >= 33 &&
                    !NotificationManagerCompat.from(context).areNotificationsEnabled()
                ) {
                    streamPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    vm.setStream(on)
                }
            })
            Spacer(Modifier.height(24.dp))
        }
    }

    if (state.showGuide) {
        BackgroundGuideSheet(onDismiss = vm::dismissGuide)
    }
}

/** 实时通知（保持连接）：开关、连接状态、测试通知、后台运行引导 */
@Composable
private fun StreamSection(
    vm: NotifySettingsViewModel,
    state: NotifySettingsState,
    onEnable: (Boolean) -> Unit,
) {
    val status by vm.streamStatus.collectAsState()
    NotifyRow(
        title = "实时通知（保持连接）",
        subtitle = "直连你的 MovieClaw 服务器，入库、下载等通知即时送达，不经过谷歌或厂商推送。" +
            "会常驻一条静音通知；断网重连后补发错过的通知。",
        checked = state.stream,
        onChange = { if (!state.streamBusy) onEnable(it) },
    )
    if (state.stream) {
        val (dot, text) = when (val s = status) {
            is PushStreamStatus.Connected -> Ok to "已连接"
            PushStreamStatus.Connecting -> Warn to "正在连接…"
            is PushStreamStatus.Retrying -> Warn to "未连接：${s.reason}，会自动重试"
            PushStreamStatus.Off -> Danger to "未运行，可能被系统清理了，请检查后台运行设置"
        }
        Column(
            Modifier
                .fillMaxWidth()
                .padding(vertical = 4.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(FillCard)
                .border(1.dp, LineSoft, RoundedCornerShape(12.dp))
                .padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(dot)
                Spacer(Modifier.width(8.dp))
                Text(text, style = McType.caption, color = TextPrimary)
            }
            state.streamMessage?.let {
                Spacer(Modifier.height(6.dp))
                Text(it, style = McType.caption, color = TextMuted)
            }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton(if (state.testing) "发送中…" else "发送测试通知", enabled = !state.testing, onClick = vm::sendTest)
                PillButton("后台运行设置", onClick = vm::openGuide)
            }
        }
        val snapshot by PushStreamState.snapshot.collectAsState()
        Spacer(Modifier.height(18.dp))
        OngoingSection(
            mode = state.ongoingMode,
            template = state.ongoingTemplate,
            // 预览按「已连接」画内容；连接状态看上面那张卡
            preview = OngoingNotice.build(state.ongoingMode, state.ongoingTemplate, PushStreamStatus.Connected(0), snapshot),
            onMode = { vm.setOngoing(mode = it) },
            onTemplate = { vm.setOngoing(template = it) },
        )
        EventPrefsSection(state = state, onToggle = vm::setEvent)
    } else {
        state.streamMessage?.let {
            Text(
                it,
                style = McType.caption,
                color = TextMuted,
                modifier = Modifier.padding(horizontal = 6.dp, vertical = 4.dp),
            )
        }
    }
}

/** 常驻通知显示：单选卡片 + 自定义文字（emoji、变量快捷）+ 实时预览 */
@Composable
internal fun OngoingSection(
    mode: OngoingMode,
    template: String,
    preview: OngoingView,
    onMode: (OngoingMode) -> Unit,
    onTemplate: (String) -> Unit,
) {
    var field by remember { mutableStateOf(TextFieldValue(template)) }
    fun insert(token: String) {
        val start = minOf(field.selection.start, field.selection.end)
        val end = maxOf(field.selection.start, field.selection.end)
        field = TextFieldValue(field.text.replaceRange(start, end, token), TextRange(start + token.length))
        onTemplate(field.text)
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(FillCard)
            .border(1.dp, LineSoft, RoundedCornerShape(18.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("常驻通知显示", style = McType.subheadlineSemibold, modifier = Modifier.padding(start = 2.dp, bottom = 4.dp))
        OngoingMode.entries.forEach { option ->
            OngoingOption(option, selected = option == mode, onClick = { onMode(option) }) {
                if (option != OngoingMode.CUSTOM) return@OngoingOption
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = field,
                    onValueChange = {
                        field = it
                        onTemplate(it.text)
                    },
                    singleLine = true,
                    placeholder = { Text(OngoingNotice.DEFAULT_TEMPLATE, style = McType.footnote, color = TextFaint) },
                    colors = settingsFieldColors(),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(10.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OngoingNotice.EMOJIS.forEach { emoji ->
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .size(40.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color.White.copy(alpha = 0.06f))
                                .clickable { insert(emoji) },
                        ) { Text(emoji, fontSize = 20.sp) }
                    }
                }
                Spacer(Modifier.height(8.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OngoingNotice.VARIABLES.forEach { variable ->
                        Text(
                            variable,
                            style = McType.caption,
                            color = TextMuted,
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(Color.White.copy(alpha = 0.06f))
                                .clickable { insert(variable) }
                                .padding(horizontal = 10.dp, vertical = 5.dp),
                        )
                    }
                }
            }
        }
    }
    Text(
        "效果预览",
        style = McType.caption,
        color = TextFaint,
        modifier = Modifier.padding(start = 6.dp, top = 14.dp, bottom = 6.dp),
    )
    OngoingPreview(preview)
}

@Composable
private fun OngoingOption(
    mode: OngoingMode,
    selected: Boolean,
    onClick: () -> Unit,
    extra: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(14.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Color.White.copy(alpha = if (selected) 0.06f else 0.03f))
            .border(if (selected) 1.5.dp else 1.dp, if (selected) TextPrimary.copy(alpha = 0.85f) else LineSoft, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(22.dp)
                .border(2.dp, if (selected) TextPrimary else TextFaint, CircleShape),
        ) {
            if (selected) Box(Modifier.size(10.dp).background(TextPrimary, CircleShape))
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(mode.title, style = McType.bodySemibold, color = TextPrimary)
                if (mode == OngoingMode.SMART) {
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "推荐",
                        style = McType.captionSemibold,
                        color = AccentStrong,
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(AccentSoft)
                            .padding(horizontal = 7.dp, vertical = 1.dp),
                    )
                }
            }
            Spacer(Modifier.height(2.dp))
            Text(mode.subtitle, style = McType.caption, color = TextMuted)
            extra()
        }
    }
}

/** 照着系统通知的样子画：图标、标题、正文、进度条、展开的列表、按钮 */
@Composable
private fun OngoingPreview(view: OngoingView) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(Color(0xFF1E1F23))
            .padding(14.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Color.Black),
        ) {
            Icon(
                painterResource(io.movieclaw.android.R.drawable.ic_mc_notify),
                contentDescription = null,
                tint = TextPrimary,
                modifier = Modifier.size(22.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.Top) {
                Text(view.title, style = McType.bodySemibold, color = TextPrimary, modifier = Modifier.weight(1f))
                Text("现在", style = McType.caption, color = TextFaint)
            }
            if (view.lines.isEmpty()) {
                Text(view.text, style = McType.caption, color = TextMuted)
            } else {
                view.lines.forEach { Text(it, style = McType.caption, color = TextMuted, modifier = Modifier.padding(top = 3.dp)) }
            }
            if (view.progress != null) {
                Spacer(Modifier.height(10.dp))
                if (view.indeterminate) {
                    LinearProgressIndicator(Modifier.fillMaxWidth(), color = Accent, trackColor = Color.White.copy(alpha = 0.1f))
                } else {
                    LinearProgressIndicator(
                        progress = { view.progress / 100f },
                        modifier = Modifier.fillMaxWidth(),
                        color = Accent,
                        trackColor = Color.White.copy(alpha = 0.1f),
                    )
                }
            }
            if (view.openDownloads) {
                Spacer(Modifier.height(10.dp))
                Text(
                    "打开下载",
                    style = McType.captionSemibold,
                    color = TextPrimary,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.08f))
                        .padding(horizontal = 14.dp, vertical = 7.dp),
                )
            }
        }
    }
}

/** 推送哪些事：服务器上按账号存的偏好，iOS、网页改了这里也一样 */
@Composable
private fun EventPrefsSection(state: NotifySettingsState, onToggle: (String, Boolean) -> Unit) {
    val events = state.events
    Spacer(Modifier.height(18.dp))
    Text("推送哪些事", style = McType.subheadlineSemibold, modifier = Modifier.padding(horizontal = 6.dp))
    Text(
        "按账号保存，与 iOS、网页共用同一份设置",
        style = McType.caption,
        color = TextMuted,
        modifier = Modifier.padding(start = 6.dp, end = 6.dp, top = 2.dp, bottom = 6.dp),
    )
    state.eventsError?.let {
        Text(it, style = McType.caption, color = Danger, modifier = Modifier.padding(horizontal = 6.dp, vertical = 4.dp))
    }
    if (events == null) {
        if (state.eventsError == null) {
            Text("正在读取…", style = McType.caption, color = TextFaint, modifier = Modifier.padding(horizontal = 6.dp))
        }
        return
    }
    events.groupBy { it.group }.forEach { (group, items) ->
        if (group.isNotBlank()) {
            Text(
                group,
                style = McType.caption,
                color = TextFaint,
                modifier = Modifier.padding(start = 6.dp, end = 6.dp, top = 10.dp, bottom = 2.dp),
            )
        }
        items.forEach { event ->
            NotifyRow(
                title = event.title,
                subtitle = event.description,
                checked = event.enabled,
                onChange = { onToggle(event.key, it) },
            )
        }
    }
}

@Composable
private fun PillButton(text: String, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .clip(CircleShape)
            .background(AccentSoft)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(text, style = McType.captionSemibold, color = if (enabled) AccentStrong else TextMuted)
    }
}

/** 后台运行引导：国产系统要手动放行，否则熄屏后连接会被断开 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BackgroundGuideSheet(onDismiss: () -> Unit) {
    val context = LocalContext.current
    var ignoring by remember { mutableStateOf(BackgroundGuide.ignoringBatteryOptimizations(context)) }
    // 从系统弹窗 / 设置页回来时刷新「已允许」
    androidx.lifecycle.compose.LifecycleResumeEffect(Unit) {
        ignoring = BackgroundGuide.ignoringBatteryOptimizations(context)
        onPauseOrDispose { }
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = GuideSheetSurface,
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .formSheetScroll().verticalScroll(rememberScrollState())
                .padding(start = 20.dp, end = 20.dp, bottom = 24.dp),
        ) {
            Text("保持通知在线", style = McType.title3)
            Spacer(Modifier.height(6.dp))
            Text(
                (if (BackgroundGuide.isVivo()) "vivo / iQOO" else "很多手机") + "会清理后台应用。放行下面几项，熄屏后也能及时收到通知。",
                style = McType.caption,
                color = TextMuted,
            )
            Spacer(Modifier.height(16.dp))
            BackgroundGuide.steps().forEachIndexed { index, step ->
                val done = step.action == BackgroundGuide.Action.BATTERY_OPTIMIZATION && ignoring
                GuideStepCard(
                    number = index + 1,
                    step = step,
                    done = done,
                    onAction = {
                        when (step.action) {
                            BackgroundGuide.Action.BATTERY_OPTIMIZATION -> BackgroundGuide.requestIgnoreBatteryOptimizations(context)
                            BackgroundGuide.Action.VENDOR_SETTINGS -> BackgroundGuide.openVendorBackgroundSettings(context)
                            BackgroundGuide.Action.APP_DETAILS -> BackgroundGuide.openAppDetails(context)
                            null -> Unit
                        }
                    },
                )
                Spacer(Modifier.height(10.dp))
            }
            Spacer(Modifier.height(10.dp))
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(AccentStrong)
                    .clickable(onClick = onDismiss),
            ) {
                Text("好了", style = McType.bodySemibold, color = Color.Black)
            }
        }
    }
}

private val GuideSheetSurface = Color(0xFF15161A)

@Composable
private fun GuideStepCard(
    number: Int,
    step: BackgroundGuide.Step,
    done: Boolean,
    onAction: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(FillCard)
            .border(1.dp, LineSoft, RoundedCornerShape(14.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .padding(top = 1.dp)
                .size(24.dp)
                .background(if (done) Ok.copy(alpha = 0.18f) else AccentSoft, CircleShape),
        ) {
            if (done) {
                Icon(Icons.Rounded.Check, contentDescription = "已完成", tint = Ok, modifier = Modifier.size(15.dp))
            } else {
                Text("$number", style = McType.captionSemibold, color = AccentStrong)
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(step.title, style = McType.bodySemibold, color = if (done) TextMuted else TextPrimary)
            Spacer(Modifier.height(3.dp))
            Text(
                if (done) "已允许" else step.detail,
                style = McType.caption,
                color = if (done) Ok else TextMuted,
            )
        }
        if (step.action != null && !done) {
            Spacer(Modifier.width(10.dp))
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(AccentSoft)
                    .clickable(onClick = onAction)
                    .padding(horizontal = 14.dp, vertical = 7.dp),
            ) {
                Text(
                    if (step.action == BackgroundGuide.Action.BATTERY_OPTIMIZATION) "允许" else "去设置",
                    style = McType.captionSemibold,
                    color = AccentStrong,
                )
            }
        }
    }
}

@Composable
private fun NotifyRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .border(1.dp, Color.White.copy(alpha = 0.06f), RoundedCornerShape(12.dp))
            .clickable { onChange(!checked) }
            .padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = McType.subheadline)
            Text(subtitle, style = McType.caption, color = TextFaint)
        }
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = Accent),
        )
    }
}

@Composable
private fun settingsFieldColors() = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
    focusedContainerColor = Color.White.copy(alpha = 0.055f),
    unfocusedContainerColor = Color.White.copy(alpha = 0.055f),
    focusedBorderColor = Accent.copy(alpha = 0.45f),
    unfocusedBorderColor = Color.White.copy(alpha = 0.1f),
    focusedTextColor = Color.White,
    unfocusedTextColor = Color.White,
    cursorColor = Accent,
)
