package io.movieclaw.androidtv.ui.library

import io.movieclaw.core.model.generated.FacetValueView
import io.movieclaw.core.model.generated.LibraryFacetsView
import io.movieclaw.core.model.generated.LibraryIndexEntryView
import io.movieclaw.core.model.generated.RelaxSuggestionView

/** 海报墙右侧索引条的一档（TVWallIndexEntry，docs/design/tvos-app.md §3.1） */
data class WallIndexEntry(
    /** 档名：首字母（A–Z / #）、年份（2023）、年代（1990s）、评分档（9+ / 更低 / 未评分） */
    val key: String,
    /** 索引条上写的字（「S」「2023」「90s」「<7」） */
    val label: String,
    /** 位置提示与预览气泡里的大字（「S」「2023」「1990 年代」「7 分以下」） */
    val title: String,
    /** 这一档有几部；0 = 空档（压暗、跳不过去） */
    val count: Int,
    /** 这一档第一部在整份排序里的位置（`/items?offset=`）；空档为 null */
    val offset: Int?,
)

/** 服务端跳转索引（`item-index`）→ 电视的索引条（TVWallIndex） */
object WallIndex {
    /** 有索引条的排序：按标题（首字母）、按上映（年份）、按评分（分数档）；按添加时间没有有意义的分档 */
    fun supports(sort: String): Boolean = sort in setOf("title", "release_date", "rating")

    fun entries(sort: String, reversed: Boolean, raw: List<LibraryIndexEntryView>): List<WallIndexEntry> = when (sort) {
        "title" -> letters(reversed, raw)
        "release_date" -> years(reversed, raw)
        "rating" -> ratings(raw)
        else -> emptyList()
    }

    /** 整份排序里第 offset 部落在哪一档（档按排序先后排好，取起点不超过 offset 的最后一档） */
    fun entryAt(offset: Int, entries: List<WallIndexEntry>): WallIndexEntry? =
        entries.filter { (it.offset ?: Int.MAX_VALUE) <= offset }.maxByOrNull { it.offset ?: 0 }

    /** 按标题：A–Z 加 #（# 在最后，同服务端的排序）全部列出，库里没有的字母压暗——字母表不缺字，按上下找字母不会忽然跳过一截 */
    private fun letters(reversed: Boolean, raw: List<LibraryIndexEntryView>): List<WallIndexEntry> {
        val found = raw.groupBy { it.initial }.mapValues { it.value.first() }
        val keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZ#".map { it.toString() }.let { if (reversed) it.reversed() else it }
        return keys.map { key ->
            WallIndexEntry(key, key, key, found[key]?.count?.toInt() ?: 0, found[key]?.offset?.toInt())
        }
    }

    /**
     * 按上映：每年一档，2000 年以前按年代并成一档（几千部的库按年能有六七十档，遥控器选不过来）；
     * 从最新一年到最早一年逐年列出，中间没片的年份压暗。服务端回的是按年还是按月（旧服务端）都一样：
     * 档位在排好的序列上是连续的，同一年的几档挨在一起，并起来时部数相加、起点取最前
     */
    private fun years(reversed: Boolean, raw: List<LibraryIndexEntryView>): List<WallIndexEntry> {
        val groups = LinkedHashMap<String, Pair<Int, Int>>()
        var unknown: Pair<Int, Int>? = null
        for (entry in raw) {
            val count = entry.count.toInt()
            val offset = entry.offset.toInt()
            val year = entry.initial.take(4).toIntOrNull()
            if (year == null) {
                // 「未知」：没有上映日期的，服务端排在最后
                unknown = Pair((unknown?.first ?: 0) + count, minOf(unknown?.second ?: offset, offset))
                continue
            }
            val key = if (year >= 2000) year.toString() else "${year / 10 * 10}s"
            val current = groups[key]
            groups[key] = Pair((current?.first ?: 0) + count, minOf(current?.second ?: offset, offset))
        }
        val years = groups.keys.mapNotNull { it.toIntOrNull() }
        val keys = mutableListOf<String>()
        if (years.isNotEmpty()) keys += (years.max() downTo years.min()).map { it.toString() }
        keys += groups.keys.filter { it.endsWith("s") }.sortedDescending()
        if (reversed) keys.reverse()
        val entries = keys.map { key ->
            val group = groups[key]
            val decade = key.endsWith("s")
            WallIndexEntry(
                key,
                label = if (decade) key.drop(2) else key,
                title = if (decade) "${key.dropLast(1)} 年代" else key,
                count = group?.first ?: 0,
                offset = group?.second,
            )
        }.toMutableList()
        unknown?.let { entries += WallIndexEntry("unknown", "?", "未知年份", it.first, it.second) }
        return entries
    }

    /** 按评分：服务端给几档就几档（9+ / 8+ / 7+ / 更低 / 未评分） */
    private fun ratings(raw: List<LibraryIndexEntryView>): List<WallIndexEntry> = raw.map { entry ->
        val (label, title) = when (entry.initial) {
            "9+" -> "9+" to "9 分以上"
            "8+" -> "8+" to "8 分以上"
            "7+" -> "7+" to "7 分以上"
            "更低" -> "<7" to "7 分以下"
            "未评分" -> "—" to "未评分"
            else -> entry.initial to entry.initial
        }
        WallIndexEntry(entry.initial, label, title, entry.count.toInt(), entry.offset.toInt())
    }
}

/** 媒体库墙上选的类型 / 年代 / 画质（TVWallPicks；各单选：电视上一维选一个就够，多选的组合交给网页和手机） */
data class WallPicks(val genre: Long? = null, val decade: String? = null, val quality: String? = null) {
    val isEmpty: Boolean get() = genre == null && decade == null && quality == null

    companion object {
        /** 画质里「HDR」的取值（其余取值是分辨率，如 2160p） */
        const val HDR = "hdr"
    }
}

/**
 * 墙、索引、计数、放宽建议四个接口共用的条件展开（LibraryFilter 里电视用得到的几维）：
 * 「菜单上写多少部、选下去墙上就是多少部」由此在结构上得到保证。
 */
data class WallFilter(
    val g: String? = null,
    val d: String? = null,
    val res: String? = null,
    val hdr: Boolean? = null,
    val w: String? = null,
) {
    val isEmpty: Boolean get() = g == null && d == null && res == null && hdr == null && w == null
}

/** 媒体库墙的条件与叫法（TVLibraryView 的条件部分） */
object WallFilters {
    fun of(picks: WallPicks, unwatched: Boolean) = WallFilter(
        g = picks.genre?.toString(),
        d = picks.decade,
        res = picks.quality?.takeIf { it != WallPicks.HDR },
        hdr = if (picks.quality == WallPicks.HDR) true else null,
        w = if (unwatched) "unwatched" else null,
    )

    /** 年代档在电视上写成「2010 年代」（服务端的展示名是「2010s」） */
    fun decadeLabel(value: String, options: List<FacetValueView>? = null): String {
        if (value.length == 5 && value.endsWith("s") && value.take(4).toIntOrNull() != null) return "${value.take(4)} 年代"
        return options?.firstOrNull { it.value == value }?.label ?: value
    }

    fun decadeOptions(facets: LibraryFacetsView?): List<FacetValueView>? =
        facets?.decades?.map { it.copy(label = decadeLabel(it.value)) }

    /** 画质：分辨率按习惯叫法（2160p 写「4K」），最后跟一档 HDR */
    fun qualityOptions(facets: LibraryFacetsView?): List<FacetValueView>? {
        facets ?: return null
        val resolutions = facets.resolutions.map { if (it.value == "2160p") it.copy(label = "4K") else it }
        val hdr = facets.hdr.filter { it.value == "1" }.map { it.copy(value = WallPicks.HDR) }
        return resolutions + hdr
    }

    fun qualityLabel(value: String, facets: LibraryFacetsView?): String {
        if (value == WallPicks.HDR) return "HDR"
        return qualityOptions(facets)?.firstOrNull { it.value == value }?.label ?: if (value == "2160p") "4K" else value
    }

    /** 标题旁的条件摘要（「科幻 · 2010 年代 · 未看」），名字取服务端 facet 的展示名 */
    fun conditions(picks: WallPicks, unwatched: Boolean, facets: LibraryFacetsView?): List<String> = buildList {
        picks.genre?.let { genre -> add(facets?.genres?.firstOrNull { it.value == genre.toString() }?.label ?: "类型") }
        picks.decade?.let { add(decadeLabel(it, facets?.decades)) }
        picks.quality?.let { add(qualityLabel(it, facets)) }
        if (unwatched) add("未看")
    }

    /** 「西部 · 4K · 49 部」；什么都没有时为 null */
    fun summary(conditions: List<String>, total: Long?): String? {
        val parts = conditions + listOfNotNull(total?.let { "$it 部" })
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }

    /** 放宽建议里的条件名与标题旁的摘要同一种叫法（「4K」「2010 年代」「未看」） */
    fun relaxLabel(suggestion: RelaxSuggestionView): String = when (suggestion.dim) {
        "resolutions" -> if (suggestion.value == "2160p") "4K" else suggestion.label
        "decades" -> decadeLabel(suggestion.value)
        else -> suggestion.label
    }

    /** 去掉一维条件（放宽建议的按钮）：返回新的选择与「只看没看过的」 */
    fun remove(dim: String, picks: WallPicks, unwatched: Boolean): Pair<WallPicks, Boolean> = when (dim) {
        "genres" -> picks.copy(genre = null) to unwatched
        "decades" -> picks.copy(decade = null) to unwatched
        "resolutions", "hdr" -> picks.copy(quality = null) to unwatched
        "watch" -> picks to false
        else -> picks to unwatched
    }

    /** 按添加时间排序时的位置提示：「2026 年 8 月」（added_at 是 ISO 时间，只取年月） */
    fun addedMonth(added: String?): String? {
        if (added == null || added.length < 7) return null
        val year = added.take(4).toIntOrNull() ?: return null
        val month = added.substring(5, 7).toIntOrNull() ?: return null
        return "$year 年 $month 月"
    }
}
