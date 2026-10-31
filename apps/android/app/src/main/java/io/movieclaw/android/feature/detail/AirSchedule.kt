package io.movieclaw.android.feature.detail

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Ok
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warn
import io.movieclaw.android.core.designsystem.formSheetScroll
import io.movieclaw.android.core.designsystem.formSheetContent
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.model.SeasonAirSchedule
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.TextStyle as DateTextStyle
import java.time.temporal.ChronoUnit
import java.util.Locale

/*
 * 播出日历（issue #547，网页 `lib/air-schedule.ts` + `components/library-air-schedule.tsx`、iOS `AirSchedule.swift`）：
 * 分集区里的「季进度条」入口卡 + 按天的日程底部面板。只在本季还有今天或以后的播出日期时出现
 * （服务端不给 airSchedule 就整块不画）。日期一律是 yyyy-MM-dd 的日历日，「今天」由服务端按站点日历给出。
 */

enum class AirTone(val color: Color) {
    Owned(Color(0xFFC3CAD6)),
    Missing(Color(0xFFF59E0B)),
    Today(Color(0xFF3B82F6)),
    TodayFree(Color(0xFF7C8494)),
    Upcoming(Color.White.copy(alpha = 0.14f)),
    Absent(Color.White.copy(alpha = 0.14f)),
}

data class AirDay(
    val date: LocalDate,
    val episodes: List<EpisodeView>,
    val past: Boolean,
    val today: Boolean,
    val finale: Boolean,
)

data class AirCounts(val owned: Int, val missing: Int, val upcoming: Int)

object AirSchedule {
    /** 超过这么多集就把同状态的连续集合并成色段，一集一格太细 */
    const val MERGE_ABOVE = 40

    private val zh = Locale.SIMPLIFIED_CHINESE

    fun date(raw: String?): LocalDate? = raw?.take(10)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }

    fun daysBetween(from: String, to: String): Int {
        val a = date(from) ?: return 0
        val b = date(to) ?: return 0
        return ChronoUnit.DAYS.between(a, b).toInt()
    }

    fun shortDate(day: LocalDate): String = "${day.monthValue}月${day.dayOfMonth}日"

    fun weekday(day: LocalDate): String = weekdayName(day.dayOfWeek)

    /** 「周四」 */
    private fun weekdayName(day: DayOfWeek): String = day.getDisplayName(DateTextStyle.SHORT, zh)

    fun tone(episode: EpisodeView, schedule: SeasonAirSchedule): AirTone {
        if (episode.owned) return AirTone.Owned
        if (episode.episodeNumber in schedule.missingEpisodes) return AirTone.Missing
        val air = episode.airDate ?: return AirTone.Upcoming
        val offset = daysBetween(schedule.today, air)
        return when {
            offset > 0 -> AirTone.Upcoming
            offset == 0 -> if (schedule.subscriptionId != null) AirTone.Today else AirTone.TodayFree
            else -> AirTone.Absent
        }
    }

    /** 进度条分段：(状态, 集数)；40 集以内一集一格 */
    fun segments(episodes: List<EpisodeView>, schedule: SeasonAirSchedule): List<Pair<AirTone, Int>> {
        val tones = episodes.map { tone(it, schedule) }
        if (tones.size <= MERGE_ABOVE) return tones.map { it to 1 }
        val runs = mutableListOf<Pair<AirTone, Int>>()
        for (t in tones) {
            val last = runs.lastOrNull()
            if (last?.first == t) runs[runs.size - 1] = t to last.second + 1 else runs += t to 1
        }
        return runs
    }

    fun counts(episodes: List<EpisodeView>, schedule: SeasonAirSchedule) = AirCounts(
        owned = episodes.count { it.owned },
        missing = schedule.missingEpisodes.size,
        upcoming = episodes.count { e -> !e.owned && (e.airDate?.let { daysBetween(schedule.today, it) > 0 } ?: true) },
    )

    /** 有日期的集按播出日分组，升序 */
    fun days(episodes: List<EpisodeView>, schedule: SeasonAirSchedule): List<AirDay> {
        val last = date(schedule.lastAirDate)
        val today = date(schedule.today)
        return episodes
            .mapNotNull { e -> date(e.airDate)?.let { it to e } }
            .groupBy({ it.first }, { it.second })
            .toSortedMap()
            .map { (day, eps) ->
                AirDay(
                    date = day,
                    episodes = eps,
                    past = today != null && day < today,
                    today = day == today,
                    finale = day == last,
                )
            }
    }

    fun rangeLabel(episodes: List<EpisodeView>): String {
        val numbers = episodes.map { it.episodeNumber }.sorted()
        val from = numbers.firstOrNull() ?: return ""
        val to = numbers.last()
        return if (from == to) "第 $from 集" else "第 $from–$to 集"
    }

    /** 「10月29日 周四」，海外首播加地区「（美国）」 */
    fun dayLabel(day: LocalDate, schedule: SeasonAirSchedule): String {
        val label = "${shortDate(day)} ${weekday(day)}"
        return schedule.region?.let { "$label（${regionName(it)}）" } ?: label
    }

    fun regionName(code: String): String =
        Locale("", code).getDisplayCountry(zh).ifBlank { code }

    /** 「每天 / 每周四 / 周一至周四 / 周二、周五」更新 */
    fun cadence(weekdays: List<Int>): String? {
        val days = weekdays.distinct().sorted()
        if (days.isEmpty()) return null
        val names = days.map { weekdayName(DayOfWeek.of(it + 1)) }
        return when {
            days.size == 7 -> "每天更新"
            days.size == 1 -> "每${names[0]}更新"
            days.zipWithNext().all { (a, b) -> b == a + 1 } -> "${names.first()}至${names.last()}更新"
            else -> names.joinToString("、") + "更新"
        }
    }

    fun finale(schedule: SeasonAirSchedule): String? {
        val last = date(schedule.lastAirDate) ?: return null
        return if (last == date(schedule.today)) "今天完结" else "${shortDate(last)} 完结"
    }

    /** 两个播出日之间的停更说明；周更剧的正常间隔不说（头部已经写了「每周四更新」） */
    fun gap(previous: LocalDate, next: LocalDate, weekly: Boolean): String? {
        val skipped = ChronoUnit.DAYS.between(previous, next).toInt() - 1
        if (skipped <= 0) return null
        if (skipped >= 7) return "停更 $skipped 天"
        if (weekly) return null
        val first = weekday(previous.plusDays(1))
        return if (skipped == 1) "${first}不更新" else "${first}至${weekday(next.minusDays(1))}不更新"
    }

    /** 一组同日播出的集在订阅里走到哪了（入口卡与日程「今天」行右侧） */
    fun arrival(episodes: List<EpisodeView>, schedule: SeasonAirSchedule): Pair<String, Color>? {
        val pending = episodes.filterNot { it.owned }.map { it.episodeNumber }.toSet()
        if (pending.isEmpty()) return "已入库，可以看了" to Ok
        if (schedule.subscriptionId == null) return "未订阅" to TextMuted
        val arrivals = schedule.arrivals.filter { it.episodeNumber in pending }
        if (arrivals.any { it.stage == "organizing" }) return "整理中" to Info
        if (arrivals.any { it.stage == "downloading" }) return "下载中" to Info
        arrivals.mapNotNull { it.expectedAt }.minOrNull()?.let { return "预计 ${expectedTime(it)} 入库" to Info }
        return if (arrivals.isEmpty()) null else "等待资源" to TextMuted
    }

    /** 预计入库时刻：今天只给时分，跨天带上日期 */
    fun expectedTime(iso: String): String {
        val clock = McFormat.clockTime(iso)
        val day = date(McFormat.dayKey(iso)) ?: return clock
        return if (day == LocalDate.now()) clock else "${shortDate(day)} $clock"
    }

    fun missingText(numbers: List<Int>): String =
        if (numbers.size == 1) "缺第 ${numbers[0]} 集" else "缺 ${numbers.size} 集"
}

/* ---------------- 季进度条 ---------------- */

@Composable
private fun AirSeasonBar(episodes: List<EpisodeView>, schedule: SeasonAirSchedule, height: Dp = 8.dp) {
    val segments = AirSchedule.segments(episodes, schedule)
    val counts = AirSchedule.counts(episodes, schedule)
    Row(
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .semantics {
                contentDescription = "本季进度：已入库 ${counts.owned}，缺 ${counts.missing}，待播 ${counts.upcoming}"
            },
    ) {
        segments.forEach { (tone, count) ->
            Box(
                Modifier
                    .weight(count.toFloat())
                    .fillMaxSize()
                    .clip(RoundedCornerShape(2.dp))
                    .background(tone.color),
            )
        }
    }
}

/* ---------------- 入口卡 ---------------- */

@Composable
internal fun AirScheduleCard(
    episodes: List<EpisodeView>,
    schedule: SeasonAirSchedule,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val days = remember(episodes, schedule) { AirSchedule.days(episodes, schedule) }
    val next = days.firstOrNull { !it.past }
    val counts = AirSchedule.counts(episodes, schedule)
    val meta = listOfNotNull(AirSchedule.cadence(schedule.weekdays), AirSchedule.finale(schedule)).joinToString(" · ")
    Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .fillMaxWidth()
            .testTag("air-schedule-card")
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xBD1E212B))
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
            .clickable(onClick = onOpen)
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.CalendarMonth, contentDescription = null, tint = Color(0xFFEEF2F8), modifier = Modifier.size(17.dp))
            Spacer(Modifier.width(8.dp))
            Text("播出日历", style = McType.subSemibold, color = TextPrimary)
            Spacer(Modifier.width(8.dp))
            Text(
                meta,
                style = McType.caption,
                color = TextMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.End,
            )
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = TextFaint, modifier = Modifier.size(18.dp))
        }
        AirSeasonBar(episodes, schedule)
        if (next != null) {
            val range = AirSchedule.rangeLabel(next.episodes)
            val headline = when {
                next.today && next.finale -> "今天大结局 $range"
                next.today -> "今天更新 $range"
                else -> "下次 ${AirSchedule.dayLabel(next.date, schedule)} · $range"
            }
            val note = if (next.today) {
                AirSchedule.arrival(next.episodes, schedule)
            } else {
                val offset = AirSchedule.daysBetween(schedule.today, next.date.toString())
                (if (offset == 1) "明天" else "$offset 天后") to TextMuted
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    headline,
                    style = McType.bodySemibold,
                    color = TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                note?.let { (text, color) ->
                    Spacer(Modifier.width(8.dp))
                    Text(text, style = McType.caption, color = color, maxLines = 1)
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("已入库 ${counts.owned}", style = McType.caption, color = TextMuted)
            if (counts.missing > 0) Text(AirSchedule.missingText(schedule.missingEpisodes), style = McType.caption, color = Warn)
            if (counts.upcoming > 0) Text("还有 ${counts.upcoming} 集待播", style = McType.caption, color = TextMuted)
        }
    }
}

/* ---------------- 日程底部面板 ---------------- */

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AirScheduleSheet(
    title: String,
    seasonLabel: String,
    episodes: List<EpisodeView>,
    schedule: SeasonAirSchedule,
    canSubscribe: Boolean,
    searching: Boolean,
    onFindMissing: () -> Unit,
    /** 未订阅时底部「订阅追更」；null 不显示 */
    onSubscribe: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    val days = remember(episodes, schedule) { AirSchedule.days(episodes, schedule) }
    val past = days.filter { it.past }
    val coming = days.filterNot { it.past }
    val counts = AirSchedule.counts(episodes, schedule)
    val weekly = schedule.weekdays.distinct().size == 1
    val canFind = canSubscribe && schedule.subscriptionId != null && schedule.missingEpisodes.isNotEmpty()
    var pastOpen by remember { mutableStateOf(false) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Color(0xFF1C1E24),
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .semantics { testTagsAsResourceId = true }
                .testTag("air-schedule-sheet"),
        ) {
            Column(Modifier.padding(horizontal = 20.dp)) {
                Text("播出日历", style = McType.headline, color = TextPrimary)
                Text(
                    listOfNotNull(title, seasonLabel, AirSchedule.cadence(schedule.weekdays)).joinToString(" · "),
                    style = McType.caption,
                    color = TextMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(14.dp))
                AirSeasonBar(episodes, schedule, height = 10.dp)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Legend(AirTone.Owned, "已入库 ${counts.owned}")
                    if (counts.missing > 0) Legend(AirTone.Missing, "缺集 ${counts.missing}")
                    coming.firstOrNull()?.takeIf { it.today }?.let { today ->
                        Legend(
                            if (schedule.subscriptionId != null) AirTone.Today else AirTone.TodayFree,
                            "今天 ${today.episodes.count { !it.owned }}",
                        )
                    }
                    Legend(AirTone.Upcoming, "待播 ${counts.upcoming}")
                    Spacer(Modifier.weight(1f))
                    AirSchedule.finale(schedule)?.let { Text(it, style = McType.micro, color = TextMuted) }
                }
            }
            Column(Modifier.weight(1f, fill = false).fillMaxWidth().formSheetContent()) {
                Spacer(Modifier.height(14.dp))
                Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.08f)))
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
                    modifier = Modifier.weight(1f, fill = false).heightIn(max = 560.dp).testTag("air-schedule-list").formSheetScroll(),
                ) {
                    if (past.isNotEmpty()) {
                        item(key = "past") {
                            PastSummary(past, schedule, pastOpen, canFind, searching, onToggle = { pastOpen = !pastOpen }, onFind = onFindMissing)
                        }
                    }
                    val shown = (if (pastOpen) past else emptyList()) + coming
                    shown.forEachIndexed { index, day ->
                        val previous = shown.getOrNull(index - 1)
                        // 已播与待播之间（折叠时）不画间隙：中间隔着汇总行
                        val gap = previous?.let { AirSchedule.gap(it.date, day.date, weekly) }
                        if (gap != null) item(key = "gap-${day.date}") { GapRow(gap) }
                        item(key = day.date.toString()) { DayRow(day, schedule, canFind, searching, onFindMissing) }
                    }
                    schedule.region?.let { code ->
                        item(key = "region") { Footnote("播出日期为${AirSchedule.regionName(code)}当地日期") }
                    }
                    if (schedule.subscriptionId != null) {
                        item(key = "source") { Footnote("播出日期来自 TMDB · 入库时间是订阅按站点发布规律推算的") }
                    }
                }
                if (schedule.subscriptionId == null && onSubscribe != null) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp).navigationBarsPadding(),
                    ) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(48.dp)
                                .clip(RoundedCornerShape(999.dp))
                                .background(Color.White)
                                .clickable(onClick = onSubscribe)
                                .testTag("air-schedule-subscribe"),
                        ) {
                            Text("订阅追更", style = McType.bodySemibold, color = Color.Black)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text("之后每一集播出后都会自动下载入库", style = McType.caption, color = TextMuted)
                    }
                }
            }
        }
    }
}

@Composable
private fun Legend(tone: AirTone, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).clip(RoundedCornerShape(2.dp)).background(tone.color))
        Spacer(Modifier.width(5.dp))
        Text(label, style = McType.micro, color = TextMuted, maxLines = 1)
    }
}

@Composable
private fun Footnote(text: String) {
    Text(text, style = McType.micro, color = TextMuted, modifier = Modifier.padding(start = 4.dp, top = 6.dp))
}

@Composable
private fun GapRow(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        DashedLine(Modifier.weight(1f))
        Text(text, style = McType.micro, color = TextMuted, modifier = Modifier.padding(horizontal = 10.dp))
        DashedLine(Modifier.weight(1f))
    }
}

@Composable
private fun DashedLine(modifier: Modifier) {
    Canvas(modifier.height(1.dp)) {
        drawLine(
            color = Color.White.copy(alpha = 0.2f),
            start = Offset(0f, size.height / 2),
            end = Offset(size.width, size.height / 2),
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 8f)),
        )
    }
}

@Composable
private fun FindButton(text: String, filled: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Text(
        text,
        style = McType.captionSemibold,
        color = Warn,
        modifier = Modifier
            .testTag("air-schedule-find")
            .clip(RoundedCornerShape(999.dp))
            .background(if (filled) Warn.copy(alpha = 0.1f) else Color.Transparent)
            .border(1.dp, Warn.copy(alpha = 0.55f), RoundedCornerShape(999.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    )
}

@Composable
private fun PastSummary(
    past: List<AirDay>,
    schedule: SeasonAirSchedule,
    open: Boolean,
    canFind: Boolean,
    searching: Boolean,
    onToggle: () -> Unit,
    onFind: () -> Unit,
) {
    val all = past.flatMap { it.episodes }
    val missing = all.map { it.episodeNumber }.filter { it in schedule.missingEpisodes }
    val title = if (past.size == 1) {
        "已播出 · ${AirSchedule.shortDate(past[0].date)}"
    } else {
        "已播出 · ${AirSchedule.shortDate(past.first().date)}–${AirSchedule.shortDate(past.last().date)}"
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .padding(start = 12.dp, end = 10.dp, top = 6.dp, bottom = 6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .weight(1f)
                .heightIn(min = 44.dp)
                .testTag("air-schedule-past")
                .clickable(onClick = onToggle),
        ) {
            Icon(
                Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                contentDescription = if (open) "收起已播出" else "展开已播出",
                tint = TextMuted,
                modifier = Modifier.size(18.dp).rotate(if (open) 90f else 0f),
            )
            Spacer(Modifier.width(8.dp))
            Column {
                Text(title, style = McType.subSemibold, color = TextPrimary)
                Row {
                    Text("${all.size} 集 · 已入库 ${all.count { it.owned }}", style = McType.caption, color = TextMuted)
                    if (missing.isNotEmpty()) Text(" · ${AirSchedule.missingText(missing)}", style = McType.caption, color = Warn)
                }
            }
        }
        if (canFind) {
            val ids = schedule.missingEpisodes
            FindButton(if (ids.size == 1) "补第 ${ids[0]} 集" else "补 ${ids.size} 集", filled = true, enabled = !searching, onClick = onFind)
        }
    }
}

@Composable
private fun DayRow(day: AirDay, schedule: SeasonAirSchedule, canFind: Boolean, searching: Boolean, onFind: () -> Unit) {
    val dayMissing = day.episodes.map { it.episodeNumber }.filter { it in schedule.missingEpisodes }
    val allOwned = day.episodes.all { it.owned }
    val shape = RoundedCornerShape(12.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 60.dp)
            .testTag("air-day-${day.date}")
            .clip(shape)
            .background(if (day.today) AirTone.Today.color.copy(alpha = 0.12f) else Color.White.copy(alpha = 0.04f))
            .then(if (day.today) Modifier.border(1.dp, AirTone.Today.color.copy(alpha = 0.5f), shape) else Modifier)
            .padding(start = 4.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(80.dp)) {
            Text(
                if (day.today) "今天" else AirSchedule.weekday(day.date),
                style = if (day.today) McType.microSemibold else McType.micro,
                color = if (day.today) Info else TextMuted,
            )
            Text(AirSchedule.shortDate(day.date), style = McType.bodySemibold.copy(fontWeight = FontWeight.Bold), color = TextPrimary, maxLines = 1)
        }
        Spacer(Modifier.width(6.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(AirSchedule.rangeLabel(day.episodes), style = McType.bodySemibold, color = TextPrimary)
                if (day.finale) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "大结局",
                        style = McType.microSemibold,
                        color = TextPrimary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .background(Color.White.copy(alpha = 0.14f))
                            .padding(horizontal = 6.dp, vertical = 1.dp),
                    )
                }
            }
            if (day.past && dayMissing.isNotEmpty()) {
                Text(AirSchedule.missingText(dayMissing), style = McType.caption, color = Warn)
            }
        }
        when {
            day.past && allOwned -> Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Check, contentDescription = null, tint = Ok, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(3.dp))
                Text("已入库", style = McType.caption, color = Ok)
            }
            day.past && dayMissing.isEmpty() -> Text("库里没有", style = McType.caption, color = TextMuted)
            day.past && canFind -> FindButton("补这一集", filled = false, enabled = !searching, onClick = onFind)
            day.today -> AirSchedule.arrival(day.episodes, schedule)?.let { (text, color) ->
                Text(text, style = McType.captionSemibold, color = color, maxLines = 1)
            }
        }
    }
}

/* ---------------- 还没播的集的剧照位 ---------------- */

/** 今天播出描蓝边、写入库状态；之后的虚线框写播出日；没日期写待定档 */
@Composable
internal fun UnairedStill(episode: EpisodeView, schedule: SeasonAirSchedule, today: Boolean) {
    val shape = RoundedCornerShape(12.dp)
    if (today) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier
                .fillMaxSize()
                .clip(shape)
                .background(Color(0xFF11151D))
                .border(1.5.dp, AirTone.Today.color.copy(alpha = 0.75f), shape),
        ) {
            Text("今天播出", style = McType.subSemibold, color = TextPrimary)
            AirSchedule.arrival(listOf(episode), schedule)?.let { (text, color) ->
                Spacer(Modifier.height(3.dp))
                Text(text, style = McType.micro, color = color, maxLines = 1)
            }
        }
    } else {
        val air = AirSchedule.date(episode.airDate)
        Box(Modifier.fillMaxSize().clip(shape).background(Color(0xFF0E0F13))) {
            Canvas(Modifier.fillMaxSize()) {
                drawRoundRect(
                    color = Color.White.copy(alpha = 0.25f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(12.dp.toPx()),
                    style = androidx.compose.ui.graphics.drawscope.Stroke(
                        width = 1.dp.toPx(),
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f)),
                    ),
                )
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.align(Alignment.Center)) {
                if (air != null) {
                    Text("${AirSchedule.shortDate(air)} ${AirSchedule.weekday(air)}", style = McType.subSemibold, color = TextPrimary.copy(alpha = 0.85f))
                    val offset = AirSchedule.daysBetween(schedule.today, air.toString())
                    Spacer(Modifier.height(3.dp))
                    Text(if (offset == 1) "明天" else "$offset 天后", style = McType.micro, color = TextMuted)
                } else {
                    Text("待定档", style = McType.subSemibold, color = TextPrimary.copy(alpha = 0.85f))
                }
            }
        }
    }
}
