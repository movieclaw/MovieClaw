package io.movieclaw.android.core.offline

import android.content.Context
import io.movieclaw.android.core.designsystem.McFormat

/** 离线下载界面共用的说法（与 iOS 同一套文案） */
object OfflineFormat {
    fun bytes(value: Long): String = McFormat.bytes(value)

    /** 「iPhone」在安卓上的说法：手机 / 平板 */
    fun deviceName(context: Context): String =
        if (context.resources.configuration.smallestScreenWidthDp >= 600) "平板" else "手机"

    fun seasonEpisode(season: Int, episode: Int) = "第 $season 季第 $episode 集"
}

/** 单元状态的一句话（存储页「下载中」、详情页下载状态条共用；iOS `OfflineUnitStatus`） */
object OfflineUnitStatus {
    /**
     * [ahead]：下载队列里排在它前面的个数（「下一个下载」「等待下载，前面还有 N 个」）；
     * [waitingForWiFi]：只许 Wi-Fi 下、眼下是计费网络，排队和下着的都在等 Wi-Fi
     */
    fun text(unit: OfflineUnit, ahead: Int = 0, waitingForWiFi: Boolean = false): String = when {
        waitingForWiFi && unit.runnable -> "等待 Wi-Fi"
        unit.state == OfflineUnit.State.queued && ahead == 1 -> "下一个下载"
        unit.state == OfflineUnit.State.queued && ahead > 1 -> "等待下载，前面还有 $ahead 个"
        else -> text(unit)
    }

    private fun text(unit: OfflineUnit): String = when (unit.state) {
        OfflineUnit.State.preparing -> "正在准备…"
        OfflineUnit.State.queued -> "等待下载"
        OfflineUnit.State.downloading ->
            if (unit.expectedBytes > 0) "下载中 ${(unit.progressFraction * 100).toInt()}%" else "下载中 ${OfflineFormat.bytes(unit.receivedBytes)}"
        OfflineUnit.State.paused -> "已暂停"
        OfflineUnit.State.failed -> when {
            unit.waitingForTranscode -> unit.transcodeWait ?: "等待转码"
            unit.retryable -> "下载中断，稍后自动重试"
            else -> unit.error ?: "下载失败"
        }
        OfflineUnit.State.done -> if (unit.damaged) "文件损坏，请重新下载" else "已下载"
    }

    /** 一行状态（卡片窄，比通用文案短；iOS `OfflineDownloadStrip.status`）。参数同 [text] */
    fun short(unit: OfflineUnit, ahead: Int = 0, waitingForWiFi: Boolean = false): String {
        val percent = if (unit.expectedBytes > 0) " ${(unit.progressFraction * 100).toInt()}%" else ""
        if (unit.damaged) return "文件损坏，请重新下载"
        if (waitingForWiFi && unit.runnable) return "等待 Wi-Fi"
        return when (unit.state) {
            OfflineUnit.State.preparing -> "准备下载"
            OfflineUnit.State.queued -> when {
                ahead == 1 -> "下一个下载"
                ahead > 1 -> "前面还有 $ahead 个"
                else -> "等待下载"
            }
            OfflineUnit.State.downloading -> "下载中$percent"
            OfflineUnit.State.paused -> "已暂停$percent"
            OfflineUnit.State.failed -> when {
                unit.waitingForTranscode -> unit.transcodeWait ?: "等待转码"
                unit.retryable -> "下载中断，稍后重试"
                else -> "下载失败"
            }
            OfflineUnit.State.done -> "已下载"
        }
    }
}

/** 进行中的下载汇总成一句话（首页提示条、下载通知；iOS `OfflineDownloadSummary`） */
data class OfflineDownloadSummary(
    val title: String,
    val detail: String,
    /** 已下字节 ÷ 预计总字节（大小都还不知道时为 null） */
    val fraction: Double?,
    /** 只剩中断的：警告色 */
    val warning: Boolean,
    val allPaused: Boolean,
) {
    companion object {
        /** [waitingForWiFi]：只许 Wi-Fi 下、眼下是计费网络，明说在等 Wi-Fi */
        fun make(units: List<OfflineUnit>, speeds: Map<Long, Double>, titles: Map<Long, String> = emptyMap(), waitingForWiFi: Boolean = false): OfflineDownloadSummary {
            val downloading = units.filter { it.state == OfflineUnit.State.downloading }
            val failed = units.filter { it.needsAttention }
            val waitingTranscode = units.filter { it.waitingForTranscode }
            val speed = downloading.sumOf { speeds[it.fileId] ?: 0.0 }
            val sized = units.filter { it.expectedBytes > 0 }
            val expected = sized.sumOf { it.expectedBytes }
            val received = sized.sumOf { minOf(it.receivedBytes, it.expectedBytes) }
            val fraction = if (expected > 0) received.toDouble() / expected else null
            val allPaused = units.isNotEmpty() && units.all { it.state == OfflineUnit.State.paused }
            val parts = mutableListOf<String>()
            when {
                waitingForWiFi && !allPaused && units.any { it.runnable } -> parts += "等待 Wi-Fi"
                speed > 0 -> parts += "${OfflineFormat.bytes(speed.toLong())}/s"
                failed.isNotEmpty() && downloading.isEmpty() -> parts += "${failed.size} 个下载中断"
                waitingTranscode.isNotEmpty() && downloading.isEmpty() -> parts += "等待转码"
                !allPaused && downloading.isEmpty() -> parts += "等待下载"
            }
            if (fraction != null) parts += "${(fraction * 100).toInt()}%"
            return OfflineDownloadSummary(
                title = title(units, titles, allPaused),
                detail = if (parts.isEmpty()) "点按查看" else parts.joinToString(" · "),
                fraction = fraction,
                warning = failed.isNotEmpty() && downloading.isEmpty(),
                allPaused = allPaused,
            )
        }

        /**
         * 标题写清在下什么：「正在下载《沙丘》」「正在下载《兰香如故》5 集」「3 部电影正在下载」
         * 「2 部剧共 5 集正在下载」「3 部电影、5 集剧集正在下载」；全暂停时「正在下载」换成「已暂停」
         */
        fun title(units: List<OfflineUnit>, titles: Map<Long, String>, paused: Boolean): String {
            val movies = units.filter { it.isMovie }.map { it.mediaItemId }.toSet()
            val episodes = units.filter { !it.isMovie }
            val shows = episodes.map { it.mediaItemId }.toSet()
            if (movies.size == 1 && shows.isEmpty()) {
                titles[movies.first()]?.let { return if (paused) "已暂停下载《$it》" else "正在下载《$it》" }
            }
            if (movies.isEmpty() && shows.size == 1) {
                titles[shows.first()]?.let { return if (paused) "已暂停下载《$it》${episodes.size} 集" else "正在下载《$it》${episodes.size} 集" }
            }
            val subject = when {
                shows.isEmpty() -> "${movies.size} 部电影"
                movies.isEmpty() && shows.size == 1 -> "${episodes.size} 集剧集"
                movies.isEmpty() -> "${shows.size} 部剧共 ${episodes.size} 集"
                else -> "${movies.size} 部电影、${episodes.size} 集剧集"
            }
            return if (paused) "${subject}已暂停下载" else "${subject}正在下载"
        }
    }
}
