package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
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
import io.movieclaw.android.core.designsystem.DirectoryPickerSheet
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.ClaimPayload
import io.movieclaw.android.core.model.DiscoveredTitle
import io.movieclaw.android.core.model.DownloaderView
import io.movieclaw.android.core.model.FsBrowseView
import io.movieclaw.android.core.model.ImportWatchPayload
import io.movieclaw.android.core.model.ImportWatchView
import io.movieclaw.android.core.model.IngestEntriesView
import io.movieclaw.android.core.model.IngestEntryView
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.TitleSearchRequest
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import io.movieclaw.android.core.designsystem.formSheetScroll

/*
 * 设置 → 自动入库（原生页，参照移动网页端 `import-watch-section.tsx`，服务端 routes/import_watch.py）：
 * 规则列表（源目录 / 硬链接或复制 / 目标 / 台账计数）+ 新增编辑（源目录、策略、目标三态、存量）
 * + 台账清单（待处理 / 失败 / 已入库 / 已忽略，认领 / 忽略 / 恢复）。
 */

private val ENTRY_TABS = listOf(
    "pending" to "待处理",
    "failed" to "失败",
    "imported" to "已入库",
    "ignored" to "已忽略",
)

/** 认领确认所需的最小信息（搜索结果或直接粘贴的 TMDB ID） */
private data class ClaimSeed(val tmdbId: Long, val title: String, val year: Int? = null)

@HiltViewModel
class ImportWatchViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val error: String? = null,
        val rules: List<ImportWatchView> = emptyList(),
        val libraries: List<LibraryView> = emptyList(),
        val downloaders: List<DownloaderView> = emptyList(),
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui.asStateFlow()
    private fun api() = repository.ui.value.origin?.let { apiFactory.forOrigin(it) }

    init { load() }

    fun load() {
        viewModelScope.launch {
            val api = api() ?: run {
                _ui.value = _ui.value.copy(loading = false, error = "还没有连上服务器")
                return@launch
            }
            _ui.value = _ui.value.copy(loading = true, error = null)
            val libs = runCatching { api.libraries().dataOrThrow() }.getOrDefault(emptyList())
            // 下载器目录只是表单的快捷候选，拉取失败静默降级（同网页）
            val dls = runCatching { api.downloaders().dataOrThrow() }.getOrDefault(emptyList())
            runCatching { api.importWatch().dataOrThrow() }
                .onSuccess {
                    _ui.value = Ui(loading = false, rules = it, libraries = libs, downloaders = dls)
                }
                .onFailure {
                    _ui.value = _ui.value.copy(
                        loading = false, libraries = libs, downloaders = dls,
                        error = it.message ?: "自动入库配置加载失败",
                    )
                }
        }
    }

    suspend fun browse(path: String?): FsBrowseView {
        val api = api() ?: throw IllegalStateException("尚未连接服务器")
        return api.fsBrowse(path).dataOrThrow()
    }

    fun save(editingId: Long?, payload: ImportWatchPayload, onDone: (String?) -> Unit) {
        viewModelScope.launch {
            val api = api() ?: return@launch onDone("还没有连上服务器")
            runCatching {
                if (editingId == null) api.createImportWatch(payload).dataOrThrow()
                else api.updateImportWatch(editingId, payload).dataOrThrow()
            }.onSuccess { onDone(null); load() }
                .onFailure { onDone(it.message ?: "保存失败，请稍后重试") }
        }
    }

    fun delete(item: ImportWatchView, onDone: (String?) -> Unit) {
        viewModelScope.launch {
            val api = api() ?: return@launch onDone("还没有连上服务器")
            runCatching { api.deleteImportWatch(item.id).dataOrThrow() }
                .onSuccess {
                    _ui.value = _ui.value.copy(rules = _ui.value.rules.filterNot { it.id == item.id })
                    onDone(null)
                }
                .onFailure { onDone(it.message ?: "删除失败，请稍后重试") }
        }
    }

    suspend fun entries(ruleId: Long, status: String?): Result<IngestEntriesView> {
        val api = api() ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { api.importWatchEntries(ruleId, status).dataOrThrow() }
    }

    suspend fun ignore(entryId: Long): Result<IngestEntryView> {
        val api = api() ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { api.ignoreIngestEntry(entryId).dataOrThrow() }
    }

    suspend fun restore(entryId: Long): Result<IngestEntryView> {
        val api = api() ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { api.restoreIngestEntry(entryId).dataOrThrow() }
    }

    suspend fun claim(entryId: Long, tmdbId: Long, entryFile: String?): Result<IngestEntryView> {
        val api = api() ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            api.claimIngestEntry(entryId, ClaimPayload(tmdbId = tmdbId, entryFile = entryFile)).dataOrThrow()
        }
    }

    suspend fun search(query: String): Result<List<DiscoveredTitle>> {
        val api = api() ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            api.searchTitles(TitleSearchRequest(query = query, provider = "tmdb", saveHistory = false))
                .dataOrThrow().titles
        }
    }
}

@Composable
fun ImportWatchScreen(onBack: () -> Unit, vm: ImportWatchViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val feedback = LocalFeedback.current
    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<ImportWatchView?>(null) }
    var deleting by remember { mutableStateOf<ImportWatchView?>(null) }

    Column(Modifier.fillMaxSize().background(Bg)) {
        SettingsTopBar(title = "自动入库", onBack = onBack)
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Spacer(Modifier.height(2.dp))
            Text(
                "监听下载目录，其中下载完成的内容（下载器确认完成，或文件持续静默且探测通过）自动识别、按「标题 (年份)」规范命名搬进目标媒体库或你指定的自定义目录。源文件原地保留：硬链接零占用、可继续做种；复制适合跨盘。把下载器的保存目录设为这里的源目录，即可实现「下载完成自动整理入库」。",
                style = McType.caption, color = TextMuted, lineHeight = 19.sp,
            )
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
                Column(Modifier.weight(1f)) {
                    Text("自动入库规则", style = McType.title3, color = TextPrimary)
                    if (ui.rules.isNotEmpty()) {
                        Spacer(Modifier.height(3.dp))
                        Text("${ui.rules.size} 条规则", style = McType.caption, color = TextFaint)
                    }
                }
                Text(
                    "＋ 添加规则", style = McType.caption, color = Color(0xFF141821),
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(Accent)
                        .clickable { creating = true }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                )
            }
            ui.error?.let { message ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(message, style = McType.caption, color = Color(0xFFFF8A80), modifier = Modifier.weight(1f))
                    Text(
                        "重试", style = McType.caption, color = Accent,
                        modifier = Modifier.clip(RoundedCornerShape(999.dp))
                            .background(Color.White.copy(alpha = 0.06f))
                            .clickable { vm.load() }
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                    )
                }
            }

            when {
                ui.loading && ui.rules.isEmpty() -> {
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 16.dp),
                        horizontalArrangement = Arrangement.Center,
                    ) {
                        CircularProgressIndicator(color = TextMuted, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                    }
                }
                ui.rules.isEmpty() && ui.error == null -> {
                    GlassCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(18.dp)) {
                            Text("还没有自动入库规则", style = McType.subheadlineSemibold, color = TextPrimary)
                            Spacer(Modifier.height(4.dp))
                            Text(
                                "不需要「下载区 → 库」自动搬运的话，这里保持为空即可。",
                                style = McType.footnote, color = TextMuted,
                            )
                        }
                    }
                }
                ui.rules.isNotEmpty() -> {
                    GlassCard(Modifier.fillMaxWidth()) {
                        Column {
                            ui.rules.forEachIndexed { index, rule ->
                                val kind = if (rule.libraryId != null) {
                                    ui.libraries.find { it.id == rule.libraryId }?.kind
                                } else rule.kind
                                RuleCard(
                                    rule = rule,
                                    movie = (kind ?: "movie") == "movie",
                                    onEdit = { editing = rule },
                                    onDelete = { deleting = rule },
                                    entries = { status -> vm.entries(rule.id, status) },
                                    ignore = { id -> vm.ignore(id) },
                                    restore = { id -> vm.restore(id) },
                                    claim = { id, tmdb, file -> vm.claim(id, tmdb, file) },
                                    search = { q -> vm.search(q) },
                                    onStatsChanged = { vm.load() },
                                )
                                if (index != ui.rules.lastIndex) HorizontalDivider(color = LineSoft)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(28.dp))
        }
    }

    if (creating || editing != null) {
        RuleSheet(
            rule = editing,
            libraries = ui.libraries,
            downloaders = ui.downloaders,
            browse = { vm.browse(it) },
            onDismiss = { creating = false; editing = null },
            onSave = { payload, done -> vm.save(editing?.id, payload, done) },
        )
    }
    deleting?.let { rule ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            containerColor = Color(0xFF171A23),
            title = { Text("删除对 ${rule.sourcePath} 的监听？", style = McType.bodySemibold, color = TextPrimary) },
            text = { Text("源目录与已导入的文件都不受影响，只是停止监听。", style = McType.body, color = TextMuted) },
            confirmButton = {
                TextButton(onClick = {
                    deleting = null
                    vm.delete(rule) { err ->
                        if (err != null) feedback.error(err) else feedback.success("已删除")
                    }
                }) { Text("删除", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消", color = TextMuted) } },
        )
    }
}

@Composable
private fun RuleCard(
    rule: ImportWatchView,
    movie: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    entries: suspend (String) -> Result<IngestEntriesView>,
    ignore: suspend (Long) -> Result<IngestEntryView>,
    restore: suspend (Long) -> Result<IngestEntryView>,
    claim: suspend (Long, Long, String?) -> Result<IngestEntryView>,
    search: suspend (String) -> Result<List<DiscoveredTitle>>,
    onStatsChanged: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    var openTab by remember { mutableStateOf<String?>(null) }
    val stats = rule.stats
    val total = ENTRY_TABS.sumOf { (key, _) -> stats[key] ?: 0 }

    Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    rule.sourcePath, style = McType.sub.copy(fontFamily = FontFamily.Monospace),
                    color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    (if (rule.strategy == "hardlink") "硬链接" else "复制") + " → " + rule.targetLabel +
                        if (!rule.processExisting) "（跳过存量）" else "",
                    style = McType.caption, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            Box {
                Text(
                    "⋯", style = McType.body, color = TextMuted,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).clickable { menu = true }
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                )
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text("编辑", style = McType.body, color = TextPrimary) },
                        onClick = { menu = false; onEdit() },
                    )
                    DropdownMenuItem(
                        text = { Text("删除", style = McType.body, color = Danger) },
                        onClick = { menu = false; onDelete() },
                    )
                }
            }
        }
        if (total > 0) {
            HorizontalDivider(color = LineSoft, modifier = Modifier.padding(vertical = 8.dp))
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                ENTRY_TABS.filter { (stats[it.first] ?: 0) > 0 }.forEach { (key, label) ->
                    PickerChip(label = labelCount(rule, stats, key, label), selected = openTab == key) {
                        openTab = if (openTab == key) null else key
                    }
                }
            }
        }
        openTab?.let { status ->
            RuleEntriesPanel(
                rule = rule,
                status = status,
                movie = movie,
                entries = entries,
                ignore = ignore,
                restore = restore,
                claim = claim,
                search = search,
                onStatsChanged = onStatsChanged,
            )
        }
    }
}

/** 已入库报作品数（同剧多季/多版本算一部）；条目数与作品数不同再补注规模 */
private fun labelCount(rule: ImportWatchView, stats: Map<String, Int>, key: String, label: String): String {
    val count = stats[key] ?: 0
    if (key != "imported" || rule.importedWorks <= 0) return "$label $count"
    val extra = if (rule.importedFiles > 0 && count > rule.importedWorks) {
        "（$count 个条目 · ${rule.importedFiles} 个文件）"
    } else ""
    return "$label ${rule.importedWorks} 部$extra"
}

@Composable
private fun RuleEntriesPanel(
    rule: ImportWatchView,
    status: String,
    movie: Boolean,
    entries: suspend (String) -> Result<IngestEntriesView>,
    ignore: suspend (Long) -> Result<IngestEntryView>,
    restore: suspend (Long) -> Result<IngestEntryView>,
    claim: suspend (Long, Long, String?) -> Result<IngestEntryView>,
    search: suspend (String) -> Result<List<DiscoveredTitle>>,
    onStatsChanged: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var data by remember(rule.id, status) { mutableStateOf<IngestEntriesView?>(null) }
    var failed by remember(rule.id, status) { mutableStateOf(false) }

    suspend fun reloadNow() {
        entries(status)
            .onSuccess { data = it; failed = false }
            .onFailure { failed = true }
    }
    LaunchedEffect(rule.id, status) {
        data = null
        failed = false
        reloadNow()
    }

    Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        val current = data
        when {
            failed -> Text("清单加载失败，请重试。", style = McType.caption, color = TextMuted)
            current == null -> Text("加载中…", style = McType.caption, color = TextFaint)
            current.entries.isEmpty() -> Text("该状态下暂无条目。", style = McType.caption, color = TextFaint)
            else -> {
                if (status == "pending") {
                    Text(
                        "这些条目无法自动识别，不会重复尝试也不会报错：搜索认领后立即整理入库；确认不需要整理的（花絮、自录、其他工具管理的内容）可忽略。",
                        style = McType.caption, color = TextFaint, lineHeight = 17.sp,
                    )
                }
                current.entries.forEach { entry ->
                    EntryRow(
                        entry = entry,
                        movie = movie,
                        ignore = ignore,
                        restore = restore,
                        claim = claim,
                        search = search,
                        onChanged = {
                            scope.launch { reloadNow() }
                            onStatsChanged()
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun EntryRow(
    entry: IngestEntryView,
    movie: Boolean,
    ignore: suspend (Long) -> Result<IngestEntryView>,
    restore: suspend (Long) -> Result<IngestEntryView>,
    claim: suspend (Long, Long, String?) -> Result<IngestEntryView>,
    search: suspend (String) -> Result<List<DiscoveredTitle>>,
    onChanged: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // null=关闭；ClaimSeed=确认面板
    var panel by remember { mutableStateOf<ClaimSeed?>(null) }
    var searchOpen by remember { mutableStateOf(false) }
    var claimFile by remember { mutableStateOf<String?>(null) }

    val actionable = entry.status == "pending" || entry.status == "failed"
    // 电影合集：已认出的已入库，剩下识别不出的视频逐个认领；整条认领会钉成同一部片，所以不给条目级认领
    val unresolved = if (actionable) entry.unresolvedFiles else emptyList()

    fun act(fn: suspend () -> Result<*>) {
        scope.launch {
            busy = true
            error = null
            fn()
                .onSuccess {
                    panel = null
                    searchOpen = false
                    claimFile = null
                    onChanged()
                }
                .onFailure { error = it.message ?: "操作失败" }
            busy = false
        }
    }

    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(Color.White.copy(alpha = 0.03f))
            .padding(horizontal = 10.dp, vertical = 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                entry.name, style = McType.sub.copy(fontFamily = FontFamily.Monospace),
                color = TextPrimary.copy(alpha = 0.9f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (actionable && unresolved.isEmpty()) {
                Text(
                    "认领", style = McType.caption, color = if (searchOpen) TextPrimary else Accent,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = if (searchOpen) 0.14f else 0.05f))
                        .clickable(enabled = !busy) {
                            searchOpen = !searchOpen
                            panel = null
                            claimFile = null
                        }
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
            if (actionable) {
                Spacer(Modifier.width(6.dp))
                Text(
                    "忽略", style = McType.caption, color = TextMuted,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).clickable(enabled = !busy) {
                        act { ignore(entry.id) }
                    }.padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
            if (entry.status == "ignored") {
                Text(
                    "恢复处理", style = McType.caption, color = Accent,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.05f))
                        .clickable(enabled = !busy) { act { restore(entry.id) } }
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
        }
        entry.message?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = McType.caption, color = TextFaint, maxLines = 2, lineHeight = 16.sp)
        }
        unresolved.forEach { file ->
            val open = searchOpen && claimFile == file && panel == null
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 3.dp)) {
                Text(
                    file, style = McType.caption.copy(fontFamily = FontFamily.Monospace),
                    color = TextPrimary.copy(alpha = 0.7f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    "认领", style = McType.caption, color = if (open) TextPrimary else Accent,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = if (open) 0.14f else 0.05f))
                        .clickable(enabled = !busy) {
                            searchOpen = true
                            panel = null
                            claimFile = file
                        }
                        .padding(horizontal = 10.dp, vertical = 3.dp),
                )
            }
        }
        error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80), modifier = Modifier.padding(top = 3.dp)) }

        if (searchOpen && panel == null) {
            ClaimSearch(
                movie = movie,
                initialQuery = searchSeedFromLabel(
                    claimFile?.substringAfterLast('/')?.substringBeforeLast('.') ?: entry.name,
                ),
                search = search,
                onPick = { seed -> panel = seed },
            )
        }
        panel?.let { seed ->
            ClaimConfirm(
                seed = seed,
                movie = movie,
                busy = busy,
                onCancel = { panel = null },
                onConfirm = { act { claim(entry.id, seed.tmdbId, claimFile) } },
            )
        }
    }
}

/** 组名/条目名 → 搜索词：去掉 [tmdbid=…] 等标记块与尾部年份括号（同 Web `searchSeedFromLabel`） */
private fun searchSeedFromLabel(label: String): String =
    Regex("[[{][^\\]}]*[\\]}]").replace(label, " ")
        .replace(Regex("\\((?:18|19|20)\\d{2}\\)\\s*$"), "")
        .replace(Regex("\\s+"), " ")
        .trim()

/**
 * TMDB 搜索面板：候选全不对时按片名检索；直接粘一串数字则按 ID 认领。
 * 认领只关心本条目类型（movie / tv），多类型混排的结果先过滤。
 */
@Composable
private fun ClaimSearch(
    movie: Boolean,
    initialQuery: String,
    search: suspend (String) -> Result<List<DiscoveredTitle>>,
    onPick: (ClaimSeed) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf(initialQuery) }
    var results by remember { mutableStateOf<List<DiscoveredTitle>?>(null) }
    var searching by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val idOnly = query.trim().toLongOrNull() != null && query.trim().length <= 10
    val kind = if (movie) "movie" else "tv"

    fun runSearch() {
        val q = query.trim()
        if (q.isEmpty() || idOnly) return
        scope.launch {
            searching = true
            error = null
            search(q)
                .onSuccess { list -> results = list.filter { it.mediaType == null || it.mediaType == kind } }
                .onFailure { results = null; error = it.message }
            searching = false
        }
    }

    Column(
        Modifier.fillMaxWidth().padding(top = 8.dp).clip(RoundedCornerShape(10.dp))
            .background(Color.White.copy(alpha = 0.03f)).padding(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextField(
                value = query, onValueChange = { query = it }, singleLine = true,
                placeholder = { Text("片名关键词，或直接粘 TMDB ID", style = McType.caption, color = TextFaint) },
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(6.dp))
            if (idOnly) {
                Text(
                    "查看该 ID", style = McType.caption, color = Color(0xFF141821),
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Accent)
                        .clickable {
                            val id = query.trim().toLongOrNull() ?: return@clickable
                            onPick(ClaimSeed(tmdbId = id, title = "TMDB #$id"))
                        }
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            } else {
                Text(
                    if (searching) "搜索中…" else "搜索", style = McType.caption,
                    color = if (searching || query.isBlank()) TextMuted else Accent,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.05f))
                        .clickable(enabled = !searching && query.isNotBlank()) { runSearch() }
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        }
        error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80), modifier = Modifier.padding(top = 4.dp)) }
        val list = results
        when {
            list == null -> Unit
            list.isEmpty() -> Text(
                "没有找到" + (if (movie) "电影" else "剧集") +
                    "结果，换个关键词试试（TMDB 对中文名支持有限时可试英文/原名）。确认 TMDB 没收录的话，可以去 TMDB 补录该条目——它是维基式社区库，收录后回来搜索或粘 ID 即可认领。",
                style = McType.caption, color = TextMuted, lineHeight = 16.sp,
                modifier = Modifier.padding(top = 6.dp),
            )
            else -> Column(
                Modifier.heightIn(max = 210.dp).verticalScroll(rememberScrollState()).padding(top = 4.dp),
            ) {
                list.take(20).forEach { item ->
                    val tmdbId = item.titleRef.split(':').lastOrNull()?.toLongOrNull()
                        ?: item.externalId.toLongOrNull()
                    Row(
                        Modifier.fillMaxWidth()
                            .clickable(enabled = tmdbId != null) {
                                tmdbId?.let { onPick(ClaimSeed(it, item.title, item.releaseYear)) }
                            }
                            .padding(vertical = 7.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                item.title, style = McType.sub, color = TextPrimary,
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                listOfNotNull(
                                    item.releaseYear?.toString(),
                                    item.mediaType?.let { if (it == "tv") "剧集" else "电影" },
                                ).joinToString(" · "),
                                style = McType.caption, color = TextMuted,
                            )
                        }
                        if (item.providerRating > 0) {
                            Text("★ %.1f".format(item.providerRating), style = McType.caption, color = TextFaint)
                        }
                    }
                }
            }
        }
    }
}

/** 认领确认：点候选先看清楚是谁再点认领（同名双版本只看名字不够） */
@Composable
private fun ClaimConfirm(
    seed: ClaimSeed,
    movie: Boolean,
    busy: Boolean,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
) {
    val uri = LocalUriHandler.current
    Column(
        Modifier.fillMaxWidth().padding(top = 8.dp).clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.03f)).padding(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                seed.title, style = McType.bodySemibold, color = TextPrimary,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
            )
            seed.year?.let { Text(" $it", style = McType.sub, color = TextMuted) }
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 6.dp)) {
            Text(
                "在 TMDB 打开核对 ↗", style = McType.caption, color = TextMuted,
                modifier = Modifier.clickable {
                    uri.openUri("https://www.themoviedb.org/${if (movie) "movie" else "tv"}/${seed.tmdbId}")
                },
            )
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onCancel, enabled = !busy) { Text("取消", color = TextMuted) }
            Button(
                onClick = onConfirm, enabled = !busy,
                colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF141821)),
                shape = RoundedCornerShape(999.dp),
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp),
            ) {
                if (busy) {
                    CircularProgressIndicator(color = Color(0xFF141821), strokeWidth = 2.dp, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.width(6.dp))
                }
                Text("认领", fontSize = 13.sp)
            }
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun RuleSheet(
    rule: ImportWatchView?,
    libraries: List<LibraryView>,
    downloaders: List<DownloaderView>,
    browse: suspend (String?) -> FsBrowseView,
    onDismiss: () -> Unit,
    onSave: (ImportWatchPayload, (String?) -> Unit) -> Unit,
) {
    var source by remember { mutableStateOf(rule?.sourcePath.orEmpty()) }
    var strategy by remember { mutableStateOf(rule?.strategy ?: "hardlink") }
    var processExisting by remember { mutableStateOf(rule?.processExisting ?: true) }
    // 目标三态：lib:<id> / auto:<movie|tv|video> / path（自定义目录，配 pathKind）
    var target by remember {
        mutableStateOf(
            when {
                rule?.libraryId != null -> "lib:${rule.libraryId}"
                rule?.targetPath != null -> "path"
                rule?.kind != null -> "auto:${rule.kind}"
                libraries.isNotEmpty() -> "lib:${libraries.first().id}"
                else -> "auto:movie"
            },
        )
    }
    var pathKind by remember { mutableStateOf(rule?.kind ?: "movie") }
    var targetPath by remember { mutableStateOf(rule?.targetPath.orEmpty()) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var pickingSource by remember { mutableStateOf(false) }
    var pickingTarget by remember { mutableStateOf(false) }
    val quickDirs = remember(downloaders) {
        buildList {
            downloaders.forEach { d ->
                d.savePath?.takeIf { it.isNotBlank() }?.let { add(it) }
                d.pathMappings.orEmpty().forEach { m -> m.local.takeIf { it.isNotBlank() }?.let { add(it) } }
            }
        }.distinct()
    }
    val canSubmit = !busy && source.isNotBlank() && (target != "path" || targetPath.isNotBlank())

    ModalBottomSheet(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier.fillMaxWidth().heightIn(max = 740.dp).formSheetScroll().verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(if (rule == null) "添加自动入库规则" else "编辑自动入库规则", style = McType.title3, color = TextPrimary)

            SectionHint("源目录（监听这里的下载）")
            Text(
                source.ifBlank { "浏览服务器目录并选择…" },
                style = if (source.isBlank()) McType.sub else McType.sub.copy(fontFamily = FontFamily.Monospace),
                color = if (source.isBlank()) TextFaint else TextPrimary,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                    .background(Color.White.copy(alpha = 0.05f))
                    .clickable { pickingSource = true }
                    .padding(horizontal = 10.dp, vertical = 11.dp),
            )
            if (quickDirs.isNotEmpty()) {
                Text(
                    "从下载器目录快速选择（选后可再浏览细化到子目录）：",
                    style = McType.caption, color = TextFaint,
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    quickDirs.forEach { p ->
                        PickerChip(label = p, selected = source == p) { source = p }
                    }
                }
            }
            Text(
                "不能与任何媒体库的根路径重叠（库根下的内容由库自己扫描管理）。订阅和手动下载会把种子投到这个目录（movieclaw 视角）；若下载器在另一个容器/主机上、看到的路径不同，请先到「设置 → 下载器」配置路径映射，否则会下载到错误位置。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )

            SectionHint("搬运策略")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("hardlink" to "硬链接", "copy" to "复制").forEach { (v, label) ->
                    PickerChip(label, selected = strategy == v) { strategy = v }
                }
            }
            Text(
                if (strategy == "hardlink") "保存时会检测源目录与整理落点（库主根或自定义目录）是否同一文件系统，跨盘会提示改用复制。"
                else "复制适合源目录与落点不在同一块盘的部署。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )

            SectionHint("导入目标")
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                libraries.forEach { lib ->
                    PickerChip(lib.name, selected = target == "lib:${lib.id}") { target = "lib:${lib.id}" }
                }
                listOf(
                    "auto:movie" to "自动路由（电影）",
                    "auto:tv" to "自动路由（剧集）",
                    "auto:video" to "落入其他库",
                ).forEach { (v, label) ->
                    PickerChip(label, selected = target == v) { target = v }
                }
                PickerChip("自定义目录…", selected = target == "path") {
                    target = "path"
                    if (targetPath.isBlank()) pickingTarget = true
                }
            }
            if (libraries.isEmpty()) {
                Text("还没有媒体库，请先在「媒体库」页创建。", style = McType.sub, color = TextFaint)
            }
            if (target == "path") {
                Text(
                    targetPath.ifBlank { "选择整理结果的存放目录…" },
                    style = if (targetPath.isBlank()) McType.sub else McType.sub.copy(fontFamily = FontFamily.Monospace),
                    color = if (targetPath.isBlank()) TextFaint else TextPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                        .background(Color.White.copy(alpha = 0.05f))
                        .clickable { pickingTarget = true }
                        .padding(horizontal = 10.dp, vertical = 11.dp),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("movie" to "电影", "tv" to "剧集", "video" to "其他").forEach { (v, label) ->
                        PickerChip(label, selected = pathKind == v) { pathKind = v }
                    }
                }
            }
            Text(
                when {
                    target.startsWith("auto:") && target != "auto:video" ->
                        "自动路由：识别出作品后按各媒体库的「收藏范围」分流（如动画进动漫库），未命中进该类型的默认库；订阅投递的内容始终进订阅指定的库。每个类型至多一条自动路由规则。"
                    target == "auto:video" ->
                        "落入其他库：不识别不改名，原样搬进默认的「其他」库；放什么由你定。"
                    target == "path" && pathKind == "video" ->
                        "自定义目录（其他）：不识别不改名，条目原样搬进该目录，不进入任何媒体库。文件后续出现在某个「其他」库的根目录时会被自动扫描入账。目录不得与库根或监听源重叠，每个类型至多一条。"
                    target == "path" ->
                        "自定义目录：下载整理（识别改名）后的文件放入该目录，不进入任何媒体库。适合整理结果还需外部流转（如上传网盘、转存、人工确认）再进入媒体库的场景——文件后续出现在某个库的根目录时会被自动扫描入账。目录不得与库根或监听源重叠，每个类型至多一条。"
                    else -> "指定库：这个目录里的内容固定导入所选库（落其主根）。"
                },
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )

            SectionHint("存量内容")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                PickerChip("整理存量", selected = processExisting) { processExisting = true }
                PickerChip("跳过存量", selected = !processExisting) { processExisting = false }
            }
            Text(
                if (processExisting) "目录里已有的内容也会被识别并整理入库；认不出的进入「待处理」清单，可逐个认领或忽略。"
                else "规则生效时目录里已有的条目会被标记为「已忽略」（不整理、不报错），之后只处理新增的下载；忽略的条目随时可在清单中恢复处理。适合目录里有其他工具管理的存量内容的场景。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )

            error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }

            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss, enabled = !busy) { Text("取消", color = TextMuted) }
                Spacer(Modifier.weight(1f))
                Button(
                    enabled = canSubmit,
                    onClick = {
                        busy = true
                        error = null
                        val payload = when {
                            target.startsWith("lib:") -> ImportWatchPayload(
                                sourcePath = source.trim(),
                                strategy = strategy,
                                libraryId = target.removePrefix("lib:").toLongOrNull(),
                                processExisting = processExisting,
                            )
                            target == "path" -> ImportWatchPayload(
                                sourcePath = source.trim(),
                                strategy = strategy,
                                targetPath = targetPath.trim(),
                                kind = pathKind,
                                processExisting = processExisting,
                            )
                            else -> ImportWatchPayload(
                                sourcePath = source.trim(),
                                strategy = strategy,
                                kind = target.removePrefix("auto:"),
                                processExisting = processExisting,
                            )
                        }
                        onSave(payload) { err ->
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
                    Text(if (busy) "保存中…" else "保存", fontSize = 14.sp)
                }
            }
            Spacer(Modifier.height(12.dp))
        }
    }

    if (pickingSource) {
        DirectoryPickerSheet(
            initialPath = source.ifBlank { null },
            browse = browse,
            onSelect = { source = it; pickingSource = false },
            onDismiss = { pickingSource = false },
        )
    }
    if (pickingTarget) {
        DirectoryPickerSheet(
            initialPath = targetPath.ifBlank { null },
            browse = browse,
            onSelect = { targetPath = it; pickingTarget = false },
            onDismiss = { pickingTarget = false },
        )
    }
}

@Composable
private fun SectionHint(text: String) {
    Text(text, style = McType.sub.copy(fontWeight = FontWeight.Medium), color = TextMuted)
}

@Composable
private fun PickerChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Text(
        label,
        style = McType.caption,
        color = if (selected) Color(0xFF141821) else TextMuted,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(if (selected) Accent else Color.White.copy(alpha = 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    )
}
