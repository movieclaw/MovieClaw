package io.movieclaw.androidtv.core.playback

import androidx.media3.common.PlaybackException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 兜底阶梯、看门狗、重试预算、换画质提议（同 Apple 端 PlaybackRoutingTests / PlaybackWatchdogsTests 的同一组用例） */
class PlaybackRoutingTest {
    private fun decide(cause: FailureCause, original: Boolean, restart: Boolean = false, retry: Boolean = false) =
        FailurePolicy.decide(FailurePolicy.Input(cause, original, restart, retry))

    @Test fun networkReconnectsThenFailsOrStepsDown() {
        assertEquals(FailurePolicy.Response.Reconnect, decide(FailureCause.Network, original = true, restart = true))
        assertEquals(FailurePolicy.Response.Reconnect, decide(FailureCause.Network, original = false, restart = true))
        // 预算用完：原文件连不上就是连不上；服务端流按「这一档放不了」降档
        assertEquals(FailurePolicy.Response.FailNetwork, decide(FailureCause.Network, original = true))
        assertEquals(FailurePolicy.Response.StepDownTier, decide(FailureCause.Network, original = false))
    }

    @Test fun sourceMissingAlwaysFails() {
        assertEquals(FailurePolicy.Response.FailSourceMissing, decide(FailureCause.SourceMissing, original = true, restart = true, retry = true))
        assertEquals(FailurePolicy.Response.FailSourceMissing, decide(FailureCause.SourceMissing, original = false))
    }

    @Test fun decodeOnOriginalRetriesOnceThenFallsBackToServer() {
        assertEquals(FailurePolicy.Response.RetryNative, decide(FailureCause.Decode, original = true, retry = true))
        assertEquals(FailurePolicy.Response.FallbackToServerStream, decide(FailureCause.Decode, original = true))
        assertEquals(FailurePolicy.Response.FallbackToServerStream, decide(FailureCause.DecodeFinal, original = true, retry = true))
        assertEquals(FailurePolicy.Response.StepDownTier, decide(FailureCause.Decode, original = false, retry = true))
        assertEquals(FailurePolicy.Response.StepDownTier, decide(FailureCause.DecodeFinal, original = false))
    }

    @Test fun exoErrorClassification() {
        val classify = FailurePolicy::classify
        assertEquals(FailureCause.Network, classify(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED, null, true))
        assertEquals(FailureCause.Network, classify(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT, null, false))
        // 取流令牌过期（401 / 403）：开新会话换张令牌
        assertEquals(FailureCause.Network, classify(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS, 403, true))
        // 原文件 404 是文件不在了；服务端流的分片 404 是会话被回收
        assertEquals(FailureCause.SourceMissing, classify(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS, 404, true))
        assertEquals(FailureCause.Network, classify(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS, 404, false))
        assertEquals(FailureCause.DecodeFinal, classify(PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED, null, true))
        assertEquals(FailureCause.DecodeFinal, classify(PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED, null, true))
        assertEquals(FailureCause.Decode, classify(PlaybackException.ERROR_CODE_DECODING_FAILED, null, true))
        assertEquals(FailureCause.Decode, classify(PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED, null, false))
        assertEquals(FailureCause.Decode, classify(PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED, null, true))
    }

    @Test fun sourceProbeVerdicts() {
        assertEquals(SourceProbe.Verdict.Reachable, SourceProbe.verdict(206))
        assertEquals(SourceProbe.Verdict.Reachable, SourceProbe.verdict(401))
        assertEquals(SourceProbe.Verdict.Reachable, SourceProbe.verdict(403))
        assertEquals(SourceProbe.Verdict.Missing, SourceProbe.verdict(404))
        assertEquals(SourceProbe.Verdict.Unreachable("HTTP 502"), SourceProbe.verdict(502))
    }

    @Test fun nativeRetryOncePerWindow() {
        val budget = NativeRetryBudget()
        assertTrue(budget.allowRetry(0))
        assertFalse(budget.allowRetry(179_999))
        assertTrue(budget.allowRetry(180_000))
        budget.reset()
        assertTrue(budget.allowRetry(180_001))
    }

    @Test fun networkRestartBudgetCapsConsecutiveRestarts() {
        val budget = NetworkRestartBudget()
        assertTrue(budget.allowRestart())
        assertTrue(budget.allowRestart())
        assertFalse(budget.allowRestart())
        assertFalse(budget.allowRestart())
        budget.reachedPlaying()
        assertTrue(budget.allowRestart())
        budget.reset()
        assertEquals(0, budget.consecutive)
    }

    @Test fun prematureEndResumesOnlyFarFromTheEnd() {
        assertTrue(PrematureEndGuard().shouldResume(731_000, 2_700_000))
        assertFalse(PrematureEndGuard().shouldResume(2_680_000, 2_700_000))
        assertFalse(PrematureEndGuard().shouldResume(731_000, null))
        val guard = PrematureEndGuard()
        assertTrue(guard.shouldResume(731_000, 2_700_000))
        // 重开后原地附近又报播完：片长写错了，这里就是真结尾
        assertFalse(guard.shouldResume(735_000, 2_700_000))
        assertTrue(guard.shouldResume(1_500_000, 2_700_000))
        guard.reset()
        assertTrue(guard.shouldResume(1_500_000, 2_700_000))
    }

    @Test fun reconnectBackoffSpansAboutAMinute() {
        val backoff = ReconnectBackoff()
        val delays = generateSequence { backoff.nextDelayMs() }.toList()
        assertEquals(listOf(2_000L, 4_000L, 8_000L, 15_000L, 15_000L, 15_000L), delays)
        backoff.reset()
        assertEquals(2_000L, backoff.nextDelayMs())
    }

    // ---- 看门狗 ----

    @Test fun frameDropNeedsFullWindowAndMinFrames() {
        val tracker = FrameDropTracker()
        for (second in 0 until 10) assertNull(tracker.sample(second * 5L, second * 24L))
        val ratio = tracker.sample(50, 240)
        assertNotNull(ratio)
        assertTrue(ratio!! >= FrameDropTracker.RATIO)
        val small = FrameDropTracker()
        for (second in 0..10) assertNull(small.sample(second.toLong(), second * 5L))
        // 计数变小 = 换了流：窗口作废
        assertNull(small.sample(0, 10))
    }

    @Test fun stallDecodeStalledAfterTwoNudges() {
        val watch = StallWatch()
        val verdicts = mutableListOf<StallWatch.Verdict>()
        for (second in 0 until 3) verdicts += watch.sample(second.toDouble(), 10.0, false, false, false, true, 45)
        repeat(20) { verdicts += watch.sample(2.0, 10.0, false, false, false, true, 45) }
        val index = verdicts.indexOf(StallWatch.Verdict.DecodeStalled)
        assertEquals(StallWatch.MAX_NUDGES, verdicts.take(index).count { it == StallWatch.Verdict.Nudge })
        assertEquals(3 + 3 + 8, index - 2)
        assertEquals("播放停滞超过 8 秒，这一档的码流播放器吃不下", StallWatch.reason(StallWatch.Verdict.DecodeStalled, 45))
    }

    @Test fun stallSlowLinkNeverFails() {
        val watch = StallWatch()
        repeat(600) {
            assertEquals(StallWatch.Verdict.Ok, watch.sample(0.0, 0.5, false, false, false, true, StallWatch.DIRECT_DEAD_SECONDS))
        }
    }

    @Test fun stallDeadAfterSilentSeconds() {
        for (limit in listOf(StallWatch.DIRECT_DEAD_SECONDS, StallWatch.SERVER_DEAD_SECONDS)) {
            val watch = StallWatch()
            val deadAt = (1..60).firstOrNull { watch.sample(0.0, 0.5, false, false, false, false, limit) == StallWatch.Verdict.Dead }
            assertEquals(limit, deadAt)
        }
        assertEquals("连续 15 秒没有收到数据——连接可能中断了", StallWatch.reason(StallWatch.Verdict.Dead, 15))
        assertEquals("连续 45 秒没有收到服务端的数据——转码可能中断了", StallWatch.reason(StallWatch.Verdict.Dead, 45))
    }

    @Test fun stallIgnoresPausedAndSeeking() {
        val watch = StallWatch()
        repeat(60) {
            assertEquals(StallWatch.Verdict.Ok, watch.sample(5.0, 0.0, true, false, false, false, 15))
            assertEquals(StallWatch.Verdict.Ok, watch.sample(5.0, 0.0, false, false, true, false, 15))
        }
    }

    @Test fun scrubFollowPlans() {
        assertEquals(ScrubFollow.Plan.Skip, ScrubFollow.plan(1000, 0, cheap = true, reachable = false, settleOnly = false))
        assertEquals(ScrubFollow.Plan.Skip, ScrubFollow.plan(1000, 0, cheap = false, reachable = true, settleOnly = false))
        assertEquals(ScrubFollow.Plan.Deferred(60), ScrubFollow.plan(1000, 0, cheap = false, reachable = true, settleOnly = true))
        assertEquals(ScrubFollow.Plan.Follow, ScrubFollow.plan(1000, 0, cheap = true, reachable = true, settleOnly = false))
        assertEquals(ScrubFollow.Plan.Deferred(30), ScrubFollow.plan(1070, 1000, cheap = true, reachable = true, settleOnly = false))
    }

    // ---- 换画质提议 ----

    @Test fun recommendedRung() {
        assertEquals(720, QualitySuggestion.recommendedHeight(4_000_000.0, 2160))
        assertEquals(1080, QualitySuggestion.recommendedHeight(8_000_000.0, 2160))
        // 都装不下：给最低档；已在最低档：没得换
        assertEquals(480, QualitySuggestion.recommendedHeight(500_000.0, 1080))
        assertNull(QualitySuggestion.recommendedHeight(500_000.0, 480))
        assertEquals(480, QualitySuggestion.recommendedHeight(1_300_000.0, 720))
    }

    @Test fun longWaitOffersOnceUsingFastestSpeed() {
        val suggestion = QualitySuggestion()
        // 起播宽限 10 秒内等待也计入「一次等太久」
        repeat(7) { suggestion.tick(stalled = true, seeking = false, loadingBps = 2_000_000.0) }
        assertNull(suggestion.offer(20_000_000.0, 2160))
        suggestion.tick(stalled = true, seeking = false, loadingBps = 3_000_000.0)
        val offer = suggestion.offer(20_000_000.0, 2160)
        assertEquals(QualitySuggestion.Offer(3_000_000.0, 20_000_000.0, 480), offer)
        // 每个单元最多一次
        suggestion.tick(stalled = true, seeking = false, loadingBps = 3_000_000.0)
        assertNull(suggestion.offer(20_000_000.0, 2160))
    }

    @Test fun fastLinkNeverOffers() {
        val suggestion = QualitySuggestion()
        repeat(20) { suggestion.tick(stalled = true, seeking = false, loadingBps = 30_000_000.0) }
        assertNull(suggestion.offer(20_000_000.0, 2160))
    }

    @Test fun repeatedStallsAfterGraceUseMedian() {
        val suggestion = QualitySuggestion()
        repeat(11) { suggestion.tick(stalled = false, seeking = false, loadingBps = null) }
        repeat(2) { suggestion.tick(stalled = true, seeking = false, loadingBps = 4_000_000.0) }
        suggestion.tick(stalled = false, seeking = false, loadingBps = null)
        assertNull(suggestion.offer(10_000_000.0, 2160))
        repeat(2) { suggestion.tick(stalled = true, seeking = false, loadingBps = 4_000_000.0) }
        assertEquals(720, suggestion.offer(10_000_000.0, 2160)?.maxHeight)
    }

    // ---- 网络环境 ----

    @Test fun networkClassification() {
        val nas = PlaybackNetwork.parseIPv4("192.168.1.10")!!
        val home = PlaybackNetwork.Interface(PlaybackNetwork.parseIPv4("192.168.1.23")!!, 0xFFFFFF00L)
        val vpn = PlaybackNetwork.Interface(PlaybackNetwork.parseIPv4("10.8.0.2")!!, 0xFFFFFF00L)
        assertEquals(PlaybackNetwork.Home, PlaybackNetwork.classify(nas, listOf(vpn, home)))
        assertEquals(PlaybackNetwork.Away, PlaybackNetwork.classify(nas, listOf(vpn)))
        assertEquals(PlaybackNetwork.Unknown, PlaybackNetwork.classify(PlaybackNetwork.parseIPv4("8.8.8.8"), listOf(home)))
        assertEquals(PlaybackNetwork.Unknown, PlaybackNetwork.classify(null, listOf(home)))
        assertTrue(PlaybackNetwork.isPrivate(PlaybackNetwork.parseIPv4("172.20.0.1")!!))
        assertFalse(PlaybackNetwork.isPrivate(PlaybackNetwork.parseIPv4("172.32.0.1")!!))
        assertNull(PlaybackNetwork.parseIPv4("nas.local"))
        assertNull(PlaybackNetwork.parseIPv4("1.2.3.256"))
    }

    @Test fun qualityMemoryPerTitleAndNetwork() {
        val store = object : PrefsStore {
            val map = HashMap<String, String>()
            override fun string(key: String) = map[key]
            override fun putString(key: String, value: String?) {
                if (value == null) map.remove(key) else map[key] = value
            }
        }
        var now = 0L
        val memory = QualityMemory(store) { now++ }
        memory.remember(720, 1, PlaybackNetwork.Away)
        assertEquals(720, memory.quality(1, PlaybackNetwork.Away))
        assertNull(memory.quality(1, PlaybackNetwork.Home))
        memory.remember(null, 1, PlaybackNetwork.Away)
        assertNull(memory.quality(1, PlaybackNetwork.Away))
        // 超出上限丢最久没用的
        for (id in 1..QualityMemory.LIMIT + 1L) memory.remember(480, id, PlaybackNetwork.Home)
        assertNull(memory.quality(1, PlaybackNetwork.Home))
        assertEquals(480, memory.quality(QualityMemory.LIMIT + 1L, PlaybackNetwork.Home))
    }
}
