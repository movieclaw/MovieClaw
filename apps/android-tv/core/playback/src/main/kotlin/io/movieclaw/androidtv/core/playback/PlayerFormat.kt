package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.generated.TrickplayView
import java.util.Locale
import kotlin.math.floor
import kotlin.math.roundToLong

/** 播放器里的文案格式（对照 Apple 端 Theme.swift Formatters 与 PlaybackController 的速度格式） */
object PlayerFormat {
    /** 秒 → 「1:52:18」/「53:55」；向下取整，无效值「--:--」 */
    fun clock(seconds: Double?): String {
        if (seconds == null || !seconds.isFinite() || seconds < 0) return "--:--"
        val total = floor(seconds).toLong()
        val h = total / 3600
        val m = total % 3600 / 60
        val s = total % 60
        return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s) else String.format(Locale.ROOT, "%d:%02d", m, s)
    }

    fun clockMs(ms: Long): String = clock(ms / 1000.0)

    fun episodeCode(season: Long, episode: Long): String = String.format(Locale.ROOT, "S%02dE%02d", season, episode)

    /** bps →「3.2 MB/s」（用户对下载速度的直觉来自下载器，一律 MB/s，进位 1024）；没有读数 / 0 返回 null */
    fun bandwidth(bps: Double?): String? {
        if (bps == null || !bps.isFinite() || bps <= 0) return null
        val bytes = bps / 8
        val mb = bytes / (1024 * 1024)
        if (mb >= 1) return String.format(Locale.ROOT, "%.1f MB/s", mb)
        val kb = bytes / 1024
        return if (kb < 1) "0 KB/s" else "${kb.roundToLong()} KB/s"
    }

    /** 加载速度：没在加载时明确写「0 KB/s」（一眼看出现在没在下），还没有读数时 null 不显示 */
    fun loadingSpeed(bps: Double?): String? {
        if (bps == null || !bps.isFinite() || bps < 0) return null
        return bandwidth(bps) ?: "0 KB/s"
    }
}

/**
 * 按住左右键拖进度（Apple TV 是触控板横滑：满屏宽一划 = 片长的 1/5，夹在 1～15 分钟之间）。
 * 安卓遥控器没有触控板，换成「按住」：按住 [FULL_SWEEP_HOLD_MS] 走满一划，前段由慢到快（平方曲线，
 * 刚按住时挪得少、好微调），之后保持那一刻的速度匀速走。
 */
object ScrubMath {
    const val MIN_SWEEP_MS = 60_000L
    const val MAX_SWEEP_MS = 900_000L
    const val FULL_SWEEP_HOLD_MS = 2000L

    fun sweepMs(durationMs: Long): Long = (durationMs / 5).coerceIn(MIN_SWEEP_MS, MAX_SWEEP_MS)

    /** 按住 [heldMs] 毫秒挪动的距离（毫秒） */
    fun holdOffset(heldMs: Long, sweepMs: Long): Long {
        val x = heldMs.coerceAtLeast(0) / FULL_SWEEP_HOLD_MS.toDouble()
        val fraction = if (x <= 1) x * x else 1 + 2 * (x - 1)
        return (fraction * sweepMs).toLong()
    }

    /** 落点：基准 ± 按住挪的距离，夹在时间轴内（[startMs] 起，长 [durationMs]） */
    fun target(baseMs: Long, direction: Int, heldMs: Long, durationMs: Long, startMs: Long = 0): Long {
        val moved = baseMs + direction * holdOffset(heldMs, sweepMs(durationMs))
        return moved.coerceIn(startMs, startMs + durationMs)
    }
}

/** 雪碧图里的一格：第几张图、裁剪矩形（像素） */
data class TrickplayTile(val sheetIndex: Int, val sheet: String, val x: Int, val y: Int, val width: Int, val height: Int)

/** 进度条缩略图的格子定位（同 Web `lib/player/trickplay.ts` 的 tileAt） */
object TrickplayMath {
    fun tile(index: TrickplayView?, ms: Long): TrickplayTile? {
        if (index == null || !index.ready || index.count <= 0 || index.intervalMs <= 0 || index.columns <= 0 ||
            index.rows <= 0 || index.sheets.isEmpty()
        ) {
            return null
        }
        val perSheet = index.columns * index.rows
        // 越界夹到最后一格：拖到片尾时给最后一帧，比忽然没有预览好
        val ordinal = minOf(ms.coerceAtLeast(0) / index.intervalMs, index.count - 1)
        val sheetIndex = minOf(ordinal / perSheet, (index.sheets.size - 1).toLong())
        val within = ordinal - sheetIndex * perSheet
        return TrickplayTile(
            sheetIndex = sheetIndex.toInt(),
            sheet = index.sheets[sheetIndex.toInt()],
            x = ((within % index.columns) * index.tileWidth).toInt(),
            y = ((within / index.columns) * index.tileHeight).toInt(),
            width = index.tileWidth.toInt(),
            height = index.tileHeight.toInt(),
        )
    }
}
