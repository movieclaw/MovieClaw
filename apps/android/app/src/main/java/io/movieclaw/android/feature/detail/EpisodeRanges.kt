package io.movieclaw.android.feature.detail

import io.movieclaw.android.core.model.EpisodeView

/**
 * 长剧集分段（docs/design/long-season-episode-ranges.md §1～§3）的纯逻辑，界面只管画。
 *
 * 本季超过 50 集才分段；段按集号切（第 floor((集号-1)/50) 段），空段不出现，
 * 段名用段内实际首末集号。一切以「接着看的那一集」（锚点）为准。
 */
object EpisodeRanges {
    const val SIZE = 50

    /** 一段：段号 + 段内实际首末集号 + 段内的集 */
    data class Range(val index: Int, val episodes: List<EpisodeView>) {
        val first: Int get() = episodes.first().episodeNumber
        val last: Int get() = episodes.last().episodeNumber
        val label: String get() = "$first–$last"
        operator fun contains(episode: Int): Boolean = indexOf(episode) == index
    }

    fun segmented(episodes: List<EpisodeView>): Boolean = episodes.size > SIZE

    /** 集号所在的段号（floorDiv：特别篇第 0 集落在 -1 段，不和第 1 集混在一起） */
    fun indexOf(episode: Int): Int = Math.floorDiv(episode - 1, SIZE)

    /** 本季的段（不分段时返回空表）；按段号升序，段内按集号升序 */
    fun of(episodes: List<EpisodeView>): List<Range> {
        if (!segmented(episodes)) return emptyList()
        return episodes.sortedBy { it.episodeNumber }
            .groupBy { indexOf(it.episodeNumber) }
            .toSortedMap()
            .map { (index, list) -> Range(index, list) }
    }

    /**
     * 锚点：服务端 `resume_episode` 在本季列表里就用它；否则退回客户端原规则——
     * 第一个看了一半的 → 第一个没看过的 → 第一集（都是有片源的优先）。
     * 不要拿客户端扫描结果覆盖服务端锚点：长剧里「第一个没看过的」可能是几百集前跳过的那一集。
     */
    fun anchor(episodes: List<EpisodeView>, resumeEpisode: Int?): Int? {
        if (resumeEpisode != null && episodes.any { it.episodeNumber == resumeEpisode }) return resumeEpisode
        val halfWatched = { e: EpisodeView -> !e.played && (e.positionMs > 0 || (e.progressPercent ?: 0) > 0) }
        return (
            episodes.firstOrNull { it.owned && halfWatched(it) }
                ?: episodes.firstOrNull { it.owned && !it.played }
                ?: episodes.firstOrNull { it.owned }
                ?: episodes.firstOrNull()
            )?.episodeNumber
    }

    /** 手动换段落在哪一集：段里有锚点选锚点，否则段首 */
    fun entryOf(range: Range, anchor: Int?): Int =
        anchor?.takeIf { a -> range.episodes.any { it.episodeNumber == a } } ?: range.first

    /**
     * 刷新（播放回来）后选中哪一集：锚点变了 → 新锚点（段跟着锁到它）；
     * 没变 → 保留原选中（用户可能正在别的段浏览）。返回 null = 不动。
     */
    fun afterRefresh(oldAnchor: Int?, newAnchor: Int?): Int? =
        newAnchor.takeIf { it != oldAnchor }
}
