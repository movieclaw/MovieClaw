package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Accent2
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.FeedbackBus
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.SurfaceRaised
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.MemberCreateRequest
import io.movieclaw.android.core.model.MemberStatusRequest
import io.movieclaw.android.core.model.MemberUpdateRequest
import io.movieclaw.android.core.model.MemberView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

@HiltViewModel
class MembersViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val feedback: FeedbackBus,
) : ViewModel() {

    private val _state = MutableStateFlow<Loadable<List<MemberView>>>(Loadable.Loading)
    val state = _state.asStateFlow()

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _state.value = Loadable.Loading
            runCatching { apiFactory.forOrigin(origin).members().dataOrThrow() }
                .onSuccess { _state.value = Loadable.Ready(it) }
                .onFailure { e -> _state.value = Loadable.Failed(friendlyMessage(e)) }
        }
    }

    fun create(username: String, password: String, nickname: String) {
        if (_busy.value) return
        _busy.value = true
        viewModelScope.launch {
            val origin = origin
            if (origin == null) {
                _busy.value = false
                return@launch
            }
            runCatching {
                apiFactory.forOrigin(origin)
                    .createMember(MemberCreateRequest(username, password, nickname))
                    .dataOrThrow()
            }
                .onSuccess {
                    feedback.success("已创建成员「$username」")
                    load()
                }
                .onFailure { e -> feedback.error(friendlyMessage(e)) }
            _busy.value = false
        }
    }

    fun setStatus(member: MemberView, enabled: Boolean) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin)
                    .setMemberStatus(member.id, MemberStatusRequest(enabled))
                    .dataOrThrow()
            }
                .onSuccess {
                    feedback.success(if (enabled) "已启用「${member.nickname.ifEmpty { member.username }}」" else "已停用")
                    load()
                }
                .onFailure { e -> feedback.error(friendlyMessage(e)) }
        }
    }

    /** 权限开关:乐观更新 + 失败回滚 */
    fun setPermission(member: MemberView, patch: MemberUpdateRequest, optimistic: (MemberView) -> MemberView) {
        val current = (_state.value as? Loadable.Ready)?.value ?: return
        _state.value = Loadable.Ready(current.map { if (it.id == member.id) optimistic(it) else it })
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).updateMember(member.id, patch).dataOrThrow() }
                .onSuccess { updated ->
                    _state.value = Loadable.Ready(
                        current.map { if (it.id == member.id) updated else it },
                    )
                }
                .onFailure { e ->
                    _state.value = Loadable.Ready(current)
                    feedback.error(friendlyMessage(e))
                }
        }
    }

    fun resetPassword(member: MemberView, onResult: (String) -> Unit) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).resetMemberPassword(member.id).dataOrThrow() }
                .onSuccess { onResult(it.password) }
                .onFailure { e -> onResult("!${friendlyMessage(e)}") }
        }
    }

    fun signOut(member: MemberView) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).signOutMember(member.id).dataOrThrow() }
                .onSuccess {
                    feedback.success("已登出「${member.nickname.ifEmpty { member.username }}」的全部设备")
                    load()
                }
                .onFailure { e -> feedback.error(friendlyMessage(e)) }
        }
    }

    fun delete(member: MemberView) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).deleteMember(member.id).dataOrThrow() }
                .onSuccess {
                    feedback.success("已删除成员「${member.username}」")
                    load()
                }
                .onFailure { e -> feedback.error(friendlyMessage(e)) }
        }
    }
}

@Composable
fun MembersSettingsScreen(onBack: () -> Unit, vm: MembersViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    var creating by remember { mutableStateOf(false) }
    var newUsername by remember { mutableStateOf("") }
    var newPassword by remember { mutableStateOf("") }
    var newNickname by remember { mutableStateOf("") }
    var resetResult by remember { mutableStateOf<Pair<MemberView, String>?>(null) }
    var deleting by remember { mutableStateOf<MemberView?>(null) }

    Column(Modifier.fillMaxSize()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .height(McMetrics.topBarHeight)
                .padding(horizontal = McMetrics.topBarInsetSub),
        ) {
            // 返回键用全站那枚玻璃圆钮（同 McTopBar(Sub) 的行首）：各页返回按钮长得一样
            McNavButton(
                icon = Icons.AutoMirrored.Rounded.ArrowBack,
                contentDescription = "返回",
                onClick = onBack,
            )
            Spacer(Modifier.width(4.dp))
            Text("家庭成员", style = McType.title3, color = TextPrimary, modifier = Modifier.weight(1f))
            TextButton(onClick = { creating = true }) {
                Icon(Icons.Rounded.Add, contentDescription = null, tint = Accent, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("新建", style = McType.subheadline, color = Accent)
            }
        }

        when (val s = state) {
            Loadable.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            is Loadable.Failed -> ErrorPane(message = s.message, onRetry = vm::load)
            is Loadable.Ready -> LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(s.value, key = { it.id }) { member ->
                    MemberCard(
                        member = member,
                        onToggleStatus = { enabled -> vm.setStatus(member, enabled) },
                        onTogglePermission = { patch, optimistic -> vm.setPermission(member, patch, optimistic) },
                        onReset = { vm.resetPassword(member) { pwd -> resetResult = member to pwd } },
                        onSignOut = { vm.signOut(member) },
                        onDelete = { deleting = member },
                    )
                }
                item {
                    Text(
                        "媒体库可见范围与站点白名单请在网页端「设置 → 家庭成员」里配置;" +
                            "这里可以管权限开关、重置密码、踢下线。",
                        style = McType.caption2,
                        color = TextFaint,
                        lineHeight = 17.sp,
                    )
                }
            }
        }
    }

    if (creating) {
        AlertDialog(
            onDismissRequest = { creating = false },
            title = { Text("新建成员") },
            text = {
                Column {
                    OutlinedTextField(
                        value = newUsername,
                        onValueChange = { newUsername = it },
                        singleLine = true,
                        placeholder = { Text("登录名(至少 3 位,创建后不可改)", style = McType.caption, color = TextFaint) },
                        colors = settingsFieldColors(),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = newPassword,
                        onValueChange = { newPassword = it },
                        singleLine = true,
                        placeholder = { Text("初始密码(至少 8 位)", style = McType.caption, color = TextFaint) },
                        visualTransformation = PasswordVisualTransformation(),
                        colors = settingsFieldColors(),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = newNickname,
                        onValueChange = { newNickname = it },
                        singleLine = true,
                        placeholder = { Text("昵称(可留空)", style = McType.caption, color = TextFaint) },
                        colors = settingsFieldColors(),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        vm.create(newUsername.trim(), newPassword, newNickname.trim())
                        creating = false
                        newUsername = ""
                        newPassword = ""
                        newNickname = ""
                    },
                    enabled = newUsername.trim().length >= 3 && newPassword.length >= 8,
                ) { Text("创建", color = Accent) }
            },
            dismissButton = { TextButton(onClick = { creating = false }) { Text("取消") } },
        )
    }

    resetResult?.let { (member, password) ->
        AlertDialog(
            onDismissRequest = { resetResult = null },
            title = { Text("新的密码") },
            text = {
                Column {
                    if (password.startsWith("!")) {
                        Text(password.removePrefix("!"), style = McType.footnote, color = Danger)
                    } else {
                        Text(
                            "「${member.nickname.ifEmpty { member.username }}」的新密码如下,**只显示这一次**,请立刻转告本人:",
                            style = McType.footnote,
                            lineHeight = 20.sp,
                        )
                        Spacer(Modifier.height(10.dp))
                        Text(
                            password,
                            style = McType.title3.copy(fontWeight = FontWeight.Bold),
                            color = AccentStrong,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(Color.White.copy(alpha = 0.06f))
                                .padding(12.dp),
                        )
                    }
                }
            },
            confirmButton = { TextButton(onClick = { resetResult = null }) { Text("知道了", color = Accent) } },
        )
    }

    deleting?.let { member ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("删除成员「${member.username}」?") },
            text = { Text("账号与它的观看记录会一并删除,此操作不可恢复。", style = McType.footnote, lineHeight = 20.sp) },
            confirmButton = {
                TextButton(onClick = {
                    vm.delete(member)
                    deleting = null
                }) { Text("删除", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } },
        )
    }
}

@Composable
private fun MemberCard(
    member: MemberView,
    onToggleStatus: (Boolean) -> Unit,
    onTogglePermission: (MemberUpdateRequest, (MemberView) -> MemberView) -> Unit,
    onReset: () -> Unit,
    onSignOut: () -> Unit,
    onDelete: () -> Unit,
) {
    val enabled = member.status == "active"
    GlassCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(Brush.verticalGradient(listOf(AccentStrong, Accent2))),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    (member.nickname.ifEmpty { member.username }).take(1).uppercase(),
                    style = McType.subheadlineSemibold,
                    color = Color(0xFF0A0E12),
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        member.nickname.ifEmpty { member.username },
                        style = McType.subheadlineSemibold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (!enabled) {
                        Spacer(Modifier.width(6.dp))
                        Text("已停用", style = McType.caption2, color = Warning)
                    }
                }
                Text("@${member.username}", style = McType.caption, color = TextMuted)
                Text(
                    buildString {
                        append(if (member.lastLoginAt == null) "从未登录" else "最近登录 ${member.lastLoginAt.take(16).replace('T', ' ')}")
                        if (member.deviceCount > 0) append(" · ${member.deviceCount} 台设备")
                        append(if (member.allLibraries) " · 全部媒体库" else " · 指定媒体库")
                    },
                    style = McType.caption2,
                    color = TextFaint,
                )
            }
            Switch(
                checked = enabled,
                onCheckedChange = onToggleStatus,
                colors = SwitchDefaults.colors(checkedTrackColor = Accent),
            )
        }

        Spacer(Modifier.height(12.dp))
        PermissionRow("允许订阅与追更", "发起订阅并管理自己的订阅", member.allowSubscribe) { next ->
            onTogglePermission(MemberUpdateRequest(allowSubscribe = next)) { it.copy(allowSubscribe = next) }
        }
        // 「站点搜索」已更名「资源搜索」（member-permissions-v2）：搜影视、搜媒体库不受这个开关限制
        PermissionRow(
            "允许资源搜索",
            "在被分配的 PT 站点里搜索种子资源（媒体库内搜索不受此开关影响）",
            member.allowSearch,
        ) { next ->
            // 关掉资源搜索时一键下载必须跟着关（它依赖前者，服务端也按同一口径校验）
            if (!next) {
                onTogglePermission(
                    MemberUpdateRequest(allowSearch = false, allowDirectDownload = false),
                ) { it.copy(allowSearch = false, allowDirectDownload = false) }
            } else {
                onTogglePermission(MemberUpdateRequest(allowSearch = true)) { it.copy(allowSearch = true) }
            }
        }
        PermissionRow(
            "允许一键下载",
            "从搜索结果直接提交下载、给自己的订阅手动选种，依赖资源搜索",
            member.allowDirectDownload,
            enabled = member.allowSearch,
        ) { next ->
            onTogglePermission(MemberUpdateRequest(allowDirectDownload = next)) { it.copy(allowDirectDownload = next) }
        }

        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = onReset) { Text("重置密码", style = McType.caption, color = Accent) }
            TextButton(onClick = onSignOut) { Text("登出全部设备", style = McType.caption, color = Warning) }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onDelete) { Text("删除", style = McType.caption, color = Danger) }
        }
    }
}

@Composable
private fun PermissionRow(
    label: String,
    subtitle: String,
    checked: Boolean,
    enabled: Boolean = true,
    onChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                label,
                style = McType.footnote,
                color = if (enabled) TextMuted else TextFaint,
            )
            Text(subtitle, style = McType.caption2, color = TextFaint, lineHeight = 15.sp)
        }
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            enabled = enabled,
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
