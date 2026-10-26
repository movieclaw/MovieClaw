package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
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
import io.movieclaw.android.core.designsystem.formSheetScroll
import io.movieclaw.android.core.model.RoutingOptionsView
import io.movieclaw.android.core.model.RuleSetPayload
import io.movieclaw.android.core.model.RuleSetView
import io.movieclaw.android.core.model.SmartPreferences
import io.movieclaw.android.core.model.SmartProfilePayload
import io.movieclaw.android.core.model.SmartProfileView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.feature.subscriptions.parseRuleSetSpec
import io.movieclaw.android.feature.subscriptions.specSummary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject
import io.movieclaw.android.core.designsystem.formSheetScroll

/*
 * 设置 → 订阅规则（规则组；原生页，参照移动网页端 `rule-sets-panel.tsx`）：
 * 列表（名称 / 默认 / 适用范围 / 摘要芯片）+ 编辑器（适用范围、分辨率与片源偏好序、编码、HDR、
 * 平台、制作组、字幕与音轨、免费/H&R、体积与做种、洗版）+ 复制 / 设默认 / 删除。
 */

@HiltViewModel
class RuleSetsViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val error: String? = null,
        val list: List<RuleSetView> = emptyList(),
        /** 适用范围选项（电影/剧集类型、国家码、区域预设）；取不到时编辑器只留作品类型 */
        val routing: RoutingOptionsView? = null,
        /** 智能选择：movie / tv 各自一份（null = 还没设置） */
        val smart: Map<String, SmartProfileView?> = emptyMap(),
        val smartLoading: Boolean = true,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui.asStateFlow()
    private fun api() = repository.ui.value.origin?.let { apiFactory.forOrigin(it) }

    init {
        load()
        loadSmart()
        loadRouting()
    }

    fun load() {
        viewModelScope.launch {
            val api = api() ?: run {
                _ui.value = _ui.value.copy(loading = false, error = "还没有连上服务器")
                return@launch
            }
            _ui.value = _ui.value.copy(loading = true, error = null)
            runCatching { api.ruleSets().dataOrThrow() }
                .onSuccess { _ui.value = _ui.value.copy(loading = false, list = it) }
                .onFailure { _ui.value = _ui.value.copy(loading = false, error = it.message ?: "加载失败，请稍后重试") }
        }
    }

    fun loadRouting() {
        viewModelScope.launch {
            val api = api() ?: return@launch
            runCatching { api.routingOptions().dataOrThrow() }
                .onSuccess { _ui.value = _ui.value.copy(routing = it) }
        }
    }

    fun loadSmart() {
        viewModelScope.launch {
            val api = api() ?: run {
                _ui.value = _ui.value.copy(smartLoading = false)
                return@launch
            }
            val movie = runCatching { api.smartProfile("movie").dataOrThrow() }.getOrNull()
            val tv = runCatching { api.smartProfile("tv").dataOrThrow() }.getOrNull()
            _ui.value = _ui.value.copy(
                smart = mapOf("movie" to movie, "tv" to tv),
                smartLoading = false,
            )
        }
    }

    fun saveSmart(kind: String, prefs: SmartPreferences, onDone: (String?) -> Unit) {
        viewModelScope.launch {
            val api = api() ?: return@launch onDone("还没有连上服务器")
            val revision = _ui.value.smart[kind]?.revision ?: 0
            runCatching { api.saveSmartProfile(kind, SmartProfilePayload(revision, prefs)).dataOrThrow() }
                .onSuccess { view ->
                    _ui.value = _ui.value.copy(smart = _ui.value.smart + (kind to view))
                    onDone(null)
                }
                .onFailure { onDone(it.message ?: "保存失败，请稍后重试") }
        }
    }

    fun save(editingId: Long?, payload: RuleSetPayload, onDone: (String?) -> Unit) {
        viewModelScope.launch {
            val api = api() ?: return@launch onDone("还没有连上服务器")
            runCatching {
                if (editingId == null) api.createRuleSet(payload).dataOrThrow()
                else api.updateRuleSet(editingId, payload).dataOrThrow()
            }.onSuccess { onDone(null); load() }
                .onFailure { onDone(it.message ?: "保存失败，请稍后重试") }
        }
    }

    fun setDefault(item: RuleSetView, onDone: (String?) -> Unit) {
        viewModelScope.launch {
            val api = api() ?: return@launch onDone("还没有连上服务器")
            runCatching { api.setDefaultRuleSet(item.id).dataOrThrow() }
                .onSuccess {
                    onDone(null)
                    load()
                }
                .onFailure { onDone(it.message ?: "设置失败，请稍后重试") }
        }
    }

    fun delete(item: RuleSetView, onDone: (String?) -> Unit) {
        viewModelScope.launch {
            val api = api() ?: return@launch onDone("还没有连上服务器")
            runCatching { api.deleteRuleSet(item.id).dataOrThrow() }
                .onSuccess { _ui.value = _ui.value.copy(list = _ui.value.list.filterNot { it.id == item.id }); onDone(null) }
                .onFailure { onDone(it.message ?: "删除失败，请稍后重试") }
        }
    }
}

private val RESOLUTIONS = listOf("2160p", "1080p", "720p")
private val SOURCES = listOf("remux" to "Remux", "blu-ray" to "蓝光", "web-dl" to "WEB-DL", "rip" to "Rip 类", "tv" to "电视录制类")
private val CODECS = listOf("H.265" to listOf("x265", "H.265", "HEVC"), "H.264" to listOf("x264", "H.264", "AVC"), "AV1" to listOf("AV1"))
private val HDRS = listOf("DV", "HDR10+", "HDR10", "HLG", "SDR")
// 只能「排除」的 HDR 项：「DV P5」= 只标 DV、没有 HDR10 兼容层的杜比视界（Profile 5），转码会偏色。
// 后端按命名约定与站点标记判定，「只要 P5」没有意义，所以不进三态循环。
private val HDR_BLOCK_ONLY = listOf("DV P5")
private val PLATFORMS = listOf(
    "netflix" to "Netflix", "disney_plus" to "Disney+", "amazon" to "Prime Video", "hbo_max" to "HBO Max",
    "apple_tv_plus" to "Apple TV+", "hulu" to "Hulu", "paramount_plus" to "Paramount+", "peacock" to "Peacock",
    "iqiyi" to "爱奇艺", "wetv" to "腾讯视频", "youku" to "优酷", "mangotv" to "芒果 TV",
    "bilibili" to "哔哩哔哩", "viu" to "Viu", "crunchyroll" to "Crunchyroll", "hotstar" to "Hotstar",
)
private val SUB_LANGS = listOf("zh" to "中文（不限简繁）", "zh-Hans" to "简体中文", "zh-Hant" to "繁体中文", "en" to "英文")
private val AUDIO_LANGS = listOf("cmn" to "国语", "yue" to "粤语", "ja" to "日语", "en" to "英语")
private val UPGRADE_TARGETS = listOf("" to "不洗版", "web-dl" to "洗到 WEB-DL", "blu-ray" to "洗到蓝光", "remux" to "洗到 Remux")

private fun JsonObject.strList(key: String): List<String> =
    (this[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList()

private val JsonPrimitive.contentOrNull: String? get() = if (isString) content else content

private fun JsonObject.boolOf(key: String): Boolean =
    (this[key] as? JsonPrimitive)?.content?.toBooleanStrictOrNull() ?: false

private fun JsonObject.intOf(key: String): Int? =
    (this[key] as? JsonPrimitive)?.content?.toIntOrNull()

/** 编辑草稿：从 JsonObject 解析，保存时只覆盖已知键、其余原样保留（网页端同做法） */
private data class RuleDraft(
    val raw: JsonObject = JsonObject(emptyMap()),
    val name: String = "",
    val kind: String = "",
    val resolutions: List<String> = emptyList(),
    val sources: List<String> = emptyList(),
    val codecs: List<String> = emptyList(),
    val hdrAllow: List<String> = emptyList(),
    val hdrBlock: List<String> = emptyList(),
    val platformsAllow: List<String> = emptyList(),
    val platformsBlock: List<String> = emptyList(),
    val groupsAllow: String = "",
    val groupsBlock: String = "",
    val subs: List<String> = emptyList(),
    val audios: List<String> = emptyList(),
    val freeOnly: Boolean = false,
    val excludeHr: Boolean = false,
    val hrStrict: Boolean = false,
    val minSeeders: String = "",
    val sizeMin: String = "",
    val sizeMax: String = "",
    val upgradeSource: String = "",
    val cutoff: String = "",
    val keepOld: Boolean = false,
    val ladderHdr: Boolean = false,
    /** 适用范围附加维度（同 Web `buildScope`：空维度不生成条件） */
    val regions: List<String> = emptyList(),
    val genres: List<Int> = emptyList(),
) {
    companion object {
        fun from(view: RuleSetView?, copyName: String? = null): RuleDraft {
            val spec = view?.spec ?: JsonObject(emptyMap())
            fun ruleValues(field: String): JsonArray? =
                view?.matchRules?.firstOrNull { it.strValue("field") == field }?.let { it["values"] as? JsonArray }
            val kind = ruleValues("kind")?.firstOrNull()?.strValue().orEmpty()
            val regions = ruleValues("origin_countries")?.mapNotNull { it.strValue() } ?: emptyList()
            val genres = ruleValues("genres")?.mapNotNull { it.strValue()?.toIntOrNull() } ?: emptyList()
            val codecs = spec.strList("video_codecs")
            return RuleDraft(
                raw = spec,
                name = copyName ?: view?.name.orEmpty(),
                kind = kind,
                resolutions = spec.strList("resolutions"),
                sources = spec.strList("media_sources"),
                codecs = codecs,
                hdrAllow = spec.strList("hdr_levels"),
                hdrBlock = spec.strList("hdr_block"),
                platformsAllow = spec.strList("platforms"),
                platformsBlock = spec.strList("platforms_block"),
                groupsAllow = spec.strList("release_groups_allow").joinToString(", "),
                groupsBlock = spec.strList("release_groups_block").joinToString(", "),
                subs = spec.strList("subtitle_languages_require"),
                audios = spec.strList("audio_languages_require"),
                freeOnly = spec.boolOf("free_only"),
                excludeHr = spec.boolOf("exclude_hr"),
                hrStrict = (spec["hr_unknown_policy"] as? JsonPrimitive)?.content == "strict",
                minSeeders = spec.intOf("min_seeders")?.toString().orEmpty(),
                sizeMin = spec.intOf("size_min_mb")?.toString().orEmpty(),
                sizeMax = spec.intOf("size_max_mb")?.toString().orEmpty(),
                upgradeSource = (spec["upgrade_source"] as? JsonPrimitive)?.content.orEmpty(),
                cutoff = (spec["cutoff_resolution"] as? JsonPrimitive)?.content.orEmpty(),
                keepOld = spec.boolOf("upgrade_keep_old"),
                ladderHdr = (spec["upgrade_ladder"] as? JsonArray)?.any { it.jsonPrimitive.content == "hdr" } == true,
                regions = regions,
                genres = genres,
            )
        }
    }

    fun spec(): JsonObject {
        val map = raw.toMutableMap()
        fun put(key: String, value: kotlinx.serialization.json.JsonElement?) {
            if (value == null) map.remove(key) else map[key] = value
        }
        fun arr(list: List<String>): JsonArray? = if (list.isEmpty()) null else JsonArray(list.map { JsonPrimitive(it) })
        put("resolutions", arr(resolutions))
        put("media_sources", arr(sources))
        put("video_codecs", arr(codecs))
        put("hdr_levels", arr(hdrAllow))
        put("hdr_block", arr(hdrBlock))
        put("platforms", arr(platformsAllow))
        put("platforms_block", arr(platformsBlock))
        put("release_groups_allow", arr(groupsAllow.split(',', ' ').map { it.trim() }.filter { it.isNotEmpty() }))
        put("release_groups_block", arr(groupsBlock.split(',', ' ').map { it.trim() }.filter { it.isNotEmpty() }))
        put("subtitle_languages_require", arr(subs))
        put("audio_languages_require", arr(audios))
        put("free_only", if (freeOnly) JsonPrimitive(true) else null)
        put("exclude_hr", if (excludeHr) JsonPrimitive(true) else null)
        put("hr_unknown_policy", if (excludeHr && hrStrict) JsonPrimitive("strict") else null)
        put("min_seeders", minSeeders.trim().toIntOrNull()?.takeIf { it > 0 }?.let { JsonPrimitive(it) })
        put("size_min_mb", sizeMin.trim().toIntOrNull()?.takeIf { it > 0 }?.let { JsonPrimitive(it) })
        put("size_max_mb", sizeMax.trim().toIntOrNull()?.takeIf { it > 0 }?.let { JsonPrimitive(it) })
        put("upgrade_source", upgradeSource.takeIf { it.isNotBlank() }?.let { JsonPrimitive(it) })
        put("cutoff_resolution", cutoff.takeIf { it.isNotBlank() }?.let { JsonPrimitive(it) })
        put("upgrade_keep_old", if (keepOld) JsonPrimitive(true) else null)
        put(
            "upgrade_ladder",
            if (ladderHdr) JsonArray(listOf(JsonPrimitive("resolution"), JsonPrimitive("source"), JsonPrimitive("hdr")))
            else null,
        )
        return JsonObject(map)
    }

    fun matchRules(): JsonArray = buildJsonArray {
        if (kind.isNotBlank()) {
            add(buildJsonObject {
                put("field", JsonPrimitive("kind"))
                put("op", JsonPrimitive("any_of"))
                put("values", JsonArray(listOf(JsonPrimitive(kind))))
            })
        }
        if (regions.isNotEmpty()) {
            add(buildJsonObject {
                put("field", JsonPrimitive("origin_countries"))
                put("op", JsonPrimitive("any_of"))
                put("values", JsonArray(regions.map { JsonPrimitive(it) }))
            })
        }
        if (genres.isNotEmpty()) {
            add(buildJsonObject {
                put("field", JsonPrimitive("genres"))
                put("op", JsonPrimitive("any_of"))
                put("values", JsonArray(genres.map { JsonPrimitive(it) }))
            })
        }
    }
}

/** match_rules 条目的字段名 / 字符串值（服务端只回字符串与数字两种） */
private fun JsonObject.strValue(key: String): String? = (this[key] as? JsonPrimitive)?.content
private fun JsonElement.strValue(): String? = (this as? JsonPrimitive)?.content

@Composable
fun RuleSetsScreen(onBack: () -> Unit, vm: RuleSetsViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val feedback = LocalFeedback.current
    var editing by remember { mutableStateOf<RuleSetView?>(null) }
    var creating by remember { mutableStateOf(false) }
    var copySource by remember { mutableStateOf<RuleSetView?>(null) }
    var deleting by remember { mutableStateOf<RuleSetView?>(null) }
    /** smart = 智能选择 / rules = 自定义规则（网页端两个页签，默认智能选择） */
    var tab by remember { mutableStateOf("smart") }
    var editingSmart by remember { mutableStateOf<String?>(null) }

    Column(Modifier.fillMaxSize().background(io.movieclaw.android.core.designsystem.Bg)) {
        SettingsTopBar(title = "订阅规则", onBack = onBack)
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Spacer(Modifier.height(4.dp))
            PageTabs(selected = tab, onSelect = { tab = it })
            ui.error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }

            if (tab == "smart") {
                Text(
                    "按品质目标和等待耐心自动选择版本，电影和剧集分别设置。后续订阅复用对应设置；已有订阅保持创建时的设置。",
                    style = McType.caption, color = TextMuted, lineHeight = 19.sp,
                )
                SmartProfileCard(
                    kind = "movie",
                    profile = ui.smart["movie"],
                    loading = ui.smartLoading,
                    onEdit = { editingSmart = "movie" },
                )
                SmartProfileCard(
                    kind = "tv",
                    profile = ui.smart["tv"],
                    loading = ui.smartLoading,
                    onEdit = { editingSmart = "tv" },
                )
                Text(
                    "优先比较分辨率，再比较片源；后续洗版不会降低任一项品质。等待上限指选择下载版本的时间，不是可观看时间。",
                    style = McType.caption, color = TextFaint, lineHeight = 18.sp,
                )
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("规则组", style = McType.title3, color = TextPrimary)
                        Spacer(Modifier.height(3.dp))
                        Text(
                            "规则组定义「什么样的资源可接受」——硬性条件（分辨率、编码、体积、免费等）与偏好顺序。",
                            style = McType.footnote, color = TextMuted, lineHeight = 19.sp,
                        )
                    }
                    Text(
                        "+ 新建规则组", style = McType.caption, color = Accent,
                        modifier = Modifier.clip(RoundedCornerShape(999.dp))
                            .background(Color.White.copy(alpha = 0.06f))
                            .clickable { creating = true }
                            .padding(horizontal = 12.dp, vertical = 7.dp),
                    )
                }

                if (ui.list.isEmpty() && !ui.loading) {
                    GlassCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(18.dp)) {
                            Text("还没有规则组", style = McType.subheadlineSemibold, color = TextPrimary)
                            Spacer(Modifier.height(4.dp))
                            Text("点「新建规则组」创建。", style = McType.footnote, color = TextMuted)
                        }
                    }
                } else {
                    GlassCard(Modifier.fillMaxWidth()) {
                        Column {
                            ui.list.forEachIndexed { i, item ->
                                RuleSetRow(
                                    item = item,
                                    routing = ui.routing,
                                    onEdit = { editing = item },
                                    onCopy = { copySource = item },
                                    onDefault = {
                                        vm.setDefault(item) { err ->
                                            if (err != null) feedback.error(err) else feedback.success("「${item.name}」已设为默认规则组")
                                        }
                                    },
                                    onDelete = { deleting = item },
                                )
                                if (i != ui.list.lastIndex) HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
                            }
                        }
                    }
                }
                Text(
                    "给规则组设置「适用范围」（电影/剧集、区域、类型）后，订阅时会自动选中匹配的组：多个组都匹配时条件更多的优先，都不匹配时用标「默认」的组。修改只影响之后的资源评估，已下载的内容不受影响。",
                    style = McType.caption, color = TextFaint, lineHeight = 18.sp,
                )
            }
            Spacer(Modifier.height(28.dp))
        }
    }

    editingSmart?.let { kind ->
        SmartProfileSheet(
            kind = kind,
            profile = ui.smart[kind],
            onDismiss = { editingSmart = null },
            onSave = { prefs, done -> vm.saveSmart(kind, prefs, done) },
        )
    }
    if (creating || editing != null || copySource != null) {
        RuleSetEditor(
            view = editing ?: copySource,
            isNew = creating || copySource != null,
            routing = ui.routing,
            onDismiss = { creating = false; editing = null; copySource = null },
            onSave = { payload, done -> vm.save(editing?.id, payload, done) },
        )
    }
    deleting?.let { item ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            containerColor = Color(0xFF171A23),
            title = { Text("删除规则组「${item.name}」？", style = McType.bodySemibold, color = TextPrimary) },
            text = {
                if (item.referenceCount > 0) Text("${item.referenceCount} 个订阅在使用它，先换绑后再删。", style = McType.sub, color = TextMuted)
            },
            confirmButton = {
                TextButton(onClick = {
                    deleting = null
                    vm.delete(item) { err ->
                        if (err != null) feedback.error(err) else feedback.success("已删除")
                    }
                }) { Text("删除", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消", color = TextMuted) } },
        )
    }
}

@Composable
private fun RuleSetRow(
    item: RuleSetView,
    routing: RoutingOptionsView?,
    onEdit: () -> Unit,
    onCopy: () -> Unit,
    onDefault: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().clickable(onClick = onEdit).padding(horizontal = 14.dp, vertical = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(item.name, style = McType.subheadlineSemibold, color = TextPrimary, maxLines = 1, modifier = Modifier.weight(1f))
            if (item.isDefault) {
                Text("默认", style = McType.caption, color = TextFaint,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.08f))
                        .padding(horizontal = 6.dp, vertical = 1.dp))
                Spacer(Modifier.width(6.dp))
            }
            Box {
                Text("⋯", style = McType.sub, color = TextMuted,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).clickable { menu = true }
                        .padding(horizontal = 10.dp, vertical = 4.dp))
                androidx.compose.material3.DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    RuleMenuItem("编辑") { menu = false; onEdit() }
                    RuleMenuItem("复制为新组") { menu = false; onCopy() }
                    RuleMenuItem(if (item.isDefault) "已是默认组" else "设为默认组", enabled = !item.isDefault) { menu = false; onDefault() }
                    RuleMenuItem("删除", enabled = !item.isDefault && item.referenceCount == 0, danger = true) { menu = false; onDelete() }
                }
            }
        }
        val chips = specSummary(parseRuleSetSpec(item.spec))
        Text(
            ruleScopeSummary(item, routing),
            style = McType.caption,
            color = if (item.matchRules.isEmpty()) TextFaint else TextMuted,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 5.dp),
        )
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 6.dp)) {
            if (chips.isEmpty()) {
                Text("全不限：任何识别为本条目的资源都可接受", style = McType.caption, color = TextFaint)
            } else {
                chips.forEach {
                    Text(it, style = McType.caption, color = TextMuted,
                        modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.05f))
                            .padding(horizontal = 8.dp, vertical = 2.dp))
                }
            }
        }
        if (item.referenceCount > 0) {
            Spacer(Modifier.height(4.dp))
            Text("${item.referenceCount} 个订阅使用中", style = McType.caption, color = TextFaint)
        }
    }
}

@Composable
private fun PageTabs(selected: String, onSelect: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 2.dp)) {
        listOf("smart" to "智能选择", "rules" to "自定义规则").forEach { (key, label) ->
            val active = selected == key
            Column(
                Modifier.weight(1f).clickable { onSelect(key) }.padding(top = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(label, style = McType.bodyMedium, color = if (active) TextPrimary else TextMuted)
                Spacer(Modifier.height(7.dp))
                Box(Modifier.fillMaxWidth().height(2.dp).background(if (active) Accent else Color.Transparent))
            }
        }
    }
}

private fun matchValues(item: RuleSetView, field: String): List<String> =
    item.matchRules.firstOrNull { it.strValue("field") == field }
        ?.let { it["values"] as? JsonArray }
        ?.mapNotNull { it.strValue() }
        .orEmpty()

/** 适用范围一句话摘要（「适用范围 · 剧集 · 日韩 · 动画」；未声明返回说明文案） */
private fun ruleScopeSummary(item: RuleSetView, routing: RoutingOptionsView?): String {
    if (item.matchRules.isEmpty()) return "未设适用范围，仅手动选用"
    val kind = matchValues(item, "kind").firstOrNull()
    val regions = matchValues(item, "origin_countries")
    val genres = matchValues(item, "genres").mapNotNull { it.toIntOrNull() }
    val parts = buildList {
        when (kind) {
            "movie" -> add("电影")
            "tv" -> add("剧集")
        }
        if (regions.isNotEmpty()) add(regionLabels(regions, routing))
        if (genres.isNotEmpty()) {
            val options = when (kind) {
                "movie" -> routing?.movieGenres.orEmpty()
                "tv" -> routing?.tvGenres.orEmpty()
                else -> (routing?.movieGenres.orEmpty() + routing?.tvGenres.orEmpty())
            }
            add(
                genres.map { id -> options.firstOrNull { it.id == id }?.label ?: "#$id" }
                    .distinct().joinToString("/"),
            )
        }
    }
    return if (parts.isEmpty()) "未设适用范围，仅手动选用" else "适用范围 · " + parts.joinToString(" · ")
}

private fun regionLabels(regions: List<String>, routing: RoutingOptionsView?): String {
    if (routing == null) return "${regions.size} 个区域"
    var rest = regions
    val parts = mutableListOf<String>()
    routing.regionPresets.forEach { preset ->
        if (preset.countries.isNotEmpty() && preset.countries.all { it in rest }) {
            parts += preset.label
            rest = rest.filterNot { it in preset.countries }
        }
    }
    parts += rest.map { routing.countryNames[it] ?: it }
    return parts.joinToString("/")
}

private fun resLabel(res: String): String = if (res == "2160p") "4K" else res

private fun sourceLabel(source: String): String = when (source) {
    "web-dl" -> "WEB-DL"
    "blu-ray" -> "蓝光"
    "remux" -> "Remux"
    else -> source
}

private fun smartSummary(p: SmartPreferences): String = "${resLabel(p.resolution)} ${sourceLabel(p.source)}"

private fun waitLabel(seconds: Int): String = when {
    seconds <= 0 -> "尽快下载"
    seconds % 86400 == 0 -> "最多等 ${seconds / 86400} 天"
    seconds % 3600 == 0 -> "最多等 ${seconds / 3600} 小时"
    else -> "最多等 ${(seconds + 59) / 60} 分钟"
}

@Composable
private fun SmartProfileCard(
    kind: String,
    profile: SmartProfileView?,
    loading: Boolean,
    onEdit: () -> Unit,
) {
    val label = if (kind == "movie") "电影" else "剧集"
    val prefs = profile?.preferences
    GlassCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "${label}智能设置", style = McType.subheadlineSemibold, color = TextPrimary,
                    modifier = Modifier.weight(1f),
                )
                if (!loading) {
                    Text(
                        if (prefs == null) "设置" else "修改设置",
                        style = McType.caption, color = Accent,
                        modifier = Modifier.clip(RoundedCornerShape(999.dp))
                            .background(Color.White.copy(alpha = 0.06f))
                            .clickable(onClick = onEdit)
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                    )
                }
            }
            Spacer(Modifier.height(6.dp))
            when {
                loading -> Text("正在读取设置…", style = McType.caption, color = TextFaint)
                prefs == null -> Text(
                    "还没设置。只需设置一次，后续${label}订阅自动复用。",
                    style = McType.caption, color = TextMuted, lineHeight = 18.sp,
                )
                else -> {
                    Text("优先 ${smartSummary(prefs)}", style = McType.title3, color = TextPrimary)
                    Spacer(Modifier.height(3.dp))
                    Text(
                        waitLabel(prefs.waitSeconds) + " · " +
                            if (prefs.allowUpgrade) "达标后停止洗版" else "入库后不洗版",
                        style = McType.caption, color = TextMuted, lineHeight = 18.sp,
                    )
                    if (prefs.strictResolution) {
                        Text(
                            "只接受 ${resLabel(prefs.resolution)}，到期也不降低要求。",
                            style = McType.caption, color = TextMuted,
                        )
                    }
                }
            }
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun SmartProfileSheet(
    kind: String,
    profile: SmartProfileView?,
    onDismiss: () -> Unit,
    onSave: (SmartPreferences, (String?) -> Unit) -> Unit,
) {
    val label = if (kind == "movie") "电影" else "剧集"
    val p = profile?.preferences
    var resolution by remember { mutableStateOf(p?.resolution ?: "2160p") }
    var source by remember { mutableStateOf(p?.source ?: "web-dl") }
    var waitSeconds by remember { mutableStateOf(p?.waitSeconds ?: if (kind == "movie") 86400 else 10800) }
    var allowUpgrade by remember { mutableStateOf(p?.allowUpgrade ?: true) }
    var strict by remember { mutableStateOf(p?.strictResolution ?: false) }
    val presetWaits = listOf(0, 10800, 86400)
    // 旧配置里可能存在非整天的自定义值（如 7200 秒）：保留成一个「原有设置」选项，
    // 不动它直接保存时不能擅自改成 1 天。
    val legacyWait = waitSeconds.takeIf { it !in presetWaits && it % 86400 != 0 }
    var custom by remember { mutableStateOf(waitSeconds !in presetWaits && waitSeconds % 86400 == 0) }
    var customDays by remember { mutableStateOf(((waitSeconds + 86399) / 86400).coerceIn(1, 7).toString()) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val days = customDays.toIntOrNull()
    val daysValid = days != null && days in 1..7

    ModalBottomSheet(
        onDismissRequest = { if (!busy) onDismiss() },
        // 面板拖动与内部滚动抢手势：拉满后滑到底再滑回顶部会来回跳（用户反馈）。
        // formSheetScroll 吃掉内容滚到底后的剩余手势，面板仍可拖，但不再和列表互相带。
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier.fillMaxWidth().heightIn(max = 680.dp).formSheetScroll().verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text("${label}智能设置", style = McType.title3, color = TextPrimary)
            Text(
                if (p != null) "修改只影响之后新建的订阅。"
                else "只需设置一次，后续${label}订阅自动复用。",
                style = McType.caption, color = TextFaint,
            )

            SectionLabel("优先分辨率")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("2160p" to "4K", "1080p" to "1080p").forEach { (v, text) ->
                    PickerChip(text, selected = resolution == v) { resolution = v }
                }
            }
            SectionLabel("优先片源")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("web-dl" to "WEB-DL", "blu-ray" to "蓝光", "remux" to "Remux").forEach { (v, text) ->
                    PickerChip(text, selected = source == v) { source = v }
                }
            }
            SectionLabel("等待耐心")
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                PickerChip("尽快下载 · 不等待", selected = !custom && waitSeconds == 0) {
                    custom = false; waitSeconds = 0
                }
                PickerChip("可以等 · 最多 3 小时", selected = !custom && waitSeconds == 10800) {
                    custom = false; waitSeconds = 10800
                }
                PickerChip("更有耐心 · 最多 1 天", selected = !custom && waitSeconds == 86400) {
                    custom = false; waitSeconds = 86400
                }
                legacyWait?.let { legacy ->
                    PickerChip("原有设置 · ${waitLabel(legacy)}", selected = !custom && waitSeconds == legacy) {
                        custom = false
                        waitSeconds = legacy
                    }
                }
                PickerChip("自定义", selected = custom) {
                    custom = true
                    waitSeconds = (customDays.toIntOrNull() ?: 1).coerceIn(1, 7) * 86400
                }
            }
            if (custom) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("最多等待", style = McType.caption, color = TextFaint, modifier = Modifier.weight(1f))
                    TextField(
                        value = customDays,
                        onValueChange = { v ->
                            customDays = v.filter { it.isDigit() }.take(1)
                            customDays.toIntOrNull()?.takeIf { it in 1..7 }?.let { waitSeconds = it * 86400 }
                        },
                        singleLine = true,
                        modifier = Modifier.width(90.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("天（1–7）", style = McType.caption, color = TextFaint)
                }
            }
            Text(
                "优先比较分辨率，再比较片源；后续洗版不会降低任一项品质。已有资源的发布时间会计入等待。等待上限指选择下载版本的时间，不是可观看时间。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )

            ToggleRow("允许后续洗版", "达到目标并完成入库核验后停止洗版", allowUpgrade) { allowUpgrade = it }
            ToggleRow("只接受 ${resLabel(resolution)}", "到期也不降低分辨率", strict) { strict = it }

            error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }

            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss, enabled = !busy) { Text("取消", color = TextMuted) }
                Spacer(Modifier.weight(1f))
                Button(
                    enabled = !busy && (!custom || daysValid),
                    onClick = {
                        if (custom && !daysValid) {
                            error = "自定义等待需为 1–7 天"
                            return@Button
                        }
                        busy = true
                        error = null
                        val effectiveWait = if (custom) (days ?: 1) * 86400 else waitSeconds
                        onSave(
                            SmartPreferences(
                                resolution = resolution,
                                source = source,
                                waitSeconds = effectiveWait,
                                allowUpgrade = allowUpgrade,
                                strictResolution = strict,
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
                    Text(if (busy) "正在保存…" else "保存${label}设置", fontSize = 14.sp)
                }
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun RuleMenuItem(text: String, enabled: Boolean = true, danger: Boolean = false, onClick: () -> Unit) {
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

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun RuleSetEditor(
    view: RuleSetView?,
    isNew: Boolean,
    routing: RoutingOptionsView?,
    onDismiss: () -> Unit,
    onSave: (RuleSetPayload, (String?) -> Unit) -> Unit,
) {
    var d by remember(view) { mutableStateOf(RuleDraft.from(view, copyName = if (isNew && view != null) "${view.name} 副本" else null)) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(
        onDismissRequest = { if (!busy) onDismiss() },
        // 面板拖动与内部滚动抢手势：拉满后滑到底再滑回顶部会来回跳（用户反馈）。
        // formSheetScroll 吃掉内容滚到底后的剩余手势，面板仍可拖，但不再和列表互相带。
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier.fillMaxWidth().heightIn(max = 760.dp).formSheetScroll().verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(if (isNew) "新建规则组" else "编辑规则组", style = McType.title3, color = TextPrimary)
            Text(
                "所有条件都可以留空 = 不限该维度；条件之间是「且」的关系。",
                style = McType.caption, color = TextFaint,
            )
            if (!isNew && (view?.referenceCount ?: 0) > 0) {
                Text(
                    "此组正被 ${view!!.referenceCount} 个订阅使用，保存后对它们之后的资源评估立即生效（已下载的内容不受影响）。",
                    style = McType.caption, color = Color(0xFFFFD180), lineHeight = 17.sp,
                )
            }

            Text("名称", style = McType.caption, color = TextFaint)
            TextField(
                value = d.name, onValueChange = { d = d.copy(name = it); error = null }, singleLine = true,
                placeholder = { Text("如：4K 免费、追剧省流", style = McType.caption, color = TextFaint) },
                modifier = Modifier.fillMaxWidth(),
            )

            Text("适用范围 · 作品类型", style = McType.caption, color = TextFaint)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("" to "不限", "movie" to "电影", "tv" to "剧集").forEach { (v, label) ->
                    PickerChip(label, selected = d.kind == v) {
                        val allowed = when (v) {
                            "movie" -> routing?.movieGenres
                            "tv" -> routing?.tvGenres
                            else -> null
                        }
                        d = d.copy(
                            kind = v,
                            genres = if (allowed == null) d.genres
                            else d.genres.filter { id -> allowed.any { it.id == id } },
                        )
                    }
                }
            }
            Text(
                "订阅的作品符合这里的条件时自动选用本组；多个组都符合时条件更多的优先，都不符合时用默认组。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )
            if (routing != null) {
                SectionLabel("区域（勾选任一即匹配；不选 = 不限）")
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    routing.regionPresets.forEach { preset ->
                        val active = preset.countries.isNotEmpty() && preset.countries.all { it in d.regions }
                        PickerChip(preset.label, selected = active) {
                            d = if (active) d.copy(regions = d.regions.filterNot { it in preset.countries })
                            else d.copy(regions = (d.regions + preset.countries).distinct())
                        }
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    routing.countryNames.entries.forEach { (code, name) ->
                        PickerChip(name, selected = code in d.regions) {
                            d = d.copy(
                                regions = if (code in d.regions) d.regions - code else d.regions + code,
                            )
                        }
                    }
                    d.regions.filterNot { it in routing.countryNames }.forEach { code ->
                        PickerChip(code, selected = true) { d = d.copy(regions = d.regions - code) }
                    }
                }
                SectionLabel("类型（勾选任一即匹配；不选 = 不限）")
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    val genreOptions = when (d.kind) {
                        "movie" -> routing.movieGenres
                        "tv" -> routing.tvGenres
                        else -> (routing.movieGenres + routing.tvGenres)
                    }.distinctBy { it.id }
                    genreOptions.forEach { genre ->
                        PickerChip(genre.label, selected = genre.id in d.genres) {
                            d = d.copy(
                                genres = if (genre.id in d.genres) d.genres - genre.id else d.genres + genre.id,
                            )
                        }
                    }
                }
            } else {
                Text("区域/类型选项加载失败，保存时会保留原有适用范围。", style = McType.caption, color = TextFaint)
            }

            SectionLabel("分辨率（点击依次选择，先选的优先；不选 = 不限）")
            DragReorderList(
                items = d.resolutions,
                label = { it },
                onOrder = { d = d.copy(resolutions = it) },
                onRemove = { r -> d = d.copy(resolutions = d.resolutions - r) },
            )
            OptionChips(RESOLUTIONS.filter { it !in d.resolutions }.map { it to it }) { v ->
                d = d.copy(resolutions = d.resolutions + v)
            }

            SectionLabel("片源（顺序即偏好；不选 = 不限）")
            DragReorderList(
                items = d.sources,
                label = { s -> SOURCES.firstOrNull { it.first == s }?.second ?: s },
                onOrder = { d = d.copy(sources = it) },
                onRemove = { s -> d = d.copy(sources = d.sources - s) },
            )
            OptionChips(SOURCES.filter { it.first !in d.sources }) { v ->
                d = d.copy(sources = d.sources + v)
            }

            SectionLabel("视频编码（按家族；不选 = 不限）")
            MultiChips(CODECS.map { it.first to it.first }, d.codecs) { v ->
                d = d.copy(codecs = if (v in d.codecs) d.codecs - v else d.codecs + v)
            }

            SectionLabel("HDR（点一下「要」，再点「排除」，第三下取消；都不选 = 不限）")
            Text(
                "「DV P5」是只标了 DV、没有 HDR10 兼容层的杜比视界，转码会偏色；只能排除，点一下即排除。",
                style = McType.caption, color = TextFaint, lineHeight = 16.sp,
            )
            TriChips((HDRS + HDR_BLOCK_ONLY).map { it to it }, d.hdrAllow, d.hdrBlock, blockOnly = HDR_BLOCK_ONLY) { v, state ->
                d = when (state) {
                    1 -> d.copy(hdrAllow = d.hdrAllow + v, hdrBlock = d.hdrBlock - v)
                    2 -> d.copy(hdrAllow = d.hdrAllow - v, hdrBlock = d.hdrBlock + v)
                    else -> d.copy(hdrAllow = d.hdrAllow - v, hdrBlock = d.hdrBlock - v)
                }
            }

            SectionLabel("流媒体平台（同上，三态）")
            TriChips(PLATFORMS, d.platformsAllow, d.platformsBlock) { v, state ->
                d = when (state) {
                    1 -> d.copy(platformsAllow = d.platformsAllow + v, platformsBlock = d.platformsBlock - v)
                    2 -> d.copy(platformsAllow = d.platformsAllow - v, platformsBlock = d.platformsBlock + v)
                    else -> d.copy(platformsAllow = d.platformsAllow - v, platformsBlock = d.platformsBlock - v)
                }
            }

            Text("制作组白名单（逗号或空格分隔，留空不限）", style = McType.caption, color = TextFaint)
            TextField(value = d.groupsAllow, onValueChange = { d = d.copy(groupsAllow = it) }, singleLine = true,
                placeholder = { Text("如 FRDS, WiKi", style = McType.caption, color = TextFaint) },
                modifier = Modifier.fillMaxWidth())
            Text("制作组黑名单（这些组的资源一律不要）", style = McType.caption, color = TextFaint)
            TextField(value = d.groupsBlock, onValueChange = { d = d.copy(groupsBlock = it) }, singleLine = true,
                placeholder = { Text("留空不启用", style = McType.caption, color = TextFaint) },
                modifier = Modifier.fillMaxWidth())

            SectionLabel("字幕语言（任一命中即通过；不选 = 不限）")
            MultiChips(SUB_LANGS, d.subs) { v ->
                d = d.copy(subs = if (v in d.subs) d.subs - v else d.subs + v)
            }
            SectionLabel("音轨语言")
            MultiChips(AUDIO_LANGS, d.audios) { v ->
                d = d.copy(audios = if (v in d.audios) d.audios - v else d.audios + v)
            }

            ToggleRow("只要免费资源", "促销状态未知的按非免费处理", d.freeOnly) { d = d.copy(freeOnly = it) }
            ToggleRow("排除 H&R 考核种子", "有做种考核要求的资源不下载", d.excludeHr) { d = d.copy(excludeHr = it) }
            if (d.excludeHr) {
                ToggleRow(
                    "站点未提供 H&R 信息时，保守视作有考核而排除",
                    "", d.hrStrict,
                ) { d = d.copy(hrStrict = it) }
            }

            NumberRow("做种数下限", d.minSeeders, { d = d.copy(minSeeders = it) })
            NumberRow("单集体积下限 (MB)", d.sizeMin, { d = d.copy(sizeMin = it) })
            NumberRow("单集体积上限 (MB)", d.sizeMax, { d = d.copy(sizeMax = it) })
            Text(
                "体积按「每集均摊」评估：整季包用总体积 ÷ 集数比较，整季合集不会被单集上限误杀。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )

            SectionLabel("洗版")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                UPGRADE_TARGETS.forEach { (v, label) ->
                    PickerChip(label, selected = d.upgradeSource == v) { d = d.copy(upgradeSource = v) }
                }
            }
            if (d.upgradeSource.isNotBlank()) {
                Text(
                    "收齐后继续追更高版本，直到达到目标档位为止。新版本入库后旧版本进回收站保留 7 天；不开启 = 下到即止。",
                    style = McType.caption, color = TextFaint, lineHeight = 17.sp,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("", "2160p", "1080p", "720p").forEach { v ->
                        PickerChip(if (v.isBlank()) "缺省目标" else v, selected = d.cutoff == v) { d = d.copy(cutoff = v) }
                    }
                }
                ToggleRow("洗到新版本后保留旧版本", "多版本共存（收藏家模式）；关闭 = 旧版本进回收站保留 7 天", d.keepOld) {
                    d = d.copy(keepOld = it)
                }
            }

            error?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }

            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss, enabled = !busy) { Text("取消", color = TextMuted) }
                Spacer(Modifier.weight(1f))
                Button(
                    enabled = !busy && d.name.isNotBlank(),
                    onClick = {
                        val min = d.sizeMin.trim().toIntOrNull() ?: 0
                        val max = d.sizeMax.trim().toIntOrNull() ?: 0
                        if (min > 0 && max > 0 && min > max) {
                            error = "体积下限不能大于上限"
                            return@Button
                        }
                        busy = true
                        error = null
                        onSave(RuleSetPayload(name = d.name.trim(), spec = d.spec(), matchRules = d.matchRules())) { err ->
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
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, style = McType.caption, color = TextFaint, lineHeight = 17.sp)
}

@Composable
private fun PickerChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        label, style = McType.caption,
        color = if (selected) Color(0xFF141821) else TextMuted,
        modifier = Modifier.clip(RoundedCornerShape(999.dp))
            .background(if (selected) Accent else Color.White.copy(alpha = 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    )
}

@Composable
private fun OptionChips(options: List<Pair<String, String>>, onClick: (String) -> Unit) {
    if (options.isEmpty()) return
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        options.forEach { (v, label) ->
            Text(
                "＋ $label", style = McType.caption, color = Accent,
                modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.05f))
                    .clickable { onClick(v) }.padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun MultiChips(options: List<Pair<String, String>>, selected: List<String>, onClick: (String) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        options.forEach { (v, label) ->
            PickerChip(label, selected = v in selected) { onClick(v) }
        }
    }
}

/** 三态：off → 要（强调）→ 排除（红边）→ off */
@Composable
private fun TriChips(
    options: List<Pair<String, String>>,
    allow: List<String>,
    block: List<String>,
    blockOnly: List<String> = emptyList(),
    onChange: (String, Int) -> Unit,
) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        options.forEach { (v, label) ->
            val state = when {
                v in allow -> 1
                v in block -> 2
                else -> 0
            }
            Text(
                label, style = McType.caption,
                color = when (state) {
                    1 -> Color(0xFF141821)
                    2 -> Color(0xFFFF8A80)
                    else -> TextMuted
                },
                modifier = Modifier.clip(RoundedCornerShape(999.dp))
                    .background(
                        when (state) {
                            1 -> Accent
                            2 -> Color(0xFF3A1F22)
                            else -> Color.White.copy(alpha = 0.05f)
                        }
                    )
                    // 只能排除的项在「不限 ↔ 排除」之间切，不经过「要」
                    .clickable { onChange(v, if (v in blockOnly) (if (state == 2) 0 else 2) else (state + 1) % 3) }
                    .padding(horizontal = 9.dp, vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun ToggleRow(title: String, hint: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = McType.sub, color = TextPrimary, lineHeight = 19.sp)
            if (hint.isNotBlank()) Text(hint, style = McType.caption, color = TextFaint, lineHeight = 16.sp)
        }
        Spacer(Modifier.width(8.dp))
        Switch(checked = checked, onCheckedChange = onChange, colors = SwitchDefaults.colors(checkedTrackColor = Accent))
    }
}

@Composable
private fun NumberRow(label: String, value: String, onChange: (String) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = McType.caption, color = TextFaint, modifier = Modifier.weight(1f))
        TextField(
            value = value,
            onValueChange = { onChange(it.filter { c -> c.isDigit() }.take(6)) },
            singleLine = true,
            placeholder = { Text("不限", style = McType.caption, color = TextFaint) },
            modifier = Modifier.width(110.dp),
        )
    }
}
