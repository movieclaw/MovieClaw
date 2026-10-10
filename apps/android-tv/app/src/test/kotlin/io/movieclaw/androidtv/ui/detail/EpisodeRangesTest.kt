package io.movieclaw.androidtv.ui.detail

import io.movieclaw.androidtv.core.model.generated.EpisodeView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EpisodeRangesTest {
    private fun ep(n: Long, owned: Boolean = true, position: Long = 0, played: Boolean = false) =
        EpisodeView(episodeNumber = n, owned = owned, positionMs = position, played = played)

    private fun season(count: Int) = (1..count.toLong()).map { ep(it) }

    @Test
    fun noRangesAtOrBelowFifty() {
        assertTrue(EpisodeRanges.ranges(season(50)).isEmpty())
        assertTrue(EpisodeRanges.ranges(season(12)).isEmpty())
        assertEquals(2, EpisodeRanges.ranges(season(51)).size)
    }

    @Test
    fun rangesUseActualFirstAndLastNumbers() {
        val ranges = EpisodeRanges.ranges(season(1186))
        assertEquals(24, ranges.size)
        assertEquals("1–50", ranges.first().label)
        assertEquals("1001–1050", ranges[20].label)
        assertEquals("1151–1186", ranges.last().label)
        // 120 集：最后一段 101–120
        assertEquals(listOf("1–50", "51–100", "101–120"), EpisodeRanges.ranges(season(120)).map { it.label })
    }

    @Test
    fun rangesSkipEmptyChunksAndFollowEpisodeNumbers() {
        // 不按位置切：缺了 51～100 整段就不出这一段；段首段尾是段内实际有的集号
        val list = (3L..50L).map { ep(it) } + (101L..140L).map { ep(it) } + listOf(ep(205))
        val ranges = EpisodeRanges.ranges(list.shuffled())
        assertEquals(listOf("3–50", "101–140", "205–205"), ranges.map { it.label })
        assertEquals(listOf(0, 2, 4), ranges.map { it.index })
    }

    @Test
    fun positionAndEntry() {
        val ranges = EpisodeRanges.ranges(season(1186))
        assertEquals(20, EpisodeRanges.position(1050, ranges))
        assertEquals(21, EpisodeRanges.position(1051, ranges))
        assertEquals(0, EpisodeRanges.position(50, ranges))
        assertEquals(-1, EpisodeRanges.position(null, ranges))
        assertEquals(-1, EpisodeRanges.position(9999, ranges))
        // 段里有锚点进锚点，否则段首
        assertEquals(1050L, EpisodeRanges.entry(ranges[20], 1050))
        assertEquals(1101L, EpisodeRanges.entry(ranges[22], 1050))
        assertEquals(1L, EpisodeRanges.entry(ranges[0], null))
    }

    @Test
    fun anchorPrefersServerResumeEpisode() {
        // 柯南：第 3 集没看过、120 集看了一半，服务端锚点 1050 → 用 1050，不被客户端扫描覆盖
        val list = (1L..1186L).map {
            when (it) {
                3L -> ep(it)
                120L -> ep(it, position = 1000)
                1050L -> ep(it, position = 5000)
                in 1L..1049L -> ep(it, played = true)
                else -> ep(it)
            }
        }
        assertEquals(1050L, EpisodeRanges.anchor(list, 1050)?.episodeNumber)
        // 没给锚点（本季没播放过 / 旧服务端 / 分享页）或锚点不在清单里：退回客户端规则
        assertEquals(120L, EpisodeRanges.anchor(list, null)?.episodeNumber)
        assertEquals(120L, EpisodeRanges.anchor(list, 5000)?.episodeNumber)
        assertNull(EpisodeRanges.anchor(emptyList(), 3))
    }

    @Test
    fun resumeTagOnlyWhenSeasonWatched() {
        // 短季看过几集：标在锚点（服务端给的第 5 集）
        val watched = (1L..12L).map { if (it < 5) ep(it, played = true) else ep(it) }
        assertEquals(5L, EpisodeRanges.resumeTag(watched, 5))
        // 只有续播点也算看过
        assertEquals(2L, EpisodeRanges.resumeTag(listOf(ep(1), ep(2, position = 1000)), null))
        // 一集没碰过：不标（锚点照样是第 1 集，焦点落在它上面）
        val fresh = (1L..30L).map { ep(it) }
        assertNull(EpisodeRanges.resumeTag(fresh, null))
        assertEquals(1L, EpisodeRanges.anchor(fresh, null)?.episodeNumber)
    }
}
