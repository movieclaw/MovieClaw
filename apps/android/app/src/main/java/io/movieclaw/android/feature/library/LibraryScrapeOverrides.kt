package io.movieclaw.android.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.ScrapeConfigView
import io.movieclaw.android.core.model.ScrapeCountryOption
import io.movieclaw.android.core.model.ScrapeLanguageOption
import io.movieclaw.android.core.model.ScrapeSetting
import io.movieclaw.android.feature.settings.NAMING_FIELDS
import io.movieclaw.android.feature.settings.validateNaming
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/*
 * 库级刮削覆盖（iOS `ManageScrapeOverrides`）：编辑库表单里的「刮削设置」分组。
 *
 * 只存**显式覆盖**的字段：没出现在这里的键 = 跟随全局（服务端 `scrape_overrides` 同口径）。
 * 三态：卡片级「跟随全局 / 自定义」（语言、分级、海报、背景、画质）、字段级（命名模板留空即跟随）、
 * 三段选择（目录写入：跟随全局（开）/ 开 / 关）。
 */

/** 编辑库表单里的刮削覆盖草稿：键 = 服务端字段名，值 = JSON（只存被覆盖的） */
class ScrapeOverridesState(initial: JsonObject?) {
    val values = mutableStateMapOf<String, JsonElement>()

    /** 用户动过没有（区分「没覆盖」与「清空了覆盖」：清空要提交 {}） */
    var dirty by mutableStateOf(false)
        private set

    init {
        initial?.forEach { (k, v) -> values[k] = v }
    }

    fun set(key: String, value: JsonElement) {
        values[key] = value
        dirty = true
    }

    fun setAll(entries: Map<String, JsonElement>) {
        entries.forEach { (k, v) -> values[k] = v }
        dirty = true
    }

    fun removeAll(keys: Collection<String>) {
        keys.forEach { values.remove(it) }
        dirty = true
    }

    fun hasAny(keys: Collection<String>): Boolean = keys.any { values.containsKey(it) }

    fun list(key: String): List<String> =
        (values[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNullSafe() }.orEmpty()

    fun boolean(key: String): Boolean? = (values[key] as? JsonPrimitive)?.contentOrNullSafe()?.toBooleanStrictOrNull()

    fun string(key: String): String? = (values[key] as? JsonPrimitive)?.contentOrNullSafe()

    fun toJson(): JsonObject = buildJsonObject { values.forEach { (k, v) -> put(k, v) } }

    /** 保存用：没动过 → null（不改）；动过 → 当前覆盖（空对象 = 清空覆盖） */
    fun payload(): JsonObject? = if (!dirty) null else toJson()

    /** 命名覆盖的本地校验；有错误时库表单不应提交（与全局页同一套 token 白名单） */
    fun namingError(): String? = NAMING_FIELDS.firstNotNullOfOrNull { field ->
        string(field.key)?.takeIf { it.isNotBlank() }?.let { validateNaming(it, field.allowed) }
    }
}

private fun JsonPrimitive.contentOrNullSafe(): String = content

/** iOS 的卡片分组：卡片 → 它管的字段 */
private val OVERRIDE_CARDS = listOf(
    "meta" to listOf("language_priority"),
    "cert" to listOf("cert_country_priority"),
    "poster" to listOf("poster_mode", "poster_language_priority", "poster_min_width", "poster_size"),
    "backdrop" to listOf("backdrop_language_priority", "backdrop_min_width", "backdrop_size"),
    "quality" to listOf("image_quality", "poster_size", "backdrop_size", "still_size", "profile_size"),
    "naming" to listOf("naming_entry_dir", "naming_movie_file", "naming_season_dir", "naming_episode_file"),
    "mirror" to listOf("mirror_images", "mirror_nfo", "mirror_episode_thumbs"),
)

private val IMAGE_TOKENS = listOf("meta" to "跟随元数据主语言", "orig" to "原始语言", "null" to "无文字")
private val MIRROR_FIELDS = listOf(
    "mirror_images" to "条目图片",
    "mirror_nfo" to "NFO 元数据",
    "mirror_episode_thumbs" to "分集剧照",
)

/** 库级「刮削设置」分组（iOS `ManageScrapeOverrides` 的三态卡片版） */
@Composable
fun LibraryScrapeOverridesSection(
    state: ScrapeOverridesState,
    global: ScrapeConfigView?,
    languages: List<ScrapeLanguageOption>,
    countries: List<ScrapeCountryOption>,
) {
    var open by androidx.compose.runtime.remember { mutableStateOf(false) }
    val g = global?.setting ?: ScrapeSetting()
    val overridden = OVERRIDE_CARDS.sumOf { (_, keys) -> if (state.hasAny(keys)) 1 else 0 }

    Row(
        Modifier.fillMaxWidth().clickable { open = !open }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("刮削设置", style = McType.subheadlineSemibold, color = TextPrimary)
            Text(
                if (overridden == 0) "跟随全局设置" else "已覆盖 $overridden 组",
                style = McType.caption, color = TextFaint,
            )
        }
        Text(if (open) "收起" else "展开", style = McType.caption, color = Accent)
    }
    if (!open) return

    Text(
        "本库单独的刮削口味，未显式修改的项跟随「设置 → 刮削与整理」。",
        style = McType.caption, color = TextFaint, lineHeight = 18.sp,
    )
    Spacer(Modifier.height(6.dp))
    if (overridden > 0) {
        TextButton(onClick = {
            state.removeAll(OVERRIDE_CARDS.flatMap { it.second } + MIRROR_FIELDS.map { it.first })
        }) { Text("全部恢复跟随", color = Color(0xFFFF8A80), style = McType.caption) }
    }

    OverrideCard("元数据语言", state, "meta", seed = { mapOf("language_priority" to JsonArray(g.languagePriority.map { JsonPrimitive(it) })) }) {
        OrderedChips(
            values = state.list("language_priority").ifEmpty { g.languagePriority },
            options = languages.map { it.code to it.name.ifBlank { it.code } },
            onChange = { state.set("language_priority", JsonArray(it.map { s -> JsonPrimitive(s) })) },
        )
    }
    OverrideCard("内容分级", state, "cert", seed = { mapOf("cert_country_priority" to JsonArray(g.certCountryPriority.map { JsonPrimitive(it) })) }) {
        OrderedChips(
            values = state.list("cert_country_priority").ifEmpty { g.certCountryPriority },
            options = countries.map { it.code to "${it.name}(${it.code})" },
            onChange = { state.set("cert_country_priority", JsonArray(it.map { s -> JsonPrimitive(s) })) },
        )
    }
    OverrideCard("海报", state, "poster", seed = { mapOf("poster_language_priority" to JsonArray(g.posterLanguagePriority.map { JsonPrimitive(it) })) }) {
        val posterMode = state.string("poster_mode") ?: g.posterMode
        Text("选择方式", style = McType.caption, color = TextFaint)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(vertical = 4.dp)) {
            listOf("default" to "TMDB 默认", "language" to "按语言优先级").forEach { (v, label) ->
                ChoiceChip(label, posterMode == v) { state.set("poster_mode", JsonPrimitive(v)) }
            }
        }
        OrderedChips(
            values = state.list("poster_language_priority").ifEmpty { g.posterLanguagePriority },
            options = IMAGE_TOKENS + languages.map { it.code to it.name.ifBlank { it.code } },
            onChange = { state.set("poster_language_priority", JsonArray(it.map { s -> JsonPrimitive(s) })) },
        )
    }
    OverrideCard("背景图", state, "backdrop", seed = { mapOf("backdrop_language_priority" to JsonArray(g.backdropLanguagePriority.map { JsonPrimitive(it) })) }) {
        OrderedChips(
            values = state.list("backdrop_language_priority").ifEmpty { g.backdropLanguagePriority },
            options = IMAGE_TOKENS + languages.map { it.code to it.name.ifBlank { it.code } },
            onChange = { state.set("backdrop_language_priority", JsonArray(it.map { s -> JsonPrimitive(s) })) },
        )
    }
    OverrideCard("图片画质", state, "quality", seed = { mapOf("image_quality" to JsonPrimitive(g.imageQuality.ifBlank { "original" })) }) {
        listOf(
            Triple("original", "原图（默认）", "所有图存 TMDB 原图"),
            Triple("standard", "标准", "省约四成空间"),
            Triple("compact", "节省空间", "手机和网页够用"),
            Triple("custom", "自定义", "逐项指定档位"),
        ).forEach { (v, name, why) ->
            Row(
                Modifier.fillMaxWidth()
                    .clickable { state.set("image_quality", JsonPrimitive(v)) }
                    .padding(vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(name, style = McType.sub, color = TextPrimary)
                    Text(why, style = McType.caption, color = TextFaint)
                }
                if (state.string("image_quality") == v) Text("✓", style = McType.caption, color = Accent)
            }
        }
        if (state.string("image_quality") == "custom") {
            listOf(
                "poster_size" to ("海报" to listOf("original", "w780", "w500", "w342", "w185")),
                "backdrop_size" to ("背景" to listOf("original", "w1280", "w780", "w300")),
                "still_size" to ("剧照" to listOf("original", "w300", "w185", "w92")),
                "profile_size" to ("头像" to listOf("original", "w185", "h632", "w45")),
            ).forEach { (key, meta) ->
                val (label, options) = meta
                Text(label, style = McType.caption, color = TextFaint, modifier = Modifier.padding(top = 6.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    val current = state.string(key)
                    ChoiceChip("跟随", current == null) { state.removeAll(listOf(key)) }
                    options.forEach { v ->
                        ChoiceChip(v, current == v) { state.set(key, JsonPrimitive(v)) }
                    }
                }
            }
        }
    }

    // 命名模板：字段级三态（留空 = 跟随全局）
    Text("命名模板", style = McType.subheadlineSemibold, color = TextPrimary, modifier = Modifier.padding(top = 10.dp))
    Text(
        "留空即跟随全局模板。命名的产物是本库目录树里的路径，所以每个库可以各用一套。",
        style = McType.caption, color = TextFaint, lineHeight = 18.sp,
    )
    listOf(
        "naming_entry_dir" to ("条目目录" to g.namingEntryDir),
        "naming_movie_file" to ("电影文件名" to g.namingMovieFile),
        "naming_season_dir" to ("季目录" to g.namingSeasonDir),
        "naming_episode_file" to ("剧集文件名" to g.namingEpisodeFile),
    ).forEach { (key, meta) ->
        val (title, globalValue) = meta
        var text by androidx.compose.runtime.remember { mutableStateOf(state.string(key).orEmpty()) }
        // 外部恢复/清空时同步；输入过程中不重建状态，避免光标与输入法被打断
        LaunchedEffect(state.string(key)) {
            val v = state.string(key).orEmpty()
            if (v != text) text = v
        }
        val field = NAMING_FIELDS.firstOrNull { it.key == key }
        val error = field?.let { validateNaming(text, it.allowed) }
        Row(Modifier.fillMaxWidth().padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = McType.caption, color = TextMuted, modifier = Modifier.width(78.dp))
            Column(Modifier.weight(1f)) {
                TextField(
                    value = text,
                    onValueChange = {
                        text = it
                        if (it.isBlank()) state.removeAll(listOf(key))
                        else state.set(key, JsonPrimitive(it))
                    },
                    singleLine = true,
                    isError = error != null,
                    placeholder = {
                        Text(
                            "跟随全局（${globalValue.ifBlank { "默认模板" }}）",
                            style = McType.caption, color = TextFaint,
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                if (error != null) {
                    Text(error, style = McType.caption, color = Color(0xFFFF8A80))
                }
            }
        }
    }

    // 目录写入：三段（跟随全局（开/关）/ 开 / 关）
    Text("媒体目录写入", style = McType.subheadlineSemibold, color = TextPrimary, modifier = Modifier.padding(top = 10.dp))
    val globalMirrors = mapOf(
        "mirror_images" to g.mirrorImages,
        "mirror_nfo" to g.mirrorNfo,
        "mirror_episode_thumbs" to g.mirrorEpisodeThumbs,
    )
    MIRROR_FIELDS.forEach { (key, title) ->
        val current = state.boolean(key)
        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(
                null to "跟随全局（${if (globalMirrors[key] == true) "开" else "关"}）",
                true to "开",
                false to "关",
            ).forEach { (v, label) ->
                val selected = current == v
                Text(
                    label, style = McType.caption,
                    color = if (selected) Color(0xFF141821) else TextMuted,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(if (selected) Accent else Color.White.copy(alpha = 0.06f))
                        .clickable {
                            if (v == null) state.removeAll(listOf(key))
                            else state.set(key, JsonPrimitive(v))
                        }
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                )
            }
        }
        Spacer(Modifier.height(4.dp))
    }
    Text(
        "语言与选图的产物挂在条目上，按条目的「刮削归属库」生效；命名与目录写入按文件所在库生效。",
        style = McType.caption, color = TextFaint, lineHeight = 18.sp, modifier = Modifier.padding(top = 6.dp),
    )
}

/** 卡片级三态：跟随全局 / 自定义（自定义时把全局值作为起点写进 overrides） */
@Composable
private fun OverrideCard(
    title: String,
    state: ScrapeOverridesState,
    card: String,
    seed: () -> Map<String, JsonElement> = { emptyMap() },
    content: @Composable () -> Unit,
) {
    val keys = OVERRIDE_CARDS.first { it.first == card }.second
    val custom = state.hasAny(keys)
    Column(Modifier.padding(top = 10.dp)) {
        // 标题行只留标题：当前态由下面两颗按钮的选中样式表达（曾在这里多渲染一对文字，和按钮重复）
        Text(title, style = McType.subheadlineSemibold, color = TextPrimary)
        Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                "跟随全局", style = McType.caption,
                color = if (!custom) Color(0xFF141821) else TextMuted,
                modifier = Modifier.clip(RoundedCornerShape(999.dp))
                    .background(if (!custom) Accent else Color.White.copy(alpha = 0.06f))
                    .clickable { if (custom) state.removeAll(keys) }
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            )
            Text(
                "自定义", style = McType.caption,
                color = if (custom) Color(0xFF141821) else TextMuted,
                modifier = Modifier.clip(RoundedCornerShape(999.dp))
                    .background(if (custom) Accent else Color.White.copy(alpha = 0.06f))
                    .clickable {
                        // 切到自定义：以全局当前值为起点（iOS 同做法），免得保存出一份空覆盖
                        if (!custom) state.setAll(seed())
                    }
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            )
        }
        if (custom) {
            Spacer(Modifier.height(6.dp))
            content()
        }
    }
}

/** 有序列表编辑：序号 + 名称 + 上移/下移/移除 + 底部「＋ 添加」 */
@Composable
private fun OrderedChips(
    values: List<String>,
    options: List<Pair<String, String>>,
    onChange: (List<String>) -> Unit,
) {
    var adding by androidx.compose.runtime.remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        io.movieclaw.android.feature.settings.DragReorderList(
            items = values,
            label = { c -> options.firstOrNull { it.first == c }?.second ?: c },
            onOrder = onChange,
            onRemove = { onChange(values - it) },
        )
        Text(
            "＋ 添加", style = McType.caption, color = Accent,
            modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.06f))
                .clickable { adding = !adding }.padding(horizontal = 10.dp, vertical = 5.dp),
        )
        if (adding) {
            Column(Modifier.padding(top = 4.dp)) {
                options.filter { it.first !in values }.forEach { (code, name) ->
                    Text(
                        name, style = McType.caption, color = TextPrimary,
                        modifier = Modifier.fillMaxWidth().clickable { onChange(values + code); adding = false }
                            .padding(vertical = 6.dp),
                    )
                }
            }
        }
    }
}


@Composable
private fun ChoiceChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        label, style = McType.caption,
        color = if (selected) Color(0xFF141821) else TextMuted,
        modifier = Modifier.clip(RoundedCornerShape(999.dp))
            .background(if (selected) Accent else Color.White.copy(alpha = 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    )
}
