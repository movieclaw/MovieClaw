package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.FlatCard
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.LlmModelInfo
import io.movieclaw.android.core.model.LlmPresetView
import io.movieclaw.android.core.model.LlmProviderPayload
import io.movieclaw.android.core.model.LlmProviderView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 「模型接入」（iOS `.settingsSection(.llm)` / Web `/settings/llm`）：
 * 接入 OpenAI、百炼等供应商，可同时接入多家。AI 字幕生成的「去接入」落点就是这里。
 */
@HiltViewModel
class LlmSettingsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {

    data class Data(
        val presets: List<LlmPresetView> = emptyList(),
        val providers: List<LlmProviderView> = emptyList(),
    )

    private val _state = MutableStateFlow<Loadable<Data>>(Loadable.Loading)
    val state = _state.asStateFlow()

    /** 保存失败的后端中文原因（显示在表单顶部，弹层保持打开） */
    private val _formError = MutableStateFlow<String?>(null)
    val formError = _formError.asStateFlow()

    private val _saving = MutableStateFlow(false)
    val saving = _saving.asStateFlow()

    private val origin: String? get() = repository.ui.value.origin

    init {
        load()
        // pending / verifying 是中间态：每 2 秒轮询到落定（iOS 同款）
        viewModelScope.launch {
            while (true) {
                delay(2_000)
                val current = (_state.value as? Loadable.Ready)?.value ?: continue
                if (current.providers.none { it.status == "pending" || it.status == "verifying" }) continue
                refresh(quiet = true)
            }
        }
    }

    fun load() = refresh(quiet = false)

    private fun refresh(quiet: Boolean) {
        viewModelScope.launch {
            val origin0 = origin ?: return@launch
            if (!quiet) _state.value = Loadable.Loading
            runCatching {
                val api = apiFactory.forOrigin(origin0)
                Data(presets = api.llmPresets().dataOrThrow(), providers = api.llmProviders().dataOrThrow())
            }.onSuccess { _state.value = Loadable.Ready(it) }
                .onFailure { if (!quiet) _state.value = Loadable.Failed(friendlyMessage(it)) }
        }
    }

    fun save(existingId: Int?, body: LlmProviderPayload, onDone: () -> Unit) {
        viewModelScope.launch {
            _saving.value = true
            _formError.value = null
            val origin0 = origin ?: return@launch
            val api = apiFactory.forOrigin(origin0)
            runCatching {
                if (existingId == null) api.createLlmProvider(body).dataOrThrow()
                else api.updateLlmProvider(existingId, body).dataOrThrow()
            }.onSuccess {
                _saving.value = false
                refresh(quiet = true)
                onDone()
            }.onFailure {
                _saving.value = false
                _formError.value = friendlyMessage(it)
            }
        }
    }

    fun verify(id: Int) {
        viewModelScope.launch {
            val origin0 = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin0).verifyLlmProvider(id).dataOrThrow() }
            refresh(quiet = true)
        }
    }

    fun delete(id: Int) {
        viewModelScope.launch {
            val origin0 = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin0).deleteLlmProvider(id).dataOrThrow() }
            refresh(quiet = true)
        }
    }
}

/** 状态胶囊文案（iOS `SettingsBLLMSupport` / Web `STATUS_META` 同口径） */
private fun statusLabel(status: String): String = when (status) {
    "active" -> "已连接"
    "verifying" -> "测试中"
    "pending" -> "待测试"
    "failed" -> "连接失败"
    else -> status
}

private fun statusColor(status: String): Color = when (status) {
    "active" -> Color(0xFF7ED9A0)
    "failed" -> Color(0xFFFF9F9F)
    else -> Color(0xFFF5C451)
}

@Composable
fun LlmSettingsScreen(onBack: () -> Unit, vm: LlmSettingsViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    val saving by vm.saving.collectAsStateWithLifecycle()
    val formError by vm.formError.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<LlmProviderView?>(null) }
    var adding by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<LlmProviderView?>(null) }

    Column(Modifier.fillMaxSize()) {
        SettingsTopBar(title = "模型接入", onBack = onBack)
        when (val s = state) {
            Loadable.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            is Loadable.Failed -> ErrorPane(message = s.message, onRetry = vm::load)
            is Loadable.Ready -> {
                val data = s.value
                Column(
                    Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = McMetrics.pagePadding)
                        .padding(bottom = 32.dp),
                ) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        if (data.providers.isEmpty()) {
                            "接入一个或多个大语言模型供应商，AI 能力（对话助手、字幕处理、智能识别等）将由它们驱动。"
                        } else {
                            "接入后该供应商目录里的全部模型都可在对话框里选用；各场景默认用哪个模型，在「AI 设定」里配置。"
                        },
                        style = McType.sub, color = TextMuted,
                    )
                    Spacer(Modifier.height(14.dp))

                    if (data.providers.isEmpty()) {
                        FlatCard(Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(16.dp)) {
                                Text("还没有接入模型供应商", style = McType.bodySemibold, color = TextPrimary)
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    "支持 OpenAI、阿里云百炼，以及任何 OpenAI 兼容端点（如自建 vLLM / Ollama）。",
                                    style = McType.sub, color = TextMuted,
                                )
                                Spacer(Modifier.height(14.dp))
                                Text(
                                    "接入模型供应商",
                                    style = McType.subSemibold, color = Color(0xFF0A0E12),
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(Accent)
                                        .clickable { adding = true }
                                        .padding(horizontal = 14.dp, vertical = 10.dp),
                                )
                            }
                        }
                    } else {
                        data.providers.forEach { provider ->
                            LlmProviderCard(
                                provider = provider,
                                presets = data.presets,
                                onEdit = { editing = provider },
                                onVerify = { vm.verify(provider.id) },
                                onDelete = { deleting = provider },
                            )
                            Spacer(Modifier.height(12.dp))
                        }
                        Text(
                            "＋ 接入另一家供应商",
                            style = McType.subSemibold, color = Accent,
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable { adding = true }
                                .padding(vertical = 8.dp),
                        )
                    }
                }
            }
        }
    }

    if (adding || editing != null) {
        LlmProviderFormSheet(
            presets = (state as? Loadable.Ready)?.value?.presets.orEmpty(),
            existing = editing,
            saving = saving,
            formError = formError,
            onDismiss = { adding = false; editing = null },
            onSave = { id, body -> vm.save(id, body) { adding = false; editing = null } },
        )
    }

    deleting?.let { provider ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("删除「${provider.name}」？", style = McType.bodySemibold) },
            text = {
                Text(
                    "它目录里的模型将不再可选；AI 设定中指向它的默认模型会自动兜底到其它已接入的供应商。",
                    style = McType.sub, color = TextMuted,
                )
            },
            confirmButton = {
                TextButton(onClick = { vm.delete(provider.id); deleting = null }) {
                    Text("删除", color = Color(0xFFFF9F9F))
                }
            },
            dismissButton = {
                TextButton(onClick = { deleting = null }) { Text("取消", color = TextMuted) }
            },
        )
    }
}

/** 一个已接入的供应商：标题 + 状态胶囊 + 副标题 + 信息行 + 三个动作 */
@Composable
private fun LlmProviderCard(
    provider: LlmProviderView,
    presets: List<LlmPresetView>,
    onEdit: () -> Unit,
    onVerify: () -> Unit,
    onDelete: () -> Unit,
) {
    val preset = presets.firstOrNull { it.id == provider.providerType }
    val verified = provider.status == "pending" || provider.status == "verifying"
    FlatCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(provider.name, style = McType.bodySemibold, color = TextPrimary)
                Spacer(Modifier.width(8.dp))
                Text(
                    statusLabel(provider.status),
                    style = McType.caption,
                    color = statusColor(provider.status),
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .background(statusColor(provider.status).copy(alpha = 0.12f))
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                provider.lastError?.takeIf { provider.status == "failed" && it.isNotBlank() }
                    ?: buildString {
                        append(preset?.displayName ?: provider.providerType)
                        if (provider.extraModels.isNotEmpty()) append(" · ${provider.extraModels.size} 个自定义模型")
                        append(" · 上次检查 ")
                        append(relativeTime(provider.lastCheckedAt))
                    },
                style = McType.caption, color = TextMuted,
            )
            Spacer(Modifier.height(10.dp))
            InfoRow("API 端点", provider.baseUrl ?: preset?.baseUrl ?: "官方默认")
            InfoRow("连接测试模型", provider.defaultModel)
            provider.userAgent?.takeIf { it.isNotBlank() }?.let { InfoRow("User-Agent", it) }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CardAction("编辑配置", onClick = onEdit)
                CardAction("重新测试", enabled = !verified, onClick = onVerify)
                CardAction("删除", danger = true, onClick = onDelete)
            }
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(label, style = McType.caption, color = TextFaint, modifier = Modifier.width(96.dp))
        Text(value, style = McType.caption, color = TextMuted)
    }
}

@Composable
private fun CardAction(label: String, enabled: Boolean = true, danger: Boolean = false, onClick: () -> Unit) {
    Text(
        label,
        style = McType.caption,
        color = when {
            !enabled -> TextFaint
            danger -> Color(0xFFFF9F9F)
            else -> TextPrimary
        },
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .border(1.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 7.dp),
    )
}

/** 相对时间（「上次检查 3 分钟前 / 从未」）：服务端给的是 ISO 时间串 */
private fun relativeTime(iso: String?): String {
    if (iso.isNullOrBlank()) return "从未"
    val then = runCatching { java.time.OffsetDateTime.parse(iso).toInstant().toEpochMilli() }
        .recoverCatching { java.time.Instant.parse(iso).toEpochMilli() }
        .getOrNull() ?: return "从未"
    val minutes = (System.currentTimeMillis() - then) / 60_000
    return when {
        minutes < 1 -> "刚刚"
        minutes < 60 -> "$minutes 分钟前"
        minutes < 24 * 60 -> "${minutes / 60} 小时前"
        else -> "${minutes / (24 * 60)} 天前"
    }
}
