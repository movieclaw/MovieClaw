package io.movieclaw.android.core.designsystem

import androidx.compose.ui.graphics.Color
import io.movieclaw.android.core.model.SubscriptionView

/**
 * 订阅状态的**唯一说法与配色**（iOS `SubscriptionStatusMeta` 的对应物）：
 * 发现页详情、订阅列表、订阅详情页说的必须是同一套词，否则同一个订阅在三处三个叫法。
 */
fun SubscriptionView.statusLabel(): String = when (status) {
    "completed" -> if (media.kind == "tv") "已收齐" else "已入库"
    "paused" -> "已暂停"
    else -> "追踪中"
}

fun SubscriptionView.statusColor(): Color = when (status) {
    "completed" -> Ok
    "paused" -> Warning
    // iOS：追踪中用 #6AA7FF（不是纯强调色，蓝色更"进行中"）
    else -> Color(0xFF6AA7FF)
}

/**
 * 进度一句话：回答「还缺多少 / 入库了多少」（iOS `SubscriptionStatusMeta.progressNote` 的对应物）。
 * 订阅弹层的管理态与订阅列表都用它，避免同一件事两处两种说法。
 */
fun progressNote(sub: SubscriptionView): String {
    val p = sub.progress
    if (sub.status == "paused") return "暂停追踪"
    val inPipeline = p.grabbed + p.downloaded
    val isMovie = sub.media.kind == "movie"
    if (p.wanted == 0) {
        if (isMovie) {
            return when {
                p.imported > 0 -> "已入库"
                inPipeline > 0 -> "下载安排中"
                else -> "已收齐"
            }
        }
        if (inPipeline > 0) return "$inPipeline 集下载中 · 已入库 ${p.imported}"
        if (sub.status == "active") return "等待新集播出"
        return if (p.imported > 0) "全部 ${p.total} 集已入库" else "全部 ${p.total} 集已安排"
    }
    if (isMovie) return "正在寻找资源"
    return "还缺 ${p.wanted} 集 · 已入库 ${p.imported}"
}
