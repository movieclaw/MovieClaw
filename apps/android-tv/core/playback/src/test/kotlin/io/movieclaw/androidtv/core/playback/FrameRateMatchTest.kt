package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.playback.FrameRateMatch.Mode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FrameRateMatchTest {
    // 典型 4K 电视：60 / 59.94 / 50 / 30 / 25 / 24 / 23.976，外加 1080p 的几档
    private val modes = listOf(
        Mode(1, 3840, 2160, 60f), Mode(2, 3840, 2160, 59.94f), Mode(3, 3840, 2160, 50f), Mode(4, 3840, 2160, 30f),
        Mode(5, 3840, 2160, 25f), Mode(6, 3840, 2160, 24f), Mode(7, 3840, 2160, 23.976f), Mode(8, 1920, 1080, 24f),
    )
    private val home = modes[0]

    @Test
    fun filmGoesToItsOwnRefreshRateAtTheSameResolution() {
        assertEquals(7, FrameRateMatch.pick(modes, home, 23.976f)?.id)
        assertEquals(6, FrameRateMatch.pick(modes, home, 24f)?.id)
        // 25 帧（片库六成）：25Hz 是一倍，优于 50Hz
        assertEquals(5, FrameRateMatch.pick(modes, home, 25f)?.id)
        assertEquals(2, FrameRateMatch.pick(modes, home, 29.97f)?.id)
    }

    @Test
    fun withoutAnExactModeTheClosestMultipleIsAccepted() {
        val no23976 = modes.filter { it.id != 7 }
        assertEquals(6, FrameRateMatch.pick(no23976, home, 23.976f)?.id) // 24Hz：每 42 秒重复一帧，好过 60Hz 的 3:2 抖动
        val onlyHigh = listOf(Mode(1, 3840, 2160, 60f), Mode(3, 3840, 2160, 50f))
        assertEquals(3, FrameRateMatch.pick(onlyHigh, home, 25f)?.id)
    }

    @Test
    fun staysPutWhenAlreadyRightOrNothingFits() {
        assertNull(FrameRateMatch.pick(modes, home, 60f))
        assertNull(FrameRateMatch.pick(modes, modes[2], 50f))
        assertNull(FrameRateMatch.pick(listOf(home), home, 24f)) // 只有 60Hz（模拟器）：没得切
        assertNull(FrameRateMatch.pick(modes, home, null))
        // 不为帧率改分辨率：4K 屏不会因为 1080p 有 24Hz 就切过去
        assertNull(FrameRateMatch.pick(listOf(home, modes[7]), home, 24f))
    }
}
