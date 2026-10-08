package io.movieclaw.android.feature.settings

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Cached
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
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
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.FeedbackBus
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.ProgressBar
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.SurfaceRaised
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.LogDay
import io.movieclaw.android.core.model.LogContent
import io.movieclaw.android.core.model.NetworkConfig
import io.movieclaw.android.core.model.NetworkTestResult
import io.movieclaw.android.core.model.StorageState
import io.movieclaw.android.core.model.UpdateCheck
import io.movieclaw.android.core.model.UpdateProgress
import io.movieclaw.android.core.model.UpdateStatus
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/* ---------------- 更新与维护 ---------------- */

@HiltViewModel
class MaintenanceViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val feedback: FeedbackBus,
) : ViewModel() {

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val status: UpdateStatus? = null,
        val check: UpdateCheck? = null,
        val progress: UpdateProgress? = null,
        val storage: StorageState? = null,
        val storageLoading: Boolean = false,
        val applying: Boolean = false,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            val api = apiFactory.forOrigin(origin)
            runCatching { api.updateStatus().dataOrThrow() }
                .onSuccess { status -> _ui.update { it.copy(loading = false, status = status) } }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
            runCatching { api.storageState().dataOrThrow() }
                .onSuccess { storage -> _ui.update { it.copy(storage = storage) } }
        }
    }

    fun checkUpdate() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).checkUpdate().dataOrThrow() }
                .onSuccess { check -> _ui.update { it.copy(check = check) } }
                .onFailure { e -> feedback.error(friendlyMessage(e)) }
        }
    }

    /** 应用更新:起一次并把进度轮询到结束(服务端更新期间会重启) */
    fun applyUpdate() {
        if (_ui.value.applying) return
        _ui.update { it.copy(applying = true) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            runCatching { api.applyUpdate().dataOrThrow() }
                .onSuccess { p -> _ui.update { it.copy(progress = p) } }
                .onFailure { e ->
                    _ui.update { it.copy(applying = false) }
                    feedback.error(friendlyMessage(e))
                    return@launch
                }
            repeat(120) {
                delay(2_500)
                val current = runCatching { api.updateProgress().dataOrThrow() }.getOrNull()
                if (current != null) {
                    _ui.update { it.copy(progress = current) }
                    val phase = current.phase.lowercase()
                    if (phase in setOf("done", "completed", "finished", "failed", "error")) {
                        _ui.update { it.copy(applying = false) }
                        feedback.success("更新流程结束:${current.detail.ifEmpty { current.phase }}")
                        refresh()
                        return@launch
                    }
                }
            }
            _ui.update { it.copy(applying = false) }
            feedback.info("更新仍在进行,可稍后再打开查看")
        }
    }

    fun clean(key: String) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(storageLoading = true) }
            runCatching { apiFactory.forOrigin(origin).cleanStorage(key).dataOrThrow() }
                .onSuccess { result ->
                    feedback.success(
                        "已清理 ${result.removed} 项,释放 ${McFormat.bytes(result.freedBytes)}" +
                            if (result.skippedBusy > 0) "(跳过 ${result.skippedBusy} 项使用中)" else ""
                    )
                    runCatching { apiFactory.forOrigin(origin).storageState().dataOrThrow() }
                        .onSuccess { storage -> _ui.update { it.copy(storage = storage) } }
                }
                .onFailure { e -> feedback.error(friendlyMessage(e)) }
            _ui.update { it.copy(storageLoading = false) }
        }
    }
}

@Composable
fun MaintenanceSettingsScreen(onBack: () -> Unit, vm: MaintenanceViewModel = hiltViewModel()) {
    val state by vm.ui.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize()) {
        SettingsHeader(title = "更新与维护", onBack = onBack)
        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::refresh)
            else -> Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
            ) {
                state.status?.let { status ->
                    GlassCard(Modifier.fillMaxWidth()) {
                        Text("服务器版本", style = McType.subheadlineSemibold)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            buildString {
                                append(status.currentVersion.ifEmpty { "未知" })
                                if (status.overlayVersion != null) append("(覆盖层 ${status.overlayVersion})")
                                status.modelTag?.let { append(" · 模型 $it") }
                            },
                            style = McType.footnote,
                            color = TextMuted,
                        )
                        if (status.badVersions.isNotEmpty()) {
                            Spacer(Modifier.height(6.dp))
                            Text(
                                "已知问题版本:${status.badVersions.joinToString("、")}",
                                style = McType.caption,
                                color = Warning,
                            )
                        }
                        if (status.inactiveOverlayVersion != null) {
                            Spacer(Modifier.height(6.dp))
                            Text(
                                "覆盖层 ${status.inactiveOverlayVersion} 未激活:${status.inactiveOverlayReason ?: "原因未知"}",
                                style = McType.caption,
                                color = Warning,
                                lineHeight = 17.sp,
                            )
                        }
                        Spacer(Modifier.height(12.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            SettingsActionButton("检查更新", enabled = true) { vm.checkUpdate() }
                            if ((state.check?.updateAvailable == true) && status.canUpdate) {
                                SettingsActionButton(
                                    text = if (state.applying) "更新中…" else "立即更新",
                                    enabled = !state.applying,
                                    primary = true,
                                ) { vm.applyUpdate() }
                            }
                        }
                    }
                }

                state.check?.let { check ->
                    Spacer(Modifier.height(10.dp))
                    GlassCard(Modifier.fillMaxWidth()) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("更新检查", style = McType.subheadlineSemibold)
                            Spacer(Modifier.weight(1f))
                            Text(
                                if (check.updateAvailable) "有新版 ${check.latestVersion}" else "已是最新",
                                style = McType.caption,
                                color = if (check.updateAvailable) Accent else Success,
                            )
                        }
                        if (!check.compatible) {
                            Spacer(Modifier.height(6.dp))
                            Text(
                                "新版本需要更新的运行环境(runtime ≥ ${check.requiresRuntime}),请按官方升级说明处理。",
                                style = McType.caption,
                                color = Warning,
                                lineHeight = 17.sp,
                            )
                        }
                        if (check.latestKnownBad) {
                            Spacer(Modifier.height(6.dp))
                            Text("最新版本已被标记为有问题,建议暂缓更新。", style = McType.caption, color = Danger)
                        }
                        if (check.changelog.isNotEmpty()) {
                            Spacer(Modifier.height(8.dp))
                            Text(
                                check.changelog.take(1200),
                                style = McType.caption,
                                color = TextMuted,
                                lineHeight = 18.sp,
                            )
                        }
                        if (check.publishedAt.isNotEmpty()) {
                            Spacer(Modifier.height(6.dp))
                            Text("发布于 ${McFormat.relative(check.publishedAt)}", style = McType.caption2, color = TextFaint)
                        }
                    }
                }

                state.progress?.let { progress ->
                    Spacer(Modifier.height(10.dp))
                    GlassCard(Modifier.fillMaxWidth()) {
                        Text("更新进度", style = McType.subheadlineSemibold)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            listOfNotNull(progress.phase, progress.detail.takeIf { it.isNotEmpty() }).joinToString(" · "),
                            style = McType.footnote,
                            color = TextMuted,
                        )
                        progress.percent?.let { percent ->
                            Spacer(Modifier.height(8.dp))
                            ProgressBar(fraction = percent / 100f)
                            Spacer(Modifier.height(4.dp))
                            Text("%.0f%%".format(percent), style = McType.caption, color = TextMuted)
                        }
                        progress.error?.let {
                            Spacer(Modifier.height(6.dp))
                            Text(it, style = McType.caption, color = Danger, lineHeight = 17.sp)
                        }
                    }
                }

                state.storage?.let { storage ->
                    Spacer(Modifier.height(10.dp))
                    GlassCard(Modifier.fillMaxWidth()) {
                        Text("存储", style = McType.subheadlineSemibold)
                        Spacer(Modifier.height(8.dp))
                        storage.usage?.let { usage ->
                            Row(Modifier.fillMaxWidth()) {
                                StorageFact("磁盘可用", McFormat.bytes(usage.diskFree))
                                StorageFact("缓存", McFormat.bytes(usage.cacheBytes))
                                StorageFact("数据", McFormat.bytes(usage.dataBytes))
                            }
                            Spacer(Modifier.height(8.dp))
                            ProgressBar(
                                fraction = if (usage.diskTotal > 0) usage.diskUsed.toFloat() / usage.diskTotal else 0f,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                "已用 ${McFormat.bytes(usage.diskUsed)} / 共 ${McFormat.bytes(usage.diskTotal)}",
                                style = McType.caption2,
                                color = TextFaint,
                            )
                        } ?: Text(
                            if (storage.computing) "正在统计存储用量…" else (storage.error ?: "暂无用量数据"),
                            style = McType.caption,
                            color = TextFaint,
                        )
                        Spacer(Modifier.height(10.dp))
                        storage.usage?.dirs?.filter { it.group == "cache" && it.clearable }?.forEach { dir ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth().padding(vertical = 5.dp),
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(dir.title, style = McType.footnote)
                                    Text(
                                        dir.summary.ifEmpty { dir.path },
                                        style = McType.caption2,
                                        color = TextFaint,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    if (dir.rebuildCost == "expensive") {
                                        Text("清理后重建较慢", style = McType.caption2, color = Warning)
                                    }
                                }
                                TextButton(
                                    onClick = { vm.clean(dir.key) },
                                    enabled = !state.storageLoading && dir.exists,
                                ) { Text("清理", style = McType.caption, color = Accent) }
                            }
                        }
                    }
                }

                Spacer(Modifier.height(12.dp))
                Text(
                    "重启服务器、计划任务、NER 模型更新等请在网页端「设置 → 更新与维护」操作;" +
                        "App 内只提供状态查看、更新与缓存清理。",
                    style = McType.caption2,
                    color = TextFaint,
                    lineHeight = 17.sp,
                )
                Spacer(Modifier.height(30.dp))
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.StorageFact(label: String, value: String) {
    Column(Modifier.weight(1f)) {
        Text(label, style = McType.caption2, color = TextFaint)
        Text(value, style = McType.footnote, color = TextPrimary2)
    }
}

private val TextPrimary2 = Color(0xFFF3F5F9)

/* ---------------- 网络 ---------------- */

@HiltViewModel
class NetworkSettingsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val feedback: FeedbackBus,
) : ViewModel() {

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val config: NetworkConfig = NetworkConfig(),
        val saving: Boolean = false,
        val testing: Boolean = false,
        val testResult: NetworkTestResult? = null,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            runCatching { apiFactory.forOrigin(origin).networkConfig().dataOrThrow() }
                .onSuccess { config -> _ui.update { it.copy(loading = false, config = config) } }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
        }
    }

    fun update(transform: (NetworkConfig) -> NetworkConfig) = _ui.update { it.copy(config = transform(it.config)) }

    fun save() {
        if (_ui.value.saving) return
        _ui.update { it.copy(saving = true) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).saveNetworkConfig(_ui.value.config).dataOrThrow() }
                .onSuccess { saved ->
                    _ui.update { it.copy(saving = false, config = saved) }
                    feedback.success("网络配置已保存")
                }
                .onFailure { e ->
                    _ui.update { it.copy(saving = false) }
                    feedback.error(friendlyMessage(e))
                }
        }
    }

    fun test() {
        if (_ui.value.testing) return
        _ui.update { it.copy(testing = true, testResult = null) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).testNetwork().dataOrThrow() }
                .onSuccess { result -> _ui.update { it.copy(testing = false, testResult = result) } }
                .onFailure { e ->
                    _ui.update { it.copy(testing = false) }
                    feedback.error(friendlyMessage(e))
                }
        }
    }
}

@Composable
fun NetworkSettingsScreen(onBack: () -> Unit, vm: NetworkSettingsViewModel = hiltViewModel()) {
    val state by vm.ui.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize()) {
        SettingsHeader(title = "网络", onBack = onBack)
        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::load)
            else -> Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
            ) {
                Text("代理", style = McType.caption, color = TextFaint)
                Spacer(Modifier.height(6.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(
                        "off" to "不使用",
                        "env" to "读环境变量",
                        "manual" to "手动指定",
                    ).forEach { (mode, label) ->
                        val on = state.config.proxyMode == mode
                        Text(
                            label,
                            style = McType.footnote,
                            color = if (on) Accent else TextMuted,
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .background(if (on) AccentSoft else SurfaceRaised)
                                .clickable { vm.update { it.copy(proxyMode = mode) } }
                                .padding(horizontal = 12.dp, vertical = 7.dp),
                        )
                    }
                }
                if (state.config.proxyMode == "manual") {
                    Spacer(Modifier.height(10.dp))
                    Text("代理地址", style = McType.caption, color = TextFaint)
                    Spacer(Modifier.height(6.dp))
                    SettingsTextField(
                        value = state.config.proxyUrl,
                        placeholder = "http://192.168.1.2:7890",
                        onValueChange = { value -> vm.update { it.copy(proxyUrl = value) } },
                    )
                }

                Spacer(Modifier.height(16.dp))
                Text("图床与数据源", style = McType.caption, color = TextFaint)
                Spacer(Modifier.height(6.dp))
                SettingsTextField(
                    value = state.config.tmdbApiBaseUrl,
                    placeholder = "TMDB API 基址(留空用默认)",
                    onValueChange = { value -> vm.update { it.copy(tmdbApiBaseUrl = value) } },
                )
                Spacer(Modifier.height(8.dp))
                SettingsTextField(
                    value = state.config.tmdbImageBaseUrl,
                    placeholder = "TMDB 图床基址(留空用默认)",
                    onValueChange = { value -> vm.update { it.copy(tmdbImageBaseUrl = value) } },
                )
                Spacer(Modifier.height(8.dp))
                SettingsTextField(
                    value = state.config.doubanApiBaseUrl,
                    placeholder = "豆瓣 API 基址(留空用默认)",
                    onValueChange = { value -> vm.update { it.copy(doubanApiBaseUrl = value) } },
                )

                Spacer(Modifier.height(16.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SettingsActionButton(
                        text = if (state.saving) "保存中…" else "保存",
                        enabled = !state.saving,
                        primary = true,
                    ) { vm.save() }
                    SettingsActionButton(
                        text = if (state.testing) "测试中…" else "连通性测试",
                        enabled = !state.testing,
                    ) { vm.test() }
                }

                state.testResult?.let { result ->
                    Spacer(Modifier.height(12.dp))
                    GlassCard(Modifier.fillMaxWidth()) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                if (result.ok) "连通正常" else "连通失败",
                                style = McType.subheadlineSemibold,
                                color = if (result.ok) Success else Danger,
                            )
                            result.latencyMs?.let {
                                Spacer(Modifier.width(8.dp))
                                Text("${it} ms", style = McType.caption, color = TextMuted)
                            }
                        }
                        if (result.message.isNotEmpty()) {
                            Spacer(Modifier.height(5.dp))
                            Text(result.message, style = McType.caption, color = TextMuted, lineHeight = 17.sp)
                        }
                    }
                }
                Spacer(Modifier.height(30.dp))
            }
        }
    }
}

/* ---------------- 日志 ---------------- */

@HiltViewModel
class LogsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {

    private val _days = MutableStateFlow<Loadable<List<LogDay>>>(Loadable.Loading)
    val days = _days.asStateFlow()

    private val _content = MutableStateFlow<LogContent?>(null)
    val content = _content.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    init {
        loadDays()
    }

    fun loadDays() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _days.value = Loadable.Loading
            runCatching { apiFactory.forOrigin(origin).logDays().dataOrThrow().days }
                .onSuccess { _days.value = Loadable.Ready(it) }
                .onFailure { e -> _days.value = Loadable.Failed(friendlyMessage(e)) }
        }
    }

    fun open(day: String) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).logContent(day).dataOrThrow() }
                .onSuccess { _content.value = it }
        }
    }

    fun close() {
        _content.value = null
    }
}

@Composable
fun LogsSettingsScreen(onBack: () -> Unit, vm: LogsViewModel = hiltViewModel()) {
    val days by vm.days.collectAsStateWithLifecycle()
    val content by vm.content.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize()) {
        SettingsHeader(
            title = if (content == null) "日志" else "日志 · ${content!!.day}",
            onBack = { if (content != null) vm.close() else onBack() },
        )
        when {
            content != null -> {
                val log = content!!
                Column(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 6.dp)) {
                        Text(
                            "${log.totalLines} 行 · ${McFormat.bytes(log.sizeBytes)}" +
                                if (log.truncated) " · 已截断(仅显示末尾)" else "",
                            style = McType.caption,
                            color = TextFaint,
                        )
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = vm::close) {
                            Text("返回列表", style = McType.caption, color = Accent)
                        }
                    }
                    androidx.compose.foundation.lazy.LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(bottom = 24.dp),
                    ) {
                        items(log.lines) { line ->
                            Text(
                                line,
                                style = McType.caption2.copy(
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 10.5.sp,
                                    lineHeight = 15.sp,
                                ),
                                color = when {
                                    line.contains("ERROR", ignoreCase = true) -> Danger
                                    line.contains("WARN", ignoreCase = true) -> Warning
                                    else -> TextMuted
                                },
                            )
                        }
                    }
                }
            }
            days is Loadable.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            days is Loadable.Failed -> ErrorPane(
                message = (days as Loadable.Failed).message,
                onRetry = vm::loadDays,
            )
            else -> LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items((days as Loadable.Ready<List<LogDay>>).value, key = { it.day }) { day ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(SurfaceRaised)
                            .clickable { vm.open(day.day) }
                            .padding(14.dp),
                    ) {
                        Icon(
                            Icons.Rounded.Cached,
                            contentDescription = null,
                            tint = TextFaint,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(day.day, style = McType.subheadline, modifier = Modifier.weight(1f))
                        Text(McFormat.bytes(day.sizeBytes), style = McType.caption, color = TextFaint)
                    }
                }
                if ((days as Loadable.Ready<List<LogDay>>).value.isEmpty()) {
                    item {
                        Text(
                            "服务端还没有日志文件",
                            style = McType.footnote,
                            color = TextFaint,
                            modifier = Modifier.padding(vertical = 20.dp),
                        )
                    }
                }
            }
        }
    }
}

/* ---------------- 共用小件 ---------------- */

/** 子页顶栏：直接用全站那一条（`McTopBar(Sub)`），返回键与标题各页统一 */
@Composable
private fun SettingsHeader(title: String, onBack: () -> Unit) {
    io.movieclaw.android.core.designsystem.McTopBar(
        variant = io.movieclaw.android.core.designsystem.McTopBarVariant.Sub,
        title = title,
        onBack = onBack,
    )
}

@Composable
private fun SettingsActionButton(
    text: String,
    enabled: Boolean,
    primary: Boolean = false,
    onClick: () -> Unit,
) {
    TextButton(onClick = onClick, enabled = enabled) {
        Text(
            text,
            style = if (primary) McType.subheadlineSemibold else McType.subheadline,
            color = when {
                !enabled -> TextFaint
                primary -> Accent
                else -> TextMuted
            },
        )
    }
}

@Composable
private fun SettingsTextField(
    value: String,
    placeholder: String,
    onValueChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        placeholder = { Text(placeholder, style = McType.caption, color = TextFaint) },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = Color.White.copy(alpha = 0.055f),
            unfocusedContainerColor = Color.White.copy(alpha = 0.055f),
            focusedBorderColor = Accent.copy(alpha = 0.45f),
            unfocusedBorderColor = Color.White.copy(alpha = 0.1f),
            focusedTextColor = Color.White,
            unfocusedTextColor = Color.White,
            cursorColor = Accent,
        ),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    )
}
