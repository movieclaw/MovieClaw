package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.generated.TrickplayView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 时间 / 速度文案、按住拖动的速度曲线、缩略图格子、VTT 解析 */
class PlayerFormatTest {
    @Test fun clock() {
        assertEquals("0:00", PlayerFormat.clock(0.0))
        assertEquals("0:59", PlayerFormat.clock(59.99))
        assertEquals("53:55", PlayerFormat.clock(3235.0))
        assertEquals("1:00:00", PlayerFormat.clock(3600.0))
        assertEquals("1:52:18", PlayerFormat.clock(6738.7))
        assertEquals("--:--", PlayerFormat.clock(null))
        assertEquals("--:--", PlayerFormat.clock(-1.0))
        assertEquals("--:--", PlayerFormat.clock(Double.NaN))
        assertEquals("1:05", PlayerFormat.clockMs(65_999))
    }

    @Test fun speed() {
        assertEquals("3.2 MB/s", PlayerFormat.bandwidth(3.2 * 8 * 1024 * 1024))
        assertEquals("1.0 MB/s", PlayerFormat.bandwidth(8.0 * 1024 * 1024))
        assertEquals("512 KB/s", PlayerFormat.bandwidth(512.0 * 8 * 1024))
        assertEquals("0 KB/s", PlayerFormat.bandwidth(4000.0))
        assertNull(PlayerFormat.bandwidth(0.0))
        assertNull(PlayerFormat.bandwidth(null))
        // 加载速度：没在下载明确写 0，没有读数不显示
        assertEquals("0 KB/s", PlayerFormat.loadingSpeed(0.0))
        assertNull(PlayerFormat.loadingSpeed(null))
        assertEquals("S01E02", PlayerFormat.episodeCode(1, 2))
    }

    @Test fun sweepIsAFifthOfDurationClampedToOneToFifteenMinutes() {
        assertEquals(60_000L, ScrubMath.sweepMs(120_000))
        assertEquals(540_000L, ScrubMath.sweepMs(2_700_000))
        assertEquals(900_000L, ScrubMath.sweepMs(9_000_000))
    }

    @Test fun holdingAcceleratesThenKeepsSpeed() {
        val sweep = 540_000L
        assertEquals(0L, ScrubMath.holdOffset(0, sweep))
        // 前 2 秒平方曲线：半程只走四分之一；2 秒走满一划
        assertEquals(sweep / 4, ScrubMath.holdOffset(1000, sweep))
        assertEquals(sweep, ScrubMath.holdOffset(2000, sweep))
        // 之后按 2 秒末的速度（每秒一划）匀速
        assertEquals(2 * sweep, ScrubMath.holdOffset(3000, sweep))
        assertTrue(ScrubMath.holdOffset(200, sweep) < ScrubMath.holdOffset(400, sweep) / 2)
    }

    @Test fun scrubTargetClampedToTimeline() {
        val duration = 2_700_000L
        assertEquals(600_000L + 540_000L, ScrubMath.target(600_000, 1, 2000, duration))
        assertEquals(0L, ScrubMath.target(100_000, -1, 2000, duration))
        assertEquals(duration, ScrubMath.target(2_600_000, 1, 5000, duration))
    }

    private val index = TrickplayView(
        ready = true, intervalMs = 10_000, tileWidth = 320, tileHeight = 180, columns = 10, rows = 10, count = 250,
        sheets = listOf("/s0", "/s1", "/s2"),
    )

    @Test fun trickplayTiles() {
        assertEquals(TrickplayTile(0, "/s0", 0, 0, 320, 180), TrickplayMath.tile(index, 0))
        assertEquals(TrickplayTile(0, "/s0", 320 * 3, 180 * 1, 320, 180), TrickplayMath.tile(index, 135_000))
        // 第 100 格进第二张图的左上角
        assertEquals(TrickplayTile(1, "/s1", 0, 0, 320, 180), TrickplayMath.tile(index, 1_000_000))
        // 越界夹到最后一格（第 249 格：第三张图第 49 格）
        assertEquals(TrickplayTile(2, "/s2", 320 * 9, 180 * 4, 320, 180), TrickplayMath.tile(index, 99_000_000))
        assertEquals(TrickplayTile(0, "/s0", 0, 0, 320, 180), TrickplayMath.tile(index, -5))
        assertNull(TrickplayMath.tile(index.copy(ready = false), 0))
        assertNull(TrickplayMath.tile(index.copy(sheets = emptyList()), 0))
        assertNull(TrickplayMath.tile(null, 0))
        // 图张数比格子少：夹到最后一张
        assertEquals(1, TrickplayMath.tile(index.copy(sheets = listOf("/s0", "/s1")), 99_000_000)?.sheetIndex)
    }

    @Test fun vttParsing() {
        val raw = "WEBVTT\r\n\r\n1\r\n00:00:01.000 --> 00:00:03.500 align:start\r\n<i>你好</i> &amp; 再见\r\n\r\n" +
            "00:02.000 --> 00:04,000\n第二条\n第二行\n\nNOTE 注释\n\n00:00:10.000 --> 00:00:11.000\n   \n"
        val cues = WebVtt.parse(raw)
        assertEquals(2, cues.size)
        assertEquals(SubtitleCue(1.0, 3.5, "你好 & 再见"), cues[0])
        assertEquals(SubtitleCue(2.0, 4.0, "第二条\n第二行"), cues[1])
        assertEquals(listOf("你好 & 再见", "第二条\n第二行"), WebVtt.active(cues, 2.5).map { it.text })
        assertEquals(listOf("第二条\n第二行"), WebVtt.active(cues, 3.6).map { it.text })
        assertTrue(WebVtt.active(cues, 0.5).isEmpty())
        assertEquals(3723.5, WebVtt.timestamp("01:02:03.500")!!, 1e-9)
        assertNull(WebVtt.timestamp("abc"))
    }

    @Test fun tokenFromSignedPath() {
        assertEquals("abc", PlaybackController.tokenIn("/api/v1/playback/files/3/stream?token=abc"))
        assertEquals("t1", PlaybackController.tokenIn("/x.m3u8?a=1&token=t1&b=2"))
        assertNull(PlaybackController.tokenIn("/x.m3u8"))
        assertNull(PlaybackController.tokenIn(null))
    }
}

class BufferBudgetTest {
    private val mb = 1L shl 20

    @org.junit.Test
    fun bufferFollowsTheHeap() {
        // 大堆（largeHeap 512 MB）用满 Exo 的默认上限；192 MB 的电视 48 MB；小堆的老盒子保底 16 MB
        org.junit.Assert.assertEquals(128 * mb, BufferBudget.targetBytes(512 * mb).toLong())
        org.junit.Assert.assertEquals(48 * mb, BufferBudget.targetBytes(192 * mb).toLong())
        org.junit.Assert.assertEquals(16 * mb, BufferBudget.targetBytes(48 * mb).toLong())
    }
}
