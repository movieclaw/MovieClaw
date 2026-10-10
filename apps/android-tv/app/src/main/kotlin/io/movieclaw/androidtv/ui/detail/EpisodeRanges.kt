package io.movieclaw.androidtv.ui.detail

import io.movieclaw.androidtv.core.model.generated.EpisodeView

/** 长剧集分段选集的一段（docs/design/long-season-episode-ranges.md）：按集号每 50 集一段，段名用段内实际首末集号 */
data class EpisodeRange(val index: Int, val first: Long, val last: Long) {
    val label: String get() = "$first–$last"

    fun contains(episodeNumber: Long): Boolean = EpisodeRanges.indexOf(episodeNumber) == index
}

object EpisodeRanges {
    const val SIZE = 50

    fun indexOf(episodeNumber: Long): Int = (maxOf(0L, episodeNumber - 1) / SIZE).toInt()

    /** 一季的段：超过 50 集才分段，否则为空（界面保持改版前的样子）；空段不出现 */
    fun ranges(episodes: List<EpisodeView>): List<EpisodeRange> {
        if (episodes.size <= SIZE) return emptyList()
        val result = mutableListOf<EpisodeRange>()
        for (number in episodes.map { it.episodeNumber }.sorted()) {
            val index = indexOf(number)
            val last = result.lastOrNull()
            if (last != null && last.index == index) result[result.lastIndex] = last.copy(last = number)
            else result += EpisodeRange(index, number, number)
        }
        return result
    }

    /** 某集所在的段（在 [ranges] 里的位置）；不分段或找不到时为 -1 */
    fun position(episodeNumber: Long?, ranges: List<EpisodeRange>): Int {
        if (episodeNumber == null) return -1
        return ranges.indexOfFirst { it.contains(episodeNumber) }
    }

    /** 进某一段时落在哪一集：段里有锚点就是锚点，否则段首 */
    fun entry(range: EpisodeRange, anchor: Long?): Long =
        if (anchor != null && range.contains(anchor)) anchor else range.first

    /**
     * 本季接着看的那一集：服务端给的 resume_episode 在清单里就用它（同首页「接下来继续」）；
     * 本季没播放过、旧服务端没给或分享页时退回客户端规则（[DetailLogic.resumeEpisode]）
     */
    fun anchor(episodes: List<EpisodeView>, resumeEpisode: Long?): EpisodeView? =
        resumeEpisode?.let { number -> episodes.firstOrNull { it.episodeNumber == number } }
            ?: DetailLogic.resumeEpisode(episodes)

    /** 「接着看」标在哪一集：本季有观看记录（任一集看完或有续播点）时是锚点，一集没碰过的季不标（焦点仍落在锚点） */
    fun resumeTag(episodes: List<EpisodeView>, resumeEpisode: Long?): Long? =
        if (episodes.any { it.played || it.positionMs > 0 }) anchor(episodes, resumeEpisode)?.episodeNumber else null
}
