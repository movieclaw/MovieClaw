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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.DirectoryPickerSheet
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.DownloaderLimits
import io.movieclaw.android.core.model.DownloaderPayload
import io.movieclaw.android.core.model.DownloaderStatusPayload
import io.movieclaw.android.core.model.DownloaderTypeInfo
import io.movieclaw.android.core.model.DownloaderView
import io.movieclaw.android.core.model.FsBrowseView
import io.movieclaw.android.core.model.PathMapping
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import io.movieclaw.android.core.designsystem.formSheetScroll

/*
 * 设置 → 下载器（原生页，参照移动网页端 `downloader-config-section.tsx`）：
 * 列表（状态徽标 / 默认 / 停用 / 路径体检）→ 新增与编辑（类型、地址、账号、保存目录、路径映射）
 * → 行内动作（启停、限速与队列、设默认、重测、删除）。保存后服务端异步测试，页面按 2 秒轮询。
 */

@HiltViewModel
class DownloadersViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val error: String? = null,
        val types: List<DownloaderTypeInfo> = emptyList(),
        val list: List<DownloaderView> = emptyList(),
        val busy: Set<Long> = emptySet(),
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui.asStateFlow()

    /** 验证轮询只保留一条：页面首次进入与每次操作都会调用，防重 */
    private var pollJob: Job? = null

    private fun api() = repository.ui.value.origin?.let { apiFactory.forOrigin(it) }

    init { load() }

    fun load() {
        viewModelScope.launch {
            val api = api() ?: run {
                _ui.value = _ui.value.copy(loading = false, error = "还没有连上服务器")
                return@launch
            }
            _ui.value = _ui.value.copy(loading = true, error = null)
            val types = runCatching { api.downloaderTypes().dataOrThrow() }.getOrDefault(emptyList())
            runCatching { api.downloaders().dataOrThrow() }
                .onSuccess { _ui.value = _ui.value.copy(loading = false, types = types, list = it) }
                .onFailure {
                    _ui.value = _ui.value.copy(
                        loading = false, types = types,
                        error = it.message ?: "加载失败，请稍后重试",
                    )
                }
        }
    }

    /** 有 pending / verifying 时每 2 秒刷新一次，全部落定后停（网页端同口径） */
    fun pollWhileVerifying() {
        if (pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            try {
                while (true) {
                    delay(2000)
                    val api = api() ?: return@launch
                    val pending = _ui.value.list.any { it.status == "pending" || it.status == "verifying" }
                    if (!pending) return@launch
                    runCatching { api.downloaders().dataOrThrow() }
                        .onSuccess { fresh -> _ui.value = _ui.value.copy(list = fresh) }
                }
            } finally {
                pollJob = null
            }
        }
    }

    suspend fun browse(path: String?): FsBrowseView {
        val api = api() ?: throw IllegalStateException("尚未连接服务器")
        return api.fsBrowse(path).dataOrThrow()
    }

    private fun withBusy(id: Long?, block: suspend (io.movieclaw.android.core.api.McApi) -> Unit) {
        viewModelScope.launch {
            val api = api() ?: return@launch
            if (id != null) _ui.value = _ui.value.copy(busy = _ui.value.busy + id)
            try {
                block(api)
            } finally {
                if (id != null) _ui.value = _ui.value.copy(busy = _ui.value.busy - id)
            }
            pollWhileVerifying()
        }
    }

    fun save(editingId: Long?, payload: DownloaderPayload, onDone: (String?) -> Unit) {
        withBusy(editingId) { api ->
            runCatching {
                if (editingId == null) api.createDownloader(payload).dataOrThrow()
                else api.updateDownloader(editingId, payload).dataOrThrow()
            }.onSuccess {
                onDone(null)
                load()
            }.onFailure { onDone(it.message ?: "保存失败，请稍后重试") }
        }
    }

    fun toggleEnabled(item: DownloaderView, onResult: (String?) -> Unit) {
        withBusy(item.id) { api ->
            runCatching { api.setDownloaderEnabled(item.id, DownloaderStatusPayload(!item.enabled)).dataOrThrow() }
                .onSuccess { fresh ->
                    _ui.value = _ui.value.copy(list = _ui.value.list.map { if (it.id == fresh.id) fresh else it })
                    onResult(null)
                }
                .onFailure { onResult(it.message ?: "操作失败，请稍后重试") }
        }
    }

    fun setDefault(item: DownloaderView, onResult: (String?) -> Unit) {
        withBusy(item.id) { api ->
            runCatching { api.setDefaultDownloader(item.id).dataOrThrow() }
                .onSuccess {
                    onResult(null)
                    load()
                }
                .onFailure { onResult(it.message ?: "操作失败，请稍后重试") }
        }
    }

    fun verify(item: DownloaderView, onResult: (String?) -> Unit) {
        withBusy(item.id) { api ->
            runCatching { api.verifyDownloader(item.id).dataOrThrow() }
                .onSuccess { fresh ->
                    _ui.value = _ui.value.copy(list = _ui.value.list.map { if (it.id == fresh.id) fresh else it })
                    onResult(null)
                }
                .onFailure { onResult(it.message ?: "操作失败，请稍后重试") }
        }
    }

    fun delete(item: DownloaderView, onResult: (String?) -> Unit) {
        withBusy(item.id) { api ->
            runCatching { api.deleteDownloader(item.id).dataOrThrow() }
                .onSuccess {
                    _ui.value = _ui.value.copy(list = _ui.value.list.filterNot { it.id == item.id })
                    onResult(null)
                }
                .onFailure { onResult(it.message ?: "删除失败，请稍后重试") }
        }
    }

    suspend fun limits(id: Long): Result<DownloaderLimits> {
        val api = api() ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { api.downloaderLimits(id).dataOrThrow() }
    }

    suspend fun saveLimits(id: Long, body: DownloaderLimits): Result<DownloaderLimits> {
        val api = api() ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { api.setDownloaderLimits(id, body).dataOrThrow() }
    }
}

private fun statusLabel(item: DownloaderView): String = when {
    item.status == "active" && !item.pathsHealthy -> "路径异常"
    item.status == "active" -> "已连接"
    item.status == "verifying" -> "测试中"
    item.status == "failed" -> "连接失败"
    else -> "待测试"
}

private fun statusColor(item: DownloaderView): Color = when {
    item.status == "active" && !item.pathsHealthy -> Color(0xFFFFB74D)
    item.status == "active" -> Color(0xFF66D19E)
    item.status == "verifying" -> Color(0xFF8AB4F8)
    item.status == "failed" -> Color(0xFFFF8A80)
    else -> TextFaint
}

@Composable
fun DownloadersScreen(onBack: () -> Unit, vm: DownloadersViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val feedback = LocalFeedback.current
    var editing by remember { mutableStateOf<DownloaderView?>(null) }
    var creating by remember { mutableStateOf(false) }
    var limitsFor by remember { mutableStateOf<DownloaderView?>(null) }
    var deleting by remember { mutableStateOf<DownloaderView?>(null) }
    var expanded by remember { mutableStateOf<Long?>(null) }

    LaunchedEffect(Unit) { vm.pollWhileVerifying() }

    Column(Modifier.fillMaxSize().background(io.movieclaw.android.core.designsystem.Bg)) {
        SettingsTopBar(title = "下载器", onBack = onBack)
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("已接入下载器", style = McType.title3, color = TextPrimary)
                    Spacer(Modifier.height(3.dp))
                    Text(
                        when {
                            ui.loading -> "加载中…"
                            ui.list.isEmpty() -> "接入你自己部署的下载软件，资源将由它们完成下载。"
                            else -> "共 ${ui.list.size} 个，${ui.list.count { it.usable }} 个可用。保存后系统会自动测试连接。"
                        },
                        style = McType.footnote, color = TextMuted, lineHeight = 19.sp,
                    )
                }
                Text(
                    "+ 添加下载器", style = McType.caption, color = Accent,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.06f))
                        .clickable { creating = true }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                )
            }

            ui.error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }

            if (ui.list.isEmpty() && !ui.loading) {
                GlassCard(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(18.dp)) {
                        Text("还没有接入任何下载器", style = McType.subheadlineSemibold, color = TextPrimary)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "点「添加下载器」接入，支持 qBittorrent、Transmission；装下载器插件可以接入更多。",
                            style = McType.footnote, color = TextMuted, lineHeight = 19.sp,
                        )
                    }
                }
            } else if (ui.list.isNotEmpty()) {
                GlassCard(Modifier.fillMaxWidth()) {
                    Column {
                        ui.list.forEachIndexed { i, item ->
                            DownloaderRow(
                                item = item,
                                expanded = expanded == item.id,
                                busy = item.id in ui.busy,
                                onToggleExpand = { expanded = if (expanded == item.id) null else item.id },
                                onEdit = { editing = item },
                                onToggleEnabled = {
                                    vm.toggleEnabled(item) { err ->
                                        if (err != null) feedback.error(err) else feedback.success(
                                            if (item.enabled) "已停用「${item.name}」" else "已启用「${item.name}」",
                                        )
                                    }
                                },
                                onLimits = { limitsFor = item },
                                onDefault = {
                                    vm.setDefault(item) { err ->
                                        if (err != null) feedback.error(err) else feedback.success("已设为默认下载器")
                                    }
                                },
                                onVerify = {
                                    vm.verify(item) { err ->
                                        if (err != null) feedback.error(err) else feedback.success("已重新发起连接测试")
                                    }
                                },
                                onDelete = { deleting = item },
                            )
                            if (i != ui.list.lastIndex) {
                                HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(28.dp))
        }
    }

    if (creating || editing != null) {
        DownloaderFormSheet(
            item = editing,
            types = ui.types,
            browse = { vm.browse(it) },
            onDismiss = { creating = false; editing = null },
            onSave = { payload, done -> vm.save(editing?.id, payload, done) },
        )
    }
    limitsFor?.let { item ->
        LimitsSheet(
            item = item,
            load = { vm.limits(item.id) },
            save = { vm.saveLimits(item.id, it) },
            onDismiss = { limitsFor = null },
        )
    }
    deleting?.let { item ->
        DeleteDownloaderDialog(
            item = item,
            onDismiss = { deleting = null },
            onConfirm = {
                deleting = null
                vm.delete(item) { err ->
                    if (err != null) feedback.error(err) else feedback.success("已删除「${item.name}」")
                }
            },
        )
    }
}

@Composable
private fun DownloaderRow(
    item: DownloaderView,
    expanded: Boolean,
    busy: Boolean,
    onToggleExpand: () -> Unit,
    onEdit: () -> Unit,
    onToggleEnabled: () -> Unit,
    onLimits: () -> Unit,
    onDefault: () -> Unit,
    onVerify: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.alphaIf(!item.enabled)) {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onToggleExpand).padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(item.name, style = McType.subheadlineSemibold, color = TextPrimary, maxLines = 1)
                    if (item.isDefault) {
                        Spacer(Modifier.width(6.dp))
                        Badge("默认", TextFaint)
                    }
                    Spacer(Modifier.width(6.dp))
                    Box(Modifier.size(7.dp).clip(CircleShape).background(statusColor(item)))
                    Spacer(Modifier.width(4.dp))
                    Text(statusLabel(item), style = McType.caption, color = statusColor(item))
                    if (!item.enabled) {
                        Spacer(Modifier.width(6.dp))
                        Badge("已停用", TextFaint)
                    }
                }
                Spacer(Modifier.height(3.dp))
                Text(
                    listOfNotNull(item.clientType.ifBlank { null }, item.version?.takeIf { it.isNotBlank() })
                        .joinToString(" · ").ifBlank { item.clientType },
                    style = McType.caption, color = TextFaint,
                )
                val bad = item.lastError?.takeIf { it.isNotBlank() }
                    ?: item.pathHealth.firstOrNull { it.state != "ok" }?.detail
                if (bad != null) {
                    Spacer(Modifier.height(4.dp))
                    Text(bad, style = McType.caption, color = Color(0xFFFF8A80), lineHeight = 17.sp)
                }
            }
            Text("编辑", style = McType.caption, color = Accent,
                modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.06f))
                    .clickable(enabled = !busy, onClick = onEdit).padding(horizontal = 10.dp, vertical = 5.dp))
            Spacer(Modifier.width(4.dp))
            Box {
                Text("⋯", style = McType.sub, color = TextMuted,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).clickable { menu = true }
                        .padding(horizontal = 10.dp, vertical = 4.dp))
                androidx.compose.material3.DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    MenuItem(if (item.enabled) "停用下载器" else "启用下载器", enabled = !busy) { menu = false; onToggleEnabled() }
                    MenuItem("限速与队列…", enabled = !busy) { menu = false; onLimits() }
                    MenuItem("设为默认", enabled = !busy && !item.isDefault) { menu = false; onDefault() }
                    MenuItem(
                        "重新测试连接",
                        enabled = !busy && item.status != "pending" && item.status != "verifying",
                    ) { menu = false; onVerify() }
                    MenuItem("删除配置", enabled = !busy, danger = true) { menu = false; onDelete() }
                }
            }
        }
        if (expanded) {
            Column(Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, bottom = 12.dp)) {
                DetailLine("地址", item.url)
                DetailLine("用户名", item.username?.takeIf { it.isNotBlank() } ?: "未设置")
                DetailLine("版本", item.version?.takeIf { it.isNotBlank() } ?: "—")
                DetailLine("默认保存目录", item.savePath?.takeIf { it.isNotBlank() } ?: "下载器默认")
                Spacer(Modifier.height(8.dp))
                Text("路径映射", style = McType.caption, color = TextFaint)
                val maps = item.pathMappings.orEmpty()
                if (maps.isEmpty()) {
                    Text(
                        "未配置——MovieClaw 与下载器看到的是同一套路径。",
                        style = McType.caption, color = TextMuted, modifier = Modifier.padding(top = 3.dp),
                    )
                } else {
                    maps.forEach { m ->
                        Text(
                            "${m.local} → ${m.remote}",
                            style = McType.caption, color = TextMuted, fontFamily = FontFamily.Monospace,
                            modifier = Modifier.padding(top = 3.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
        Text(label, style = McType.caption, color = TextFaint, modifier = Modifier.width(96.dp))
        Text(
            value, style = McType.caption, color = TextPrimary, maxLines = 2,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun Badge(text: String, color: Color) {
    Text(
        text, style = McType.caption, color = color,
        maxLines = 1, softWrap = false,
        modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.08f))
            .padding(horizontal = 6.dp, vertical = 1.dp),
    )
}

@Composable
private fun MenuItem(text: String, enabled: Boolean = true, danger: Boolean = false, onClick: () -> Unit) {
    androidx.compose.material3.DropdownMenuItem(
        text = {
            Text(
                text, style = McType.sub,
                color = when {
                    !enabled -> TextFaint
                    danger -> Danger
                    else -> TextPrimary
                },
            )
        },
        enabled = enabled,
        onClick = onClick,
    )
}

private fun Modifier.alphaIf(dim: Boolean): Modifier =
    if (dim) this.alpha(0.6f) else this

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun DownloaderFormSheet(
    item: DownloaderView?,
    types: List<DownloaderTypeInfo>,
    browse: suspend (String?) -> FsBrowseView,
    onDismiss: () -> Unit,
    onSave: (DownloaderPayload, (String?) -> Unit) -> Unit,
) {
    var type by remember { mutableStateOf(item?.clientType ?: types.firstOrNull()?.type ?: "qbittorrent") }
    var name by remember { mutableStateOf(item?.name.orEmpty()) }
    var url by remember { mutableStateOf(item?.url.orEmpty()) }
    var username by remember { mutableStateOf(item?.username.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var savePath by remember { mutableStateOf(item?.savePath) }
    var mappings by remember { mutableStateOf(item?.pathMappings.orEmpty()) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var pickingSave by remember { mutableStateOf(false) }
    var pickingMapping by remember { mutableStateOf<Int?>(null) }
    val typeInfo = types.firstOrNull { it.type == type }

    ModalBottomSheet(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier.fillMaxWidth().heightIn(max = 700.dp).formSheetScroll().verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                if (item == null) "添加下载器" else "编辑「${item.name}」",
                style = McType.title3, color = TextPrimary,
            )

            Text("下载器类型", style = McType.caption, color = TextFaint)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                types.ifEmpty {
                    listOf(DownloaderTypeInfo(type = "qbittorrent", title = "qBittorrent"),
                        DownloaderTypeInfo(type = "transmission", title = "Transmission"))
                }.forEach { t ->
                    val sel = t.type == type
                    Text(
                        t.title, style = McType.caption,
                        color = if (sel) Color(0xFF141821) else TextMuted,
                        modifier = Modifier.clip(RoundedCornerShape(999.dp))
                            .background(if (sel) Accent else Color.White.copy(alpha = 0.06f))
                            .clickable(enabled = item == null && !busy) { type = t.type }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                }
            }

            Field("名称", name, { name = it; error = null }, placeholder = "如：家里的 qBittorrent")
            Field(
                typeInfo?.urlLabel ?: (if (type == "transmission") "RPC 地址" else "WebUI 地址"),
                url, { url = it; error = null },
                placeholder = typeInfo?.urlPlaceholder ?: "http://192.168.1.10:8080",
            )
            typeInfo?.help?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = McType.caption, color = TextFaint, lineHeight = 17.sp)
            }
            Field("用户名（可选）", username, { username = it }, placeholder = "")
            Field(
                "密码（可选）", password, { password = it },
                placeholder = if (item != null) "出于安全，请重新填写" else "",
                secret = true,
            )

            Text("默认保存目录（可选）", style = McType.caption, color = TextFaint)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    savePath?.takeIf { it.isNotBlank() } ?: "浏览服务器目录并选择…",
                    style = McType.caption, color = if (savePath.isNullOrBlank()) TextMuted else TextPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).clip(RoundedCornerShape(10.dp))
                        .background(Color.White.copy(alpha = 0.05f))
                        .clickable { pickingSave = true }
                        .padding(horizontal = 10.dp, vertical = 10.dp),
                )
                if (!savePath.isNullOrBlank()) {
                    Spacer(Modifier.width(6.dp))
                    Text("清除", style = McType.caption, color = TextMuted,
                        modifier = Modifier.clickable { savePath = null }.padding(6.dp))
                }
            }
            Text(
                "提交下载时文件的保存位置，从 movieclaw 能看到的目录里选择；下载器看到的路径不同时，配合下方「路径映射」翻译。留空则使用下载器自己设置的默认下载目录。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )

            Text("路径映射（可选）", style = McType.caption, color = TextFaint)
            mappings.forEachIndexed { idx, m ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        m.local.ifBlank { "movieclaw 上的路径…" },
                        style = McType.caption,
                        color = if (m.local.isBlank()) TextMuted else TextPrimary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f).clip(RoundedCornerShape(8.dp))
                            .background(Color.White.copy(alpha = 0.05f))
                            .clickable { pickingMapping = idx }
                            .padding(horizontal = 8.dp, vertical = 8.dp),
                    )
                    Text("→", style = McType.caption, color = TextFaint,
                        modifier = Modifier.clickable {
                            mappings = mappings.toMutableList().also { it[idx] = it[idx].copy(remote = it[idx].local) }
                        }.padding(horizontal = 6.dp))
                    TextField(
                        value = m.remote,
                        onValueChange = { v ->
                            mappings = mappings.toMutableList().also { it[idx] = it[idx].copy(remote = v) }
                        },
                        singleLine = true,
                        placeholder = { Text("下载器上的路径，如 /downloads", style = McType.caption, color = TextFaint) },
                        modifier = Modifier.weight(1f),
                        textStyle = TextStyle(fontSize = 12.sp, fontFamily = FontFamily.Monospace),
                    )
                    Text("×", style = McType.caption, color = TextMuted,
                        modifier = Modifier.clickable {
                            mappings = mappings.toMutableList().also { it.removeAt(idx) }
                        }.padding(6.dp))
                }
            }
            Text(
                "＋ 添加映射", style = McType.caption, color = Accent,
                modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.06f))
                    .clickable { mappings = mappings + PathMapping() }
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            )
            Text(
                "movieclaw 与下载器同一块盘、路径一致时不需要映射；配了映射后，所有下载保存目录都必须被某条映射覆盖，否则会拒绝投递。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )

            error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }

            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss, enabled = !busy) { Text("取消", color = TextMuted) }
                Spacer(Modifier.weight(1f))
                Button(
                    enabled = !busy && name.isNotBlank() && url.startsWith("http"),
                    onClick = {
                        val bad = mappings.any { it.local.isBlank() || !it.remote.startsWith("/") } ||
                            mappings.distinctBy { it.local }.size != mappings.size ||
                            mappings.distinctBy { it.remote }.size != mappings.size
                        if (bad) {
                            error = "每条映射两边都要填：左边浏览选择，右边填下载器上以 / 开头的绝对路径；不需要的行请删除。"
                            return@Button
                        }
                        busy = true
                        onSave(
                            DownloaderPayload(
                                name = name.trim(),
                                clientType = type,
                                url = url.trim(),
                                username = username.trim().ifEmpty { null },
                                password = password.ifEmpty { null },
                                savePath = savePath,
                                pathMappings = mappings.takeIf { it.isNotEmpty() },
                                enabled = item?.enabled ?: true,
                            ),
                        ) { err ->
                            busy = false
                            if (err == null) onDismiss() else error = err
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF141821)),
                    shape = RoundedCornerShape(999.dp),
                ) {
                    if (busy) {
                        CircularProgressIndicator(color = Color(0xFF141821), strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(if (busy) "保存中…" else if (item == null) "添加" else "保存", fontSize = 14.sp)
                }
            }
            Spacer(Modifier.height(10.dp))
        }
    }

    if (pickingSave) {
        DirectoryPickerSheet(
            initialPath = savePath,
            browse = browse,
            onSelect = { savePath = it; pickingSave = false },
            onDismiss = { pickingSave = false },
        )
    }
    pickingMapping?.let { idx ->
        DirectoryPickerSheet(
            initialPath = mappings.getOrNull(idx)?.local,
            browse = browse,
            onSelect = { path ->
                mappings = mappings.toMutableList().also { it[idx] = it[idx].copy(local = path) }
                pickingMapping = null
            },
            onDismiss = { pickingMapping = null },
        )
    }
}

@Composable
private fun Field(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    placeholder: String = "",
    secret: Boolean = false,
) {
    Text(label, style = McType.caption, color = TextFaint)
    TextField(
        value = value,
        onValueChange = onChange,
        singleLine = true,
        placeholder = { Text(placeholder, style = McType.caption, color = TextFaint) },
        modifier = Modifier.fillMaxWidth(),
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation()
        else androidx.compose.ui.text.input.VisualTransformation.None,
    )
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun LimitsSheet(
    item: DownloaderView,
    load: suspend () -> Result<DownloaderLimits>,
    save: suspend (DownloaderLimits) -> Result<DownloaderLimits>,
    onDismiss: () -> Unit,
) {
    var data by remember { mutableStateOf<DownloaderLimits?>(null) }
    var down by remember { mutableStateOf("") }
    var up by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var altSpeed by remember { mutableStateOf(false) }
    var queue by remember { mutableStateOf(false) }
    var maxDown by remember { mutableStateOf("") }
    var maxUp by remember { mutableStateOf("") }
    var maxTorrents by remember { mutableStateOf("") }
    var shownTorrents by remember { mutableStateOf(false) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    LaunchedEffect(item.id) {
        load().onSuccess { l ->
            data = l
            down = l.downloadLimitBytes?.let { (it / 1024).toString() } ?: ""
            up = l.uploadLimitBytes?.let { (it / 1024).toString() } ?: ""
            altSpeed = l.altSpeedEnabled == true
            queue = l.queueEnabled == true
            maxDown = l.maxActiveDownloads?.toString() ?: ""
            maxUp = l.maxActiveUploads?.toString() ?: ""
            maxTorrents = l.maxActiveTorrents?.toString() ?: ""
            shownTorrents = l.maxActiveTorrents != null
        }.onFailure { error = it.message ?: "读取失败" }
    }

    ModalBottomSheet(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier.fillMaxWidth().formSheetScroll().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("限速与队列 · ${item.name}", style = McType.title3, color = TextPrimary)
            Text(
                "实时读写下载器的全局设置。限速留空 = 不限；队列上限决定同时活动的任务数，开着刷流大量做种时建议调大做种/活动上限，避免新任务排队。",
                style = McType.caption, color = TextMuted, lineHeight = 18.sp,
            )
            NumberField("全局下载限速", down, { down = it }, "KiB/s")
            NumberField("全局上传限速", up, { up = it }, "KiB/s")
            SwitchRow("备用限速档（计划任务/手动一键慢速时生效的那组限速）", altSpeed) { altSpeed = it }
            SwitchRow("任务队列（超出上限的任务排队等待）", queue) { queue = it }
            if (queue) {
                NumberField("最大同时下载数", maxDown, { maxDown = it }, "")
                NumberField("最大做种数", maxUp, { maxUp = it }, "")
                if (shownTorrents || maxTorrents.isNotBlank()) NumberField("最大活动种子数", maxTorrents, { maxTorrents = it }, "")
            }
            error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss, enabled = !busy) { Text("取消", color = TextMuted) }
                Spacer(Modifier.weight(1f))
                Button(
                    enabled = !busy && data != null,
                    onClick = {
                        val body = DownloaderLimits(
                            downloadLimitBytes = down.trim().takeIf { it.isNotEmpty() }?.toLongOrNull()?.times(1024),
                            uploadLimitBytes = up.trim().takeIf { it.isNotEmpty() }?.toLongOrNull()?.times(1024),
                            altSpeedEnabled = altSpeed,
                            queueEnabled = queue,
                            maxActiveDownloads = maxDown.trim().toIntOrNull(),
                            maxActiveUploads = maxUp.trim().toIntOrNull(),
                            maxActiveTorrents = maxTorrents.trim().toIntOrNull(),
                        )
                        scope.launch {
                        busy = true
                        error = null
                        save(body)
                            .onSuccess { l ->
                                data = l
                                down = l.downloadLimitBytes?.let { (it / 1024).toString() } ?: ""
                                up = l.uploadLimitBytes?.let { (it / 1024).toString() } ?: ""
                                altSpeed = l.altSpeedEnabled == true
                                queue = l.queueEnabled == true
                                maxDown = l.maxActiveDownloads?.toString() ?: ""
                                maxUp = l.maxActiveUploads?.toString() ?: ""
                                maxTorrents = l.maxActiveTorrents?.toString() ?: ""
                                shownTorrents = l.maxActiveTorrents != null
                                busy = false
                                onDismiss()
                            }
                            .onFailure { busy = false; error = it.message ?: "保存失败，请稍后重试" }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF141821)),
                    shape = RoundedCornerShape(999.dp),
                ) {
                    if (busy) {
                        CircularProgressIndicator(color = Color(0xFF141821), strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(if (busy) "保存中…" else "保存", fontSize = 14.sp)
                }
            }
            Spacer(Modifier.height(10.dp))
        }
    }
}

@Composable
private fun NumberField(label: String, value: String, onChange: (String) -> Unit, suffix: String) {
    Text(label, style = McType.caption, color = TextFaint)
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextField(
            value = value,
            onValueChange = { onChange(it.filter { c -> c.isDigit() }.take(10)) },
            singleLine = true,
            placeholder = { Text("不限", style = McType.caption, color = TextFaint) },
            modifier = Modifier.weight(1f),
        )
        if (suffix.isNotEmpty()) {
            Spacer(Modifier.width(6.dp))
            Text(suffix, style = McType.caption, color = TextMuted)
        }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f), lineHeight = 19.sp)
        Spacer(Modifier.width(8.dp))
        Switch(checked = checked, onCheckedChange = onChange, colors = SwitchDefaults.colors(checkedTrackColor = Accent))
    }
}

@Composable
private fun DeleteDownloaderDialog(item: DownloaderView, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF171A23),
        title = { Text("删除下载器「${item.name}」？", style = McType.bodySemibold, color = TextPrimary) },
        text = {
            Column {
                Text("下载器中的任务不受影响，只是 movieclaw 不再向它投递。", style = McType.sub, color = TextMuted)
            }
        },
        confirmButton = { TextButton(onClick = onConfirm) { Text("删除", color = Danger) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) } },
    )
}
