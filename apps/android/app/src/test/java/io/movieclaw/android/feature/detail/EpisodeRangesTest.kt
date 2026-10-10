package io.movieclaw.android.feature.detail

import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.model.SeasonEpisodesView
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 长剧集分段的纯逻辑（docs/design/long-season-episode-ranges.md §1～§3） */
class EpisodeRangesTest {

    /** 夹具同款「名侦探柯南」：1186 集，97 的倍数与 301–304 缺；1–1049 看完（第 3 集没看、第 120 集弃在 30%），1050 看到 42% */
    private val conan = (1..1186).map { n ->
        val owned = !(n % 97 == 0 || n in 301..304)
        EpisodeView(
            episodeNumber = n,
            owned = owned,
            played = n < 1050 && owned && n != 3 && n != 120,
            progressPercent = when (n) { 120 -> 30; 1050 -> 42; else -> null },
            positionMs = if (n == 120 || n == 1050) 60_000 else 0,
        )
    }

    @Test fun `50 episodes or fewer are not segmented`() {
        assertTrue(EpisodeRanges.of((1..50).map { EpisodeView(it) }).isEmpty())
        assertFalse(EpisodeRanges.segmented((1..12).map { EpisodeView(it) }))
        assertEquals(2, EpisodeRanges.of((1..51).map { EpisodeView(it) }).size)
    }

    @Test fun `ranges are cut by episode number with actual bounds`() {
        val ranges = EpisodeRanges.of(conan)
        assertEquals(24, ranges.size)
        assertEquals("1–50", ranges.first().label)
        assertEquals("1151–1186", ranges.last().label)
        assertEquals("1001–1050", ranges[20].label)
        assertEquals(20, EpisodeRanges.indexOf(1050))
        assertEquals(21, EpisodeRanges.indexOf(1051))
        assertEquals(0, EpisodeRanges.indexOf(50))
        assertEquals(1, EpisodeRanges.indexOf(51))
    }

    @Test fun `empty ranges are skipped and labels use real first and last`() {
        val sparse = (1..40).map { EpisodeView(it) } + (103..149).map { EpisodeView(it) }
        val ranges = EpisodeRanges.of(sparse)
        assertEquals(listOf("1–40", "103–149"), ranges.map { it.label })
        assertEquals(listOf(0, 2), ranges.map { it.index })
    }

    @Test fun `server resume episode wins over client scan`() {
        // 原规则会落到第 3 集（第一个没看的）；服务端锚点是 1050
        assertEquals(3, conan.first { it.owned && !it.played }.episodeNumber)
        assertEquals(1050, EpisodeRanges.anchor(conan, 1050))
    }

    @Test fun `fallback rule is half watched then unwatched then owned then first`() {
        // resume_episode 为 null：第一个看了一半的（120）先于第一个没看的（3）
        assertEquals(120, EpisodeRanges.anchor(conan, null))
        // resume_episode 不在列表里（老数据）同样退回原规则
        assertEquals(120, EpisodeRanges.anchor(conan, 9999))
        val fresh = (1..30).map { EpisodeView(it, owned = it > 2) }
        assertEquals(3, EpisodeRanges.anchor(fresh, null))
        val allPlayed = (1..5).map { EpisodeView(it, owned = it > 1, played = true) }
        assertEquals(2, EpisodeRanges.anchor(allPlayed, null))
        val nothingOwned = (1..5).map { EpisodeView(it) }
        assertEquals(1, EpisodeRanges.anchor(nothingOwned, null))
        assertNull(EpisodeRanges.anchor(emptyList(), null))
    }

    @Test fun `manual range switch picks anchor inside else range first`() {
        val ranges = EpisodeRanges.of(conan)
        assertEquals(1050, EpisodeRanges.entryOf(ranges[20], 1050))
        assertEquals(1051, EpisodeRanges.entryOf(ranges[21], 1050))
        assertEquals(1, EpisodeRanges.entryOf(ranges[0], 1050))
        assertEquals(1001, EpisodeRanges.entryOf(ranges[20], null))
    }

    @Test fun `refresh locks to new anchor only when it changed`() {
        assertEquals(1051, EpisodeRanges.afterRefresh(1050, 1051))
        assertNull(EpisodeRanges.afterRefresh(1050, 1050))
        assertEquals(77, EpisodeRanges.afterRefresh(null, 77))
    }

    @Test fun `resume_episode decodes from snake case and defaults to null`() {
        val json = Json { ignoreUnknownKeys = true; namingStrategy = JsonNamingStrategy.SnakeCase }
        val withResume = json.decodeFromString<SeasonEpisodesView>(
            """{"season_number":1,"resume_episode":1050,"episodes":[{"episode_number":1050}]}""",
        )
        assertEquals(1050, withResume.resumeEpisode)
        val old = json.decodeFromString<SeasonEpisodesView>("""{"season_number":2,"episodes":[]}""")
        assertNull(old.resumeEpisode)
        val explicitNull = json.decodeFromString<SeasonEpisodesView>("""{"season_number":2,"resume_episode":null}""")
        assertNull(explicitNull.resumeEpisode)
    }
}
