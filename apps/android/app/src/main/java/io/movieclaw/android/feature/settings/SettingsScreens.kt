package io.movieclaw.android.feature.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.border
import androidx.compose.material.icons.rounded.SwitchAccount
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Badge
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.OpenInNew
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
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
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.FlatRow
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.SurfaceRaised
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.ChangePasswordRequest
import io.movieclaw.android.core.model.DeviceRenameRequest
import io.movieclaw.android.core.model.LoginDevice
import io.movieclaw.android.core.model.PlaybackPolicy
import io.movieclaw.android.core.model.PlaybackPolicyPatchFull
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.model.UpdateProfileRequest
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import java.io.File
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody.Companion.asRequestBody

/* ---------------- 设置索引 ---------------- */

enum class SettingsSection(
    val label: String,
    val subtitle: String,
    val group: String,
    /**
     * 成员可见的分区。同 Web `MEMBER_SECTION_IDS`（profile / devices / appearance）与
     * iOS `memberVisible`（profile / devices）：成员只剩「个人信息」与自己的设备，
     * 其余分区后端一律 403，前端不给入口（安全边界仍在后端）。
     */
    val memberVisible: Boolean = false,
) {
    PROFILE("个人信息", "昵称、头像、登录密码", "账号", memberVisible = true),
    NOTIFY("通知", "下载完成、入库、今天有更新时在本机提醒", "账号", memberVisible = true),
    DEVICES("设备管理", "已登录的客户端与播放器,可改名或注销", "账号", memberVisible = true),
    MEMBERS("家庭成员", "成员权限、媒体库可见范围、重置密码", "账号"),
    PLAYBACK("播放", "软件转码、进度预览、转码缓存", "播放与内容"),
    SUBSCRIPTION_WEB("订阅与追更", "在网页端管理订阅规则与规则集", "播放与内容"),
    SITES_WEB("站点与索引器", "在网页端管理站点与登录态", "播放与内容"),
    DOWNLOADERS_WEB("下载器", "在网页端管理下载器与限速", "播放与内容"),
    IMPORT_WATCH_WEB("导入与观看记录", "在网页端管理导入监听与记录导入", "播放与内容"),
    OVERVIEW_WEB("总览", "服务器概况与体检", "服务器"),
    /** 模型供应商接入（iOS `.settingsSection(.llm)`「模型接入」）：AI 字幕生成等能力的落点 */
    LLM("模型接入", "接入 OpenAI、百炼等模型供应商，可同时接入多家", "服务器"),
    MAINTENANCE("更新与维护", "服务器更新、存储清理、重启", "服务器"),
    NETWORK("网络", "服务器网络配置与连通性测试", "服务器"),
    LOGS("日志", "服务器运行日志", "服务器"),
}

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val repository: SessionRepository,
) : ViewModel() {
    val origin: String? get() = repository.ui.value.origin

    fun visibleSections(): List<SettingsSection> {
        val permissions = io.movieclaw.android.core.session.Permissions.of(repository.ui.value.session)
        return SettingsSection.entries.filter { permissions.isAdmin || it.memberVisible }
    }

    /** 分区的直链守卫：成员深链到超管分区不给开（同 Web `accessiblePathFor`） */
    fun canOpen(section: SettingsSection): Boolean =
        io.movieclaw.android.core.session.Permissions.of(repository.ui.value.session)
            .let { it.isAdmin || section.memberVisible }
}

@Composable
fun SettingsIndexScreen(
    onBack: () -> Unit,
    onOpen: (SettingsSection) -> Unit,
    vm: SettingsViewModel = hiltViewModel(),
) {
    val sections = vm.visibleSections()
    Box(Modifier.fillMaxSize().background(Bg)) {
        LazyColumn(
            contentPadding = PaddingValues(
                top = McMetrics.topBarHeight,
                bottom = 24.dp,
            ),
            modifier = Modifier.fillMaxSize().statusBarsPadding(),
        ) {
            sections.groupBy { it.group }.forEach { (group, items) ->
                item(key = "h-$group") {
                    Text(
                        group,
                        style = McType.groupLabel,
                        color = TextFaint,
                        modifier = Modifier.padding(start = McMetrics.pagePadding, end = McMetrics.pagePadding, top = 24.dp, bottom = 6.dp),
                    )
                }
                items(items, key = { it.name }) { section ->
                    SettingsIndexRow(section = section, onClick = { onOpen(section) })
                }
            }
        }
        McTopBar(
            variant = McTopBarVariant.Sub,
            title = "服务器设置",
            onBack = onBack,
            modifier = Modifier.align(Alignment.TopCenter),
        )
    }
}

/**
 * 设置索引行 —— 实测：**没有卡片**，45 高、圆角 14 的透明行直接落在黑底上（hover 才出
 * 7.5% 白底）；行首 30×30 图标位（白 4%），文字 16/500 且是 62% 白，行尾雪佛龙 15。
 */
@Composable
private fun SettingsIndexRow(section: SettingsSection, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = McMetrics.pagePadding)
            .height(45.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp),
    ) {
        Box(
            Modifier
                .size(30.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(Color.White.copy(alpha = 0.04f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(sectionIcon(section), contentDescription = null, tint = TextPrimary, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(12.dp))
        Text(
            section.label,
            style = McType.bodyMedium,
            color = TextMuted,
            maxLines = 1,
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

private fun sectionIcon(section: SettingsSection) = when (section) {
    SettingsSection.PROFILE -> Icons.Rounded.Person
    SettingsSection.NOTIFY -> Icons.Rounded.Notifications
    SettingsSection.DEVICES -> Icons.Rounded.Devices
    SettingsSection.MEMBERS -> Icons.Rounded.Badge
    SettingsSection.PLAYBACK -> Icons.Rounded.PlayCircle
    // 模型接入用的是 iOS 的 sparkles（`.llm` 分区图标）——不是网页分区那个「外链」图标
    SettingsSection.LLM -> Icons.Rounded.AutoAwesome
    SettingsSection.MAINTENANCE -> Icons.Rounded.Storage
    SettingsSection.NETWORK -> Icons.Rounded.Language
    SettingsSection.LOGS -> Icons.Rounded.Tune
    else -> Icons.Rounded.OpenInNew
}

/** 子页顶栏（实测：返回钮 36×36 在 x=8，标题 20/600 在 x=48，雾层向下渐隐到 76） */
@Composable
internal fun SettingsTopBar(title: String, onBack: () -> Unit, actions: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = {}) {
    McTopBar(
        variant = McTopBarVariant.Sub,
        title = title,
        onBack = onBack,
        actions = actions,
    )
}

/** 网页托管分区:iOS 同款「说明 + 在浏览器中打开」 */
@Composable
fun WebManagedSectionScreen(section: SettingsSection, onBack: () -> Unit, vm: SettingsViewModel = hiltViewModel()) {
    val context = LocalContext.current
    val origin = vm.origin
    Column(Modifier.fillMaxSize()) {
        SettingsTopBar(title = section.label, onBack = onBack)
        Column(Modifier.padding(16.dp)) {
            GlassCard(Modifier.fillMaxWidth()) {
                Text("这一项在网页端管理", style = McType.subheadlineSemibold)
                Spacer(Modifier.height(6.dp))
                Text(
                    "「${section.label}」涉及表格、拖拽排序等复杂交互,请在网页端的「设置 → ${section.label}」里完成。",
                    style = McType.footnote,
                    color = TextMuted,
                    lineHeight = 20.sp,
                )
                Spacer(Modifier.height(12.dp))
                TextButton(onClick = {
                    origin?.let { base ->
                        runCatching {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("$base/settings")))
                        }
                    }
                }) {
                    Icon(Icons.Rounded.OpenInNew, contentDescription = null, tint = Accent, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("在浏览器中打开", style = McType.subheadlineSemibold, color = Accent)
                }
            }
        }
    }
}

/* ---------------- 个人资料 ---------------- */

@HiltViewModel
class ProfileSettingsViewModel @Inject constructor(
    @dagger.hilt.android.qualifiers.ApplicationContext private val appContext: Context,
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {
    /** 订阅式的会话仓库状态（换头像后 revalidate 写回，页面跟着重组——getter 版不订阅，页面永远不刷新） */
    val ui = repository.ui
    val origin: String? get() = repository.ui.value.origin

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    /** 退出登录（只退当前账号；同 iOS 把它放在个人信息页底部） */
    fun logout() {
        viewModelScope.launch { repository.logout() }
    }

    fun updateNickname(nickname: String, onDone: () -> Unit) {
        if (_busy.value) return
        _busy.value = true
        viewModelScope.launch {
            val origin = origin
            if (origin == null) {
                _busy.value = false
                return@launch
            }
            runCatching {
                apiFactory.forOrigin(origin).updateProfile(UpdateProfileRequest(nickname)).dataOrThrow()
            }
                .onSuccess {
                    repository.revalidate(origin)
                    onDone()
                }
                .onFailure { }
            _busy.value = false
        }
    }

    /** 改密后除本机外的会话会被服务端作废(sign_out_paired 时连配对设备一起) */
    fun changePassword(oldPassword: String, newPassword: String, signOutPaired: Boolean, onDone: (String) -> Unit) {
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
                    .changePassword(ChangePasswordRequest(oldPassword, newPassword, signOutPaired))
                    .dataOrThrow()
            }
                .onSuccess { onDone("密码已更新") }
                .onFailure { e -> onDone(friendlyMessage(e)) }
            _busy.value = false
        }
    }

    fun uploadAvatar(uri: Uri, onDone: (String) -> Unit) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val bytes = withContext(Dispatchers.IO) {
                runCatching { appContext.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
            } ?: return@launch
            val file = File(appContext.cacheDir, "avatar_${System.currentTimeMillis()}.jpg")
            withContext(Dispatchers.IO) { runCatching { file.writeBytes(bytes) } }
            runCatching {
                val part = MultipartBody.Part.createFormData("file", file.name, file.asRequestBody("image/jpeg".toMediaType()))
                apiFactory.forOrigin(origin).uploadAvatar(part)
            }
                .onSuccess {
                    repository.revalidate(origin)
                    onDone("头像已更新")
                }
                .onFailure { e -> onDone(friendlyMessage(e)) }
        }
    }

}

@Composable
fun ProfileSettingsScreen(
    onBack: () -> Unit,
    /** 「切换账号」：跳账号切换页（同 iOS：这一对动作放在个人信息页最底部，不在「我的」页） */
    onOpenAccounts: () -> Unit = {},
    vm: ProfileSettingsViewModel = hiltViewModel(),
) {
    val uiState by vm.ui.collectAsStateWithLifecycle()
    val session = uiState.session
    val context = LocalContext.current
    var nickname by remember(session?.nickname) { mutableStateOf(session?.nickname ?: "") }
    var oldPassword by remember { mutableStateOf("") }
    var newPassword by remember { mutableStateOf("") }
    var signOutPaired by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    val busy by vm.busy.collectAsStateWithLifecycle()

    val pickAvatar = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let { vm.uploadAvatar(it) { msg -> status = msg } }
    }

    Column(Modifier.fillMaxSize()) {
        SettingsTopBar(title = "个人信息", onBack = onBack)
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(64.dp).clip(RoundedCornerShape(999.dp))) {
                    RemoteImage(
                        // 保留 `?v=`：服务端在 avatar_url 里带版本参数专门破缓存，
                        // 剥掉它换头像后 Coil 会一直用同一 URL 的旧缓存（实机反馈「提示已更新但不换」）
                        url = session?.avatarUrl,
                        origin = vm.origin,
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(session?.nickname ?: "", style = McType.subheadlineSemibold)
                    Text(
                        "@${session?.username.orEmpty()} · ${if (session?.role == "admin") "超级管理员" else "成员"}",
                        style = McType.caption,
                        color = TextMuted,
                    )
                }
                TextButton(onClick = {
                    pickAvatar.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }) { Text("换头像", style = McType.caption, color = Accent) }
            }

            Spacer(Modifier.height(20.dp))
            Text("昵称", style = McType.caption, color = TextFaint)
            Spacer(Modifier.height(6.dp))
            OutlinedTextField(
                value = nickname,
                onValueChange = { nickname = it },
                singleLine = true,
                colors = settingsFieldColors(),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            SettingsPrimaryButton(
                text = if (busy) "保存中…" else "保存昵称",
                enabled = !busy && nickname.isNotBlank() && nickname != session?.nickname,
            ) { vm.updateNickname(nickname) { status = "昵称已更新" } }

            Spacer(Modifier.height(26.dp))
            Text("修改密码", style = McType.title3)
            Spacer(Modifier.height(4.dp))
            Text("改密后其他设备需要重新登录;至少 8 位。", style = McType.caption, color = TextFaint)
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(
                value = oldPassword,
                onValueChange = { oldPassword = it },
                singleLine = true,
                placeholder = { Text("当前密码", style = McType.footnote, color = TextFaint) },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                colors = settingsFieldColors(),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = newPassword,
                onValueChange = { newPassword = it },
                singleLine = true,
                placeholder = { Text("新密码(至少 8 位)", style = McType.footnote, color = TextFaint) },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                colors = settingsFieldColors(),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(
                    checked = signOutPaired,
                    onCheckedChange = { signOutPaired = it },
                    colors = SwitchDefaults.colors(checkedTrackColor = Accent),
                )
                Spacer(Modifier.width(10.dp))
                Column {
                    Text("同时下线配对设备", style = McType.subheadline)
                    Text("命令行与转码 worker 的令牌也会失效", style = McType.caption, color = TextFaint)
                }
            }
            Spacer(Modifier.height(8.dp))
            SettingsPrimaryButton(
                text = if (busy) "提交中…" else "更新密码",
                enabled = !busy && oldPassword.isNotBlank() && newPassword.length >= 8,
            ) { vm.changePassword(oldPassword, newPassword, signOutPaired) { msg ->
                status = msg
                if (msg == "密码已更新") {
                    oldPassword = ""
                    newPassword = ""
                }
            } }

            status?.let {
                Spacer(Modifier.height(14.dp))
                Text(it, style = McType.footnote, color = if (it.contains("已")) Success else Danger)
            }

            // ── 切换账号（同 iOS：账户详情页最底部，看得见的兜底入口）──
            Spacer(Modifier.height(26.dp))
            Spacer(Modifier.height(1.dp).fillMaxWidth().background(LineSoft))
            Spacer(Modifier.height(10.dp))
            FlatRow(
                title = "切换账号",
                icon = Icons.Rounded.SwitchAccount,
                onClick = onOpenAccounts,
            )
            Spacer(Modifier.height(10.dp))

            // ── 退出登录（单独一组、红色居中，同 iOS 设置 App 账户页最底部）──
            Spacer(Modifier.height(16.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color.White.copy(alpha = 0.05f))
                    .border(1.dp, LineSoft, RoundedCornerShape(14.dp))
                    .clickable { vm.logout() }
                    .padding(vertical = 14.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("退出登录", style = McType.bodyMedium, color = Danger)
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}

@Composable
private fun settingsFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedContainerColor = Color.White.copy(alpha = 0.055f),
    unfocusedContainerColor = Color.White.copy(alpha = 0.055f),
    focusedBorderColor = Accent.copy(alpha = 0.45f),
    unfocusedBorderColor = Color.White.copy(alpha = 0.1f),
    focusedTextColor = Color.White,
    unfocusedTextColor = Color.White,
    cursorColor = Accent,
)

@Composable
private fun SettingsPrimaryButton(text: String, enabled: Boolean, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = AccentStrong,
            contentColor = Color(0xFF0A0E12),
            disabledContainerColor = Color.White.copy(alpha = 0.08f),
            disabledContentColor = TextMuted,
        ),
        modifier = Modifier.fillMaxWidth().height(44.dp),
    ) {
        Text(text, style = McType.subheadlineSemibold)
    }
}

/* ---------------- 设备管理 ---------------- */

@HiltViewModel
class DevicesSettingsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {

    private val _state = MutableStateFlow<Loadable<List<LoginDevice>>>(Loadable.Loading)
    val state = _state.asStateFlow()

    private val _all = MutableStateFlow(false)
    val all = _all.asStateFlow()

    val origin: String? get() = repository.ui.value.origin
    val isAdmin: Boolean get() = repository.ui.value.session?.role == "admin"

    init {
        load()
    }

    fun setAll(value: Boolean) {
        _all.value = value
        load()
    }

    /** 清理长期没用的设备：真跑（服务端自己挑出超 days 天没用的，当前这台永远不清） */
    /**
     * 清理的两段式（iOS `DeviceCleanupSheet` 同款）：先 dry-run 列出「将注销」的名单
     * 让人看清，再真注销。服务端永远不清当前这台与连着的转码器。
     */
    fun cleanupPreview(
        days: Int,
        onResult: (List<io.movieclaw.android.core.model.DeviceCleanupItem>?) -> Unit,
    ) {
        viewModelScope.launch {
            val origin = origin ?: return@launch onResult(null)
            val body = io.movieclaw.android.core.model.DeviceCleanupRequest(
                inactiveDays = days,
                all = _all.value,
                dryRun = true,
            )
            runCatching { apiFactory.forOrigin(origin).cleanupDevices(body).dataOrThrow() }
                .onSuccess { onResult(it.devices) }
                .onFailure { onResult(null) }
        }
    }

    /** 真跑清理：成功给注销台数；失败给错误提示 */
    fun cleanup(days: Int, onDone: (Int?, String?) -> Unit) {
        viewModelScope.launch {
            val origin = origin ?: return@launch onDone(null, "还没有连上服务器")
            val body = io.movieclaw.android.core.model.DeviceCleanupRequest(
                inactiveDays = days,
                all = _all.value,
            )
            runCatching { apiFactory.forOrigin(origin).cleanupDevices(body).dataOrThrow() }
                .onSuccess {
                    load()
                    onDone(it.devices.size, null)
                }
                .onFailure { e -> onDone(null, friendlyMessage(e)) }
        }
    }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _state.value = Loadable.Loading
            runCatching { apiFactory.forOrigin(origin).devices(_all.value.takeIf { it }).dataOrThrow() }
                .onSuccess { _state.value = Loadable.Ready(it) }
                .onFailure { e -> _state.value = Loadable.Failed(friendlyMessage(e)) }
        }
    }

    fun rename(device: LoginDevice, name: String, onDone: (String) -> Unit) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).renameDevice(device.id, DeviceRenameRequest(name)) }
                .onSuccess {
                    onDone("已改名")
                    load()
                }
                .onFailure { e -> onDone(friendlyMessage(e)) }
        }
    }

    fun revoke(device: LoginDevice, onDone: (String) -> Unit) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).revokeDevice(device.id).dataOrThrow() }
                .onSuccess {
                    onDone("已注销「${device.name}」")
                    load()
                }
                .onFailure { e -> onDone(friendlyMessage(e)) }
        }
    }
}

@Composable
fun DevicesSettingsScreen(
    onBack: () -> Unit,
    /** v0.31 /activate：批准设备登录（配对码） */
    onOpenActivate: () -> Unit = {},
    vm: DevicesSettingsViewModel = hiltViewModel(),
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val all by vm.all.collectAsStateWithLifecycle()
    var renaming by remember { mutableStateOf<LoginDevice?>(null) }
    var revoking by remember { mutableStateOf<LoginDevice?>(null) }
    var nameDraft by remember { mutableStateOf("") }
    var cleanupOpen by remember { mutableStateOf(false) }
    val feedback = LocalFeedback.current

    Column(Modifier.fillMaxSize()) {
        SettingsTopBar(title = "设备管理", onBack = onBack) { }
        // 批准设备登录入口（Apple TV / 转码器在别的设备上显示配对码，拿这里批准）
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color.White.copy(alpha = 0.04f))
                .border(1.dp, LineColor, RoundedCornerShape(12.dp))
                .clickable(onClick = onOpenActivate)
                .padding(horizontal = 14.dp, vertical = 11.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text("批准设备登录", style = McType.subheadline)
                Text("输入设备上的配对码，批准或拒绝接入", style = McType.caption, color = TextFaint)
            }
            Icon(
                Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                contentDescription = null,
                tint = TextFaint,
                modifier = Modifier.size(16.dp),
            )
        }
        if (vm.isAdmin) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    Text("显示所有成员的设备", style = McType.subheadline)
                    Text("默认只看自己的登录设备与播放器", style = McType.caption, color = TextFaint)
                }
                Switch(
                    checked = all,
                    onCheckedChange = vm::setAll,
                    colors = SwitchDefaults.colors(checkedTrackColor = Accent),
                )
            }
        }
        when (val s = state) {
            Loadable.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            is Loadable.Failed -> ErrorPane(message = s.message, onRetry = vm::load)
            is Loadable.Ready -> LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(s.value, key = { it.id }) { device ->
                    DeviceCard(
                        device = device,
                        showOwner = all,
                        onRename = {
                            renaming = device
                            nameDraft = device.name
                        },
                        onRevoke = { revoking = device },
                    )
                }
                // 「清理长期没用的设备」入口（iOS `devices-cleanup-entry`）：除本机之外还有设备才有意义；
                // 超管开着「全部成员」时口径跟着变
                if (s.value.any { !it.current }) {
                    item(key = "cleanup-entry") {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color.White.copy(alpha = 0.04f))
                                .border(1.dp, LineColor, RoundedCornerShape(12.dp))
                                .clickable { cleanupOpen = true }
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                        ) {
                            Icon(
                                Icons.Rounded.AutoAwesome, contentDescription = null,
                                tint = Accent, modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(10.dp))
                            Text(
                                if (all) "清理全部成员长期没用的设备" else "清理长期没用的设备",
                                style = McType.subheadline, color = TextPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            Icon(
                                Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null,
                                tint = TextFaint, modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }
            }
        }
    }

    renaming?.let { device ->
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("重命名设备") },
            text = {
                OutlinedTextField(
                    value = nameDraft,
                    onValueChange = { nameDraft = it },
                    singleLine = true,
                    colors = settingsFieldColors(),
                    shape = RoundedCornerShape(10.dp),
                )
            },
            confirmButton = {
                TextButton(onClick = { vm.rename(device, nameDraft) { _ -> renaming = null } }) { Text("保存", color = Accent) }
            },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("取消") } },
        )
    }

    revoking?.let { device ->
        AlertDialog(
            onDismissRequest = { revoking = null },
            title = { Text("注销「${device.name}」?") },
            text = {
                Text(
                    "该设备的令牌会立刻失效,它需要重新登录才能继续使用。",
                    style = McType.footnote,
                    lineHeight = 20.sp,
                )
            },
            confirmButton = {
                TextButton(onClick = { vm.revoke(device) { _ -> }; revoking = null }) { Text("注销", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { revoking = null }) { Text("取消") } },
        )
    }

    if (cleanupOpen) {
        DeviceCleanupSheet(
            showAll = all,
            onPreview = { days, cb -> vm.cleanupPreview(days, cb) },
            onConfirm = { days, done ->
                vm.cleanup(days) { count, error ->
                    if (count != null) feedback.success("已注销 $count 台设备")
                    done(count != null, error)
                }
            },
            onDismiss = { cleanupOpen = false },
        )
    }
}

/**
 * 清理长期没用的设备（iOS `DeviceCleanupSheet` 的对应物）：7 / 30 / 90 天三档 →
 * **先让服务端 dry-run 列出「将注销 N 台」的名单**（看清了再一次注销）→「注销 N 台」。
 * 脚注写明「正在用的这台、连着的转码器不会被清理」——这是人按下按钮前真正想知道的。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun DeviceCleanupSheet(
    showAll: Boolean,
    onPreview: (Int, (List<io.movieclaw.android.core.model.DeviceCleanupItem>?) -> Unit) -> Unit,
    onConfirm: (Int, (Boolean, String?) -> Unit) -> Unit,
    onDismiss: () -> Unit,
) {
    var days by remember { mutableStateOf(90) }
    var items by remember { mutableStateOf<List<io.movieclaw.android.core.model.DeviceCleanupItem>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // 换天数就重新 dry-run：名单永远与当前档位一致（拉失败就给错误提示，别卡在「正在统计…」）
    LaunchedEffect(days) {
        items = null
        onPreview(days) { result ->
            if (result == null) error = "读取失败，请稍后再试" else items = result
        }
    }
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = Color.White,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            Text("清理设备", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(12.dp))
            Text("多久没用过", style = McType.caption, color = TextFaint)
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(7, 30, 90).forEach { option ->
                    val on = days == option
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .background(if (on) Color.White.copy(alpha = 0.18f) else Color.White.copy(alpha = 0.06f))
                            .border(
                                1.dp,
                                if (on) Color.White.copy(alpha = 0.4f) else Color.White.copy(alpha = 0.12f),
                                RoundedCornerShape(999.dp),
                            )
                            .clickable { days = option }
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                    ) {
                        Text("$option 天", style = McType.sub, color = if (on) TextPrimary else TextMuted)
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
            Text(
                if (showAll) {
                    "清理全部成员的设备。被注销的要重新登录或配对才能再用；正在用的这台、连着的转码器不会被清理。"
                } else {
                    "被注销的要重新登录或配对才能再用；正在用的这台、连着的转码器不会被清理。"
                },
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )
            Spacer(Modifier.height(14.dp))
            when {
                error != null -> Text(error!!, style = McType.footnote, color = Danger, lineHeight = 19.sp)
                items == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text("正在统计…", style = McType.footnote, color = TextMuted)
                }
                items!!.isEmpty() -> Text("没有超过 $days 天没用过的设备", style = McType.footnote, color = TextMuted)
                else -> Column(Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
                    Text("将注销 ${items!!.size} 台", style = McType.caption, color = TextFaint)
                    Spacer(Modifier.height(6.dp))
                    items!!.forEach { item ->
                        Text(
                            if (showAll && item.ownerNickname.isNotBlank()) "${item.name} · ${item.ownerNickname}" else item.name,
                            style = McType.footnote, color = TextPrimary,
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(vertical = 3.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
            val count = items?.size ?: 0
            val enabled = count > 0 && !busy
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(46.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (enabled) Danger else Color.White.copy(alpha = 0.08f))
                    .clickable(enabled = enabled) {
                        busy = true
                        error = null
                        onConfirm(days) { ok, message ->
                            busy = false
                            if (ok) onDismiss() else error = message ?: "清理失败，请稍后再试"
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    when {
                        busy -> "正在注销…"
                        count > 0 -> "注销 $count 台"
                        else -> "注销"
                    },
                    style = McType.bodySemibold,
                    color = if (enabled) Color.White else TextMuted,
                )
            }
        }
    }
}

@Composable
private fun DeviceCard(
    device: LoginDevice,
    showOwner: Boolean,
    onRename: () -> Unit,
    onRevoke: () -> Unit,
) {
    GlassCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        device.name.ifEmpty { device.kindLabel },
                        style = McType.subheadlineSemibold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (device.current) {
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "当前",
                            style = McType.caption2Semibold,
                            color = Accent,
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .background(AccentSoft)
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                    if (device.scope == "transcode") {
                        Spacer(Modifier.width(6.dp))
                        Text("转码专用", style = McType.caption2, color = Info)
                    }
                }
                Spacer(Modifier.height(3.dp))
                Text(
                    listOfNotNull(
                        device.kindLabel,
                        device.platform,
                        device.clientVersion,
                        if (device.connected) "在线" else null,
                        if (showOwner) device.ownerNickname.ifEmpty { device.ownerUsername } else null,
                    ).joinToString(" · "),
                    style = McType.caption,
                    color = TextMuted,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    "最近使用 ${McFormat.relative(device.lastSeenAt).ifEmpty { "—" }}" +
                        if (McFormat.isLive(device.lastSeenAt)) "(活跃)" else "",
                    style = McType.caption,
                    color = TextFaint,
                )
            }
            if (device.renamable) {
                TextButton(onClick = onRename) { Text("改名", style = McType.caption, color = Accent) }
            }
            if (!device.current) {
                IconButton(onClick = onRevoke) {
                    Icon(Icons.AutoMirrored.Rounded.Logout, contentDescription = "注销", tint = Danger, modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

/* ---------------- 播放设置 ---------------- */

@HiltViewModel
class PlaybackSettingsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {

    private val _state = MutableStateFlow<Loadable<PlaybackPolicy>>(Loadable.Loading)
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
            runCatching { apiFactory.forOrigin(origin).playbackPolicy().dataOrThrow() }
                .onSuccess { _state.value = Loadable.Ready(it) }
                .onFailure { e -> _state.value = Loadable.Failed(friendlyMessage(e)) }
        }
    }

    /** 乐观更新 + 失败回滚(与 iOS 的 savePolicy 同语义) */
    fun patch(
        patch: PlaybackPolicyPatchFull,
        optimistic: (PlaybackPolicy) -> PlaybackPolicy,
        onResult: (String?) -> Unit,
    ) {
        val current = (_state.value as? Loadable.Ready)?.value ?: return
        if (_busy.value) return
        _busy.value = true
        val previous = current
        _state.value = Loadable.Ready(optimistic(current))
        viewModelScope.launch {
            val origin = origin ?: run {
                _busy.value = false
                return@launch
            }
            runCatching { apiFactory.forOrigin(origin).updatePlaybackPolicy(patch).dataOrThrow() }
                .onSuccess { saved ->
                    _state.value = Loadable.Ready(saved)
                    onResult(null)
                }
                .onFailure { e ->
                    _state.value = Loadable.Ready(previous)
                    onResult(friendlyMessage(e))
                }
            _busy.value = false
        }
    }
}

@Composable
fun PlaybackSettingsScreen(onBack: () -> Unit, vm: PlaybackSettingsViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    val busy by vm.busy.collectAsStateWithLifecycle()
    var status by remember { mutableStateOf<String?>(null) }

    Column(Modifier.fillMaxSize()) {
        SettingsTopBar(title = "播放", onBack = onBack)
        when (val s = state) {
            Loadable.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            is Loadable.Failed -> ErrorPane(message = s.message, onRetry = vm::load)
            is Loadable.Ready -> {
                val policy = s.value
                Column(
                    Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(16.dp),
                ) {
                    SettingsToggleRow(
                        title = "允许软件转码",
                        detail = "客户端解不了的文件由服务器 CPU 转换后播放;关掉后这类文件将无法播放",
                        checked = policy.softwareTranscodeEnabled,
                        enabled = !busy,
                    ) { next ->
                        vm.patch(
                            PlaybackPolicyPatchFull(softwareTranscodeEnabled = next),
                            { it.copy(softwareTranscodeEnabled = next) },
                        ) { err -> status = err }
                    }
                    Spacer(Modifier.height(10.dp))
                    SettingsToggleRow(
                        title = "生成进度条预览图",
                        detail = "进度条拖动时的缩略图;关闭可省服务器算力",
                        checked = policy.trickplayEnabled,
                        enabled = !busy,
                    ) { next ->
                        vm.patch(
                            PlaybackPolicyPatchFull(trickplayEnabled = next),
                            { it.copy(trickplayEnabled = next) },
                        ) { err -> status = err }
                    }
                    Spacer(Modifier.height(10.dp))
                    SettingsToggleRow(
                        title = "保留转码产物",
                        detail = "续播/重看时复用,省算力但占空间;关闭即会话结束就删",
                        checked = policy.transcodeCacheEnabled,
                        enabled = !busy,
                    ) { next ->
                        vm.patch(
                            PlaybackPolicyPatchFull(transcodeCacheEnabled = next),
                            { it.copy(transcodeCacheEnabled = next) },
                        ) { err -> status = err }
                    }

                    Spacer(Modifier.height(18.dp))
                    GlassCard(Modifier.fillMaxWidth()) {
                        Text("硬件能力(实测)", style = McType.subheadlineSemibold)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            if (policy.hardwareAvailable) {
                                "服务器可用硬件加速:${policy.hwBackends.joinToString("、").ifEmpty { "已启用" }}"
                            } else {
                                "服务器未检测到可用硬件加速,转码将走 CPU(较慢且吃资源)"
                            },
                            style = McType.footnote,
                            color = if (policy.hardwareAvailable) Success else TextMuted,
                            lineHeight = 20.sp,
                        )
                    }
                    status?.let {
                        Spacer(Modifier.height(12.dp))
                        Text(it, style = McType.footnote, color = Danger)
                    }
                    Spacer(Modifier.height(30.dp))
                }
            }
        }
    }
}

@Composable
private fun SettingsToggleRow(
    title: String,
    detail: String,
    checked: Boolean,
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(SurfaceRaised)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = McType.subheadlineSemibold)
            Spacer(Modifier.height(3.dp))
            Text(detail, style = McType.caption, color = TextMuted, lineHeight = 17.sp)
        }
        Spacer(Modifier.width(10.dp))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(checkedTrackColor = Accent),
        )
    }
}
