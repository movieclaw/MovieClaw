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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.LlmDefaultsPayload
import io.movieclaw.android.core.model.LlmDefaultsView
import io.movieclaw.android.core.model.LlmModelOption
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import io.movieclaw.android.core.designsystem.formSheetScroll

/**
 * AI 设定（iOS `AIDefaultsSettingsView` 的对应物）：两个用途的默认模型。
 *
 * 接口与 iOS 完全同口径：`GET/PUT /llm/defaults`（`agent_model` / `subtitle_model`），
 * 可选清单来自已有的 `GET /llm/models`。之前这一项在 Android 上只有「网页端管理」占位。
 */
@HiltViewModel
class AiDefaultsViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val saving: Boolean = false,
        val error: String? = null,
        val saved: Boolean = false,
        val models: List<LlmModelOption> = emptyList(),
        val draft: LlmDefaultsView = LlmDefaultsView(),
        /** 智能体网页搜索：null = 服务端没有这个接口（< 0.39.0），整节不显示 */
        val webSearch: io.movieclaw.android.core.model.WebSearchConfig? = null,
        val webSearchBusy: Boolean = false,
        val webSearchNotice: String? = null,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null, saved = false)
            val origin = repository.ui.value.origin
            if (origin == null) {
                _ui.value = _ui.value.copy(loading = false, error = "还没有连上服务器")
                return@launch
            }
            val api = apiFactory.forOrigin(origin)
            val models = runCatching { api.llmModels().dataOrThrow() }.getOrDefault(emptyList())
            runCatching { api.llmDefaultsShow().dataOrThrow() }
                .onSuccess { d ->
                    _ui.value = _ui.value.copy(loading = false, models = models, draft = d)
                }
                .onFailure { e ->
                    _ui.value = _ui.value.copy(loading = false, models = models, error = e.message ?: "读取失败")
                }
            // 网页搜索状态：老服务端没有这个接口（404）就整节不显示（iOS `unsupported` 同口径）
            runCatching { api.webSearchShow().dataOrThrow() }
                .onSuccess { config -> _ui.value = _ui.value.copy(webSearch = config) }
        }
    }

    fun setAgent(ref: String?) {
        _ui.value = _ui.value.copy(draft = _ui.value.draft.copy(agentModel = ref), saved = false)
    }

    fun setSubtitle(ref: String?) {
        _ui.value = _ui.value.copy(draft = _ui.value.draft.copy(subtitleModel = ref), saved = false)
    }

    fun save() {
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            val models = _ui.value.models
            val refs = models.map { it.ref }.toSet()
            // 目录里已不存在的引用不能原样回传，否则服务端会整体拒绝；
            // 模型目录没拿到时（网络失败）保持原值，免得误清空。
            fun valid(ref: String?): String? =
                if (models.isEmpty()) ref else ref?.takeIf { it in refs }
            _ui.value = _ui.value.copy(saving = true, error = null)
            runCatching {
                apiFactory.forOrigin(origin)
                    .llmDefaultsUpdate(LlmDefaultsPayload(
                        agentModel = valid(_ui.value.draft.agentModel),
                        subtitleModel = valid(_ui.value.draft.subtitleModel),
                    ))
                    .dataOrThrow()
            }
                .onSuccess { d -> _ui.value = _ui.value.copy(saving = false, draft = d, saved = true) }
                .onFailure { e -> _ui.value = _ui.value.copy(saving = false, error = e.message ?: "保存失败") }
        }
    }

    /** 验证并保存网页搜索（服务端先用这把 Key 搜索一次，通过才落库）；apiKey 留空沿用原密钥 */
    fun saveWebSearch(provider: String, apiKey: String?) {
        if (_ui.value.webSearchBusy) return
        _ui.value = _ui.value.copy(webSearchBusy = true, webSearchNotice = null)
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin)
                    .webSearchUpdate(io.movieclaw.android.core.model.WebSearchSavePayload(provider, apiKey?.trim()?.takeIf { it.isNotEmpty() }))
                    .dataOrThrow()
            }
                .onSuccess { config ->
                    _ui.value = _ui.value.copy(webSearchBusy = false, webSearch = config)
                    webSearchSheetOpen.value = false
                }
                .onFailure { e ->
                    _ui.value = _ui.value.copy(webSearchBusy = false, webSearchNotice = e.message ?: "保存失败")
                }
        }
    }

    /** 重新测试连接（不保存） */
    fun testWebSearch() {
        if (_ui.value.webSearchBusy) return
        _ui.value = _ui.value.copy(webSearchBusy = true, webSearchNotice = null)
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).webSearchTest(io.movieclaw.android.core.model.WebSearchTestPayload()).dataOrThrow()
            }
                .onSuccess { r ->
                    _ui.value = _ui.value.copy(
                        webSearchBusy = false,
                        webSearchNotice = (if (r.ok) "✓ " else "✗ ") + r.message + (r.sampleTitle?.let { " · 示例：$it" } ?: ""),
                    )
                }
                .onFailure { e ->
                    _ui.value = _ui.value.copy(webSearchBusy = false, webSearchNotice = e.message ?: "测试失败")
                }
        }
    }

    /** 关闭网页搜索并清除已保存的 Key */
    fun clearWebSearch() {
        if (_ui.value.webSearchBusy) return
        _ui.value = _ui.value.copy(webSearchBusy = true, webSearchNotice = null)
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).webSearchClear().dataOrThrow() }
                .onSuccess { config -> _ui.value = _ui.value.copy(webSearchBusy = false, webSearch = config) }
                .onFailure { e ->
                    _ui.value = _ui.value.copy(webSearchBusy = false, webSearchNotice = e.message ?: "关闭失败")
                }
        }
    }

    val webSearchSheetOpen = MutableStateFlow(false)
}


@Composable
fun AiDefaultsScreen(onBack: () -> Unit, vm: AiDefaultsViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    var picking by remember { mutableStateOf<Purpose?>(null) }
    val webSearchSheetOpen by vm.webSearchSheetOpen.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.load() }

    Column(Modifier.fillMaxSize().background(Bg)) {
        SettingsTopBar(title = "AI 设定", onBack = onBack)
        when {
            ui.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            ui.error != null -> Box(Modifier.fillMaxSize().padding(24.dp)) {
                Text(ui.error!!, style = McType.footnote, color = TextMuted)
            }
            else -> Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                DefaultRow(
                    title = "智能体默认模型",
                    subtitle = "对话与智能体任务使用的默认模型",
                    value = ui.draft.agentModel,
                    fallback = ui.draft.effectiveAgentModel,
                    models = ui.models,
                    onClick = { picking = Purpose.AGENT },
                )
                DefaultRow(
                    title = "字幕处理默认模型",
                    subtitle = "字幕翻译与生成任务使用；任务创建时固定，改动不影响已开始的任务",
                    value = ui.draft.subtitleModel,
                    fallback = ui.draft.effectiveSubtitleModel,
                    models = ui.models,
                    onClick = { picking = Purpose.SUBTITLE },
                )
                if (ui.models.isEmpty()) {
                    Text(
                        "还没有可选的模型，请先在「模型接入」里接入一个供应商",
                        style = McType.footnote,
                        color = TextFaint,
                    )
                }
                // ── 网页搜索（iOS `WebSearchSettingsSection` 同款）：null = 老服务端没有接口，整节不显示 ──
                ui.webSearch?.let { config ->
                    WebSearchSection(
                        config = config,
                        busy = ui.webSearchBusy,
                        notice = ui.webSearchNotice,
                        sheetOpen = webSearchSheetOpen,
                        onEdit = { vm.webSearchSheetOpen.value = true },
                        onRetest = { vm.testWebSearch() },
                        onClear = { vm.clearWebSearch() },
                        onSheetDismiss = { vm.webSearchSheetOpen.value = false },
                        onSheetSave = { provider, key -> vm.saveWebSearch(provider, key) },
                    )
                }
                Spacer(Modifier.height(4.dp))
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(999.dp))
                        .background(if (ui.saving) Color.White.copy(alpha = 0.10f) else Accent)
                        .clickable(enabled = !ui.saving) { vm.save() }
                        .padding(vertical = 12.dp),
                    horizontalArrangement = Arrangement.Center,
                ) {
                    Text(
                        when {
                            ui.saving -> "保存中…"
                            ui.saved -> "AI 设定已保存"
                            else -> "保存"
                        },
                        style = McType.subheadlineSemibold,
                        color = if (ui.saving) TextMuted else Color(0xFF141821),
                    )
                }
            }
        }
    }

    val current = picking ?: return
    ModelPickSheet(
        purpose = current,
        models = ui.models,
        selected = if (current == Purpose.AGENT) ui.draft.agentModel else ui.draft.subtitleModel,
        onPick = { ref ->
            if (current == Purpose.AGENT) vm.setAgent(ref) else vm.setSubtitle(ref)
            picking = null
        },
        onDismiss = { picking = null },
    )
}

private enum class Purpose { AGENT, SUBTITLE }

@Composable
private fun DefaultRow(
    title: String,
    subtitle: String,
    value: String?,
    fallback: String?,
    models: List<LlmModelOption>,
    onClick: () -> Unit,
) {
    val shown = models.firstOrNull { it.ref == value }?.label
        ?: models.firstOrNull { it.ref == fallback }?.label
        ?: value ?: "未设置"
    GlassCard(Modifier.fillMaxWidth().clickable { onClick() }) {
        Column(Modifier.padding(14.dp)) {
            Text(title, style = McType.subheadlineSemibold)
            Spacer(Modifier.height(3.dp))
            Text(subtitle, style = McType.caption, color = TextFaint, lineHeight = 16.sp)
            Spacer(Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(shown, style = McType.sub, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.weight(1f))
                Text("选择模型 ›", style = McType.caption, color = Accent)
            }
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun ModelPickSheet(
    purpose: Purpose,
    models: List<LlmModelOption>,
    selected: String?,
    onPick: (String?) -> Unit,
    onDismiss: () -> Unit,
) {
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().heightIn(max = 520.dp)) {
            Text(
                if (purpose == Purpose.AGENT) "智能体默认模型" else "字幕处理默认模型",
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 20.dp, bottom = 8.dp),
            )
            LazyColumn(Modifier.fillMaxWidth().formSheetScroll()) {
                items(models, key = { it.ref }) { m ->
                    Row(
                        Modifier.fillMaxWidth().clickable { onPick(m.ref) }
                            .padding(horizontal = 20.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(m.label, style = McType.sub, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.weight(1f))
                        if (m.ref == selected) {
                            androidx.compose.material3.Icon(
                                Icons.Rounded.Check, contentDescription = null,
                                tint = Accent, modifier = Modifier.width(16.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}


@Composable
private fun WebSearchSection(
    config: io.movieclaw.android.core.model.WebSearchConfig,
    busy: Boolean,
    notice: String?,
    sheetOpen: Boolean,
    onEdit: () -> Unit,
    onRetest: () -> Unit,
    onClear: () -> Unit,
    onSheetDismiss: () -> Unit,
    onSheetSave: (provider: String, apiKey: String?) -> Unit,
) {
    val current = config.providers.firstOrNull { it.id == config.provider }
    GlassCard(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { onEdit() },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("网页搜索", style = McType.subheadlineSemibold)
                Spacer(Modifier.height(3.dp))
                if (current != null) {
                    Text(
                        if (config.keyHint.isEmpty()) "已接入 ${current.label}"
                        else "已接入 ${current.label} · 密钥末四位 ${config.keyHint}",
                        style = McType.caption, color = TextMuted,
                    )
                } else {
                    Text("接入 Tavily / Exa / Brave 等搜索供应商", style = McType.caption, color = TextMuted)
                }
            }
            if (current == null) {
                Text("未接入", style = McType.caption, color = TextFaint)
            }
            Text(" ›", style = McType.sub, color = TextFaint)
        }
        if (current != null) {
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(
                    Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.08f))
                        .clickable(enabled = !busy) { onRetest() }
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                ) { Text("重新测试连接", style = McType.caption, color = TextPrimary) }
                Box(
                    Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(io.movieclaw.android.core.designsystem.Danger.copy(alpha = 0.14f))
                        .clickable(enabled = !busy) { onClear() }
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                ) { Text("关闭网页搜索", style = McType.caption, color = io.movieclaw.android.core.designsystem.Danger) }
            }
        }
        notice?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, style = McType.caption, color = TextMuted, lineHeight = 16.sp)
        }
    }
    if (sheetOpen) {
        WebSearchEditSheet(
            config = config,
            busy = busy,
            onDismiss = onSheetDismiss,
            onSave = onSheetSave,
        )
    }
}

/** 接入/更换弹层：选供应商 + 填 Key，「验证并保存」交给服务端（验证不过不落库，iOS 同语义） */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun WebSearchEditSheet(
    config: io.movieclaw.android.core.model.WebSearchConfig,
    busy: Boolean,
    onDismiss: () -> Unit,
    onSave: (provider: String, apiKey: String?) -> Unit,
) {
    var provider by remember { mutableStateOf(config.provider ?: config.providers.firstOrNull()?.id.orEmpty()) }
    var key by remember { mutableStateOf("") }
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Text("接入网页搜索", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text(
                "服务端会先用这把 Key 搜索一次，通过才保存；编辑时留空沿用原密钥，更换供应商时必须重填。",
                style = McType.caption, color = TextMuted, lineHeight = 16.sp,
            )
            Spacer(Modifier.height(12.dp))
            config.providers.forEach { option ->
                val on = option.id == provider
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (on) Accent.copy(alpha = 0.14f) else Color.White.copy(alpha = 0.04f))
                        .clickable { provider = option.id }
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(option.label, style = McType.sub, color = if (on) Accent else TextPrimary)
                        option.signupUrl?.let {
                            Text("注册页：$it", style = McType.caption2, color = TextFaint, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    if (on) {
                        androidx.compose.material3.Icon(
                            Icons.Rounded.Check, contentDescription = null, tint = Accent,
                            modifier = Modifier.width(16.dp),
                        )
                    }
                }
                Spacer(Modifier.height(6.dp))
            }
            Spacer(Modifier.height(6.dp))
            androidx.compose.material3.OutlinedTextField(
                value = key,
                onValueChange = { key = it },
                enabled = !busy,
                singleLine = true,
                placeholder = {
                    Text(
                        if (config.configured) "留空沿用原密钥；更换供应商时必须重填" else "API Key",
                        style = McType.caption,
                    )
                },
                visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Accent,
                    unfocusedBorderColor = io.movieclaw.android.core.designsystem.LineColor,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(14.dp))
            val canSave = !busy && (key.isNotBlank() || (config.configured && config.provider != null))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (canSave) Accent else Color.White.copy(alpha = 0.10f))
                    .clickable(enabled = canSave) { onSave(provider, key.takeIf { it.isNotBlank() }) }
                    .padding(vertical = 12.dp),
                horizontalArrangement = Arrangement.Center,
            ) {
                Text(
                    if (busy) "验证并保存中…" else "验证并保存",
                    style = McType.subheadlineSemibold,
                    color = if (canSave) Color(0xFF141821) else TextMuted,
                )
            }
            Spacer(Modifier.height(20.dp))
        }
    }
}
