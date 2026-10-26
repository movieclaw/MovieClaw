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
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.ConfiguredSite
import io.movieclaw.android.core.model.DownloaderView
import io.movieclaw.android.core.model.SearchPresetsPayload
import io.movieclaw.android.core.model.SearchTabView
import io.movieclaw.android.core.model.SiteBoostStatsView
import io.movieclaw.android.core.model.SiteSyncStatsView
import io.movieclaw.android.core.model.SiteBoostPayload
import io.movieclaw.android.core.model.SiteCatalogItem
import io.movieclaw.android.core.model.SiteConfigCreate
import io.movieclaw.android.core.model.SiteConfigUpdate
import io.movieclaw.android.core.model.SiteEnabledPayload
import io.movieclaw.android.core.model.SitePausePayload
import io.movieclaw.android.core.model.SiteProtectedPayload
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.launch
import javax.inject.Inject
import io.movieclaw.android.core.designsystem.formSheetScroll

/*
 * 设置 → 资源站点（原生页，参照移动网页端 `site-config-section.tsx`）：
 * 列表（状态 / 保护 / 刷流读数 / 失败原因）+ 添加站点（先选站点再填授权，两步）
 * + 编辑授权 + 刷流设置 + 行内动作（启停 / 保护 / 刷流开关与暂停 / 重验 / 删除）。
 */

@HiltViewModel
class SitesViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val error: String? = null,
        val catalog: List<SiteCatalogItem> = emptyList(),
        val list: List<ConfiguredSite> = emptyList(),
        val downloaders: List<DownloaderView> = emptyList(),
        /** 展开详情用的统计：索引同步 / 刷流运行（按 site_id） */
        val syncStats: Map<String, SiteSyncStatsView> = emptyMap(),
        val boostStats: Map<String, SiteBoostStatsView> = emptyMap(),
        val busy: Set<String> = emptySet(),
        /** 搜索分类（内置 + 自定义预设，按展示顺序） */
        val presets: List<SearchTabView> = emptyList(),
        val presetsLoading: Boolean = true,
        val presetsBusy: Boolean = false,
        val presetsError: String? = null,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui.asStateFlow()

    /** 整体覆盖保存串行化：连续拖拽/开关时避免两个 PUT 乱序落库 */
    private val presetsSaveLock = Mutex()

    /** 验证轮询只保留一条：页面首次进入与每次操作都会调用，防重 */
    private var pollJob: Job? = null

    private fun api() = repository.ui.value.origin?.let { apiFactory.forOrigin(it) }

    init { load(); loadPresets() }

    fun load() {
        viewModelScope.launch {
            val api = api() ?: run {
                _ui.value = _ui.value.copy(loading = false, error = "还没有连上服务器")
                return@launch
            }
            _ui.value = _ui.value.copy(loading = true, error = null)
            val catalog = runCatching { api.sitesCatalog().dataOrThrow() }.getOrDefault(emptyList())
            val downloaders = runCatching { api.downloaders().dataOrThrow() }.getOrDefault(emptyList())
            // 统计只服务展开详情，拉取失败静默降级（不挡主列表）
            val syncStats = runCatching { api.siteSyncStats().dataOrThrow() }.getOrDefault(emptyMap())
            val boostStats = runCatching { api.siteBoostStats().dataOrThrow() }.getOrDefault(emptyMap())
            runCatching { api.sites().dataOrThrow() }
                .onSuccess {
                    _ui.value = _ui.value.copy(
                        loading = false, catalog = catalog, downloaders = downloaders,
                        syncStats = syncStats, boostStats = boostStats, list = it,
                    )
                }
                .onFailure {
                    _ui.value = _ui.value.copy(
                        loading = false, catalog = catalog, downloaders = downloaders,
                        syncStats = syncStats, boostStats = boostStats,
                        error = it.message ?: "加载失败，请稍后重试",
                    )
                }
        }
    }

    fun loadPresets() {
        viewModelScope.launch {
            val api = api() ?: run {
                _ui.value = _ui.value.copy(presetsLoading = false)
                return@launch
            }
            _ui.value = _ui.value.copy(presetsLoading = true, presetsError = null)
            runCatching { api.searchPresets().dataOrThrow() }
                .onSuccess {
                    _ui.value = _ui.value.copy(
                        presetsLoading = false, presets = it.presets, presetsError = null,
                    )
                }
                .onFailure {
                    _ui.value = _ui.value.copy(
                        presetsLoading = false,
                        presetsError = it.message ?: "搜索分类加载失败",
                    )
                }
        }
    }

    /** 整体覆盖保存：乐观更新，失败回滚并报错（网页端同口径） */
    fun savePresets(next: List<SearchTabView>, onDone: (String?) -> Unit = {}) {
        viewModelScope.launch {
            presetsSaveLock.withLock {
                val api = api() ?: return@withLock onDone("还没有连上服务器")
                val previous = _ui.value.presets
                _ui.value = _ui.value.copy(presets = next, presetsBusy = true, presetsError = null)
                runCatching {
                    api.updateSearchPresets(
                        SearchPresetsPayload(next.map { it.toSearchTabJson() }),
                    ).dataOrThrow()
                }.onSuccess {
                    _ui.value = _ui.value.copy(presets = it.presets, presetsBusy = false)
                    onDone(null)
                }.onFailure {
                    _ui.value = _ui.value.copy(
                        presets = previous, presetsBusy = false,
                        presetsError = it.message ?: "保存失败，请检查网络后重试",
                    )
                    onDone(it.message ?: "保存失败，请检查网络后重试")
                }
            }
        }
    }

    fun pollWhileVerifying() {
        if (pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            try {
                while (true) {
                    delay(2500)
                    val api = api() ?: return@launch
                    val pending = _ui.value.list.any { it.status == "pending" || it.status == "verifying" }
                    if (!pending) return@launch
                    runCatching { api.sites().dataOrThrow() }
                        .onSuccess { fresh -> _ui.value = _ui.value.copy(list = fresh) }
                }
            } finally {
                pollJob = null
            }
        }
    }

    fun nameOf(siteId: String): String =
        _ui.value.catalog.firstOrNull { it.siteId == siteId }?.displayName ?: siteId

    fun baseUrlOf(siteId: String): String? =
        _ui.value.catalog.firstOrNull { it.siteId == siteId }?.baseUrl

    private fun act(siteId: String?, block: suspend (io.movieclaw.android.core.api.McApi) -> Unit) {
        viewModelScope.launch {
            val api = api() ?: return@launch
            if (siteId != null) _ui.value = _ui.value.copy(busy = _ui.value.busy + siteId)
            try {
                block(api)
            } finally {
                if (siteId != null) _ui.value = _ui.value.copy(busy = _ui.value.busy - siteId)
            }
            pollWhileVerifying()
        }
    }

    fun create(body: SiteConfigCreate, onDone: (String?) -> Unit) = act(null) { api ->
        runCatching { api.createSite(body).dataOrThrow() }
            .onSuccess { onDone(null); load() }
            .onFailure { onDone(it.message ?: "保存失败，请稍后重试") }
    }

    fun update(siteId: String, body: SiteConfigUpdate, onDone: (String?) -> Unit) = act(siteId) { api ->
        runCatching { api.updateSite(siteId, body).dataOrThrow() }
            .onSuccess { fresh ->
                _ui.value = _ui.value.copy(list = replace(fresh))
                onDone(null)
            }
            .onFailure { onDone(it.message ?: "保存失败，请稍后重试") }
    }

    private fun replace(fresh: ConfiguredSite) =
        _ui.value.list.map { if (it.siteId == fresh.siteId) fresh else it }

    fun toggleEnabled(item: ConfiguredSite, onResult: (String?) -> Unit) = act(item.siteId) { api ->
        runCatching { api.setSiteEnabled(item.siteId, SiteEnabledPayload(!item.enabled)).dataOrThrow() }
            .onSuccess { fresh ->
                _ui.value = _ui.value.copy(list = replace(fresh))
                onResult(null)
            }
            .onFailure { onResult(it.message ?: "操作失败，请稍后重试") }
    }

    fun toggleProtection(item: ConfiguredSite, onResult: (String?) -> Unit) = act(item.siteId) { api ->
        runCatching { api.setSiteProtection(item.siteId, SiteProtectedPayload(!item.isProtected)).dataOrThrow() }
            .onSuccess { fresh ->
                _ui.value = _ui.value.copy(list = replace(fresh))
                onResult(null)
            }
            .onFailure { onResult(it.message ?: "操作失败，请稍后重试") }
    }

    fun setBoost(item: ConfiguredSite, on: Boolean, budgetBytes: Long? = null, holdDays: Int? = null, downloaderId: Long? = null, onResult: (String?) -> Unit) =
        act(item.siteId) { api ->
            runCatching {
                api.setSiteBoost(item.siteId, SiteBoostPayload(on, budgetBytes, holdDays, downloaderId)).dataOrThrow()
            }.onSuccess { fresh ->
                _ui.value = _ui.value.copy(list = replace(fresh))
                onResult(null)
            }.onFailure { onResult(it.message ?: "操作失败，请稍后重试") }
        }

    fun togglePaused(item: ConfiguredSite, onResult: (String?) -> Unit) = act(item.siteId) { api ->
        runCatching { api.setSiteBoostPaused(item.siteId, SitePausePayload(!item.boostPaused)).dataOrThrow() }
            .onSuccess { fresh ->
                _ui.value = _ui.value.copy(list = replace(fresh))
                onResult(null)
            }
            .onFailure { onResult(it.message ?: "操作失败，请稍后重试") }
    }

    fun verify(item: ConfiguredSite, onResult: (String?) -> Unit) = act(item.siteId) { api ->
        runCatching { api.verifySite(item.siteId).dataOrThrow() }
            .onSuccess { fresh ->
                _ui.value = _ui.value.copy(list = replace(fresh))
                onResult(null)
            }
            .onFailure { onResult(it.message ?: "操作失败，请稍后重试") }
    }

    fun delete(item: ConfiguredSite, onResult: (String?) -> Unit) = act(item.siteId) { api ->
        runCatching { api.deleteSite(item.siteId).dataOrThrow() }
            .onSuccess {
                _ui.value = _ui.value.copy(list = _ui.value.list.filterNot { it.siteId == item.siteId })
                onResult(null)
            }
            .onFailure { onResult(it.message ?: "删除失败，请稍后重试") }
    }
}

private fun siteStatusLabel(item: ConfiguredSite): String = when (item.status) {
    "active" -> "已验证"
    "verifying" -> "验证中"
    "failed" -> "验证失败"
    else -> "待验证"
}

private fun siteStatusColor(item: ConfiguredSite): Color = when (item.status) {
    "active" -> Color(0xFF66D19E)
    "verifying" -> Color(0xFF8AB4F8)
    "failed" -> Color(0xFFFF8A80)
    else -> TextFaint
}

@Composable
fun SitesScreen(onBack: () -> Unit, vm: SitesViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val feedback = LocalFeedback.current
    var adding by remember { mutableStateOf(false) }
    var editingAuth by remember { mutableStateOf<ConfiguredSite?>(null) }
    var boosting by remember { mutableStateOf<ConfiguredSite?>(null) }
    var deleting by remember { mutableStateOf<ConfiguredSite?>(null) }
    var expanded by remember { mutableStateOf<String?>(null) }
    /** sites = 站点接入 / search = 搜索分类（网页端同两个页签） */
    var tab by remember { mutableStateOf("sites") }

    LaunchedEffect(Unit) { vm.pollWhileVerifying() }

    Column(Modifier.fillMaxSize().background(io.movieclaw.android.core.designsystem.Bg)) {
        SettingsTopBar(title = "资源站点", onBack = onBack)
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Spacer(Modifier.height(4.dp))
            SitesPageTabs(selected = tab, onSelect = { tab = it })
            if (tab == "sites") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("已接入站点", style = McType.title3, color = TextPrimary)
                    Spacer(Modifier.height(3.dp))
                    Text(
                        when {
                            ui.loading -> "加载中…"
                            ui.list.isEmpty() -> "站点接入与鉴权、搜索分类、浏览器扩展 Cookie 同步"
                            else -> "已接入 ${ui.list.size} 个站点，" +
                                if (ui.list.any { it.status == "failed" }) "${ui.list.count { it.status == "failed" }} 个异常需要关注"
                                else "全部正常"
                        },
                        style = McType.footnote, color = TextMuted, lineHeight = 19.sp,
                    )
                }
                Text(
                    "+ 添加站点", style = McType.caption, color = Accent,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.06f))
                        .clickable { adding = true }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                )
            }

            ui.error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }

            if (ui.list.isEmpty() && !ui.loading) {
                GlassCard(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(18.dp)) {
                        Text("还没有配置任何站点", style = McType.subheadlineSemibold, color = TextPrimary)
                        Spacer(Modifier.height(4.dp))
                        Text("点「添加站点」开始接入。", style = McType.footnote, color = TextMuted)
                    }
                }
            } else if (ui.list.isNotEmpty()) {
                GlassCard(Modifier.fillMaxWidth()) {
                    Column {
                        ui.list.forEachIndexed { i, item ->
                            SiteRow(
                                item = item,
                                name = vm.nameOf(item.siteId),
                                baseUrl = vm.baseUrlOf(item.siteId),
                                downloaders = ui.downloaders,
                                syncStats = ui.syncStats[item.siteId],
                                boostStats = ui.boostStats[item.siteId],
                                expanded = expanded == item.siteId,
                                busy = item.siteId in ui.busy,
                                onToggleExpand = { expanded = if (expanded == item.siteId) null else item.siteId },
                                onEditAuth = { editingAuth = item },
                                onToggleEnabled = {
                                    vm.toggleEnabled(item) { err ->
                                        if (err != null) feedback.error(err)
                                        else feedback.success(if (item.enabled) "已停用站点" else "已启用站点")
                                    }
                                },
                                onToggleProtect = {
                                    vm.toggleProtection(item) { err ->
                                        if (err != null) feedback.error(err)
                                        else feedback.success(if (item.isProtected) "已取消保护" else "已开启保护")
                                    }
                                },
                                onToggleBoost = {
                                    if (item.boostEnabled) {
                                        vm.setBoost(item, false) { err ->
                                            if (err != null) feedback.error(err) else feedback.success("已关闭刷流")
                                        }
                                    } else boosting = item
                                },
                                onBoostSettings = { boosting = item },
                                onTogglePaused = {
                                    vm.togglePaused(item) { err ->
                                        if (err != null) feedback.error(err)
                                        else feedback.success(if (item.boostPaused) "已恢复刷流" else "已暂停刷流")
                                    }
                                },
                                onVerify = {
                                    vm.verify(item) { err ->
                                        if (err != null) feedback.error(err) else feedback.success("已重新发起验证")
                                    }
                                },
                                onDelete = { deleting = item },
                            )
                            if (i != ui.list.lastIndex) HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
                        }
                    }
                }
            }
            } else {
                SearchPresetsSection(
                    tabs = ui.presets,
                    sites = ui.list,
                    nameOf = { vm.nameOf(it) },
                    loading = ui.presetsLoading,
                    busy = ui.presetsBusy,
                    error = ui.presetsError,
                    feedback = feedback,
                    onChange = { next -> vm.savePresets(next) { err -> if (err != null) feedback.error(err) } },
                    onReload = { vm.loadPresets() },
                )
            }
            Spacer(Modifier.height(28.dp))
        }
    }

    if (adding) {
        AddSiteSheet(
            catalog = ui.catalog,
            configured = ui.list.map { it.siteId }.toSet(),
            onDismiss = { adding = false },
            onSave = { body, done -> vm.create(body, done) },
        )
    }
    editingAuth?.let { item ->
        SiteAuthSheet(
            site = item,
            displayName = vm.nameOf(item.siteId),
            options = ui.catalog.firstOrNull { it.siteId == item.siteId }
                ?.supportedAuthTypes.orEmpty(),
            onDismiss = { editingAuth = null },
            onSave = { body, done -> vm.update(item.siteId, body, done) },
        )
    }
    boosting?.let { item ->
        BoostSheet(
            item = item,
            downloaders = ui.downloaders,
            onDismiss = { boosting = null },
            onSave = { budget, hold, downloaderId, done ->
                vm.setBoost(item, true, budget, hold, downloaderId) { err ->
                    if (err != null) {
                        done(err)
                    } else {
                        done(null)
                        feedback.success("已开启刷流")
                    }
                }
            },
        )
    }
    deleting?.let { item ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            containerColor = Color(0xFF171A23),
            title = { Text("删除「${vm.nameOf(item.siteId)}」的配置？", style = McType.bodySemibold, color = TextPrimary) },
            text = { Text("该站点将不再参与搜索与订阅投递，可随时重新接入。", style = McType.sub, color = TextMuted) },
            confirmButton = {
                TextButton(onClick = {
                    deleting = null
                    vm.delete(item) { err ->
                        if (err != null) feedback.error(err) else feedback.success("已删除站点配置")
                    }
                }) { Text("删除", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消", color = TextMuted) } },
        )
    }
}

@Composable
private fun SiteRow(
    item: ConfiguredSite,
    name: String,
    baseUrl: String?,
    downloaders: List<DownloaderView>,
    syncStats: SiteSyncStatsView?,
    boostStats: SiteBoostStatsView?,
    expanded: Boolean,
    busy: Boolean,
    onToggleExpand: () -> Unit,
    onEditAuth: () -> Unit,
    onToggleEnabled: () -> Unit,
    onToggleProtect: () -> Unit,
    onToggleBoost: () -> Unit,
    onBoostSettings: () -> Unit,
    onTogglePaused: () -> Unit,
    onVerify: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.alphaIfSite(!item.enabled)) {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onToggleExpand).padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (item.isProtected) {
                        Text("🛡", style = McType.caption, color = Color(0xFF8AB4F8))
                        Spacer(Modifier.width(4.dp))
                    }
                    Text(
                        name, style = McType.subheadlineSemibold, color = TextPrimary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                }
                Spacer(Modifier.height(2.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(7.dp).clip(CircleShape).background(siteStatusColor(item)))
                    Spacer(Modifier.width(4.dp))
                    Text(
                        siteStatusLabel(item), style = McType.caption, color = siteStatusColor(item),
                        maxLines = 1, softWrap = false,
                    )
                    if (!item.enabled) {
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "已停用", style = McType.caption, color = TextMuted,
                            maxLines = 1, softWrap = false,
                            modifier = Modifier.clip(RoundedCornerShape(999.dp))
                                .background(Color.White.copy(alpha = 0.08f))
                                .padding(horizontal = 6.dp, vertical = 1.dp),
                        )
                    }
                }
                Spacer(Modifier.height(3.dp))
                val tail = item.lastError?.takeIf { it.isNotBlank() }
                    ?: item.profile?.let { p ->
                        listOfNotNull(
                            p.username?.takeIf { it.isNotBlank() },
                            p.userClass?.takeIf { it.isNotBlank() },
                            p.uploadedBytes.takeIf { it > 0 }?.let { "上传 ${io.movieclaw.android.core.designsystem.McFormat.bytes(it)}" },
                        ).joinToString(" · ").ifBlank { null }
                    }
                    ?: baseUrl
                if (tail != null) {
                    Text(
                        tail, style = McType.caption,
                        color = if (item.lastError.isNullOrBlank()) TextFaint else Color(0xFFFF8A80),
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Text("编辑", style = McType.caption, color = Accent,
                modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.06f))
                    .clickable(enabled = !busy, onClick = onEditAuth).padding(horizontal = 10.dp, vertical = 5.dp))
            Spacer(Modifier.width(4.dp))
            Box {
                Text("⋯", style = McType.sub, color = TextMuted,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).clickable { menu = true }
                        .padding(horizontal = 10.dp, vertical = 4.dp))
                androidx.compose.material3.DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    SiteMenuItem(if (item.enabled) "停用站点" else "启用站点", !busy) { menu = false; onToggleEnabled() }
                    SiteMenuItem(if (item.isProtected) "取消保护" else "开启保护", !busy) { menu = false; onToggleProtect() }
                    SiteMenuItem(if (item.boostEnabled) "关闭刷流…" else "开启刷流…", !busy) { menu = false; onToggleBoost() }
                    if (item.boostEnabled) {
                        SiteMenuItem(if (item.boostPaused) "恢复刷流" else "暂停刷流", !busy) { menu = false; onTogglePaused() }
                        SiteMenuItem("刷流设置…", !busy) { menu = false; onBoostSettings() }
                    }
                    SiteMenuItem("编辑授权", !busy) { menu = false; onEditAuth() }
                    SiteMenuItem("重新验证", !busy && item.status != "pending" && item.status != "verifying") { menu = false; onVerify() }
                    SiteMenuItem("删除配置", !busy, danger = true) { menu = false; onDelete() }
                }
            }
        }
        if (expanded) {
            SiteExpandedDetails(
                item = item,
                downloaders = downloaders,
                syncStats = syncStats,
                boostStats = boostStats,
            )
        }
    }
}

/**
 * 展开详情：刷流 / 账号 / 索引 / 授权 四段（同 Web `SiteDetail`）。
 * 统计来自 `/sites/boost-stats` 与 `/sites/sync-stats`，缺数据时按零/占位展示。
 */
@Composable
private fun SiteExpandedDetails(
    item: ConfiguredSite,
    downloaders: List<DownloaderView>,
    syncStats: SiteSyncStatsView?,
    boostStats: SiteBoostStatsView?,
) {
    Column(Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.02f))) {
        if (item.boostEnabled) {
            DetailSection("刷流") {
                if (item.boostPaused) {
                    Text(
                        "已暂停：在池做种压到极低上传限速，停止汰换与拉新种（任务与数据保留）。可在 ⋯ 菜单里「恢复刷流」。",
                        style = McType.caption, color = Color(0xFFFFD180), lineHeight = 17.sp,
                    )
                    Spacer(Modifier.height(6.dp))
                }
                val boostDownloader = item.boostDownloaderId
                    ?.let { id -> downloaders.firstOrNull { it.id == id } }
                    ?: downloaders.firstOrNull { it.isDefault }
                if (boostDownloader != null && !boostDownloader.usable) {
                    Text(
                        "刷流下载器「${boostDownloader.name}」当前不可用（已停用或连接失败），该站暂停抢新种，下载器恢复后自动继续。",
                        style = McType.caption, color = Color(0xFFFFD180), lineHeight = 17.sp,
                    )
                    Spacer(Modifier.height(6.dp))
                }
                val evicted = boostStats?.evictedCount ?: 0
                StatGrid(
                    listOfNotNull(
                        "已用 / 预算" to "${bytesOf(boostStats?.usedBytes ?: 0)} / ${bytesOf(item.boostBudgetBytes)}",
                        "在池做种" to "${boostStats?.activeCount ?: 0}",
                        "累计上传" to bytesOf(boostStats?.uploadedBytesTotal ?: 0),
                        "汰换保留期" to (if ((item.boostHoldDays ?: 0) > 0) "${item.boostHoldDays} 天" else "不保护"),
                        if (downloaders.size > 1 || item.boostDownloaderId != null) {
                            "刷流下载器" to (
                                boostDownloader?.let { if (it.isDefault) "${it.name}（默认）" else it.name }
                                    ?: "—"
                                )
                        } else null,
                        if (evicted > 0) "已汰换" to evicted.toString() else null,
                    ),
                )
                val avg24 = boostStats?.avgUsedBytes24h ?: 0
                if (avg24 > 0) {
                    Spacer(Modifier.height(6.dp))
                    val week = boostStats?.avgUsedBytes7d ?: 0
                    Text(
                        "近 24 小时：${bytesOf(avg24)} 在池种子贡献了 ${bytesOf(boostStats?.uploadedBytes24h ?: 0)} 上传" +
                            if (week > 0) {
                                " · 近 7 天：${bytesOf(week)} 贡献 ${bytesOf(boostStats?.uploadedBytes7d ?: 0)}"
                            } else "",
                        style = McType.caption, color = TextMuted, lineHeight = 17.sp,
                    )
                }
            }
        }
        item.profile?.let { p ->
            DetailSection("账号") {
                StatGrid(
                    listOfNotNull(
                        "用户名" to (p.username?.takeIf { it.isNotBlank() } ?: "—"),
                        p.userClass?.takeIf { it.isNotBlank() }?.let { "等级" to it },
                        "做种" to p.seedingCount.toString(),
                        p.bonus?.let { "魔力" to compactNumber(it) },
                    ),
                )
                Spacer(Modifier.height(8.dp))
                StatGrid(
                    listOf(
                        "上传量" to bytesOf(p.uploadedBytes),
                        "下载量" to bytesOf(p.downloadedBytes),
                        "分享率" to (p.ratio?.let { "%.2f".format(it) } ?: "—"),
                    ),
                )
            }
        }
        syncStats?.let { s ->
            DetailSection("索引") {
                StatGrid(
                    listOfNotNull(
                        "已缓存种子" to s.torrentCount.toString(),
                        "上次同步" to (s.lastSyncAt?.let { relativeTime(it) } ?: "从未同步"),
                        "下次同步" to nextSyncLabel(s.nextSyncAt),
                        s.syncIntervalSeconds?.let { "同步间隔" to durationLabel(it) },
                    ),
                )
                s.lastError?.takeIf { it.isNotBlank() }?.let {
                    Spacer(Modifier.height(6.dp))
                    Text("上次同步失败：$it", style = McType.caption, color = Color(0xFFFF8A80), lineHeight = 17.sp)
                }
            }
        }
        DetailSection("授权") {
            Text(
                authLabel(item.authType) + " · 上次检查 " +
                    (item.lastCheckedAt?.takeIf { it.isNotBlank() }?.let { relativeTime(it) } ?: "—"),
                style = McType.sub, color = TextMuted, lineHeight = 20.sp,
            )
        }
        item.lastError?.takeIf { it.isNotBlank() }?.let {
            Text(
                it, style = McType.caption, color = Color(0xFFFF8A80),
                modifier = Modifier.padding(start = 14.dp, end = 14.dp, bottom = 10.dp),
            )
        }
    }
}

@Composable
private fun DetailSection(label: String, content: @Composable () -> Unit) {
    HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
    Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp)) {
        Text(label, style = McType.caption, color = TextMuted)
        Spacer(Modifier.height(6.dp))
        content()
    }
}

@Composable
private fun StatGrid(entries: List<Pair<String, String>>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        entries.chunked(2).forEach { chunk ->
            Row(Modifier.fillMaxWidth()) {
                chunk.forEach { (label, value) ->
                    Column(Modifier.weight(1f)) {
                        Text(label, style = McType.caption, color = TextFaint)
                        Text(
                            value, style = McType.sub, color = TextPrimary,
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                if (chunk.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

private fun bytesOf(value: Long): String =
    io.movieclaw.android.core.designsystem.McFormat.bytes(value)

private fun compactNumber(value: Double): String = when {
    value >= 1_000_000 -> "%.1fM".format(value / 1_000_000)
    value >= 10_000 -> "%.1f 万".format(value / 10_000)
    value >= 1_000 -> "%.1fK".format(value / 1_000)
    else -> "%.0f".format(value)
}

private fun parseInstant(iso: String?): java.time.Instant? {
    if (iso.isNullOrBlank()) return null
    return runCatching { java.time.OffsetDateTime.parse(iso).toInstant() }
        .recoverCatching { java.time.Instant.parse(iso) }
        .getOrNull()
}

private fun relativeTime(iso: String): String {
    val instant = parseInstant(iso) ?: return iso
    val secs = java.time.Duration.between(instant, java.time.Instant.now()).seconds
    return when {
        secs < 60 -> "刚刚"
        secs < 3600 -> "${secs / 60} 分钟前"
        secs < 86400 -> "${secs / 3600} 小时前"
        secs < 2592000 -> "${secs / 86400} 天前"
        else -> java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd")
            .withZone(java.time.ZoneId.systemDefault()).format(instant)
    }
}

private fun nextSyncLabel(iso: String?): String {
    if (iso == null) return "立即到期"
    val instant = parseInstant(iso) ?: return iso
    val secs = java.time.Duration.between(java.time.Instant.now(), instant).seconds
    return when {
        secs <= 0 -> "已到期"
        secs < 60 -> "不到 1 分钟后"
        secs < 3600 -> "${secs / 60} 分钟后"
        secs < 86400 -> "${secs / 3600} 小时后"
        else -> "${secs / 86400} 天后"
    }
}

private fun durationLabel(seconds: Int): String = when {
    seconds < 60 -> "$seconds 秒"
    seconds < 3600 -> "${seconds / 60} 分钟"
    seconds < 86400 -> "${seconds / 3600} 小时"
    else -> "${seconds / 86400} 天"
}

@Composable
private fun SiteMenuItem(text: String, enabled: Boolean, danger: Boolean = false, onClick: () -> Unit) {
    androidx.compose.material3.DropdownMenuItem(
        text = {
            Text(text, style = McType.sub, color = when {
                !enabled -> TextFaint
                danger -> Danger
                else -> TextPrimary
            })
        },
        enabled = enabled,
        onClick = onClick,
    )
}

private fun Modifier.alphaIfSite(dim: Boolean): Modifier =
    if (dim) this.alpha(0.6f) else this

private fun authLabel(authType: String): String = when (authType) {
    "cookie" -> "Cookie"
    "apikey" -> "API 密钥"
    "credential" -> "用户名密码"
    else -> authType
}

private fun authLabelOf(site: SiteCatalogItem): String =
    site.supportedAuthTypes.joinToString(" / ") { authLabel(it.authType) }.ifBlank { "Cookie" }

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun AddSiteSheet(
    catalog: List<SiteCatalogItem>,
    configured: Set<String>,
    onDismiss: () -> Unit,
    onSave: (SiteConfigCreate, (String?) -> Unit) -> Unit,
) {
    var q by remember { mutableStateOf("") }
    var picked by remember { mutableStateOf<SiteCatalogItem?>(null) }
    val remaining = catalog.filter { it.siteId !in configured }
    val rows = remember(q, remaining) {
        if (q.isBlank()) remaining
        else remaining.filter {
            it.displayName.contains(q, true) || it.siteId.contains(q, true) || it.baseUrl.orEmpty().contains(q, true)
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().heightIn(max = 640.dp).formSheetScroll().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp)) {
            Text(if (picked == null) "添加站点" else picked!!.displayName, style = McType.title3, color = TextPrimary)
            Spacer(Modifier.height(6.dp))
            if (picked == null) {
                TextField(
                    value = q,
                    onValueChange = { q = it },
                    singleLine = true,
                    placeholder = { Text("搜索站点名称 / 地址", style = McType.caption, color = TextFaint) },
                    modifier = Modifier.fillMaxWidth(),
                )
                if (remaining.isEmpty()) {
                    Text("所有支持的站点都已配置。", style = McType.footnote, color = TextMuted, modifier = Modifier.padding(vertical = 12.dp))
                } else if (rows.isEmpty()) {
                    Text("没有匹配「$q」的站点。", style = McType.footnote, color = TextMuted, modifier = Modifier.padding(vertical = 12.dp))
                } else {
                    rows.take(30).forEach { site ->
                        Row(
                            Modifier.fillMaxWidth().clickable { picked = site }.padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(site.displayName, style = McType.sub, color = TextPrimary)
                                Text(site.baseUrl.orEmpty(), style = McType.caption, color = TextFaint)
                            }
                            Text(authLabelOf(site), style = McType.caption, color = TextMuted)
                        }
                    }
                }
            } else {
                val site = picked!!
                Text(site.baseUrl.orEmpty(), style = McType.caption, color = TextFaint)
                Spacer(Modifier.height(8.dp))
                Text("重新选择", style = McType.caption, color = Accent,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.06f))
                        .clickable { picked = null }.padding(horizontal = 10.dp, vertical = 5.dp))
                Spacer(Modifier.height(10.dp))
                SiteAuthForm(
                    options = site.supportedAuthTypes,
                    initialAuthType = site.supportedAuthTypes.firstOrNull()?.authType ?: "cookie",
                    editing = false,
                    enabled = true,
                    saveLabel = "保存并验证",
                    onCancel = onDismiss,
                    onSave = { authType, cookie, apiKey, username, password, enabled, done ->
                        onSave(SiteConfigCreate(
                            siteId = site.siteId,
                            authType = authType,
                            cookie = cookie,
                            apiKey = apiKey,
                            username = username,
                            password = password,
                            enabled = enabled,
                        ), done)
                    },
                )
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun SiteAuthSheet(
    site: ConfiguredSite,
    displayName: String,
    options: List<io.movieclaw.android.core.model.AuthTypeRequirement>,
    onDismiss: () -> Unit,
    onSave: (SiteConfigUpdate, (String?) -> Unit) -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().formSheetScroll().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp)) {
            Text("编辑「$displayName」的授权", style = McType.title3, color = TextPrimary)
            Spacer(Modifier.height(8.dp))
            SiteAuthForm(
                options = options,
                initialAuthType = site.authType,
                editing = true,
                enabled = site.enabled,
                saveLabel = "保存并重新验证",
                onCancel = onDismiss,
                onSave = { authType, cookie, apiKey, username, password, enabled, done ->
                    onSave(SiteConfigUpdate(
                        authType = authType,
                        cookie = cookie,
                        apiKey = apiKey,
                        username = username,
                        password = password,
                        enabled = enabled,
                    ), done)
                },
            )
            Spacer(Modifier.height(12.dp))
        }
    }
}

/**
 * 授权表单：只列站点支持的授权方式（多于一种才给切换），字段按该方式的 required_fields 渲染
 * —— cookie 多行 / API Key / 用户名密码（同 Web `SiteForm`；编辑时敏感字段一律重填）。
 */
@Composable
private fun SiteAuthForm(
    options: List<io.movieclaw.android.core.model.AuthTypeRequirement>,
    initialAuthType: String,
    editing: Boolean,
    enabled: Boolean,
    saveLabel: String,
    onCancel: () -> Unit,
    onSave: (String, String?, String?, String?, String?, Boolean, (String?) -> Unit) -> Unit,
) {
    val effective = remember(options) {
        options.ifEmpty {
            listOf(io.movieclaw.android.core.model.AuthTypeRequirement("cookie", listOf("cookie")))
        }
    }
    var authType by remember {
        mutableStateOf(
            effective.firstOrNull { it.authType == initialAuthType }?.authType ?: effective.first().authType,
        )
    }
    var cookie by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    val current = effective.firstOrNull { it.authType == authType } ?: effective.first()
    val fallbackFields = when (authType) {
        "cookie" -> listOf("cookie")
        "apikey" -> listOf("api_key")
        else -> listOf("username", "password")
    }
    val knownFields = setOf("cookie", "api_key", "username", "password")
    val fields = current.requiredFields.filter { it in knownFields }.ifEmpty { fallbackFields }
    fun valueOf(field: String): String = when (field) {
        "cookie" -> cookie
        "api_key" -> apiKey
        "username" -> username
        "password" -> password
        else -> ""
    }

    if (effective.size > 1) {
        Text("授权方式", style = McType.caption, color = TextFaint)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            effective.forEach { opt ->
                val sel = opt.authType == authType
                Text(
                    authLabel(opt.authType), style = McType.caption,
                    color = if (sel) Color(0xFF141821) else TextMuted,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(if (sel) Accent else Color.White.copy(alpha = 0.06f))
                        .clickable { authType = opt.authType; error = null }
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        }
        Spacer(Modifier.height(8.dp))
    }

    fields.forEach { field ->
        when (field) {
            "cookie" -> {
                Text("Cookie 字符串", style = McType.caption, color = TextFaint)
                TextField(
                    value = cookie, onValueChange = { cookie = it },
                    placeholder = {
                        Text(
                            if (editing) "出于安全，请重新填写" else "粘贴站点的 Cookie",
                            style = McType.caption, color = TextFaint,
                        )
                    },
                    minLines = 3, maxLines = 4, modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "手动粘贴的 Cookie 过期后需重填；推荐用 MovieClaw 浏览器扩展自动同步。",
                    style = McType.caption, color = TextFaint, lineHeight = 17.sp,
                )
            }
            "api_key" -> {
                Text("API 密钥", style = McType.caption, color = TextFaint)
                TextField(
                    value = apiKey, onValueChange = { apiKey = it }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    placeholder = {
                        Text(
                            if (editing) "出于安全，请重新填写" else "粘贴 API 密钥",
                            style = McType.caption, color = TextFaint,
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            "username" -> {
                Text("用户名", style = McType.caption, color = TextFaint)
                TextField(
                    value = username, onValueChange = { username = it }, singleLine = true,
                    placeholder = {
                        Text(
                            if (editing) "出于安全，请重新填写" else "站点账号",
                            style = McType.caption, color = TextFaint,
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            "password" -> {
                Text("密码", style = McType.caption, color = TextFaint)
                TextField(
                    value = password, onValueChange = { password = it }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    placeholder = {
                        Text(
                            if (editing) "出于安全，请重新填写" else "站点密码",
                            style = McType.caption, color = TextFaint,
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
    error?.let {
        Spacer(Modifier.height(6.dp))
        Text(it, style = McType.caption, color = Color(0xFFFF8A80))
    }
    Spacer(Modifier.height(10.dp))
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onCancel, enabled = !busy) { Text("取消", color = TextMuted) }
        Spacer(Modifier.weight(1f))
        Button(
            enabled = !busy && fields.isNotEmpty() && fields.all { valueOf(it).isNotBlank() },
            onClick = {
                busy = true
                error = null
                onSave(
                    authType,
                    cookie.trim().ifEmpty { null },
                    apiKey.trim().ifEmpty { null },
                    username.trim().ifEmpty { null },
                    password.ifEmpty { null },
                    enabled,
                ) { err ->
                    busy = false
                    if (err != null) error = err else onCancel()
                }
            },
            colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF141821)),
            shape = RoundedCornerShape(999.dp),
        ) {
            if (busy) {
                CircularProgressIndicator(color = Color(0xFF141821), strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(8.dp))
            }
            Text(if (busy) "保存中…" else saveLabel, fontSize = 14.sp)
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun BoostSheet(
    item: ConfiguredSite,
    downloaders: List<DownloaderView>,
    onDismiss: () -> Unit,
    onSave: (budgetBytes: Long, holdDays: Int, downloaderId: Long?, done: (String?) -> Unit) -> Unit,
) {
    var budget by remember { mutableStateOf(((item.boostBudgetBytes + (1 shl 30) - 1) shr 30).coerceAtLeast(1).toString()) }
    var hold by remember { mutableStateOf((item.boostHoldDays ?: 0).toString()) }
    var downloaderId by remember { mutableStateOf(item.boostDownloaderId) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    ModalBottomSheet(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().formSheetScroll().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp)) {
            Text(
                if (item.boostEnabled) "刷流设置 · " + item.siteId else "开启自动刷分享率",
                style = McType.title3, color = TextPrimary,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                if (item.boostEnabled) "调小预算会按上传效率从低到高汰换在池任务（连数据删除），保留期内的任务不会被提前删除。"
                else "开启后将自动抢该站新发布的免费种子做种以提升分享率，占用空间在预算内自动汰换；该站索引同步会提速到约 5 分钟一次。",
                style = McType.caption, color = TextMuted, lineHeight = 18.sp,
            )
            Spacer(Modifier.height(8.dp))
            Text("存储预算（GiB）", style = McType.caption, color = TextFaint)
            TextField(value = budget, onValueChange = { budget = it.filter { c -> c.isDigit() }.take(4) }, singleLine = true,
                placeholder = { Text("1", style = McType.caption, color = TextFaint) },
                modifier = Modifier.fillMaxWidth())
            Text("汰换保留期（天）", style = McType.caption, color = TextFaint)
            TextField(value = hold, onValueChange = { hold = it.filter { c -> c.isDigit() }.take(2) }, singleLine = true,
                placeholder = { Text("0", style = McType.caption, color = TextFaint) },
                modifier = Modifier.fillMaxWidth())
            Text("H&R 安全垫：有考核的站不小于考核时长；无考核可调 0 自由汰换。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp)
            if (downloaders.size > 1) {
                Spacer(Modifier.height(8.dp))
                Text("刷流下载器", style = McType.caption, color = TextFaint)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    downloaders.filter { it.enabled }.forEach { d ->
                        val sel = downloaderId == d.id
                        Text(
                            d.name + if (d.isDefault) "（默认）" else "", style = McType.caption,
                            color = if (sel) Color(0xFF141821) else TextMuted,
                            modifier = Modifier.clip(RoundedCornerShape(999.dp))
                                .background(if (sel) Accent else Color.White.copy(alpha = 0.06f))
                                .clickable { downloaderId = d.id }
                                .padding(horizontal = 10.dp, vertical = 5.dp),
                        )
                    }
                }
            }
            error?.let { Spacer(Modifier.height(6.dp)); Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }
            Spacer(Modifier.height(10.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss, enabled = !busy) { Text("取消", color = TextMuted) }
                Spacer(Modifier.weight(1f))
                Button(
                    enabled = !busy && (budget.toIntOrNull() ?: 0) >= 1,
                    onClick = {
                        scope.launch {
                            busy = true
                            error = null
                            onSave(
                                (budget.toLongOrNull() ?: 1L) * (1L shl 30),
                                hold.toIntOrNull() ?: 0,
                                downloaderId,
                            ) { err ->
                                busy = false
                                if (err == null) onDismiss() else error = err
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF141821)),
                    shape = RoundedCornerShape(999.dp),
                ) { Text(if (item.boostEnabled) "保存" else "开启刷流", fontSize = 14.sp) }
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

