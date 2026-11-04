package io.movieclaw.androidtv.ui.detail

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.core.model.generated.MediaBrief
import io.movieclaw.core.model.generated.PrepareView
import io.movieclaw.core.model.generated.SeasonAirScheduleView
import io.movieclaw.core.model.generated.SmartPlanView
import io.movieclaw.core.model.generated.SubscriptionCreatePayload
import io.movieclaw.core.model.generated.SubscriptionTargetPreviewPayload
import io.movieclaw.core.network.generated.McApi
import kotlinx.coroutines.CancellationException
import java.util.Calendar
import java.util.GregorianCalendar
import java.util.Locale
import java.util.TimeZone

/*
 * 播出日历（issue #547，Apple 端 Shared/Library/AirScheduleLogic.swift）的口径，单独放这里方便单测。
 * 只在本季还有今天或以后的播出日期时出现（服务端不给 airSchedule 就整块不画）。日期一律是 yyyy-MM-dd 的日历日，
 * 「今天」由服务端按站点日历给出，不用本机时钟。
 */

/**
 * 日历日（minSdk 23 没有 java.time）：从 1970-01-01 起的天数，比大小、算差值都直接减。
 * 年月日与天数互换是纯整数运算（Howard Hinnant 的 civil 算法）：一季上千集时要换算上千次，别走 Calendar
 */
internal data class AirDate(val epochDay: Int) : Comparable<AirDate> {
    private val shifted: Int get() = epochDay + 719_468
    private val era: Int get() = Math.floorDiv(shifted, 146_097)
    private val dayOfEra: Int get() = shifted - era * 146_097
    private val yearOfEra: Int get() = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    private val dayOfYear: Int get() = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    private val shiftedMonth: Int get() = (5 * dayOfYear + 2) / 153

    val day: Int get() = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    val month: Int get() = if (shiftedMonth < 10) shiftedMonth + 3 else shiftedMonth - 9
    val year: Int get() = yearOfEra + era * 400 + if (month <= 2) 1 else 0

    /** 0=周一…6=周日（1970-01-01 是周四） */
    val weekday: Int get() = Math.floorMod(epochDay + 3, 7)

    fun plusDays(days: Int) = AirDate(epochDay + days)

    /** 还原成接口里的写法 */
    val iso: String get() = "%04d-%02d-%02d".format(Locale.US, year, month, day)

    override fun compareTo(other: AirDate) = epochDay.compareTo(other.epochDay)

    companion object {
        fun parse(raw: String?): AirDate? {
            if (raw == null || raw.length < 10 || raw[4] != '-' || raw[7] != '-') return null
            val year = raw.substring(0, 4).toIntOrNull() ?: return null
            val month = raw.substring(5, 7).toIntOrNull() ?: return null
            val day = raw.substring(8, 10).toIntOrNull() ?: return null
            val shiftedYear = if (month <= 2) year - 1 else year
            val era = Math.floorDiv(shiftedYear, 400)
            val yearOfEra = shiftedYear - era * 400
            val dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
            val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            return AirDate(era * 146_097 + dayOfEra - 719_468)
        }
    }
}

internal enum class AirTone { Owned, Missing, Today, TodayFree, Upcoming, Absent }

internal data class AirDay(
    val date: AirDate,
    val episodes: List<EpisodeView>,
    val past: Boolean,
    val today: Boolean,
    val finale: Boolean,
)

/** 日程里的一行：分组标题、停更说明、一个播出日 */
internal sealed interface AirRow {
    val key: String

    data class Group(val group: Int) : AirRow {
        override val key get() = "group-$group"
    }

    data class Gap(val after: AirDate, val text: String) : AirRow {
        override val key get() = "gap-${after.epochDay}"
    }

    data class Day(val day: AirDay) : AirRow {
        override val key get() = "day-${day.date.epochDay}"
    }
}

/** 日程一行右侧写什么 */
internal sealed interface AirDayStatus {
    data object Owned : AirDayStatus
    /** 已播、库里没有、也不在订阅范围内 */
    data object Absent : AirDayStatus
    /** 已播、订阅在找 */
    data object Missing : AirDayStatus
    /** 今天的入库进度 */
    data class Arrival(val text: String, val color: Color) : AirDayStatus
    /** 「明天 / 6 天后」 */
    data class Relative(val text: String) : AirDayStatus
    data object None : AirDayStatus
}

/** 时间线上的点：今天实心蓝、大结局琥珀圈、已播按入库与否，之后的空心圈 */
internal enum class AirDot { Today, Finale, Missing, Owned, Upcoming }

internal data class AirCounts(val owned: Int, val missing: Int, val upcoming: Int)

/** 入口条右边：今天的看入库进度（预计时刻放大），之后的看还有几天 */
internal data class AirSide(val value: String, val caption: String?, val color: Color, val large: Boolean = false)

/** 入口条的内容：今天 / 下次更新哪一集 + 本季节奏，右边入库时刻或还有几天 */
internal class AirSummary(episodes: List<EpisodeView>, schedule: SeasonAirScheduleView) {
    val next: AirDay? = AirSchedule.days(episodes, schedule).firstOrNull { !it.past }
    val tag: String? = next?.let { if (it.today) "今天" else AirSchedule.weekday(it.date) }
    val headline: String? = next?.let { day ->
        val range = AirSchedule.rangeLabel(day.episodes)
        if (day.finale) "$range 大结局" else "${range}更新"
    }
    val meta: String = listOfNotNull(
        AirSchedule.cadence(schedule.weekdays),
        AirSchedule.counts(episodes, schedule).upcoming.takeIf { it > 0 }?.let { "还剩 $it 集" },
        AirSchedule.finale(schedule),
    ).joinToString(" · ")
    val side: AirSide? = next?.let { side(it, schedule) }

    private fun side(day: AirDay, schedule: SeasonAirScheduleView): AirSide? {
        if (!day.today) {
            val date = AirSchedule.shortDate(day.date)
            val caption = schedule.region?.let { "$date（${AirSchedule.regionName(it)}）" } ?: date
            return AirSide(AirSchedule.relative(day.date, schedule), caption, McColors.Text)
        }
        if (day.episodes.all { it.owned }) return AirSide("已入库", null, McColors.Success)
        AirSchedule.expectedAt(day.episodes, schedule)?.let { at ->
            return AirSide(AirSchedule.expectedTime(at), "预计入库", McColors.Info, large = AirSchedule.isToday(at))
        }
        return AirSchedule.arrival(day.episodes, schedule)?.let { (text, color) -> AirSide(text, null, color) }
    }
}

/** 已播出的日子折叠成的那一行 */
internal class AirPastSummary(past: List<AirDay>, schedule: SeasonAirScheduleView) {
    private val all = past.flatMap { it.episodes }
    val range: String = AirSchedule.rangeLabel(all)
    val missing: List<Long> = all.map { it.episodeNumber }.filter { it in schedule.missingEpisodes }
    val owned: Int = all.count { it.owned }
    val allOwned: Boolean = owned == all.size
    val aired: String = when {
        past.isEmpty() -> ""
        past.size == 1 -> "已播出 · ${AirSchedule.shortDate(past[0].date)}"
        else -> "已播出 · ${AirSchedule.shortDate(past.first().date)}–${AirSchedule.shortDate(past.last().date)}"
    }
}

internal object AirSchedule {
    private val WEEKDAYS = listOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")
    private val ISO_TIME = Regex("""^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$""")

    fun shortDate(day: AirDate): String = "${day.month}月${day.day}日"

    fun weekday(day: AirDate): String = WEEKDAYS[day.weekday]

    fun tone(episode: EpisodeView, schedule: SeasonAirScheduleView): AirTone {
        if (episode.owned) return AirTone.Owned
        if (episode.episodeNumber in schedule.missingEpisodes) return AirTone.Missing
        val air = AirDate.parse(episode.airDate) ?: return AirTone.Upcoming
        val today = AirDate.parse(schedule.today) ?: return AirTone.Upcoming
        return when {
            air > today -> AirTone.Upcoming
            air == today -> if (schedule.subscriptionId != null) AirTone.Today else AirTone.TodayFree
            else -> AirTone.Absent
        }
    }

    /** 库里没有、今天播出的集（分集卡剧照位写入库状态） */
    fun airsToday(episode: EpisodeView, schedule: SeasonAirScheduleView?): Boolean {
        if (schedule == null || episode.owned) return false
        val tone = tone(episode, schedule)
        return tone == AirTone.Today || tone == AirTone.TodayFree
    }

    /**
     * 库里没有、但还没播的集（今天播出或之后）：不置灰、不标「缺」，剧照位换成播出日。
     * 有日历才分得清「还没播」与「缺集」；没有日历时库里没有的集一律按缺集
     */
    fun isUnaired(episode: EpisodeView, schedule: SeasonAirScheduleView?): Boolean {
        if (schedule == null || episode.owned) return false
        return tone(episode, schedule) in setOf(AirTone.Today, AirTone.TodayFree, AirTone.Upcoming)
    }

    fun counts(episodes: List<EpisodeView>, schedule: SeasonAirScheduleView): AirCounts {
        val today = AirDate.parse(schedule.today)
        return AirCounts(
            owned = episodes.count { it.owned },
            missing = schedule.missingEpisodes.size,
            upcoming = episodes.count { e ->
                if (e.owned) return@count false
                val air = AirDate.parse(e.airDate)
                air == null || today == null || air > today
            },
        )
    }

    /** 有日期的集按播出日分组，升序 */
    fun days(episodes: List<EpisodeView>, schedule: SeasonAirScheduleView): List<AirDay> {
        val last = AirDate.parse(schedule.lastAirDate)
        val today = AirDate.parse(schedule.today)
        return episodes
            .mapNotNull { e -> AirDate.parse(e.airDate)?.let { it to e } }
            .groupBy({ it.first }, { it.second })
            .toSortedMap()
            .map { (day, list) ->
                AirDay(
                    date = day,
                    episodes = list,
                    past = today != null && day < today,
                    today = day == today,
                    finale = day == last,
                )
            }
    }

    /** 某天所在的周相对今天所在的周差几周（周一起算）：0 本周、1 下周，已播的为负 */
    fun weekOffset(today: AirDate, day: AirDate): Int = Math.floorDiv(day.epochDay - today.epochDay + today.weekday, 7)

    /** 日程分组标题：本周 / 下周 / 之后（再往后按周分，周更剧就成了一行一个标题） */
    fun groupTitle(group: Int): String = when (group) {
        0 -> "本周"
        1 -> "下周"
        else -> "之后"
    }

    /** 一组播出日摊成日程的行：按需插「本周 / 下周 / 之后」标题和停更说明 */
    fun rows(list: List<AirDay>, schedule: SeasonAirScheduleView, grouped: Boolean): List<AirRow> {
        val today = AirDate.parse(schedule.today) ?: return list.map { AirRow.Day(it) }
        val rows = mutableListOf<AirRow>()
        var current: Int? = null
        list.forEachIndexed { index, day ->
            val group = minOf(weekOffset(today, day.date), 2)
            if (grouped && group != current) {
                current = group
                rows += AirRow.Group(group)
            }
            val previous = list.getOrNull(index - 1)
            if (previous != null) gap(previous.date, day.date, schedule.weekdays)?.let { rows += AirRow.Gap(previous.date, it) }
            rows += AirRow.Day(day)
        }
        return rows
    }

    fun rangeLabel(episodes: List<EpisodeView>): String {
        val numbers = episodes.map { it.episodeNumber }.sorted()
        val from = numbers.firstOrNull() ?: return ""
        val to = numbers.last()
        return if (from == to) "第 $from 集" else "第 $from–$to 集"
    }

    fun regionName(code: String): String = Locale("", code).getDisplayCountry(Locale.SIMPLIFIED_CHINESE).ifBlank { code }

    /** 「每天 / 每周四 / 周一至周四 / 周二、周五」更新 */
    fun cadence(weekdays: List<Long>): String? {
        val days = weekdays.distinct().sorted().map { it.toInt() }
        if (days.isEmpty()) return null
        val names = days.map { WEEKDAYS[it] }
        return when {
            days.size == 7 -> "每天更新"
            days.size == 1 -> "每${names[0]}更新"
            days.zipWithNext().all { (a, b) -> b == a + 1 } -> "${names.first()}至${names.last()}更新"
            else -> names.joinToString("、") + "更新"
        }
    }

    fun finale(schedule: SeasonAirScheduleView): String? {
        val last = AirDate.parse(schedule.lastAirDate) ?: return null
        return if (last == AirDate.parse(schedule.today)) "今天完结" else "${shortDate(last)} 完结"
    }

    /** 「明天 / 6 天后」 */
    fun relative(day: AirDate, schedule: SeasonAirScheduleView): String {
        val offset = day.epochDay - (AirDate.parse(schedule.today)?.epochDay ?: day.epochDay)
        return if (offset == 1) "明天" else "$offset 天后"
    }

    fun missingText(numbers: List<Long>): String? = when (numbers.size) {
        0 -> null
        1 -> "缺第 ${numbers[0]} 集"
        else -> "缺 ${numbers.size} 集"
    }

    /** 这一天的集里哪些是缺集 */
    fun missing(day: AirDay, schedule: SeasonAirScheduleView): List<Long> =
        day.episodes.map { it.episodeNumber }.filter { it in schedule.missingEpisodes }

    fun status(day: AirDay, schedule: SeasonAirScheduleView): AirDayStatus = when {
        day.past && day.episodes.all { it.owned } -> AirDayStatus.Owned
        day.past -> if (missing(day, schedule).isEmpty()) AirDayStatus.Absent else AirDayStatus.Missing
        day.today -> arrival(day.episodes, schedule)?.let { (text, color) -> AirDayStatus.Arrival(text, color) } ?: AirDayStatus.None
        else -> AirDayStatus.Relative(relative(day.date, schedule))
    }

    fun dot(day: AirDay, schedule: SeasonAirScheduleView): AirDot = when {
        day.today -> AirDot.Today
        day.finale -> AirDot.Finale
        day.past && missing(day, schedule).isNotEmpty() -> AirDot.Missing
        day.past && day.episodes.all { it.owned } -> AirDot.Owned
        else -> AirDot.Upcoming
    }

    /** 能不能「补缺集」：有订阅、有缺集、账号能订阅 */
    fun canFind(schedule: SeasonAirScheduleView, canSubscribe: Boolean): Boolean =
        canSubscribe && schedule.subscriptionId != null && schedule.missingEpisodes.isNotEmpty()

    /** 「补第 7 集 / 补 3 集」 */
    fun findTitle(schedule: SeasonAirScheduleView): String {
        val ids = schedule.missingEpisodes
        return if (ids.size == 1) "补第 ${ids[0]} 集" else "补 ${ids.size} 集"
    }

    /**
     * 两个播出日之间的停更说明。头部已经写了「周五至周六更新」，按节奏空着的日子不说，
     * 只标跳过了本该更新的日子的真停更
     */
    fun gap(previous: AirDate, next: AirDate, weekdays: List<Long>): String? {
        val skipped = next.epochDay - previous.epochDay - 1
        if (skipped <= 0) return null
        if ((1..skipped).none { previous.plusDays(it).weekday.toLong() in weekdays }) return null
        if (skipped >= 7) return "停更 $skipped 天"
        val first = weekday(previous.plusDays(1))
        return if (skipped == 1) "${first}不更新" else "${first}至${weekday(next.plusDays(-1))}不更新"
    }

    /** 一组同日播出的集在订阅里走到哪了（日程「今天」行右侧） */
    fun arrival(episodes: List<EpisodeView>, schedule: SeasonAirScheduleView): Pair<String, Color>? {
        expectedAt(episodes, schedule)?.let { return "预计 ${expectedTime(it)} 入库" to McColors.Info }
        val pending = episodes.filterNot { it.owned }.map { it.episodeNumber }.toSet()
        if (pending.isEmpty()) return "已入库，可以看了" to McColors.Success
        if (schedule.subscriptionId == null) return "未订阅" to McColors.TextMuted
        val arrivals = schedule.arrivals.filter { it.episodeNumber in pending }
        if (arrivals.any { it.stage == "organizing" }) return "整理中" to McColors.Info
        if (arrivals.any { it.stage == "downloading" }) return "下载中" to McColors.Info
        return if (arrivals.isEmpty()) null else "等待资源" to McColors.TextMuted
    }

    /** 还没入库、也不在下载 / 整理中的那几集最早的预计入库时刻 */
    fun expectedAt(episodes: List<EpisodeView>, schedule: SeasonAirScheduleView): String? {
        val pending = episodes.filterNot { it.owned }.map { it.episodeNumber }.toSet()
        if (pending.isEmpty() || schedule.subscriptionId == null) return null
        val arrivals = schedule.arrivals.filter { it.episodeNumber in pending }
        if (arrivals.any { it.stage == "organizing" || it.stage == "downloading" }) return null
        return arrivals.mapNotNull { it.expectedAt }.minOrNull()
    }

    /** 接口时间 → 本机时区的日历；不带时区的按 UTC（后端库内是 UTC） */
    private fun localCalendar(iso: String): Calendar? {
        val match = ISO_TIME.find(iso) ?: return null
        val (year, month, day, hour, minute, second, zone) = match.destructured
        val utc = GregorianCalendar(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(year.toInt(), month.toInt() - 1, day.toInt(), hour.toInt(), minute.toInt(), second.ifEmpty { "0" }.toInt())
        }
        val offsetMinutes = if (zone.isEmpty() || zone == "Z") {
            0
        } else {
            val digits = zone.drop(1).replace(":", "")
            val minutes = digits.take(2).toInt() * 60 + digits.drop(2).toInt()
            if (zone[0] == '-') -minutes else minutes
        }
        return Calendar.getInstance().apply { timeInMillis = utc.timeInMillis - offsetMinutes * 60_000L }
    }

    /** 这个时刻落在本机的今天 */
    fun isToday(iso: String, now: Calendar = Calendar.getInstance()): Boolean {
        val value = localCalendar(iso) ?: return false
        return value.get(Calendar.YEAR) == now.get(Calendar.YEAR) && value.get(Calendar.DAY_OF_YEAR) == now.get(Calendar.DAY_OF_YEAR)
    }

    /** 预计入库时刻：今天只给时分，跨天带上日期 */
    fun expectedTime(iso: String, now: Calendar = Calendar.getInstance()): String {
        val value = localCalendar(iso) ?: return ""
        val clock = "%02d:%02d".format(Locale.US, value.get(Calendar.HOUR_OF_DAY), value.get(Calendar.MINUTE))
        if (isToday(iso, now)) return clock
        return "${value.get(Calendar.MONTH) + 1}月${value.get(Calendar.DAY_OF_MONTH)}日 $clock"
    }
}

/**
 * 「订阅追更」：电视上没有手机那张能改选项的订阅弹层，只确认一下同一套默认值
 * （全部已播正季、在播剧自动续订、智能选择）就建好订阅，要改范围、品质到手机或网页。
 */
internal data class QuickSubscribe(
    val media: MediaBrief,
    val seasons: List<Long>,
    val followFuture: Boolean,
    /** 智能选择摘要；服务器早于 0.42.0 时为空，按规则模式订阅 */
    val smart: SmartPlanView?,
) {
    /** 「第 1 季、第 2 季」；超过三季写「已选 5 季」；一季都没选写「仅追新集」 */
    val scope: String
        get() = when {
            seasons.isEmpty() -> "仅追新集"
            seasons.size > 3 -> "已选 ${seasons.size} 季"
            else -> seasons.joinToString("、") { if (it == 0L) "特别篇" else "第 $it 季" }
        }

    val scopeNote: String get() = if (followFuture) "自动追踪新集和新季" else "仅收录所选季"

    /** 服务端解析好的整句：「优先 4K WEB-DL」「最多等 1 天 · 达标后停止洗版」「英语 · 只下带中文字幕的」 */
    val quality: List<String> get() = listOfNotNull(smart?.qualityLabel, smart?.waitLabel, smart?.subtitleLine)

    /** 只有管理员能指定入库的库（成员的订阅走服务端路由）：从这部剧所在的库订，新集就进这个库 */
    fun payload(libraryId: Long?): SubscriptionCreatePayload {
        val plan = smart
        return SubscriptionCreatePayload(
            titleRef = "tmdb:${media.kind}:${media.tmdbId}",
            selectedSeasons = seasons,
            followFuture = followFuture,
            libraryId = libraryId,
            selectionMode = if (plan == null) "rules" else "smart",
            smartProfileRevision = plan?.profileRevision,
            // 题目出现时回传默认答案：答过就不再问（成员不能写记忆，什么都不带）
            smartLanguageAnswer = if (plan?.canEdit == true && plan.question != null) "subtitles" else null,
            smartMemoryRevision = if (plan?.canEdit == true) plan.memoryRevision else null,
        )
    }

    companion object {
        fun of(prepared: PrepareView): QuickSubscribe? {
            val media = prepared.media ?: return null
            if (prepared.status != "ready") return null
            val seasons = prepared.suggestedSeasons.ifEmpty {
                prepared.seasons.filter { it.seasonNumber > 0 && it.airedCount > 0 }.map { it.seasonNumber }
            }
            // 一季都还没播的（首季定档）只能从新集追起，否则这里没地方改选项，一步都订不了
            return QuickSubscribe(media, seasons, media.status == "Returning Series" || seasons.isEmpty(), prepared.smart)
        }
    }
}

internal sealed interface AirSubscribeStage {
    data object Idle : AirSubscribeStage
    data object Preparing : AirSubscribeStage
    data class Confirming(val draft: QuickSubscribe) : AirSubscribeStage
    data class Submitting(val draft: QuickSubscribe) : AirSubscribeStage
}

internal data class AirMessage(val text: String, val isError: Boolean)

/** 播出日历面板上的两个动作：「补缺集」让缺口重新排队搜索、「订阅追更」确认默认值后建订阅。电视上没有全局提示，结果写在面板里 */
@Stable
internal class AirScheduleActions(private val api: McApi) {
    var stage by mutableStateOf<AirSubscribeStage>(AirSubscribeStage.Idle)
        private set
    var searching by mutableStateOf(false)
        private set
    var message by mutableStateOf<AirMessage?>(null)
        private set

    /** 补缺集：返回有没有发出去（发出去了页面要重读日历） */
    suspend fun findMissing(schedule: SeasonAirScheduleView): Boolean {
        val id = schedule.subscriptionId ?: return false
        if (searching) return false
        searching = true
        return try {
            val result = api.subscriptionsSearchMissingResources(id)
            message = AirMessage("${result.resetCount} 个缺口已重新排队，正在搜索", false)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            message = AirMessage(e.message ?: "操作失败，请稍后重试", true)
            false
        } finally {
            searching = false
        }
    }

    /** 按下「订阅追更」：先读预检，能订就进确认态，订不了把原因写出来 */
    suspend fun beginSubscribe(tmdbId: Long) {
        if (stage != AirSubscribeStage.Idle) return
        stage = AirSubscribeStage.Preparing
        message = null
        try {
            val prepared = api.uiSubscriptionsPreviewTitle(SubscriptionTargetPreviewPayload("tmdb:tv:$tmdbId"))
            stage = AirSubscribeStage.Idle
            val smart = prepared.smart
            val draft = QuickSubscribe.of(prepared)
            when {
                prepared.existingSubscriptionId != null -> message = AirMessage("该剧集已在订阅中，movieclaw 正在持续追踪资源。", false)
                smart != null && !smart.configured ->
                    message = AirMessage(if (smart.canEdit) "首次订阅要先在手机或网页上完成智能设置" else "请管理员先完成智能设置，或选择规则模式。", true)
                draft != null -> stage = AirSubscribeStage.Confirming(draft)
                else -> message = AirMessage("TMDB 未收录该条目，暂时无法订阅。", true)
            }
        } catch (e: CancellationException) {
            stage = AirSubscribeStage.Idle
            throw e
        } catch (e: Exception) {
            stage = AirSubscribeStage.Idle
            message = AirMessage(e.message ?: "预检失败，请稍后重试", true)
        }
    }

    fun cancelSubscribe() {
        if (stage is AirSubscribeStage.Confirming) stage = AirSubscribeStage.Idle
    }

    /** 确认订阅：返回成功与否（成功了页面要重读日历，入口随之消失） */
    suspend fun confirmSubscribe(libraryId: Long?): Boolean {
        val draft = (stage as? AirSubscribeStage.Confirming)?.draft ?: return false
        stage = AirSubscribeStage.Submitting(draft)
        message = null
        return try {
            api.subscriptionsCreate(draft.payload(libraryId))
            stage = AirSubscribeStage.Idle
            message = AirMessage("该剧集已在订阅中，movieclaw 正在持续追踪资源。", false)
            true
        } catch (e: CancellationException) {
            stage = AirSubscribeStage.Confirming(draft)
            throw e
        } catch (e: Exception) {
            stage = AirSubscribeStage.Confirming(draft)
            message = AirMessage(e.message ?: "订阅失败，请稍后重试", true)
            false
        }
    }
}
