package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.AppConfig
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.feature.offline.OfflineDeleteDialog
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 外部访问（iOS `ExternalAccessSettingsView` 的对应物）：外部访问地址 + 对外端口。
 *
 * 端口单独一条（服务端 `PUT /app/port`）：保存后应用全量重启，改错会把用户关在门外，
 * 所以二次确认里写明重启、端口映射与反向代理都要同步调整。
 * 外部访问地址用于通知跳转、AI 回复链接与对外回调，保存即生效（`PUT /app/config`）。
 */
@HiltViewModel
class ExternalAccessViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val feedback: io.movieclaw.android.core.designsystem.FeedbackBus,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val error: String? = null,
        val config: AppConfig = AppConfig(),
        val saving: Boolean = false,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    init { load() }

    fun load() {
        viewModelScope.launch {
            val o = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            runCatching { apiFactory.forOrigin(o).appConfigShow().dataOrThrow() }
                .onSuccess { c -> _ui.update { it.copy(loading = false, config = c) } }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = e.message ?: "读取失败") } }
        }
    }

    /** 保存外部访问地址（留空 = 清除） */
    fun saveExternalUrl(url: String) {
        if (_ui.value.saving) return
        _ui.update { it.copy(saving = true) }
        viewModelScope.launch {
            val o = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(o)
                    .appConfigSave(io.movieclaw.android.core.model.AppConfigPayload(url.trim()))
                    .dataOrThrow()
            }
                .onSuccess { c ->
                    _ui.update { it.copy(saving = false, config = c) }
                    feedback.success("外部访问地址已保存")
                }
                .onFailure { e ->
                    _ui.update { it.copy(saving = false) }
                    feedback.error(e.message ?: "保存失败")
                }
        }
    }

    /** 改对外端口（null/0 = 恢复默认）；服务端会全量重启 */
    fun savePort(port: Int?) {
        if (_ui.value.saving) return
        _ui.update { it.copy(saving = true) }
        viewModelScope.launch {
            val o = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(o)
                    .appPortSave(io.movieclaw.android.core.model.WebPortPayload(port))
                    .dataOrThrow()
            }
                .onSuccess { c ->
                    _ui.update { it.copy(saving = false, config = c) }
                    feedback.success("端口已保存，应用正在重启使其生效")
                }
                .onFailure { e ->
                    _ui.update { it.copy(saving = false) }
                    feedback.error(e.message ?: "保存失败")
                }
        }
    }
}

/**
 * 外部访问（iOS `ExternalAccessSettingsView`）：
 * 根页两行（外部访问地址 / 对外端口）各开一个抽屉编辑；改端口要二次确认并写明重启与端口映射。
 */
@Composable
fun ExternalAccessScreen(onBack: () -> Unit, vm: ExternalAccessViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    var editor by remember { mutableStateOf<ExternalEditor?>(null) }
    // 保存后端口变了：iOS 显示「正在新端口重启」区块（新地址可能已生效）
    var newPort by remember { mutableStateOf<Int?>(null) }

    Column(Modifier.fillMaxSize().background(io.movieclaw.android.core.designsystem.Bg)) {
        SettingsHeader(title = "外部访问", onBack = onBack)
        when {
            ui.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            ui.error != null -> Box(Modifier.fillMaxSize().padding(24.dp)) {
                Text(ui.error!!, style = McType.footnote, color = TextMuted)
            }
            else -> Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
            ) {
                Spacer(Modifier.height(10.dp))
                if (newPort != null) {
                    GlassCard(Modifier.fillMaxWidth()) {
                        Text("对外端口已改为 $newPort", style = McType.sub, color = TextPrimary)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            portUrl(ui.config.webPort),
                            style = McType.caption.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace),
                            color = TextMuted,
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "当前连接地址可能已失效。Docker bridge 部署需将端口映射的容器侧端口改为 $newPort 并重建容器。" +
                                "重启后请在登录页的「更换服务器」中填写新地址。",
                            style = McType.caption2,
                            color = TextFaint,
                            lineHeight = 16.sp,
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                } else {
                    GlassCard(Modifier.fillMaxWidth()) {
                        ExternalNavRow(
                            "外部访问地址",
                            ui.config.externalUrl.takeIf { it.isNotBlank() } ?: "未设置",
                        ) { editor = ExternalEditor.Url }
                        Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.05f)))
                        ExternalNavRow("对外端口", "${ui.config.webPort}") { editor = ExternalEditor.Port }
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "用于通知跳转、AI 回复链接与对外回调。保存后立即生效。",
                        style = McType.caption2,
                        color = TextFaint,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                }
                Spacer(Modifier.height(30.dp))
            }
        }
    }

    when (editor) {
        ExternalEditor.Url -> UrlSheet(
            current = ui.config.externalUrl,
            currentUrl = vm.origin.orEmpty(),
            saving = ui.saving,
            onDismiss = { editor = null },
            onSave = { url ->
                editor = null
                vm.saveExternalUrl(url)
            },
        )
        ExternalEditor.Port -> PortSheet(
            config = ui.config,
            saving = ui.saving,
            onDismiss = { editor = null },
            onSaved = { changedPort ->
                if (changedPort != null) newPort = changedPort
            },
        )
        null -> Unit
    }
}

private enum class ExternalEditor { Url, Port }

/** 根页的导航行（iOS `row(title, value)`）：标题 + 右侧当前值 + › */
@Composable
private fun ExternalNavRow(title: String, value: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = McType.sub, color = TextPrimary)
        Spacer(Modifier.weight(1f))
        Text(value, style = McType.sub, color = TextMuted, maxLines = 1)
        Spacer(Modifier.width(6.dp))
        Text("›", style = McType.sub, color = TextFaint)
    }
}

/** 外部访问地址抽屉（iOS `ExternalAccessEditor` url 分支） */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun UrlSheet(
    current: String,
    currentUrl: String,
    saving: Boolean,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var draft by remember(current) { mutableStateOf(current) }
    val valid = validExternalUrl(draft)
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("外部访问地址", style = McType.title3, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) }
                TextButton(
                    enabled = valid && !saving && draft.trim() != current,
                    onClick = { onSave(draft.trim()) },
                ) { Text("保存", color = if (valid && !saving) Accent else TextFaint) }
            }
            Spacer(Modifier.height(10.dp))
            SettingsTextField(
                value = draft,
                placeholder = currentUrl.ifEmpty { "http://example.com:3000" },
                onValueChange = { draft = it },
            )
            if (draft.isNotBlank() && !valid) {
                Spacer(Modifier.height(6.dp))
                Text("请输入完整的 http(s) 地址。", style = McType.caption2, color = Warning)
            }
            Spacer(Modifier.height(8.dp))
            TextButton(
                onClick = { draft = currentUrl.trimEnd('/') },
                contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
            ) { Text("使用当前服务器地址", style = McType.caption, color = Accent) }
            Spacer(Modifier.height(8.dp))
            Text(
                "填写可从外部访问的完整 http(s) 地址；经反向代理访问时填写代理后的地址。留空可清除设置。",
                style = McType.caption2, color = TextFaint, lineHeight = 16.sp,
            )
            Spacer(Modifier.height(20.dp))
        }
    }
}

/** 对外端口抽屉（iOS `ExternalAccessEditor` port 分支）：确认后重启应用 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun PortSheet(
    config: io.movieclaw.android.core.model.AppConfig,
    saving: Boolean,
    onDismiss: () -> Unit,
    onSaved: (Int?) -> Unit,
) {
    val vm = androidx.hilt.navigation.compose.hiltViewModel<ExternalAccessViewModel>()
    var draft by remember(config.webPort) { mutableStateOf(config.webPort.toString()) }
    var confirm by remember { mutableStateOf<Pair<Int, Boolean>?>(null) } // (target port, restoreDefault)
    val port = draft.toIntOrNull()?.takeIf { it in 1..65535 }
    val canSave = !saving && port != null && (draft != config.webPort.toString() || config.webPortSource == "setting")

    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("对外端口", style = McType.title3, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) }
                TextButton(
                    enabled = canSave,
                    onClick = { port?.let { confirm = it to false } },
                ) { Text("继续", color = if (canSave) Accent else TextFaint) }
            }
            Spacer(Modifier.height(10.dp))
            if (!config.webPortConfigurable) {
                Text(
                    "当前部署由外部进程提供入口，请在启动命令或反向代理中修改端口。",
                    style = McType.caption, color = Warning, lineHeight = 16.sp,
                )
                Spacer(Modifier.height(10.dp))
            } else {
                SettingsTextField(
                    value = draft,
                    placeholder = "1–65535",
                    keyboardType = androidx.compose.ui.text.input.KeyboardType.Number,
                    onValueChange = { v -> draft = v.filter { it.isDigit() }.take(5) },
                )
                if (draft.isNotEmpty() && port == null) {
                    Spacer(Modifier.height(6.dp))
                    Text("请输入 1–65535 的整数。", style = McType.caption2, color = Warning)
                }
            }
            Spacer(Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("当前端口", style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f))
                Text("${config.webPort}", style = McType.sub, color = TextMuted)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("来源", style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f))
                Text(
                    when (config.webPortSource) {
                        "setting" -> "应用内设置"
                        "env" -> "环境变量"
                        else -> "默认"
                    },
                    style = McType.sub,
                    color = TextMuted,
                )
            }
            if (config.webPortSource == "setting") {
                Spacer(Modifier.height(8.dp))
                TextButton(
                    onClick = { confirm = config.webPortDefault to true },
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
                ) { Text("恢复默认端口（${config.webPortDefault}）", style = McType.caption, color = Accent) }
            }
            config.webPortRejected?.let { rejected ->
                Spacer(Modifier.height(6.dp))
                Text(
                    "端口 $rejected 无法绑定，已回落到 ${config.webPort}。",
                    style = McType.caption2, color = Warning,
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                "有效范围 1–65535。修改后服务器将全量重启；如果使用 Docker bridge，通常只需调整宿主侧端口映射。",
                style = McType.caption2, color = TextFaint, lineHeight = 16.sp,
            )
            Spacer(Modifier.height(20.dp))
        }
    }

    confirm?.let { (target, restore) ->
        val seenPort = vm.origin?.let { runCatching { java.net.URI(it).port }.getOrNull() } ?: 0
        val mapping = if (seenPort > 0 && seenPort != config.webPort) {
            "当前通过端口 $seenPort 访问，服务器监听 ${config.webPort}，中间存在端口映射或反向代理。"
        } else ""
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirm = null },
            containerColor = Color(0xFF15161A),
            titleContentColor = TextPrimary,
            textContentColor = TextMuted,
            title = { Text("确认修改端口并重启？", style = McType.title3) },
            text = {
                Text(
                    "服务器将重启并监听端口 $target，当前地址可能失效。$mapping" +
                        "Docker bridge 部署必须同步修改 compose 中 ports 的容器侧端口并重建容器；" +
                        "反向代理必须调整目标端口。只想改变访问端口时，可直接调整映射或反向代理。",
                    style = McType.footnote,
                    color = TextMuted,
                    lineHeight = 20.sp,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirm = null
                    onDismiss()
                    vm.savePort(if (restore) 0 else target)
                    onSaved(if (restore) config.webPortDefault else target)
                }) { Text("修改并重启", color = Danger) }
            },
            dismissButton = {
                TextButton(onClick = { confirm = null }) { Text("取消", color = TextPrimary) }
            },
        )
    }
}

/** iOS `NetworkSettingsValidation.validURL(value, allowEmpty: true)` */
internal fun validExternalUrl(value: String): Boolean {
    val v = value.trim()
    if (v.isEmpty()) return true
    if (v.any { it.isWhitespace() }) return false
    val uri = runCatching { java.net.URI(v) }.getOrNull() ?: return false
    return uri.scheme?.lowercase() in listOf("http", "https") && !uri.host.isNullOrEmpty()
}

/** 端口变化后的新地址预览（iOS `portURL`）：换掉当前 origin 的端口 */
private fun portUrl(port: Int): String {
    val origin = io.movieclaw.android.core.network.ServerRoutes.baseFor(null).orEmpty()
    if (origin.isEmpty()) return "端口 $port"
    return runCatching {
        val uri = java.net.URI(origin)
        java.net.URI(uri.scheme, uri.userInfo, uri.host, port, uri.path, uri.query, uri.fragment).toString()
    }.getOrDefault("端口 $port")
}
