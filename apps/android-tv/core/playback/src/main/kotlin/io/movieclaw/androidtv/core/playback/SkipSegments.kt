package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.generated.EpisodeView
import io.movieclaw.androidtv.core.model.generated.PlaybackSegmentView

/**
 * 跳过片头 / 片尾（docs/design/skip-intro.md，对照 Apple 端 SkipSegments.swift）：服务端整季比对认出来的区间
 * 随播放会话下发，客户端只管按播放位置用，不做任何计算。
 *
 * - `intro` 片头：位置在区间里显示「跳过片头」，点了跳到区间结束处；
 * - `outro` 片尾：`toEnd` 为真（一直放到文件结尾）时到起点就提前给「即将播放」卡片；为假时后面还有内容，按钮是「跳过片尾」；
 * - `ad` / `preview`：「跳过广告」「跳过预告」，仅手动跳过；`other` 等未知类型：「跳过此段」，不猜内容。
 */
object SkipSegments {
    /** 离区间尾不足这么多毫秒就不再给「跳过」：按下去只省一两秒，还会撞上区间尾的画面切换 */
    const val TAIL_MS = 3000L

    /** 自动播下一集的倒计时 8 秒（5 秒来不及反应） */
    const val AUTO_NEXT_MS = 8000L

    /** 连续自动播了这么多集、期间没人碰过播放器，就不再自动播（人多半睡着了，也别让 NAS 白转一晚上） */
    const val AUTO_NEXT_MAX_STREAK = 3

    /** 最后这么多毫秒兜底给「下一集」卡片（只提示，不倒计时） */
    const val UP_NEXT_TAIL_MS = 40_000L

    /** 当前位置该给哪个「跳过」按钮；一直放到结尾的片尾交给「即将播放」卡片，两者不同时出现 */
    fun active(segments: List<PlaybackSegmentView>?, positionMs: Long): PlaybackSegmentView? =
        segments?.firstOrNull { segment ->
            if (segment.type == "outro" && segment.toEnd) return@firstOrNull false
            positionMs >= segment.startMs && positionMs < segment.endMs - TAIL_MS
        }

    /** 已经进了一直放到结尾的片尾：「即将播放」卡片不必等到最后 40 秒 */
    fun isInOutro(segments: List<PlaybackSegmentView>?, positionMs: Long): Boolean =
        segments?.any { it.type == "outro" && it.toEnd && positionMs >= it.startMs } ?: false

    /**
     * 卡片要不要倒计时自动播下一集：只在服务端**认出了**一直放到结尾的片尾时才倒计时——
     * 按「最后 40 秒」猜片尾的话字幕还没放完画面就被抢走。[streak] 是连续自动播了几集
     */
    fun autoNextArmed(segments: List<PlaybackSegmentView>?, positionMs: Long, streak: Int): Boolean =
        streak < AUTO_NEXT_MAX_STREAK && isInOutro(segments, positionMs)

    fun label(segment: PlaybackSegmentView): String = when (segment.type) {
        "intro" -> "跳过片头"
        "outro" -> "跳过片尾"
        "ad" -> "跳过广告"
        "preview" -> "跳过预告"
        else -> "跳过此段"
    }

    /** 手动跳过段优先于最后 40 秒的兜底卡片，不能让「下一集」盖住「跳过预告」。有没有下一集、关没关卡片由调用方判断 */
    fun shouldShowUpNext(segments: List<PlaybackSegmentView>?, positionMs: Long, durationMs: Long?, ended: Boolean = false): Boolean {
        if (ended) return true
        if (active(segments, positionMs) != null) return false
        if (isInOutro(segments, positionMs)) return true
        if (durationMs == null || durationMs <= 0) return false
        val remaining = durationMs - positionMs
        return remaining in 1..UP_NEXT_TAIL_MS
    }
}

/** 一个播放单元：电影季集都是 0 */
data class PlaybackUnit(val mediaItemId: Long, val season: Long, val episode: Long) {
    val isEpisode: Boolean get() = season > 0 || episode > 0
}

/** 换集：只在本季、有在位文件的集里找，缺集跳过；不跨季（同 Apple 端 nextEpisode） */
object EpisodeNavigation {
    fun next(episodes: List<EpisodeView>, unit: PlaybackUnit): EpisodeView? {
        if (!unit.isEpisode) return null
        return episodes.filter { it.episodeNumber > unit.episode && it.owned }.minByOrNull { it.episodeNumber }
    }

    fun previous(episodes: List<EpisodeView>, unit: PlaybackUnit): EpisodeView? {
        if (!unit.isEpisode) return null
        return episodes.filter { it.episodeNumber < unit.episode && it.owned }.maxByOrNull { it.episodeNumber }
    }

    /** 「S01E02 · 集名」；没有集名只给「S01E02」；电影 null */
    fun label(unit: PlaybackUnit, episode: EpisodeView?): String? {
        if (!unit.isEpisode) return null
        val code = PlayerFormat.episodeCode(unit.season, episode?.episodeNumber ?: unit.episode)
        val name = episode?.name
        return if (!name.isNullOrEmpty()) "$code · $name" else code
    }
}
