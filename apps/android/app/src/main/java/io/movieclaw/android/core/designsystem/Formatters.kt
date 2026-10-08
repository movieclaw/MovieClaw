package io.movieclaw.android.core.designsystem

import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 展示格式化 —— 与 iOS Theme.swift 的 Formatters / LibraryShared.libraryBytes /
 * SettingsTime.deviceRelative 逐条对齐(包括 dayjs fromNow 的阈值阶梯)。
 */
object McFormat {

    private val dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    /** 二进制(1024)单位并按 iOS 口径显示为 KB/MB/GB/TB;≥100 或 B 取整,否则两位小数 */
    fun bytes(value: Long?): String {
        if (value == null) return "—"
        if (value <= 0) return "0 B"
        val units = listOf("B", "KB", "MB", "GB", "TB", "PB")
        var size = value.toDouble()
        var index = 0
        while (size >= 1024 && index < units.lastIndex) {
            size /= 1024
            index++
        }
        val text = if (index == 0 || size >= 100) "%.0f".format(size) else "%.2f".format(size)
        return "$text ${units[index]}"
    }

    /** "1:52:18" / "53:55";无效或负值 → "--:--" */
    fun clock(ms: Long?): String {
        if (ms == null || ms < 0) return "--:--"
        val totalSeconds = ms / 1000
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return if (hours > 0) {
            "%d:%02d:%02d".format(hours, minutes, seconds)
        } else {
            "%d:%02d".format(minutes, seconds)
        }
    }

    /** 按分钟:"1 小时 52 分" / "52 分钟" / "2 小时" */
    fun durationMinutes(minutes: Int?): String {
        if (minutes == null || minutes <= 0) return ""
        val h = minutes / 60
        val m = minutes % 60
        return when {
            h == 0 -> "$m 分钟"
            m == 0 -> "$h 小时"
            else -> "$h 小时 $m 分"
        }
    }

    fun durationFromMs(ms: Long?): String =
        if (ms == null || ms <= 0) "" else durationMinutes((ms / 60_000).toInt())

    /** "HH:mm"(历史行的时刻列;网页 TIME_DISPLAY_CONFIG.clockTimeFormat) */
    fun clockTime(iso: String?): String {
        val zoned = parse(iso) ?: return "—"
        return "%02d:%02d".format(zoned.hour, zoned.minute)
    }

    /** 历史分组键:"YYYY-MM-DD"(设备本地时区;网页 timelineDayKey) */
    fun dayKey(iso: String?): String {
        val zoned = parse(iso) ?: return ""
        return "%04d-%02d-%02d".format(zoned.year, zoned.monthValue, zoned.dayOfMonth)
    }

    /** 历史分组标题:今天早些时候 / 昨天 / M月D日 / YYYY年M月D日(网页 formatTimelineDayLabel) */
    fun dayLabel(iso: String?): String {
        val zoned = parse(iso) ?: return ""
        val day = zoned.toLocalDate()
        val today = LocalDate.now()
        return when {
            day == today -> "今天早些时候"
            day == today.minusDays(1) -> "昨天"
            day.year == today.year -> "%d月%d日".format(day.monthValue, day.dayOfMonth)
            else -> "%d年%d月%d日".format(day.year, day.monthValue, day.dayOfMonth)
        }
    }

    /** "2026-09-25 17:03"(设备本地时区) */
    fun dateTime(iso: String?): String {
        val zoned = parse(iso) ?: return ""
        return zoned.format(dateTimeFormatter)
    }

    /** dayjs fromNow(zh-cn)复刻:过去加「前」,未来加「内」 */
    fun relative(iso: String?): String {
        val zoned = parse(iso) ?: return ""
        val diffMs = ZonedDateTime.now().toInstant().toEpochMilli() - zoned.toInstant().toEpochMilli()
        val future = diffMs < 0
        val abs = abs(diffMs.toDouble())
        val seconds = (abs / 1000).roundToInt()
        val minutes = (abs / 60_000).roundToInt()
        val hours = (abs / 3_600_000).roundToInt()
        val days = (abs / 86_400_000).roundToInt()
        val months = monthDiff(zoned.toInstant(), Instant.now()).roundToInt()
        val suffix = if (future) "内" else "前"
        val text = when {
            seconds <= 44 -> "几秒"
            seconds <= 89 -> "1 分钟"
            minutes <= 44 -> "$minutes 分钟"
            minutes <= 89 -> "1 小时"
            hours <= 21 -> "$hours 小时"
            hours <= 35 -> "1 天"
            days <= 25 -> "$days 天"
            days <= 45 -> "1 个月"
            months <= 10 -> "$months 个月"
            months <= 17 -> "1 年"
            else -> "${(months / 12.0).roundToInt()} 年"
        }
        return text + suffix
    }

    /** 「刚刚 / N 分钟前 / N 小时前 / N 天前」；解析不出来返回 null（卡片文案用） */
    fun relativeFromNow(iso: String?): String? {
        val zoned = parse(iso) ?: return null
        val mins = (System.currentTimeMillis() - zoned.toInstant().toEpochMilli()) / 60_000
        return when {
            mins < 1 -> "刚刚"
            mins < 60 -> "$mins 分钟前"
            mins < 60 * 24 -> "${mins / 60} 小时前"
            else -> "${mins / (60 * 24)} 天前"
        }
    }

    /** 设备行专用(分钟粒度):刚刚活跃 / N 分钟前 / N 小时前 / N 天前 / 从未使用 */
    fun deviceRelative(iso: String?): String {
        val zoned = parse(iso) ?: return "从未使用"
        val diffMinutes = (System.currentTimeMillis() - zoned.toInstant().toEpochMilli()) / 60_000
        return when {
            diffMinutes < 1 -> "刚刚活跃"
            diffMinutes < 60 -> "$diffMinutes 分钟前"
            diffMinutes < 60 * 24 -> "${diffMinutes / 60} 小时前"
            else -> "${diffMinutes / (60 * 24)} 天前"
        }
    }

    /** 5 分钟内算「在线」 */
    fun isLive(iso: String?): Boolean {
        val zoned = parse(iso) ?: return false
        return System.currentTimeMillis() - zoned.toInstant().toEpochMilli() <= 5 * 60_000
    }

    /** "1.2 MB/s";0 或空 → "" */
    fun speed(bytesPerSecond: Double?): String {
        if (bytesPerSecond == null || bytesPerSecond <= 0) return ""
        val value = bytesPerSecond / 1024
        return if (value >= 1024) "%.1f MB/s".format(value / 1024) else "%.1f KB/s".format(value)
    }

    /** 速率简写(iOS 顶栏读数为下载速率) */
    fun rate(bytesPerSecond: Double?): String {
        val text = speed(bytesPerSecond)
        return if (text.isEmpty()) "" else "↓ $text".replace("↓ ↓ ", "↓ ")
    }

    private fun parse(iso: String?): ZonedDateTime? {
        if (iso.isNullOrEmpty()) return null
        return runCatching {
            val instant = runCatching { Instant.parse(iso) }
                .getOrElse {
                    // 无时区后缀的服务端串按 UTC 处理(iOS 同样先试 ISO8601 再补 Z)
                    Instant.parse(if (iso.endsWith("Z")) iso else iso + "Z")
                }
            instant.atZone(ZoneId.systemDefault())
        }.getOrNull()
    }

    /** dayjs monthDiff:整月数 + 下一个月已过比例 */
    private fun monthDiff(from: Instant, to: Instant): Double {
        val fromZ = from.atZone(ZoneId.systemDefault())
        val toZ = to.atZone(ZoneId.systemDefault())
        var whole = 0
        var anchor = fromZ
        while (anchor.plusMonths(1).toInstant() <= toZ.toInstant()) {
            anchor = anchor.plusMonths(1)
            whole++
        }
        val nextMonth = anchor.plusMonths(1)
        val spanMs = nextMonth.toInstant().toEpochMilli() - anchor.toInstant().toEpochMilli()
        val passedMs = toZ.toInstant().toEpochMilli() - anchor.toInstant().toEpochMilli()
        val fraction = if (spanMs > 0) passedMs.toDouble() / spanMs else 0.0
        return whole + fraction
    }

    /** 供进度条等使用:秒级本地时间戳(调试/日志) */
    fun localDateTime(instant: Instant): LocalDateTime = instant.atZone(ZoneId.systemDefault()).toLocalDateTime()
}
