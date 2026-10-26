package io.movieclaw.android.feature.settings

/**
 * 命名模板的纯逻辑（照 iOS `SettingsBScrapeModel` / 服务端 `naming.py` 的口径）：
 * 占位符集合、轻校验、以及「实时预览」用的样例渲染。
 *
 * 真正落盘以后端为准；这里只负责给用户即时反馈（与 iOS 的预览同一套规则）。
 */

/** 一个命名字段（服务端 key / 界面标题 / 默认模板 / 可用占位符） */
data class NamingField(
    val key: String,
    val title: String,
    val default: String,
    val allowed: Set<String>,
)

private val COMMON = setOf(
    "title", "original_title", "english_title", "year", "tmdb_id", "imdb_id", "douban_id",
)
/** 与服务端 `naming.ALLOWED_TOKENS[_FILE_ATTRS]` 逐项一致 */
private val FILE_ATTRS = setOf(
    "resolution", "media_source", "release_group", "video_codec", "hdr", "bit_depth", "audio",
    "site", "release_name",
)

val NAMING_FIELDS: List<NamingField> = listOf(
    NamingField("naming_entry_dir", "条目目录", "{title} ({year})", COMMON),
    NamingField("naming_movie_file", "电影文件名", "{title} ({year})", COMMON + FILE_ATTRS),
    NamingField("naming_season_dir", "季目录", "Season {season:02d}", COMMON + setOf("season", "season_name")),
    NamingField(
        "naming_episode_file", "剧集文件名", "{title} ({year}) - S{season:02d}E{episode:02d}",
        COMMON + FILE_ATTRS + setOf("season", "season_name", "episode", "episode_title"),
    ),
)

/** 占位符插入菜单的分组（与 iOS 同一套名称与顺序） */
val NAMING_TOKEN_GROUPS: List<Pair<String, List<Pair<String, String>>>> = listOf(
    "片名与编号" to listOf(
        "title" to "片名", "original_title" to "原名", "english_title" to "英文名",
        "year" to "年份", "tmdb_id" to "TMDB ID", "imdb_id" to "IMDb ID", "douban_id" to "豆瓣 ID",
    ),
    "季集" to listOf(
        "season" to "季号", "season_name" to "季名", "episode" to "集号", "episode_title" to "集名",
    ),
    "文件规格" to listOf(
        "resolution" to "分辨率", "media_source" to "片源", "video_codec" to "视频编码", "hdr" to "HDR",
        "bit_depth" to "位深", "audio" to "音轨",
    ),
    "来源" to listOf(
        "release_group" to "发布组", "site" to "站点", "release_name" to "原始文件名",
    ),
)

private val TOKEN = Regex("""\{([a-z_]+)(?::([^}]*))?\}""")

/** 空模板合法（= 用默认模板）；否则不许路径分隔符、不许当前字段用不了的占位符 */
fun validateNaming(template: String, allowed: Set<String>): String? {
    if (template.isBlank()) return null
    if (template.contains('/') || template.contains('\\')) return "不能包含路径分隔符（目录层级是固定的）"
    val bad = TOKEN.findAll(template).map { it.groupValues[1] }.filter { it !in allowed }.toList()
    return if (bad.isEmpty()) null else "不可用的占位符：" + bad.joinToString("、") { "{$it}" }
}

/** 电影 / 剧集两条预览样例（值照 iOS 的示例片：沙丘：第二部、风筝） */
private val MOVIE_VALUES = mapOf(
    "title" to "沙丘：第二部", "original_title" to "Dune: Part Two", "english_title" to "Dune: Part Two",
    "year" to "2024", "tmdb_id" to "693134", "imdb_id" to "tt15239678", "douban_id" to "36048208",
    "resolution" to "2160p", "video_codec" to "HEVC", "hdr" to "DV", "bit_depth" to "10",
    "audio" to "TrueHD Atmos", "media_source" to "BluRay", "release_group" to "FRDS", "site" to "M-Team",
    "release_name" to "Dune.Part.Two.2024.2160p.BluRay.x265.10bit.TrueHD.Atmos-FRDS",
    "season" to "", "season_name" to "", "episode" to "", "episode_title" to "",
)
private val EPISODE_VALUES = MOVIE_VALUES + mapOf(
    "title" to "风筝", "original_title" to "风筝", "english_title" to "Kite",
    "year" to "2017", "resolution" to "1080p", "video_codec" to "H.264", "hdr" to "SDR",
    "bit_depth" to "", "audio" to "AAC", "media_source" to "WEB-DL", "release_group" to "CHDWEB",
    "release_name" to "Kite.2017.S01E03.1080p.WEB-DL.AAC-CHDWEB",
    "season" to "1", "season_name" to "第一季", "episode" to "3", "episode_title" to "风起",
)

/** 渲染一条模板（取值、去重片名、丢空括号组、补零、清非法字符、收缩） */
fun renderNaming(template: String, values: Map<String, String>): String {
    if (template.isBlank()) return ""
    // 片名类：同一模板里值相同的只保留第一次出现（纯函数，不能靠调用顺序记状态）
    val titleNames = listOf("title", "original_title", "english_title")
    val seen = HashSet<String>()
    val blanked = titleNames.associateWith { n ->
        val v = values[n].orEmpty()
        v.isNotEmpty() && !seen.add(v)
    }
    fun valueOf(name: String): String = if (blanked[name] == true) "" else values[name].orEmpty()

    // 括号组：组内占位符全部渲染为空时整组（含字面量）丢掉
    val group = Regex("""([(\[【])([^()\[\]【】]*)([)\]】])""")
    var text = group.replace(template) { m ->
        val inner = m.groupValues[2]
        val renderedInner = renderTokens(inner, ::valueOf)
        if (TOKEN.containsMatchIn(inner) && renderedInner.isBlank()) "" else renderTokens(m.value, ::valueOf)
    }
    text = renderTokens(text, ::valueOf)
    // 收缩：空白、连续分隔符、首尾分隔符
    text = text.replace(Regex("""\s+"""), " ")
    text = text.replace(Regex("""(?:\s*-\s*){2,}"""), " - ")
    text = text.replace(Regex("""\s*-\s*$"""), "").replace(Regex("""^-\s*"""), "")
    text = text.trim().trim('.', ' ')
    // 非法字符
    text = text.replace(Regex("""[\/:*?"<>|]"""), "")
    return text.trim().ifEmpty { "未命名" }
}

private fun renderTokens(text: String, valueOf: (String) -> String): String =
    TOKEN.replace(text) { m ->
        val name = m.groupValues[1]
        val fmt = m.groupValues.getOrNull(2).orEmpty()
        val raw = valueOf(name)
        // {season:02d} 这类补零格式
        if (fmt.endsWith("d") && raw.toIntOrNull() != null) {
            val width = fmt.dropLast(1).substringAfter(':').toIntOrNull() ?: 0
            raw.toInt().toString().padStart(width, '0')
        } else raw
    }

/** 预览用：把四个模板 + 样例值拼成两条路径（电影 / 剧集两条） */
fun previewPaths(templates: Map<String, String>, movie: Boolean): String {
    val values = if (movie) MOVIE_VALUES else EPISODE_VALUES
    // 空模板 = 用默认模板（与保存后的行为一致）
    fun tpl(key: String): String {
        val f = NAMING_FIELDS.first { it.key == key }
        return templates[key].orEmpty().ifBlank { f.default }
    }
    val entry = renderNaming(tpl("naming_entry_dir"), values)
    return if (movie) {
        val file = renderNaming(tpl("naming_movie_file"), values)
        "$entry/$file.mkv"
    } else {
        val season = renderNaming(tpl("naming_season_dir"), values)
        val file = renderNaming(tpl("naming_episode_file"), values)
        "$entry/$season/$file.mkv"
    }
}
