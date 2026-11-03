package io.movieclaw.android.feature.detail

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Ok
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
 * 分集标题下的两行摘要入口 + 分本周 / 下周 / 之后的日程底部面板。只在本季还有今天或以后的播出日期时出现
 * （服务端不给 airSchedule 就整块不画）。日期一律是 yyyy-MM-dd 的日历日，「今天」由服务端按站点日历给出。
 */

enum class AirTone { Owned, Missing, Today, TodayFree, Upcoming, Absent }

/** 今天播出的剧照位描边 */
private val TodayBlue = Color(0xFF3B82F6)

/** 琥珀底上的深色字（大结局标签、补集按钮） */
private val OnWarn = Color(0xFF241A02)

data class AirDay(
    val date: LocalDate,
    val episodes: List<EpisodeView>,
    val past: Boolean,
    val today: Boolean,
    val finale: Boolean,
)

data class AirCounts(val owned: Int, val missing: Int, val upcoming: Int)

object AirSchedule {
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

    /** 某天所在的周相对今天所在的周差几周（周一起算）：0 本周、1 下周，已播的为负 */
    fun weekOffset(today: LocalDate, day: LocalDate): Int =
        Math.floorDiv(ChronoUnit.DAYS.between(today, day).toInt() + today.dayOfWeek.value - 1, 7)

    /** 日程分组标题：本周 / 下周 / 之后（再往后按周分，周更剧就成了一行一个标题） */
    fun groupTitle(group: Int): String = when (group) {
        0 -> "本周"
        1 -> "下周"
        else -> "之后"
    }

    fun rangeLabel(episodes: List<EpisodeView>): String {
        val numbers = episodes.map { it.episodeNumber }.sorted()
        val from = numbers.firstOrNull() ?: return ""
        val to = numbers.last()
        return if (from == to) "第 $from 集" else "第 $from–$to 集"
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

    /** 「明天 / 6 天后」 */
    fun relative(day: LocalDate, schedule: SeasonAirSchedule): String {
        val offset = daysBetween(schedule.today, day.toString())
        return if (offset == 1) "明天" else "$offset 天后"
    }

    /**
     * 两个播出日之间的停更说明。头部已经写了「周五至周六更新」，按节奏空着的日子不说，
     * 只标跳过了本该更新的日子的真停更
     */
    fun gap(previous: LocalDate, next: LocalDate, weekdays: List<Int>): String? {
        val skipped = ChronoUnit.DAYS.between(previous, next).toInt() - 1
        if (skipped <= 0) return null
        if ((1..skipped).none { previous.plusDays(it.toLong()).dayOfWeek.value - 1 in weekdays }) return null
        if (skipped >= 7) return "停更 $skipped 天"
        val first = weekday(previous.plusDays(1))
        return if (skipped == 1) "${first}不更新" else "${first}至${weekday(next.minusDays(1))}不更新"
    }

    /** 一组同日播出的集在订阅里走到哪了（日程「今天」行右侧） */
    fun arrival(episodes: List<EpisodeView>, schedule: SeasonAirSchedule): Pair<String, Color>? {
        expectedAt(episodes, schedule)?.let { return "预计 ${expectedTime(it)} 入库" to Info }
        val pending = episodes.filterNot { it.owned }.map { it.episodeNumber }.toSet()
        if (pending.isEmpty()) return "已入库，可以看了" to Ok
        if (schedule.subscriptionId == null) return "未订阅" to TextMuted
        val arrivals = schedule.arrivals.filter { it.episodeNumber in pending }
        if (arrivals.any { it.stage == "organizing" }) return "整理中" to Info
        if (arrivals.any { it.stage == "downloading" }) return "下载中" to Info
        return if (arrivals.isEmpty()) null else "等待资源" to TextMuted
    }

    /** 还没入库、也不在下载 / 整理中的那几集最早的预计入库时刻 */
    fun expectedAt(episodes: List<EpisodeView>, schedule: SeasonAirSchedule): String? {
        val pending = episodes.filterNot { it.owned }.map { it.episodeNumber }.toSet()
        if (pending.isEmpty() || schedule.subscriptionId == null) return null
        val arrivals = schedule.arrivals.filter { it.episodeNumber in pending }
        if (arrivals.any { it.stage == "organizing" || it.stage == "downloading" }) return null
        return arrivals.mapNotNull { it.expectedAt }.minOrNull()
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

/* ---------------- 入口：分集标题下的两行摘要 ---------------- */

private data class SummarySide(val value: String, val caption: String?, val color: Color, val large: Boolean = false)

/** 今天的看入库进度（预计时刻放大），之后的看还有几天 */
private fun summarySide(day: AirDay, schedule: SeasonAirSchedule): SummarySide? {
    if (!day.today) {
        val date = AirSchedule.shortDate(day.date)
        val caption = schedule.region?.let { "$date（${AirSchedule.regionName(it)}）" } ?: date
        return SummarySide(AirSchedule.relative(day.date, schedule), caption, TextPrimary)
    }
    if (day.episodes.all { it.owned }) return SummarySide("已入库", null, Ok)
    AirSchedule.expectedAt(day.episodes, schedule)?.let { at ->
        val sameDay = AirSchedule.date(McFormat.dayKey(at)) == LocalDate.now()
        return SummarySide(AirSchedule.expectedTime(at), "预计入库", Info, large = sameDay)
    }
    return AirSchedule.arrival(day.episodes, schedule)?.let { (text, color) -> SummarySide(text, null, color) }
}

/** 左边今天 / 下次更新哪一集 + 一行本季节奏，右边入库时刻或还有几天；整块点开日程。缺集只在日程里标 */
@Composable
internal fun AirScheduleSummary(
    episodes: List<EpisodeView>,
    schedule: SeasonAirSchedule,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val days = remember(episodes, schedule) { AirSchedule.days(episodes, schedule) }
    val next = days.firstOrNull { !it.past }
    val counts = AirSchedule.counts(episodes, schedule)
    val cadence = AirSchedule.cadence(schedule.weekdays)
    val remaining = if (counts.upcoming > 0) "还剩 ${counts.upcoming} 集" else null
    val finale = AirSchedule.finale(schedule)
    val side = next?.let { summarySide(it, schedule) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .testTag("air-schedule-summary")
            .clickable(onClick = onOpen),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.weight(1f)) {
            if (next != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (next.today) "今天" else AirSchedule.weekday(next.date),
                        style = McType.microSemibold.copy(fontWeight = FontWeight.Bold),
                        color = if (next.today) Color(0xFF111318) else TextPrimary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(if (next.today) TextPrimary else Color.White.copy(alpha = 0.14f))
                            .padding(horizontal = 7.dp, vertical = 2.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    val range = AirSchedule.rangeLabel(next.episodes)
                    Text(
                        if (next.finale) "$range 大结局" else "${range}更新",
                        style = McType.bodySemibold,
                        color = TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            // 一行放不下先省完结日，再省更新节奏，别把「11月8日」折成两行
            MetaLine(
                listOf(listOf(cadence, remaining, finale), listOf(cadence, remaining), listOf(remaining))
                    .map { it.filterNotNull().joinToString(" · ") }
                    .filter { it.isNotEmpty() },
            )
        }
        if (side != null) {
            Spacer(Modifier.width(14.dp))
            Box(Modifier.width(0.5.dp).height(38.dp).background(Color.White.copy(alpha = 0.18f)))
            Spacer(Modifier.width(14.dp))
            Column(horizontalAlignment = Alignment.End) {
                Text(
                    side.value,
                    style = if (side.large) McType.title3.copy(fontWeight = FontWeight.SemiBold) else McType.bodySemibold,
                    color = side.color,
                    maxLines = 1,
                )
                side.caption?.let { Text(it, style = McType.micro, color = TextMuted, maxLines = 1) }
            }
        }
    }
}

/** 从长到短挑第一条一行放得下的；都放不下就用最短的那条 */
@Composable
private fun MetaLine(candidates: List<String>) {
    if (candidates.isEmpty()) return
    val measurer = rememberTextMeasurer()
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val text = candidates.firstOrNull {
            measurer.measure(it, McType.caption, maxLines = 1, softWrap = false).size.width <= constraints.maxWidth
        } ?: candidates.last()
        Text(text, style = McType.caption, color = TextMuted)
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
    val finale = AirSchedule.finale(schedule)
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
            Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp)) {
                Text("播出日历", style = McType.headline, color = TextPrimary, modifier = Modifier.align(Alignment.Center))
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.12f))
                        .border(0.5.dp, Color.White.copy(alpha = 0.16f), CircleShape)
                        .clickable(onClick = onDismiss)
                        .semantics { contentDescription = "关闭" },
                ) {
                    Icon(Icons.Rounded.Close, contentDescription = null, tint = TextPrimary, modifier = Modifier.size(18.dp))
                }
            }
            Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 14.dp)) {
                Text(
                    listOfNotNull(title, seasonLabel, AirSchedule.cadence(schedule.weekdays)).joinToString(" · "),
                    style = McType.caption,
                    color = TextMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(3.dp))
                Row {
                    if (counts.upcoming > 0) {
                        Text("还剩 ${counts.upcoming} 集", style = McType.title, color = TextPrimary, modifier = Modifier.alignByBaseline())
                        finale?.let {
                            Spacer(Modifier.width(10.dp))
                            Text(it, style = McType.sub, color = TextMuted, modifier = Modifier.alignByBaseline())
                        }
                    } else if (finale != null) {
                        Text(finale, style = McType.title, color = TextPrimary)
                    }
                }
            }
            Column(Modifier.weight(1f, fill = false).fillMaxWidth().formSheetContent()) {
                Spacer(Modifier.height(4.dp))
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 12.dp),
                    modifier = Modifier.weight(1f, fill = false).heightIn(max = 560.dp).testTag("air-schedule-list").formSheetScroll(),
                ) {
                    if (past.isNotEmpty()) {
                        item(key = "past") {
                            PastSummary(past, schedule, pastOpen, canFind, searching, onToggle = { pastOpen = !pastOpen }, onFind = onFindMissing)
                        }
                    }
                    if (pastOpen) dayRows(past, schedule, grouped = false, canFind, searching, onFindMissing)
                    dayRows(coming, schedule, grouped = true, canFind, searching, onFindMissing)
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

/** 一组播出日：按需插「本周 / 下周 / 之后」标题和停更分隔 */
private fun LazyListScope.dayRows(
    list: List<AirDay>,
    schedule: SeasonAirSchedule,
    grouped: Boolean,
    canFind: Boolean,
    searching: Boolean,
    onFind: () -> Unit,
) {
    val today = AirSchedule.date(schedule.today) ?: return
    var current: Int? = null
    list.forEachIndexed { index, day ->
        val group = minOf(AirSchedule.weekOffset(today, day.date), 2)
        if (grouped && group != current) {
            current = group
            item(key = "group-$group") {
                Text(
                    AirSchedule.groupTitle(group),
                    style = McType.captionSemibold,
                    color = TextMuted,
                    modifier = Modifier.padding(start = 14.dp, top = if (index == 0) 4.dp else 16.dp, bottom = 4.dp),
                )
            }
        }
        val gap = list.getOrNull(index - 1)?.let { AirSchedule.gap(it.date, day.date, schedule.weekdays) }
        if (gap != null) item(key = "gap-${day.date}") { GapRow(gap) }
        item(key = day.date.toString()) { DayRow(day, schedule, canFind, searching, onFind) }
    }
}

@Composable
private fun Footnote(text: String) {
    Text(text, style = McType.micro, color = TextMuted, modifier = Modifier.padding(start = 14.dp, top = 8.dp))
}

@Composable
private fun GapRow(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp)) {
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
private fun FindButton(text: String, filled: Boolean, enabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Text(
        text,
        style = McType.captionSemibold,
        color = if (filled) OnWarn else Warn,
        modifier = modifier
            .testTag("air-schedule-find")
            .clip(RoundedCornerShape(999.dp))
            .background(if (filled) Warn else Color.Transparent)
            .then(if (filled) Modifier else Modifier.border(1.dp, Warn.copy(alpha = 0.55f), RoundedCornerShape(999.dp)))
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
    val owned = all.count { it.owned }
    val aired = if (past.size == 1) {
        "已播出 · ${AirSchedule.shortDate(past[0].date)}"
    } else {
        "已播出 · ${AirSchedule.shortDate(past.first().date)}–${AirSchedule.shortDate(past.last().date)}"
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 4.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.06f))
            .padding(start = 14.dp, end = 10.dp, top = 6.dp, bottom = 6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .weight(1f)
                .heightIn(min = 44.dp)
                .testTag("air-schedule-past")
                .clickable(onClick = onToggle),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(26.dp).clip(CircleShape).background((if (missing.isEmpty()) Ok else Warn).copy(alpha = 0.18f)),
            ) {
                if (missing.isEmpty()) {
                    Icon(Icons.Rounded.Check, contentDescription = null, tint = Ok, modifier = Modifier.size(15.dp))
                } else {
                    Text("!", style = McType.subSemibold.copy(fontWeight = FontWeight.Bold), color = Warn)
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(AirSchedule.rangeLabel(all), style = McType.subSemibold, color = TextPrimary)
                Text(aired, style = McType.caption, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.width(4.dp))
            when {
                // 能补集时右边的「补第 7 集」已经说了缺哪集，这里不再重复
                missing.isNotEmpty() -> if (!canFind) Text(AirSchedule.missingText(missing), style = McType.caption, color = Warn)
                owned == all.size -> Text("已入库", style = McType.caption, color = Ok)
                else -> Text("已入库 $owned", style = McType.caption, color = TextMuted)
            }
            Icon(
                Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                contentDescription = if (open) "收起已播出" else "展开已播出",
                tint = TextMuted,
                modifier = Modifier.padding(start = 4.dp).size(18.dp).rotate(if (open) 90f else 0f),
            )
        }
        if (canFind) {
            val ids = schedule.missingEpisodes
            Spacer(Modifier.width(8.dp))
            FindButton(if (ids.size == 1) "补第 ${ids[0]} 集" else "补 ${ids.size} 集", filled = true, enabled = !searching, onClick = onFind)
        }
    }
}

/** 时间线上的点：今天实心蓝、大结局琥珀圈、已播按入库与否，之后的空心圈 */
@Composable
private fun DayDot(day: AirDay, missing: Boolean, owned: Boolean, modifier: Modifier) {
    val base = modifier.size(10.dp).clip(CircleShape)
    Box(
        when {
            day.today -> base.background(Info)
            day.finale -> base.border(2.dp, Warn, CircleShape)
            day.past && missing -> base.background(Warn)
            day.past && owned -> base.background(Ok)
            else -> base.border(1.5.dp, Color.White.copy(alpha = 0.5f), CircleShape)
        },
    )
}

@Composable
private fun DayRow(day: AirDay, schedule: SeasonAirSchedule, canFind: Boolean, searching: Boolean, onFind: () -> Unit) {
    val dayMissing = day.episodes.map { it.episodeNumber }.filter { it in schedule.missingEpisodes }
    val allOwned = day.episodes.all { it.owned }
    // 圆点没有基线：让圆心落在集号字身中部（基线上方约 6dp）
    val dotLift = with(LocalDensity.current) { 6.dp.roundToPx() }
    // 星期单独占一行；日期、圆点、集号、右侧状态排在同一行按文字基线对齐，集号不会落在两行日期的中间
    Column(
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 60.dp)
            .testTag("air-day-${day.date}")
            .clip(RoundedCornerShape(16.dp))
            .background(if (day.today) Info.copy(alpha = 0.14f) else Color.Transparent)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text(
            if (day.today) "今天" else AirSchedule.weekday(day.date),
            style = if (day.today) McType.microSemibold.copy(fontWeight = FontWeight.Bold) else McType.micro,
            color = if (day.today) Info else TextMuted,
        )
        Row(Modifier.fillMaxWidth()) {
            // 定宽：「11月2日」与「10月28日」两行的集号要对齐
            Text(
                AirSchedule.shortDate(day.date),
                style = McType.subSemibold,
                color = TextPrimary,
                maxLines = 1,
                modifier = Modifier.width(72.dp).alignByBaseline(),
            )
            Spacer(Modifier.width(12.dp))
            DayDot(day, dayMissing.isNotEmpty(), allOwned, Modifier.alignBy { it.measuredHeight / 2 + dotLift })
            Spacer(Modifier.width(12.dp))
            Row(Modifier.weight(1f).alignByBaseline()) {
                Text(AirSchedule.rangeLabel(day.episodes), style = McType.bodySemibold, color = TextPrimary, modifier = Modifier.alignByBaseline())
                if (day.finale) {
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "大结局",
                        style = McType.microSemibold.copy(fontWeight = FontWeight.Bold),
                        color = OnWarn,
                        modifier = Modifier
                            .alignByBaseline()
                            .clip(RoundedCornerShape(6.dp))
                            .background(Warn)
                            .padding(horizontal = 6.dp, vertical = 1.dp),
                    )
                }
            }
            Spacer(Modifier.width(4.dp))
            when {
                day.past && allOwned -> Row(Modifier.alignByBaseline(), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Check, contentDescription = null, tint = Ok, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(3.dp))
                    Text("已入库", style = McType.caption, color = Ok)
                }
                day.past && dayMissing.isEmpty() -> Text("库里没有", style = McType.caption, color = TextMuted, modifier = Modifier.alignByBaseline())
                day.past && canFind -> FindButton("补这一集", filled = false, enabled = !searching, onClick = onFind, modifier = Modifier.alignByBaseline())
                day.today -> AirSchedule.arrival(day.episodes, schedule)?.let { (text, color) ->
                    Text(text, style = McType.captionSemibold, color = color, maxLines = 1, modifier = Modifier.alignByBaseline())
                }
                !day.past -> Text(AirSchedule.relative(day.date, schedule), style = McType.caption, color = TextMuted, modifier = Modifier.alignByBaseline())
            }
        }
        if (day.past && dayMissing.isNotEmpty()) {
            // 与集号左缘对齐：日期 72 + 间距 12 + 圆点 10 + 间距 12
            Text(AirSchedule.missingText(dayMissing), style = McType.caption, color = Warn, modifier = Modifier.padding(start = 106.dp))
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
                .border(1.5.dp, TodayBlue.copy(alpha = 0.75f), shape),
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
