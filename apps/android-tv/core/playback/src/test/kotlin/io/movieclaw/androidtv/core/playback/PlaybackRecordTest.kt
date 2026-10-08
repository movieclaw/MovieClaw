package io.movieclaw.androidtv.core.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackRecordTest {
    @Test
    fun firstFrameIsReportedAsTimeSinceStartNotAsAClockReading() {
        // 时刻取自 elapsedRealtime（开机以来的毫秒数），上报的必须是差值：NAS 日志里曾出现 2000 万毫秒
        val record = PlaybackRecord(PlaybackUnit(7, 0, 0), origin = "detail", startedAt = 20_000_000)
        assertNull(record.firstFrameMs)
        record.noteFirstFrame(20_001_250)
        record.noteFirstFrame(20_009_000) // 只认第一帧
        assertEquals(1_250L, record.firstFrameMs)
    }
}
