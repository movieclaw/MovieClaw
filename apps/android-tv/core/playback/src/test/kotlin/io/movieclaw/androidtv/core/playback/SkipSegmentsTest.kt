package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.generated.EpisodeView
import io.movieclaw.androidtv.core.model.generated.PlaybackSegmentView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 跳过片头 / 片尾与下一集卡片（同 Apple 端 SkipSegmentsTests、Web test/player-skip-segments.test.mjs 的同一组用例） */
class SkipSegmentsTest {
    private fun segment(type: String, start: Long, end: Long, toEnd: Boolean = false) = PlaybackSegmentView(type, start, end, toEnd)

    private val ad = segment("ad", 0, 20_000)
    private val intro = segment("intro", 60_000, 150_000)
    private val credits = segment("outro", 2_550_000, 2_700_000, toEnd = true)
    private val midOutro = segment("outro", 2_400_000, 2_500_000)

    @Test fun introRangeGivesSkipIntroAndNothingOutside() {
        assertNull(SkipSegments.active(listOf(intro), 59_999))
        assertEquals(intro, SkipSegments.active(listOf(intro), 60_000))
        assertEquals("跳过片头", SkipSegments.label(SkipSegments.active(listOf(intro), 100_000)!!))
        assertNull(SkipSegments.active(listOf(intro), 150_000))
    }

    @Test fun buttonHidesInLastThreeSeconds() {
        assertEquals(intro, SkipSegments.active(listOf(intro), 150_000 - SkipSegments.TAIL_MS - 1))
        assertNull(SkipSegments.active(listOf(intro), 150_000 - SkipSegments.TAIL_MS))
    }

    @Test fun labelsFollowRecognizedType() {
        assertEquals("跳过广告", SkipSegments.label(SkipSegments.active(listOf(ad, intro), 5_000)!!))
        assertEquals("跳过预告", SkipSegments.label(segment("preview", 0, 20_000)))
        assertEquals("跳过此段", SkipSegments.label(segment("other", 0, 20_000)))
        assertEquals("跳过此段", SkipSegments.label(segment("future-type", 0, 20_000)))
        assertEquals("跳过片尾", SkipSegments.label(SkipSegments.active(listOf(midOutro), 2_450_000)!!))
    }

    @Test fun autoNextOnlyCountsDownInDetectedCreditsAndStopsAfterStreak() {
        assertEquals(8000L, SkipSegments.AUTO_NEXT_MS)
        assertFalse(SkipSegments.autoNextArmed(listOf(credits), 2_549_999, 0))
        assertTrue(SkipSegments.autoNextArmed(listOf(credits), 2_560_000, 0))
        assertTrue(SkipSegments.autoNextArmed(listOf(credits), 2_560_000, SkipSegments.AUTO_NEXT_MAX_STREAK - 1))
        assertFalse(SkipSegments.autoNextArmed(listOf(credits), 2_560_000, SkipSegments.AUTO_NEXT_MAX_STREAK))
        assertFalse(SkipSegments.autoNextArmed(listOf(midOutro), 2_450_000, 0))
        assertFalse(SkipSegments.autoNextArmed(null, 2_690_000, 0))
    }

    @Test fun creditsToEndGoToUpNextCardNotSkipButton() {
        assertNull(SkipSegments.active(listOf(credits), 2_600_000))
        assertFalse(SkipSegments.isInOutro(listOf(credits), 2_549_999))
        assertTrue(SkipSegments.isInOutro(listOf(credits), 2_550_000))
        assertFalse(SkipSegments.isInOutro(listOf(midOutro), 2_450_000))
    }

    @Test fun adsAndPreviewsNeverAutoAdvance() {
        for (type in listOf("ad", "preview", "other")) {
            val value = segment(type, 2_550_000, 2_700_000, toEnd = true)
            assertEquals(value, SkipSegments.active(listOf(value), 2_600_000))
            assertFalse(SkipSegments.autoNextArmed(listOf(value), 2_600_000, 0))
        }
    }

    @Test fun separatedAdAndIntroPreserveStoryInBetween() {
        assertEquals(20_000L, SkipSegments.active(listOf(ad, intro), 5_000)?.endMs)
        assertNull(SkipSegments.active(listOf(ad, intro), 30_000))
        assertEquals(150_000L, SkipSegments.active(listOf(ad, intro), 70_000)?.endMs)
    }

    @Test fun manualSkipTakesPriorityOverLastFortySecondsCard() {
        for (type in listOf("preview", "ad", "outro", "other")) {
            val value = segment(type, 2_660_000, 2_690_000)
            assertFalse(SkipSegments.shouldShowUpNext(listOf(value), 2_670_000, 2_700_000))
            assertTrue(SkipSegments.shouldShowUpNext(listOf(value), 2_690_000, 2_700_000))
            assertTrue(SkipSegments.shouldShowUpNext(listOf(value), 2_700_000, 2_700_000, ended = true))
        }
        assertTrue(SkipSegments.shouldShowUpNext(emptyList(), 2_670_000, 2_700_000))
        assertTrue(SkipSegments.shouldShowUpNext(listOf(credits), 2_600_000, 2_700_000))
    }

    @Test fun lastFortySecondsWindowBounds() {
        assertFalse(SkipSegments.shouldShowUpNext(null, 2_659_999, 2_700_000))
        assertTrue(SkipSegments.shouldShowUpNext(null, 2_660_000, 2_700_000))
        // 剩 0 不算（播完由 ended 管）；片长未知不给
        assertFalse(SkipSegments.shouldShowUpNext(null, 2_700_000, 2_700_000))
        assertFalse(SkipSegments.shouldShowUpNext(null, 2_690_000, null))
    }

    @Test fun missingSegmentsGiveNothing() {
        assertNull(SkipSegments.active(null, 1_000))
        assertNull(SkipSegments.active(emptyList(), 1_000))
        assertFalse(SkipSegments.isInOutro(null, 1_000))
    }

    // ---- 播放器状态上的派生量 ----

    private fun episode(n: Long, owned: Boolean = true, name: String? = null) = EpisodeView(episodeNumber = n, owned = owned, name = name)

    private fun state(
        position: Long, segments: List<PlaybackSegmentView>?, phase: Phase = Phase.Playing,
        episodes: List<EpisodeView> = listOf(episode(1), episode(2)), dismissed: Boolean = false, streak: Int = 0,
    ) = PlayerState(
        unit = PlaybackUnit(7, 1, 1), phase = phase, positionMs = position, durationMs = 2_700_000, segments = segments,
        episodes = episodes, nextDismissed = dismissed, autoNextStreak = streak,
    )

    @Test fun upNextCardNeedsNextEpisodeAndNotDismissed() {
        assertTrue(state(2_600_000, listOf(credits)).showsUpNext)
        assertFalse(state(2_600_000, listOf(credits), episodes = listOf(episode(1))).showsUpNext)
        assertFalse(state(2_600_000, listOf(credits), dismissed = true).showsUpNext)
        // 已播完：没有片尾标记也给
        assertTrue(state(2_700_000, null, phase = Phase.Ended).showsUpNext)
    }

    @Test fun skipButtonYieldsToUpNextAndHidesWhenEndedOrError() {
        assertEquals(intro, state(100_000, listOf(intro)).skipSegment)
        assertNull(state(100_000, listOf(intro), phase = Phase.Ended).skipSegment)
        assertNull(state(100_000, listOf(intro), phase = Phase.Error).skipSegment)
        assertNull(state(100_000, listOf(intro), phase = Phase.Consent).skipSegment)
        // 片尾里（toEnd）只有卡片
        val s = state(2_600_000, listOf(credits))
        assertNull(s.skipSegment)
        assertTrue(s.showsUpNext)
    }

    @Test fun countdownArmedOnlyInDetectedCreditsWithCardShowing() {
        assertTrue(state(2_600_000, listOf(credits)).autoNextArmed)
        // 只靠最后 40 秒兜底出来的卡片不倒计时
        val tail = state(2_680_000, null)
        assertTrue(tail.showsUpNext)
        assertFalse(tail.autoNextArmed)
        assertFalse(state(2_600_000, listOf(credits), streak = 3).autoNextArmed)
        assertFalse(state(2_600_000, listOf(credits), dismissed = true).autoNextArmed)
    }

    // ---- 下一集 ----

    @Test fun nextEpisodeIsLowestOwnedAfterCurrentInSameSeason() {
        val unit = PlaybackUnit(7, 1, 2)
        val episodes = listOf(episode(5), episode(1), episode(3, owned = false), episode(4), episode(2))
        assertEquals(4L, EpisodeNavigation.next(episodes, unit)?.episodeNumber)
        assertEquals(1L, EpisodeNavigation.previous(episodes, unit)?.episodeNumber)
        assertNull(EpisodeNavigation.next(listOf(episode(1), episode(2)), unit))
        // 电影没有下一集
        assertNull(EpisodeNavigation.next(episodes, PlaybackUnit(7, 0, 0)))
    }

    @Test fun episodeLabelFormat() {
        assertEquals("S01E02 · 归来", EpisodeNavigation.label(PlaybackUnit(7, 1, 2), episode(2, name = "归来")))
        assertEquals("S01E02", EpisodeNavigation.label(PlaybackUnit(7, 1, 2), null))
        assertEquals("S10E120", EpisodeNavigation.label(PlaybackUnit(7, 10, 120), episode(120, name = "")))
        assertNull(EpisodeNavigation.label(PlaybackUnit(7, 0, 0), null))
        val s = PlayerState(unit = PlaybackUnit(7, 1, 2), episodes = listOf(episode(2, name = "归来")))
        assertEquals("正在播放 · S01E02 · 归来", s.titleLine)
        assertEquals("正在播放", PlayerState(unit = PlaybackUnit(7, 0, 0)).titleLine)
    }

    @Test fun pausedDimOnlyForUserPause() {
        val base = PlayerState(unit = PlaybackUnit(7, 0, 0), phase = Phase.Playing, positionMs = 5_000, paused = true)
        assertTrue(base.copy(wantsPlay = false).showPaused)
        // 程序性暂停（换流、换轨）不压暗
        assertFalse(base.showPaused)
        assertFalse(base.copy(wantsPlay = false, phase = Phase.Buffering).showPaused)
        assertFalse(base.copy(wantsPlay = false, positionMs = 0).showPaused)
        assertFalse(base.copy(wantsPlay = false, phase = Phase.Error).showPaused)
    }
}
