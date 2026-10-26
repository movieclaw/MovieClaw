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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
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
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.ScrapeConfigView
import io.movieclaw.android.core.model.ScrapeCountryOption
import io.movieclaw.android.core.model.ScrapeLanguageOption
import io.movieclaw.android.core.model.ScrapeFanartKeyPayload
import io.movieclaw.android.core.model.ScrapeSetting
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import io.movieclaw.android.core.designsystem.formSheetScroll

/**
 * 刮削与整理 —— 严格照**网页移动端真实页面**实现（用户截图核对）：
 * 头部（图标+标题+副标题+说明段）→ 四个分组（元数据/图片/命名与整理/目录写入）
 * → 每行「标题 + 右侧摘要 + ˅」→ 点开底部编辑层；目录写入是三行行内开关；
 * **改动自动保存**（无底部保存按钮）。
 */
@HiltViewModel
class ScrapeSettingsViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val error: String? = null,
        val config: ScrapeConfigView = ScrapeConfigView(),
        val languages: List<ScrapeLanguageOption> = emptyList(),
        val countries: List<ScrapeCountryOption> = emptyList(),
        val storage: io.movieclaw.android.core.model.ScrapeStorageEstimate? = null,
        val fanart: io.movieclaw.android.core.model.ScrapeFanartView? = null,
        /** 媒体库清单：用来在卡片上标「N 个媒体库单独设置」，以及编辑页底部列出库名 */
        val libraries: List<io.movieclaw.android.core.model.LibraryView> = emptyList(),
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui.asStateFlow()

    private fun api() = repository.ui.value.origin?.let { apiFactory.forOrigin(it) }

    fun load() {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            val api = api()
            if (api == null) {
                _ui.value = _ui.value.copy(loading = false, error = "还没有连上服务器")
                return@launch
            }
            val langs = runCatching { api.scrapeLanguages().dataOrThrow() }.getOrDefault(emptyList())
            val countries = runCatching { api.scrapeCountries().dataOrThrow() }.getOrDefault(emptyList())
            val storage = runCatching { api.scrapeStorageEstimate().dataOrThrow() }.getOrNull()
            val fanart = runCatching { api.scrapeFanartShow().dataOrThrow() }.getOrNull()
            val libraries = runCatching { api.libraries().dataOrThrow() }.getOrDefault(emptyList())
            runCatching { api.scrapeShow().dataOrThrow() }
                .onSuccess { c ->
                    _ui.value = Ui(
                        loading = false, config = c, languages = langs, countries = countries,
                        storage = storage, fanart = fanart, libraries = libraries,
                    )
                }
                .onFailure { e -> _ui.value = _ui.value.copy(loading = false, error = e.message ?: "读取失败") }
        }
    }

    /** 自动保存串行化：整份 setting 提交，避免连续操作时旧请求后到覆盖新值 */
    private val saveLock = Mutex()
    private var editVersion = 0

    /** 改动自动保存：整份 setting 提交 */
    private fun editAndSave(block: (ScrapeSetting) -> ScrapeSetting) {
        val previous = _ui.value.config
        val next = block(previous.setting)
        val version = ++editVersion
        _ui.value = _ui.value.copy(config = previous.copy(setting = next))
        viewModelScope.launch {
            saveLock.withLock {
                val api = api() ?: return@withLock
                runCatching { api.scrapeSet(next).dataOrThrow() }
                    .onSuccess { c ->
                        // 只有最后一次改动能回写服务端结果；中间结果不能覆盖后续编辑
                        if (version == editVersion) _ui.value = _ui.value.copy(config = c, error = null)
                    }
                    .onFailure { e ->
                        val message = e.message ?: "保存失败"
                        if (version == editVersion) {
                            // 最后一次失败：回滚到这次改动前的状态
                            _ui.value = _ui.value.copy(config = previous, error = message)
                        } else {
                            _ui.value = _ui.value.copy(error = message)
                        }
                    }
            }
        }
    }

    /** 编辑起点：设置为空（跟随环境 / 默认）时，用界面上显示的那一份，别对空列表增删 */
    private fun seedList(key: String, s: ScrapeSetting): List<String> = when (key) {
        "meta" -> s.languagePriority.ifEmpty { _ui.value.config.effective.languagePriority }
        "cert" -> s.certCountryPriority.ifEmpty { _ui.value.config.effective.certCountryPriority }
        // 海报/背景的空列表是「没有偏好」，不再回填内置默认值——否则删光后加一项
        // 会把之前删掉的项一起复活。
        "poster" -> s.posterLanguagePriority
        "backdrop" -> s.backdropLanguagePriority
        else -> s.logoLanguagePriority ?: listOf("meta", "en", "orig", "null")
    }

    fun toggle(key: String, code: String) = editAndSave { s ->
        fun t(list: List<String>) = if (list.contains(code)) list - code else list + code
        val base = seedList(key, s)
        when (key) {
            "meta" -> s.copy(languagePriority = t(base))
            "cert" -> s.copy(certCountryPriority = t(base))
            "poster" -> s.copy(posterLanguagePriority = t(base))
            "backdrop" -> s.copy(backdropLanguagePriority = t(base))
            else -> s.copy(logoLanguagePriority = t(base))
        }
    }

    fun setQuality(q: String) = editAndSave { it.copy(imageQuality = q) }
    fun setPosterMode(mode: String) = editAndSave { it.copy(posterMode = mode) }
    fun setSize(key: String, v: String) = editAndSave { s ->
        when (key) {
            "poster_size" -> s.copy(posterSize = if (v == "跟随") "" else v)
            "backdrop_size" -> s.copy(backdropSize = if (v == "跟随") "" else v)
            "still_size" -> s.copy(stillSize = if (v == "跟随") "" else v)
            else -> s.copy(profileSize = if (v == "跟随") "" else v)
        }
    }
    fun setMinWidth(key: String, v: Int) = editAndSave { s ->
        if (key == "poster") s.copy(posterMinWidth = v) else s.copy(backdropMinWidth = v)
    }
    fun setFanart(on: Boolean) = editAndSave { it.copy(fanartEnabled = on) }
    /** 命名模板一次保存四项（编辑页有「保存」按钮，不像其它行那样即时保存） */
    fun setNamingAll(entry: String, movie: String, season: String, episode: String) = editAndSave {
        it.copy(
            namingEntryDir = entry.trim(),
            namingMovieFile = movie.trim(),
            namingSeasonDir = season.trim(),
            namingEpisodeFile = episode.trim(),
        )
    }

    /** 拖动排序结束：整份顺序保存一次 */
    fun setOrder(key: String, list: List<String>) = editAndSave { s ->
        when (key) {
            "meta" -> s.copy(languagePriority = list)
            "cert" -> s.copy(certCountryPriority = list)
            "poster" -> s.copy(posterLanguagePriority = list)
            "backdrop" -> s.copy(backdropLanguagePriority = list)
            else -> s.copy(logoLanguagePriority = list)
        }
    }

    /** 移除一项（原来点 chip = 移出；现在移除有独立按钮） */
    fun remove(key: String, code: String) = editAndSave { s ->
        val seeded = seedList(key, s)
        when (key) {
            "meta" -> s.copy(languagePriority = seeded - code)
            "cert" -> s.copy(certCountryPriority = seeded - code)
            "poster" -> s.copy(posterLanguagePriority = seeded - code)
            "backdrop" -> s.copy(backdropLanguagePriority = seeded - code)
            else -> s.copy(logoLanguagePriority = seeded - code)
        }
    }

    /** 某一类图片的来源顺序（poster / backdrop / logo / season），默认值同 iOS */
    fun sourceOrder(s: ScrapeSetting, cat: String): List<String> = when (cat) {
        "poster" -> s.posterSourceOrder ?: listOf("tmdb", "fanart")
        "backdrop" -> s.backdropSourceOrder ?: listOf("tmdb", "fanart")
        "logo" -> s.logoSourceOrder ?: listOf("fanart", "tmdb")
        else -> s.seasonPosterSourceOrder ?: listOf("fanart", "tmdb")
    }

    /** 交换一类来源的先后（只有 TMDB / Fanart 两个来源，等价于拖动排序） */
    fun swapSource(cat: String) = editAndSave { s ->
        val next = sourceOrder(s, cat).reversed()
        when (cat) {
            "poster" -> s.copy(posterSourceOrder = next)
            "backdrop" -> s.copy(backdropSourceOrder = next)
            "logo" -> s.copy(logoSourceOrder = next)
            else -> s.copy(seasonPosterSourceOrder = next)
        }
    }

    /** 保存 Fanart API Key：验证成功才落盘，并尝试启用 Fanart（iOS 同口径） */
    fun saveFanartKey(key: String, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            val api = api() ?: return@launch onResult("还没有连上服务器")
            runCatching { api.scrapeFanartSetKey(ScrapeFanartKeyPayload(key.trim())).dataOrThrow() }
                .onSuccess { status ->
                    _ui.value = _ui.value.copy(fanart = status, error = null)
                    if (status.configured && !status.keyInvalid) {
                        editAndSave { it.copy(fanartEnabled = true) }
                        val fresh = runCatching { api.scrapeFanartShow().dataOrThrow() }.getOrNull()
                        if (fresh != null) _ui.value = _ui.value.copy(fanart = fresh)
                        onResult(null)
                    } else {
                        onResult("密钥验证失败，请检查后重试")
                    }
                }
                .onFailure { onResult(it.message ?: "验证失败，请稍后重试") }
        }
    }

    /** 某张卡片被多少个库单独覆盖（字段集合见 iOS `ManageScrapeOverrides.card.keys`） */
    fun overriddenCount(card: String): Int {
        val keys = CARD_KEYS[card] ?: return 0
        return _ui.value.libraries.count { lib ->
            val overrides = lib.scrapeOverrides ?: return@count false
            keys.any { overrides.containsKey(it) }
        }
    }

    fun setMirror(key: String, on: Boolean) = editAndSave { s ->
        when (key) {
            "images" -> s.copy(mirrorImages = on)
            "nfo" -> s.copy(mirrorNfo = on)
            else -> s.copy(mirrorEpisodeThumbs = on)
        }
    }
}

/** 每张卡片管的字段（iOS `ManageScrapeOverrides.card.keys` 的同口径子集）：覆盖统计与「已单独设置」用 */
private val CARD_KEYS: Map<String, List<String>> = mapOf(
    "meta" to listOf("language_priority"),
    "cert" to listOf("cert_country_priority"),
    "poster" to listOf("poster_mode", "poster_language_priority", "poster_min_width", "poster_size"),
    "backdrop" to listOf("backdrop_language_priority", "backdrop_min_width", "backdrop_size"),
    "logo" to listOf("logo_language_priority"),
    "quality" to listOf("image_quality", "poster_size", "backdrop_size", "still_size", "profile_size"),
    "naming" to listOf("naming_entry_dir", "naming_movie_file", "naming_season_dir", "naming_episode_file"),
    "mirror" to listOf("mirror_images", "mirror_nfo", "mirror_episode_thumbs"),
)

/** 图片语言特殊 token（网页 IMAGE_LANG_TOKENS） */
private val TOKENS = listOf("meta" to "跟随元数据主语言", "orig" to "原始语言", "null" to "无文字")

private val QUALITY = listOf(
    Triple("original", "原图（默认）", "所有图存 TMDB 原图，各设备都最清楚"),
    Triple("standard", "标准", "各设备都清楚，头像与海报不存原图，省约四成空间"),
    Triple("compact", "节省空间", "手机和网页够用；电视上剧照、头像会发虚"),
    Triple("custom", "自定义", "海报、背景、剧照、头像逐项指定 TMDB 档位"),
)

private val CUSTOM_SIZES = listOf(
    Triple("poster_size", "海报", listOf("跟随", "original", "w780", "w500", "w342", "w185")),
    Triple("backdrop_size", "背景", listOf("跟随", "original", "w1280", "w780", "w300")),
    Triple("still_size", "剧照", listOf("跟随", "original", "w300", "w185", "w92")),
    Triple("profile_size", "头像", listOf("跟随", "original", "w185", "h632", "w45")),
)

private enum class Sheet { MetaLang, Cert, Sources, Poster, Backdrop, Logo, MinWidth, Quality, Naming }

private data class Pick(val title: String, val key: String, val rows: List<Pair<String, String>>)

@Composable
fun ScrapeSettingsScreen(onBack: () -> Unit, vm: ScrapeSettingsViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    var sheet by remember { mutableStateOf<Sheet?>(null) }
    var pick by remember { mutableStateOf<Pick?>(null) }
    var keyDialog by remember { mutableStateOf(false) }
    val badgeOf: (String) -> String? = { card ->
        vm.overriddenCount(card).takeIf { it > 0 }?.let { "$it 个媒体库单独设置" }
    }
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.load() }

    val langName: (String) -> String = { c -> ui.languages.firstOrNull { it.code == c }?.name ?: c }
    val tokenName: (String) -> String = { c -> TOKENS.firstOrNull { it.first == c }?.second ?: langName(c) }
    val countryName: (String) -> String = { c -> ui.countries.firstOrNull { it.code == c }?.name ?: c }

    Column(Modifier.fillMaxSize().background(Bg)) {
        SettingsTopBar(title = "刮削与整理", onBack = onBack)
        if (ui.loading) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            return@Column
        }
        val s = ui.config.setting
        val eff = ui.config.effective

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (ui.error != null) Text(ui.error!!, style = McType.caption, color = Color(0xFFFF8A80))

            Text(
                "全站默认的刮削口味，改动自动保存，对新刮削立即生效；已入库的条目在媒体库执行" +
                    "「刷新元数据」后按新配置更新。任意一项都可以在「编辑库 → 刮削设置」里单独覆盖，" +
                    "没被覆盖的库跟随这里。",
                style = McType.footnote, color = TextMuted, lineHeight = 21.sp,
            )

            Group("元数据", "标题、简介等文本的语言，以及内容分级取哪个地区") {
                RowItem(
                    "元数据语言",
                    s.languagePriority.ifEmpty { eff.languagePriority }.joinToString(" → ", transform = langName)
                        .ifBlank { "未设置" },
                    badge = badgeOf("meta"),
                ) { sheet = Sheet.MetaLang }
                RowItem("内容分级", s.certCountryPriority.joinToString(" → ", transform = countryName).ifBlank { "未设置" }, badge = badgeOf("cert")) {
                    sheet = Sheet.Cert
                }
            }

            Group("图片", "从哪些图库挑图、各类图按什么语言挑，以及本地存多大") {
                RowItem("图片来源", sourceSummary(s)) { sheet = Sheet.Sources }
                RowItem("海报", s.posterLanguagePriority.joinToString(" → ", transform = tokenName).ifBlank { "TMDB 默认" }, badge = badgeOf("poster")) {
                    sheet = Sheet.Poster
                }
                RowItem("背景图", s.backdropLanguagePriority.joinToString(" → ", transform = tokenName).ifBlank { "TMDB 默认" }, badge = badgeOf("backdrop")) {
                    sheet = Sheet.Backdrop
                }
                RowItem(
                    "片名 Logo",
                    (s.logoLanguagePriority ?: emptyList()).joinToString(" → ", transform = tokenName)
                        .ifBlank { "跟随元数据主语言 → English → 原始语言 → 无文字" },
                    badge = badgeOf("logo"),
                ) { sheet = Sheet.Logo }
                RowItem("最低分辨率门槛", "海报 ≥${s.posterMinWidth} · 背景 ≥${s.backdropMinWidth}") {
                    sheet = Sheet.MinWidth
                }
                RowItem("本地图片画质", qualitySummary(s, ui.storage?.currentBytes ?: 0), badge = badgeOf("quality")) { sheet = Sheet.Quality }
            }

            Group("命名与整理", "整理入库时的目录与文件命名") {
                val allDefault = listOf(s.namingEntryDir, s.namingMovieFile, s.namingSeasonDir, s.namingEpisodeFile)
                    .all { it.isBlank() }
                RowItem("命名模板", if (allDefault) "全部默认模板" else "已自定义", badge = badgeOf("naming")) { sheet = Sheet.Naming }
            }

            Group(
                "目录写入",
                "把刮削成果写入媒体目录，反哺 Emby / Jellyfin / Kodi。只增不删，已存在的 NFO 绝不覆盖；" +
                    "每个媒体库还有一个总开关。",
            ) {
                SwitchItem("条目图片", "poster.jpg / fanart.jpg / clearlogo.png / 季海报", s.mirrorImages) {
                    vm.setMirror("images", it)
                }
                SwitchItem("NFO 元数据", "tvshow.nfo / movie.nfo / 分集 NFO，含 tmdbid 精确身份", s.mirrorNfo) {
                    vm.setMirror("nfo", it)
                }
                SwitchItem("分集剧照", "每集一张 -thumb.jpg，长剧集写入量最大，可单独关闭", s.mirrorEpisodeThumbs) {
                    vm.setMirror("thumbs", it)
                }
            }

            Spacer(Modifier.height(28.dp))
        }
    }

    sheet?.let { sh ->
        EditorSheet(
            sh, ui, langName, tokenName, countryName, vm,
            onDismiss = { sheet = null }, onPick = { pick = it },
            onOpenFanartKey = { keyDialog = true },
        )
    }
    if (keyDialog) {
        FanartKeyDialog(ui.fanart, vm, onDismiss = { keyDialog = false })
    }
    pick?.let { p ->
        PickSheet(p, onDismiss = { pick = null }) { key, code ->
            // 自定义档位与语言/来源是两类字段，不能都走 toggle（toggle 的 else 是 logo 语言）
            when (key) {
                "poster_size", "backdrop_size", "still_size", "profile_size" -> vm.setSize(key, code)
                else -> vm.toggle(key, code)
            }
            pick = null
        }
    }
}

@Composable
private fun Group(title: String, subtitle: String, content: @Composable () -> Unit) {
    Column(Modifier.padding(top = 10.dp)) {
        Text(title, style = McType.title3, color = TextPrimary)
        Spacer(Modifier.height(3.dp))
        Text(subtitle, style = McType.footnote, color = TextMuted, lineHeight = 19.sp)
        Spacer(Modifier.height(8.dp))
        GlassCard(Modifier.fillMaxWidth()) { Column { content() } }
    }
}

@Composable
private fun RowItem(title: String, summary: String, badge: String? = null, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onClick() }.padding(horizontal = 16.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = McType.subheadlineSemibold, color = TextPrimary)
            Spacer(Modifier.height(3.dp))
            Text(summary, style = McType.footnote, color = TextFaint, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (badge != null) {
                Spacer(Modifier.height(3.dp))
                Text(badge, style = McType.caption, color = Accent.copy(alpha = 0.9f))
            }
        }
        Spacer(Modifier.width(8.dp))
        Text("⌄", style = McType.footnote, color = TextFaint)
    }
    Divider()
}

@Composable
private fun SwitchItem(title: String, hint: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = McType.subheadlineSemibold, color = TextPrimary)
            Spacer(Modifier.height(3.dp))
            Text(hint, style = McType.footnote, color = TextFaint, lineHeight = 18.sp)
        }
        Spacer(Modifier.width(10.dp))
        Switch(checked = checked, onCheckedChange = onChange, colors = SwitchDefaults.colors(checkedTrackColor = Accent))
    }
    Divider()
}

@Composable
private fun Divider() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.06f)))
}

private fun sourceSummary(s: ScrapeSetting): String {
    if (s.fanartEnabled != true) return "仅 TMDB"
    val first = listOfNotNull(
        if (s.posterSourceOrder?.firstOrNull() == "fanart") "海报" else null,
        if (s.backdropSourceOrder?.firstOrNull() == "fanart") "背景" else null,
        if (s.logoSourceOrder?.firstOrNull() == "fanart") "片名 Logo" else null,
        if (s.seasonPosterSourceOrder?.firstOrNull() == "fanart") "季海报" else null,
    )
    return if (first.isEmpty()) "TMDB + Fanart.tv · 全部优先 TMDB"
    else "TMDB + Fanart.tv · ${first.joinToString("、")}优先 Fanart"
}

private fun qualitySummary(s: ScrapeSetting, bytes: Long): String {
    val label = QUALITY.firstOrNull { it.first == s.imageQuality }?.second ?: "原图（默认）"
    val size = when {
        bytes <= 0 -> ""
        bytes >= 1024L * 1024 * 1024 * 10 -> " · 约 ${bytes / (1024 * 1024 * 1024)} GB"
        bytes >= 1024L * 1024 * 1024 -> " · 约 ${String.format(java.util.Locale.ROOT, "%.1f", bytes / 1024.0 / 1024 / 1024)} GB"
        else -> " · 约 ${maxOf(1, (bytes / 1024 / 1024).toInt())} MB"
    }
    if (s.imageQuality != "custom") return label + size
    val parts = CUSTOM_SIZES.map { (key, name, _) ->
        val v = when (key) {
            "poster_size" -> s.posterSize
            "backdrop_size" -> s.backdropSize
            "still_size" -> s.stillSize
            else -> s.profileSize
        }.ifBlank { "跟随" }
        "$name $v"
    }
    return "自定义（${parts.joinToString(" / ")}）$size"
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun EditorSheet(
    sheet: Sheet,
    ui: ScrapeSettingsViewModel.Ui,
    langName: (String) -> String,
    tokenName: (String) -> String,
    countryName: (String) -> String,
    vm: ScrapeSettingsViewModel,
    onDismiss: () -> Unit,
    onPick: (Pick) -> Unit,
    onOpenFanartKey: () -> Unit = {},
) {
    val s = ui.config.setting
    val langTokens = TOKENS + ui.languages.map { it.code to it.name.ifBlank { it.code } }

    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier.fillMaxWidth().heightIn(max = 620.dp).formSheetScroll().verticalScroll(rememberScrollState()).padding(16.dp),
        ) {
            when (sheet) {
                Sheet.MetaLang -> {
                    Head("元数据语言")
                    Chips(
                        s.languagePriority.ifEmpty { ui.config.effective.languagePriority }, langName, "主",
                        onOrder = { vm.setOrder("meta", it) },
                        onRemove = { c -> vm.remove("meta", c) },
                    )
                    More("＋ 更多语言") {
                        onPick(Pick("元数据语言", "meta", ui.languages.map { it.code to it.name.ifBlank { it.code } }))
                    }
                }
                Sheet.Cert -> {
                    Head("内容分级")
                    Chips(s.certCountryPriority, countryName, "首选",
                        onOrder = { vm.setOrder("cert", it) },
                        onRemove = { c -> vm.remove("cert", c) },
                    )
                    More("＋ 更多地区") {
                        onPick(Pick("内容分级", "cert", ui.countries.map { it.code to "${it.name}(${it.code})" }))
                    }
                }
                Sheet.Poster -> {
                    Head("海报")
                    Text("海报选择方式", style = McType.caption, color = TextFaint)
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(vertical = 6.dp)) {
                        ChoiceChip("TMDB 默认", s.posterMode != "language") { vm.setPosterMode("default") }
                        ChoiceChip("按语言优先级", s.posterMode == "language") { vm.setPosterMode("language") }
                    }
                    Text(
                        "「TMDB 默认」跟随 TMDB 的主海报；「按语言优先级」才使用下面的语言顺序，启用 Fanart 时也按它挑图。",
                        style = McType.caption, color = TextFaint, lineHeight = 17.sp,
                    )
                    Spacer(Modifier.height(6.dp))
                    Chips(
                        s.posterLanguagePriority, tokenName, "首选",
                        onOrder = { vm.setOrder("poster", it) },
                        onRemove = { c -> vm.remove("poster", c) },
                    )
                    More("＋ 更多") { onPick(Pick("海报语言", "poster", langTokens)) }
                }
                Sheet.Backdrop -> {
                    Head("背景图（fanart）")
                    Chips(s.backdropLanguagePriority, tokenName, "首选",
                        onOrder = { vm.setOrder("backdrop", it) },
                        onRemove = { c -> vm.remove("backdrop", c) },
                    )
                    More("＋ 更多") { onPick(Pick("背景图语言", "backdrop", langTokens)) }
                }
                Sheet.Logo -> {
                    Head("片名 Logo")
                    Chips(s.logoLanguagePriority ?: emptyList(), tokenName, "首选",
                        onOrder = { vm.setOrder("logo", it) },
                        onRemove = { c -> vm.remove("logo", c) },
                    )
                    More("＋ 更多") { onPick(Pick("片名 Logo 语言", "logo", langTokens)) }
                }
                Sheet.Sources -> {
                    Head("图片来源")
                    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("启用 Fanart.tv", style = McType.sub, color = TextPrimary)
                            Text("关闭后只用 TMDB", style = McType.caption, color = TextFaint)
                        }
                        Switch(
                            checked = s.fanartEnabled == true,
                            onCheckedChange = { vm.setFanart(it) },
                            colors = SwitchDefaults.colors(checkedTrackColor = Accent),
                        )
                    }
                    // Fanart API Key 状态（iOS：未配置 / 已配置显示末四位 / 已失效）
                    val fanart = ui.fanart
                    val fanartOn = s.fanartEnabled == true
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("Fanart API Key", style = McType.sub, color = TextPrimary)
                            Text(
                                when {
                                    fanart == null -> "正在检查 API Key…"
                                    fanart.keyInvalid -> "密钥已失效，Fanart 选图已暂停"
                                    fanart.configured -> "已配置 · ••••${fanart.keyHint.takeLast(4)}"
                                    else -> "未配置 · 验证后即可启用 Fanart"
                                },
                                style = McType.caption,
                                color = if (fanart?.keyInvalid == true) Color(0xFFFF8A80) else TextFaint,
                            )
                        }
                        Text(
                            if (fanart?.configured == true) "更换 API Key" else "配置 API Key",
                            style = McType.caption, color = Accent,
                            modifier = Modifier.clip(RoundedCornerShape(999.dp))
                                .background(Color.White.copy(alpha = 0.06f))
                                .clickable { onOpenFanartKey() }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                    listOf(
                        Triple("poster", "海报", "TMDB 在前"),
                        Triple("backdrop", "背景", "TMDB 在前（常有 4K）"),
                        Triple("logo", "片名 Logo", "Fanart 在前（中文多）"),
                        Triple("season", "季海报", "Fanart 在前"),
                    ).forEach { (key, label, why) ->
                        val order = vm.sourceOrder(s, key)
                        Row(
                            Modifier.fillMaxWidth()
                                .alpha(if (fanartOn) 1f else 0.45f)
                                .clickable(enabled = fanartOn) { vm.swapSource(key) }
                                .padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(label, style = McType.sub, color = TextPrimary)
                                Text(why, style = McType.caption, color = TextFaint)
                            }
                            Text(order.joinToString(" › ") { it.uppercase() }, style = McType.caption, color = TextMuted)
                            Spacer(Modifier.width(6.dp))
                            Text("⇄", style = McType.caption, color = if (fanartOn) Accent else TextFaint)
                        }
                    }
                    Text(
                        if (fanartOn) "点按一行交换两个来源的先后。" else "启用 Fanart 后可调整来源顺序。",
                        style = McType.caption, color = TextFaint,
                    )
                }
                Sheet.MinWidth -> {
                    Head("最低分辨率门槛")
                    Text(
                        "单位为像素，0 表示不限制。低于门槛的候选图不选；候选全部不达标时自动放宽。",
                        style = McType.caption, color = TextFaint, lineHeight = 17.sp,
                    )
                    Spacer(Modifier.height(8.dp))
                    IntRow("海报最小宽度", s.posterMinWidth) { vm.setMinWidth("poster", it) }
                    IntRow("背景最小宽度", s.backdropMinWidth) { vm.setMinWidth("backdrop", it) }
                }
                Sheet.Quality -> {
                    Head("本地图片画质")
                    QUALITY.forEach { (id, name, desc) ->
                        Row(Modifier.fillMaxWidth().clickable { vm.setQuality(id) }.padding(vertical = 7.dp)) {
                            Box(
                                Modifier.size(14.dp).clip(RoundedCornerShape(999.dp))
                                    .background(if (s.imageQuality == id) Accent else Color.White.copy(alpha = 0.14f)),
                            )
                            Spacer(Modifier.width(8.dp))
                            Column {
                                Text(name, style = McType.sub, color = TextPrimary)
                                Text(desc, style = McType.caption, color = TextFaint, lineHeight = 16.sp)
                            }
                        }
                    }
                    if (s.imageQuality == "custom") {
                        CUSTOM_SIZES.forEach { (key, label, options) ->
                            val v = when (key) {
                                "poster_size" -> s.posterSize
                                "backdrop_size" -> s.backdropSize
                                "still_size" -> s.stillSize
                                else -> s.profileSize
                            }.ifBlank { "跟随" }
                            Row(
                                Modifier.fillMaxWidth().clickable { onPick(Pick(label, key, options.map { it to it })) }
                                    .padding(vertical = 7.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(label, style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f))
                                Text(v, style = McType.caption, color = Accent)
                            }
                        }
                    }
                }
                Sheet.Naming -> NamingEditor(vm, s)
            }
            Spacer(Modifier.height(18.dp))
        }
    }
}

@Composable
private fun Head(text: String) {
    Text(text, style = McType.title3, color = TextPrimary)
    Spacer(Modifier.height(10.dp))
}

@Composable
private fun Chips(
    codes: List<String>,
    label: (String) -> String,
    primaryTag: String,
    onOrder: (List<String>) -> Unit,
    onRemove: (String) -> Unit,
) {
    // 长按拖动排序（顺序 = 优先级），松手才保存
    DragReorderList(codes, label, primaryTag, onOrder, onRemove)
}

@Composable
private fun More(label: String, onClick: () -> Unit) {
    Spacer(Modifier.height(8.dp))
    Text(
        label, style = McType.caption, color = Accent,
        modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.06f))
            .clickable { onClick() }.padding(horizontal = 12.dp, vertical = 7.dp),
    )
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

@Composable
private fun IntRow(label: String, value: Int, onChange: (Int) -> Unit) {
    var text by remember { mutableStateOf(value.toString()) }
    // 外部保存回来时同步；输入过程中不重置，避免光标跳动
    LaunchedEffect(value) {
        val v = value.toString()
        if (v != text) text = v
    }
    // 停顿 500ms 再提交，别每敲一个数字就发一整份刮削配置
    LaunchedEffect(text) {
        val parsed = text.toIntOrNull()
        if (parsed != null && parsed != value) {
            delay(500)
            onChange(parsed)
        }
    }
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f))
        TextField(
            value = text,
            onValueChange = { v -> text = v.filter { it.isDigit() }.take(5) },
            singleLine = true,
            modifier = Modifier.width(110.dp),
        )
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun PickSheet(pick: Pick, onDismiss: () -> Unit, onChoose: (String, String) -> Unit) {
    var q by remember { mutableStateOf("") }
    val rows = remember(q, pick.rows) {
        if (q.isBlank()) pick.rows else pick.rows.filter { (c, n) -> n.contains(q, true) || c.contains(q, true) }
    }
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().heightIn(max = 560.dp)) {
            Text(pick.title, style = McType.title3, modifier = Modifier.padding(16.dp))
            if (pick.rows.size > 10) {
                TextField(
                    value = q, onValueChange = { q = it }, singleLine = true,
                    placeholder = { Text("搜索", style = McType.caption, color = TextFaint) },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                )
            }
            if (rows.isEmpty()) {
                Text(
                    "没有匹配的选项",
                    style = McType.caption, color = TextFaint,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                )
            }
            LazyColumn(Modifier.padding(top = 6.dp)) {
                items(rows) { (code, name) ->
                    Row(
                        Modifier.fillMaxWidth().clickable { onChoose(pick.key, code) }
                            .padding(horizontal = 20.dp, vertical = 11.dp),
                    ) { Text(name, style = McType.sub, color = TextPrimary, maxLines = 1) }
                }
            }
        }
    }
}


/**
 * 命名模板编辑页（iOS `SettingsBScrapeNaming`）：四个字段 + 占位符插入 + 实时预览 + 恢复默认。
 * 与全局页其它行不同，这一页有明确的「保存」（iOS 同款）。
 */
@Composable
private fun NamingEditor(
    vm: ScrapeSettingsViewModel,
    s: ScrapeSetting,
    onDone: () -> Unit = {},
) {
    var drafts by remember(s) {
        mutableStateOf(
            mapOf(
                "naming_entry_dir" to s.namingEntryDir,
                "naming_movie_file" to s.namingMovieFile,
                "naming_season_dir" to s.namingSeasonDir,
                "naming_episode_file" to s.namingEpisodeFile,
            ),
        )
    }
    var target by remember { mutableStateOf("naming_episode_file") }
    val errors = NAMING_FIELDS.associate { f -> f.key to validateNaming(drafts[f.key].orEmpty(), f.allowed) }
    val valid = errors.values.all { it == null }
    val original = mapOf(
        "naming_entry_dir" to s.namingEntryDir,
        "naming_movie_file" to s.namingMovieFile,
        "naming_season_dir" to s.namingSeasonDir,
        "naming_episode_file" to s.namingEpisodeFile,
    )
    val dirty = drafts != original
    val targetField = NAMING_FIELDS.first { it.key == target }

    Head("命名模板")
    Text(
        "留空即使用默认模板；字段缺失时会连同相邻括号自动收缩。目录层级固定为「条目目录 / 季目录 / 文件」，不可自定义。",
        style = McType.caption, color = TextFaint, lineHeight = 18.sp,
    )
    Spacer(Modifier.height(8.dp))

    NAMING_FIELDS.forEach { f ->
        Text(f.title, style = McType.caption, color = TextMuted, modifier = Modifier.padding(top = 8.dp))
        TextField(
            value = drafts[f.key].orEmpty(),
            onValueChange = { drafts = drafts + (f.key to it) },
            singleLine = true,
            isError = errors[f.key] != null,
            placeholder = { Text(f.default, style = McType.caption, color = TextFaint) },
            modifier = Modifier.fillMaxWidth().padding(top = 3.dp),
        )
        errors[f.key]?.let { Text(it, style = McType.caption, color = Color(0xFFFF8A80)) }
    }

    // 占位符插入：先选字段，再点占位符（iOS 是插到光标处；这里追加到末尾，效果等价）
    Spacer(Modifier.height(12.dp))
    Text("向「${targetField.title}」插入占位符", style = McType.caption, color = TextMuted)
    Spacer(Modifier.height(5.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        NAMING_FIELDS.forEach { f ->
            Text(
                f.title,
                style = McType.caption,
                color = if (f.key == target) Color(0xFF141821) else TextMuted,
                modifier = Modifier.clip(RoundedCornerShape(999.dp))
                    .background(if (f.key == target) Accent else Color.White.copy(alpha = 0.06f))
                    .clickable { target = f.key }
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            )
        }
    }
    NAMING_TOKEN_GROUPS.forEach { (group, tokens) ->
        val usable = tokens.filter { it.first in targetField.allowed }
        if (usable.isEmpty()) return@forEach
        Text(group, style = McType.caption, color = TextFaint, modifier = Modifier.padding(top = 8.dp))
        androidx.compose.foundation.layout.FlowRow(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(top = 4.dp),
        ) {
            usable.forEach { (token, label) ->
                Text(
                    label, style = McType.caption, color = TextPrimary,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.06f))
                        .clickable { drafts = drafts + (target to (drafts[target].orEmpty() + "{$token}")) }
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                )
            }
        }
    }

    // 实时预览（电影 / 剧集两条样例路径）
    Spacer(Modifier.height(14.dp))
    Text(if (valid) "✓ 模板有效" else "✕ 模板有误", style = McType.caption, color = if (valid) TextMuted else Color(0xFFFF8A80))
    if (valid) {
        Text("实时预览", style = McType.caption, color = TextFaint, modifier = Modifier.padding(top = 6.dp))
        Text(previewPaths(drafts, movie = true), style = McType.caption, color = TextPrimary, lineHeight = 17.sp)
        Text(previewPaths(drafts, movie = false), style = McType.caption, color = TextPrimary, lineHeight = 17.sp)
    }

    Spacer(Modifier.height(14.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = {
            drafts = NAMING_FIELDS.associate { it.key to "" }
        }) { Text("恢复默认模板", color = TextMuted) }
        Spacer(Modifier.weight(1f))
        Button(
            onClick = {
                vm.setNamingAll(
                    drafts["naming_entry_dir"].orEmpty(),
                    drafts["naming_movie_file"].orEmpty(),
                    drafts["naming_season_dir"].orEmpty(),
                    drafts["naming_episode_file"].orEmpty(),
                )
                onDone()
            },
            enabled = valid && dirty,
            shape = RoundedCornerShape(999.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF141821)),
        ) { Text("保存") }
    }
    Text(
        "同条目多版本会自动追加版本标签。站点与原始文件名仅对经 MovieClaw 入库的文件有效，缺失字段会自动收缩。",
        style = McType.caption, color = TextFaint, lineHeight = 18.sp,
    )
}

/**
 * Fanart API Key 弹层（iOS `SettingsBScrapeFanartKeySheet`）：
 * 验证通过才保存并启用 Fanart；失败不替换原密钥。
 */
@Composable
private fun FanartKeyDialog(
    fanart: io.movieclaw.android.core.model.ScrapeFanartView?,
    vm: ScrapeSettingsViewModel,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    var key by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = Color(0xFF171A23),
        title = {
            Text(
                if (fanart?.configured == true) "更换 Fanart API Key" else "Fanart API Key",
                style = McType.bodySemibold, color = TextPrimary,
            )
        },
        text = {
            Column {
                if (fanart?.configured == true) {
                    Text("当前密钥  ••••${fanart.keyHint.takeLast(4)}", style = McType.caption, color = TextMuted)
                    Spacer(Modifier.height(6.dp))
                }
                Text(
                    "验证成功后立即将密钥保存到当前服务器，并启用 Fanart 选图。验证失败不会替换原密钥。",
                    style = McType.caption, color = TextFaint, lineHeight = 18.sp,
                )
                Spacer(Modifier.height(8.dp))
                TextField(
                    value = key,
                    onValueChange = { key = it.trim(); error = null },
                    singleLine = true,
                    placeholder = { Text(if (fanart?.configured == true) "输入新的 API Key" else "输入 API Key", style = McType.caption, color = TextFaint) },
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "获取免费 API Key ↗",
                    style = McType.caption, color = Accent,
                    modifier = Modifier.clickable {
                        runCatching {
                            context.startActivity(
                                android.content.Intent(
                                    android.content.Intent.ACTION_VIEW,
                                    android.net.Uri.parse("https://fanart.tv/get-an-api-key/"),
                                ),
                            )
                        }
                    },
                )
                error?.let {
                    Spacer(Modifier.height(6.dp))
                    Text(it, style = McType.caption, color = Color(0xFFFF8A80))
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !busy && key.isNotBlank(),
                onClick = {
                    busy = true
                    vm.saveFanartKey(key) { err ->
                        busy = false
                        if (err == null) onDismiss() else error = err
                    }
                },
            ) { Text(if (busy) "正在验证…" else "验证", color = Accent) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) } },
    )
}
