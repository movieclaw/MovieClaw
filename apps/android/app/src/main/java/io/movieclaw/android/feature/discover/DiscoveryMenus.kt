package io.movieclaw.android.feature.discover

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Layers
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Timeline
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.MenuSurface
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary

/**
 * 发现页的筛选状态 —— 口径与移动端网页 lib/discovery-filters.ts 一致：
 * 类型传 **TMDB 数字 ID**、国家传 **ISO 码**，其余传原始值；URL 是筛选状态的唯一来源。
 * 「全部」胶囊的文案规则也来自那里：没选 = 全部；选一项 = 该项值；多选 = 首项 +N。
 *
 * 字段名同网页 / iOS 的 `DiscoveryFilters`（`originCountry` / `ratingGte` / `runtimeLte`）：
 * 与服务端参数一一对应，翻译层（`McApi.discoverTitles`）就是纯搬运——此前叫
 * `country` / `rating` / `runtime`，翻译时对成了不存在的参数名，条件全部静默失效。
 */
data class DiscoveryFilter(
    val genreIds: List<String> = emptyList(),
    val originCountry: String? = null,
    val year: String? = null,
    val ratingGte: String? = null,
    val runtimeLte: String? = null,
    val sort: String? = null,
) {
    /**
     * 已启用的维度数（iOS `DiscoveryFilters.activeCount` 同口径）：排序停在默认的
     * 「热门优先」**不算**启用——它不是条件，勾了它不该把首页翻成筛选结果页。
     */
    val activeCount: Int
        get() = listOf(
            genreIds.isNotEmpty(),
            originCountry != null,
            year != null,
            ratingGte != null,
            runtimeLte != null,
            sort != null && sort != DEFAULT_SORT,
        ).count { it }

    /**
     * 顶栏筛选键的按钮文字（iOS `DiscoverFilterMenu.buttonTitle`）：顶栏寸土寸金，
     * 只写**首个类型**（多个再带个数）；没选类型就是「全部」——不写国家 / 年份那些
     * （那一格的完整条件在结果页的胶囊行里）。
     */
    fun label(): String {
        val first = genreIds.firstOrNull() ?: return "全部"
        val name = GenreLabel[first] ?: "1 个类型"
        return if (genreIds.size == 1) name else "$name +${genreIds.size - 1}"
    }
}

/** TMDB 类型 ID → 中文名（与网页后端下发的本地化清单口径一致） */
private val GENRE_OPTIONS = listOf(
    "28" to "动作", "12" to "冒险", "16" to "动画", "35" to "喜剧", "80" to "犯罪",
    "99" to "纪录", "18" to "剧情", "10751" to "家庭", "14" to "奇幻", "36" to "历史",
    "27" to "恐怖", "10402" to "音乐", "9648" to "悬疑", "10749" to "爱情", "878" to "科幻",
    "10770" to "电视电影", "53" to "惊悚", "10752" to "战争", "37" to "西部",
)
private val COUNTRY_OPTIONS = listOf(
    "CN" to "中国大陆", "US" to "美国", "JP" to "日本", "KR" to "韩国", "GB" to "英国",
    "FR" to "法国", "HK" to "中国香港", "TW" to "中国台湾", "IN" to "印度",
)
private val YEAR_OPTIONS = (2026 downTo 2016).map { it.toString() to it.toString() }
private val RATING_OPTIONS = listOf("9" to "9 分以上", "8" to "8 分以上", "7" to "7 分以上", "6" to "6 分以上")
private val RUNTIME_OPTIONS = listOf("60" to "60 分钟以内", "90" to "90 分钟以内", "120" to "120 分钟以内", "150" to "150 分钟以内")
private val SORT_OPTIONS = listOf(
    "popular" to "热门优先", "rating" to "评分优先", "newest" to "最新优先", "most-rated" to "最多评分",
)

private val GenreLabel = GENRE_OPTIONS.toMap()
private val CountryLabel = COUNTRY_OPTIONS.toMap()

private class Dim(
    val key: String,
    val title: String,
    val icon: ImageVector,
    val options: List<Pair<String, String>>,
    val multi: Boolean = false,
)

private val DIMS = listOf(
    Dim("genres", "类型", Icons.Rounded.Layers, GENRE_OPTIONS, multi = true),
    Dim("country", "国家 / 地区", Icons.Rounded.Language, COUNTRY_OPTIONS),
    Dim("year", "上映年份", Icons.Rounded.Timeline, YEAR_OPTIONS),
    Dim("rating", "最低评分", Icons.Rounded.Star, RATING_OPTIONS),
    Dim("runtime", "最长片长", Icons.Rounded.Timer, RUNTIME_OPTIONS),
    Dim("sort", "排序", Icons.Rounded.Timeline, SORT_OPTIONS),
)

/**
 * 数据源菜单 —— 实测：192 宽、圆角 14、内边距 4、底色 rgba(21,23,29,.96)；
 * 分组标签 13/400 36%（内边距 6/12/4）；行 184×38、圆角 14、14px 62% 白；
 * 「类型」那组行首有 16px 图标，选中项行尾一枚 **#7fb0ff 的对勾**（不是白色）。
 */
@Composable
fun SourceMenu(
    mediaType: String,
    source: String,
    onPickMediaType: (String) -> Unit,
    onPickSource: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    MenuPanel(width = 192.dp, modifier = modifier) {
        MenuGroupLabel("类型")
        MenuRow("电影", icon = Icons.Rounded.Movie, selected = mediaType != "tv") { onPickMediaType("movie") }
        MenuRow("剧集", icon = Icons.Rounded.Tv, selected = mediaType == "tv") { onPickMediaType("tv") }
        MenuGroupLabel("数据源")
        MenuRow("TMDB", selected = source.equals("tmdb", ignoreCase = true)) { onPickSource("tmdb") }
        MenuRow("豆瓣", selected = source.equals("douban", ignoreCase = true)) { onPickSource("douban") }
    }
}

/**
 * 「全部」筛选菜单 —— 实测：272 宽；六行（类型 / 国家·地区 / 上映年份 / 最低评分 / 最长片长 / 排序），
 * 每行 264×38、行首 16 图标、行尾当前值 + 箭头；点进去**原地换成该维度的选项列表**
 * （顶部是「‹ 维度名」的高亮返回行），整个面板封顶 416；类型多选，其余单选且每项带「不限」复位。
 *
 * 有条件时末尾多一行「清空条件」（同 iOS `DiscoverFilterMenu`），选择即生效（没有「查看结果」这一步）。
 */
@Composable
fun DiscoveryFilterMenu(
    filter: DiscoveryFilter,
    onApply: (DiscoveryFilter) -> Unit,
    modifier: Modifier = Modifier,
) {
    var openDim by remember { mutableStateOf<Dim?>(null) }
    MenuPanel(width = 272.dp, maxHeight = 416.dp, modifier = modifier) {
        val dim = openDim
        if (dim == null) {
            DIMS.forEach { d ->
                MenuRow(d.title, value = dimValue(d, filter), icon = d.icon, chevron = true) { openDim = d }
            }
            if (filter.activeCount > 0) {
                Spacer(Modifier.height(4.dp))
                Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.07f)))
                MenuRow("清空条件", icon = Icons.Rounded.Close, danger = true) { onApply(DiscoveryFilter()) }
            }
        } else {
            // 结果页头部的条件胶囊点开也走这一份（见 DiscoverFilterChips 的调用）
            DiscoveryFilterOptionsPanel(
                dimKey = dim.key,
                filter = filter,
                onApply = onApply,
                onBack = { openDim = null },
            )
        }
    }
}

/** 某一维度当前的显示值（菜单行与条件胶囊共用同一套文案） */
private fun dimValue(dim: Dim, filter: DiscoveryFilter): String = when (dim.key) {
    "genres" -> when {
        filter.genreIds.isEmpty() -> "不限"
        filter.genreIds.size == 1 -> GenreLabel[filter.genreIds.first()] ?: "1 个类型"
        else -> "${GenreLabel[filter.genreIds.first()] ?: ""} +${filter.genreIds.size - 1}"
    }
    "country" -> filter.originCountry?.let { CountryLabel[it] ?: it } ?: "不限"
    "year" -> filter.year ?: "不限"
    "rating" -> filter.ratingGte?.let { "$it 分以上" } ?: "不限"
    "runtime" -> filter.runtimeLte?.let { "$it 分钟以内" } ?: "不限"
    else -> filter.sort?.takeIf { it != DEFAULT_SORT }
        ?.let { s -> SORT_OPTIONS.firstOrNull { it.first == s }?.second ?: s } ?: "热门优先"
}

/** 维度名（筛选结果页的条件胶囊上用它 + 当前值） */
internal fun discoveryDimTitle(key: String): String =
    DIMS.firstOrNull { it.key == key }?.title ?: key

/** 六个维度固定顺序的 key（结果页的条件胶囊按这个顺序排，不按启用与否重排） */
internal val discoveryDimKeys: List<String> = DIMS.map { it.key }

/** 一个维度的当前值摘要（未启用返回 null；排序停在「热门优先」也算未启用，与角标口径一致） */
internal fun discoveryDimSummary(key: String, filter: DiscoveryFilter): String? {
    val dim = DIMS.firstOrNull { it.key == key } ?: return null
    if (!dimEnabled(dim, filter)) return null
    return dimValue(dim, filter)
}

private const val DEFAULT_SORT = "popular"

private fun dimEnabled(dim: Dim, filter: DiscoveryFilter): Boolean = when (dim.key) {
    "genres" -> filter.genreIds.isNotEmpty()
    "country" -> filter.originCountry != null
    "year" -> filter.year != null
    "rating" -> filter.ratingGte != null
    "runtime" -> filter.runtimeLte != null
    // 默认档「热门优先」不算启用（与 activeCount 同口径）
    else -> filter.sort != null && filter.sort != DEFAULT_SORT
}

/**
 * 单维度的选项面板（二级菜单的内容）：顶部「‹ 维度名」高亮返回行，下面是非多选维度的「不限」
 * 与各选项（当前项带对勾）。**从主菜单与结果页条件胶囊两处复用**——两处的取值、文案、
 * 选中态永远一致。
 */
@Composable
fun DiscoveryFilterOptionsPanel(
    dimKey: String,
    filter: DiscoveryFilter,
    onApply: (DiscoveryFilter) -> Unit,
    onBack: (() -> Unit)? = null,
) {
    val dim = DIMS.firstOrNull { it.key == dimKey } ?: return
    Column(Modifier.fillMaxWidth()) {
        if (onBack != null) {
            MenuRow(dim.title, icon = Icons.AutoMirrored.Rounded.ArrowBack, highlight = true, onClick = onBack)
        }
        Column(Modifier.heightIn(max = 370.dp).verticalScroll(rememberScrollState())) {
            // 排序没有「不限」语义（默认档就是「热门优先」）；类型是多选，也不给「不限」
            if (dim.key != "sort" && !dim.multi) {
                OptionRow("不限", selected = !dimEnabled(dim, filter)) { onApply(clear(dim.key, filter)) }
            }
            dim.options.forEach { (value, label) ->
                val on = when (dim.key) {
                    "genres" -> filter.genreIds.contains(value)
                    "country" -> filter.originCountry == value
                    "year" -> filter.year == value
                    "rating" -> filter.ratingGte == value
                    "runtime" -> filter.runtimeLte == value
                    else -> filter.sort == value
                }
                OptionRow(label, selected = on) { onApply(toggle(dim.key, value, filter)) }
            }
        }
    }
}

private fun clear(key: String, f: DiscoveryFilter): DiscoveryFilter = when (key) {
    "genres" -> f.copy(genreIds = emptyList())
    "country" -> f.copy(originCountry = null)
    "year" -> f.copy(year = null)
    "rating" -> f.copy(ratingGte = null)
    "runtime" -> f.copy(runtimeLte = null)
    else -> f.copy(sort = null)
}

private fun toggle(key: String, value: String, f: DiscoveryFilter): DiscoveryFilter = when (key) {
    "genres" -> f.copy(genreIds = if (f.genreIds.contains(value)) f.genreIds - value else f.genreIds + value)
    "country" -> f.copy(originCountry = if (f.originCountry == value) null else value)
    "year" -> f.copy(year = if (f.year == value) null else value)
    "rating" -> f.copy(ratingGte = if (f.ratingGte == value) null else value)
    "runtime" -> f.copy(runtimeLte = if (f.runtimeLte == value) null else value)
    else -> f.copy(sort = if (f.sort == value) null else value)
}

@Composable
private fun MenuPanel(
    width: Dp,
    maxHeight: Dp? = null,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Column(
        modifier
            .width(width)
            .then(if (maxHeight != null) Modifier.heightIn(max = maxHeight) else Modifier)
            .clip(RoundedCornerShape(McMetrics.menuRadius))
            .background(MenuSurface)
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(McMetrics.menuRadius))
            .padding(4.dp),
    ) { content() }
}

@Composable
private fun MenuGroupLabel(text: String) {
    Text(
        text,
        style = McType.caption,
        color = TextFaint,
        modifier = Modifier.padding(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 4.dp),
    )
}

@Composable
private fun MenuRow(
    title: String,
    value: String? = null,
    icon: ImageVector? = null,
    selected: Boolean = false,
    highlight: Boolean = false,
    chevron: Boolean = false,
    /** 破坏性动作（「清空条件」）：文字用危险色，同 iOS 的 destructive 角色 */
    danger: Boolean = false,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(38.dp)
            .clip(RoundedCornerShape(14.dp))
            .then(if (highlight) Modifier.background(Color.White.copy(alpha = 0.075f)) else Modifier)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(
                icon,
                contentDescription = null,
                tint = if (danger) io.movieclaw.android.core.designsystem.Danger else Color.White.copy(alpha = 0.55f),
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(12.dp))
        }
        Text(
            title,
            style = McType.sub.copy(fontWeight = if (highlight) FontWeight.SemiBold else null),
            color = when {
                danger -> io.movieclaw.android.core.designsystem.Danger
                highlight -> TextPrimary
                else -> TextMuted
            },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.weight(1f))
        if (value != null) {
            Text(value, style = McType.sub, color = TextMuted, maxLines = 1)
            if (chevron) {
                Spacer(Modifier.width(6.dp))
                Icon(
                    Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                    contentDescription = null,
                    tint = Color.White.copy(alpha = 0.4f),
                    modifier = Modifier.size(14.dp),
                )
            }
        }
        if (selected) {
            Icon(Icons.Rounded.Check, contentDescription = null, tint = Info, modifier = Modifier.size(14.dp))
        }
    }
}

@Composable
private fun OptionRow(text: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(38.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = McType.sub, color = TextMuted, maxLines = 1, modifier = Modifier.weight(1f))
        if (selected) {
            Icon(Icons.Rounded.Check, contentDescription = null, tint = Info, modifier = Modifier.size(14.dp))
        }
    }
}
