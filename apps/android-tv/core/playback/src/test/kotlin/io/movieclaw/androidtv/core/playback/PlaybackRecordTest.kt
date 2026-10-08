package io.movieclaw.androidtv.core.playback

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** 播放记录的口径（playback-qoe.md §3，与 Apple 端 PlaybackRecordTests.swift 同一套规则） */
class PlaybackRecordTest {
    private var now = 20_000_000L
    private val unit = PlaybackUnit(7, 1, 2)

    @Before
    fun reset() = PlaybackRecord.resetLastExit()

    private fun record(lab: String = "") = PlaybackRecord(unit, "tap", now, { now }, lab)

    /** 每 250 毫秒采一次播放头，共 [ms] 毫秒；[moving] 时每次前进 250 */
    private fun PlaybackRecord.play(ms: Long, from: Long, moving: Boolean, eligible: Boolean = true): Long {
        var pos = from
        repeat((ms / 250).toInt()) {
            now += 250
            if (moving) pos += 250
            samplePlayhead(pos, eligible) { "network" }
        }
        return pos
    }

    private fun PlaybackRecord.detail(outcome: String = "exited"): JsonObject = payload(
        outcome, PlaybackNetwork.Home, "1.0", "wifi", JsonObject(emptyMap()), 0, null, null, null, null,
    ).detail!!

    @Test
    fun firstFrameIsReportedAsTimeSinceStartNotAsAClockReading() {
        // 时刻取自 elapsedRealtime（开机以来的毫秒数），上报的必须是差值：NAS 日志里曾出现 2000 万毫秒
        val r = record()
        assertNull(r.firstFrameMs)
        now += 1250
        r.noteFirstFrame()
        now += 8000
        r.noteFirstFrame() // 只认第一帧
        assertEquals(1_250L, r.firstFrameMs)
    }

    @Test
    fun consentWaitIsNotCountedAsStartup() {
        val r = record()
        now += 300
        r.beginUserWait()
        now += 5000
        r.endUserWait()
        now += 400
        r.noteFirstFrame()
        assertEquals(700L, r.firstFrameMs)
        assertEquals(5000L, r.payload("exited", PlaybackNetwork.Home, "1", "wifi", JsonObject(emptyMap()), 0, null, null, null, null).userWaitMs)
    }

    @Test
    fun playheadStoppedHalfASecondIsAStallWithItsCause() {
        val r = record()
        r.noteFirstFrame()
        var pos = r.play(3000, 0, moving = true)
        pos = r.play(2000, pos, moving = false)
        assertTrue(r.stalling)
        r.play(1000, pos, moving = true)
        assertFalse(r.stalling)
        assertEquals(1L, r.rebufferCount)
        // 0.5 秒没动才判卡顿、从最后一次走动算到下一次看见走动（采样间隔 250 毫秒）
        assertEquals(2250L, r.rebufferMs)
        val stall = r.detail()["interruptions"]!!.jsonArray.single().jsonObject
        assertEquals("rebuffer", stall["kind"]!!.jsonPrimitive.content)
        assertEquals("network", stall["cause"]!!.jsonPrimitive.content)
    }

    @Test
    fun shortPausesOfThePlayheadAndIneligibleTimeAreNotStalls() {
        val r = record()
        r.noteFirstFrame()
        var pos = r.play(3000, 0, moving = true)
        // 采样间隔里没动一次（0.25 秒）不算
        now += 250
        r.samplePlayhead(pos, true) { "network" }
        pos = r.play(1000, pos, moving = true)
        // 用户暂停 / 在跳转：不判
        pos = r.play(5000, pos, moving = false, eligible = false)
        r.play(1000, pos, moving = true)
        assertEquals(0L, r.rebufferCount)
    }

    @Test
    fun startupAndSeekLandingGetAOneAndAHalfSecondGrace() {
        val r = record()
        r.noteFirstFrame()
        // 首帧后 1.2 秒播放头才走：宽限内，不算卡顿
        var pos = r.play(1250, 0, moving = false)
        pos = r.play(2000, pos, moving = true)
        assertEquals(0L, r.rebufferCount)
        r.beginSeek("dpad", pos, pos + 10_000, buffered = true, paused = false, restart = false)
        now += 300
        r.seekPresented()
        // 落地后 3 秒都不走：宽限过了从落地那一刻起算
        pos = r.play(3000, pos + 10_000, moving = false)
        r.play(500, pos, moving = true)
        assertEquals(1L, r.rebufferCount)
        assertEquals(3000L, r.rebufferMs)
    }

    @Test
    fun seeksRecordLandingTimeAndSupersededOnes() {
        val r = record()
        r.noteFirstFrame()
        r.beginSeek("dpad", 600_000, 610_000, buffered = true, paused = false, restart = false)
        now += 120
        r.beginSeek("dpad", 610_000, 620_000, buffered = true, paused = false, restart = false)
        now += 200
        assertEquals(200L, r.seekPresented())
        r.beginSeek("scrub", 620_000, 1_800_000, buffered = false, paused = false, restart = true)
        now += 4000
        val seeks = r.detail()["seeks"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("superseded", "landed", "abandoned"), seeks.map { it["outcome"]!!.jsonPrimitive.content })
        assertEquals(listOf(120L, 200L, 4000L), seeks.map { it["ms"]!!.jsonPrimitive.long })
        assertEquals(true, seeks[2]["restart"]!!.jsonPrimitive.content.toBoolean())
        assertEquals(3L, r.seekCount)
    }

    @Test
    fun earlyTrackChangesAndResumeJumpsAreMisguesses() {
        val r = record()
        r.resumed = true
        r.noteFirstFrame()
        now += 10_000
        r.noteTrackChange("audio", "embedded:0", "embedded:1")
        r.beginSeek("scrub", 2_400_000, 60_000, buffered = false, paused = false, restart = false)
        now += 40_000
        r.noteTrackChange("subtitle", null, "embedded:2") // 30 秒之后：只作诊断
        val behaviors = r.detail()["behaviors"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("audio_change", "resume_seek", "subtitle_change"), behaviors.map { it["kind"]!!.jsonPrimitive.content })
        assertEquals(listOf(true, true, false), behaviors.map { it["misguess"]!!.jsonPrimitive.content.toBoolean() })
    }

    @Test
    fun quickExitAndReenterAreNoted() {
        val first = record()
        first.noteFirstFrame()
        now += 4000
        first.noteLeaving()
        now += 20_000
        val second = record()
        assertEquals(listOf("quick_exit"), first.detail()["behaviors"]!!.jsonArray.map { it.jsonObject["kind"]!!.jsonPrimitive.content })
        assertEquals(listOf("reenter"), second.detail()["behaviors"]!!.jsonArray.map { it.jsonObject["kind"]!!.jsonPrimitive.content })
    }

    @Test
    fun openStallsAndReconnectsAreCountedUpToLeaving() {
        val r = record()
        r.noteFirstFrame()
        val pos = r.play(2000, 0, moving = true)
        r.beginReconnect("播放失败：ERROR_CODE_IO_NETWORK_CONNECTION_FAILED")
        r.play(6000, pos, moving = false)
        val payload = r.payload("exited", PlaybackNetwork.Home, "1", "wifi", JsonObject(emptyMap()), pos, 3_600_000, null, null, null)
        val kinds = payload.detail!!["interruptions"]!!.jsonArray.map { it.jsonObject["kind"]!!.jsonPrimitive.content }
        assertEquals(listOf("rebuffer", "reconnect"), kinds)
        assertEquals(1L, payload.rebufferCount)
        assertEquals(6000L, payload.rebufferMs) // 从最后一次走动算到离开
    }

    @Test
    fun logTailIsWantedOnlyWhenSomethingWentWrong() {
        val clean = record()
        clean.noteFirstFrame()
        clean.play(5000, 0, moving = true)
        assertFalse(clean.wantsLogTail("exited"))
        assertTrue(clean.wantsLogTail("failed"))
        assertTrue(clean.wantsLogTail("abnormal_exit"))
        val rescued = record()
        rescued.noteEngineFailure("播放失败：ERROR_CODE_DECODING_FAILED", "Decode")
        assertTrue(rescued.wantsLogTail("exited"))
    }

    @Test
    fun payloadCarriesLabDeviceAndQoeShape() {
        val r = record(lab = "rig:cut-hls")
        r.device = JsonObject(mapOf("model" to JsonPrimitive("BRAVIA 4K VH2")))
        r.noteDelivery(JsonObject(mapOf("route" to JsonPrimitive("direct"), "tier" to JsonPrimitive(0))))
        r.noteFirstFrame()
        val payload = r.payload("watched", PlaybackNetwork.Away, "1.2", "wired", JsonObject(emptyMap()), 10, 20, 3, 100, "tail")
        assertEquals("rig:cut-hls", payload.labScenario)
        assertEquals("androidtv", payload.client)
        assertEquals("wired", payload.`interface`)
        assertEquals("tail", payload.logTail)
        val detail = payload.detail!!
        for (key in listOf("startup", "seeks", "switches", "interruptions", "delivery", "behaviors", "context", "device", "resources", "timeline", "end")) {
            assertTrue("缺 $key", key in detail)
        }
        assertEquals("BRAVIA 4K VH2", detail["device"]!!.jsonObject["model"]!!.jsonPrimitive.content)
        assertTrue((detail["timeline"] as JsonArray).isNotEmpty())
    }

    @Test
    fun timelineAndListsAreCapped() {
        val r = record()
        repeat(500) { r.event("x", "事件 $it") }
        repeat(80) { r.beginSeek("dpad", 0, 10_000, buffered = true, paused = false, restart = false) }
        val detail = r.detail()
        assertEquals(PlaybackRecord.MAX_TIMELINE, detail["timeline"]!!.jsonArray.size)
        assertEquals(PlaybackRecord.MAX_LIST, detail["seeks"]!!.jsonArray.size)
    }

    @Test
    fun abnormalExitSnapshotIsReportedNextTimeWithTheCrash() {
        val prefs = object : PrefsStore {
            val map = mutableMapOf<String, String>()
            override fun string(key: String) = map[key]
            override fun putString(key: String, value: String?) {
                if (value == null) map.remove(key) else map[key] = value
            }
        }
        val dir = Files.createTempDirectory("qoe").toFile()
        val store = PlaybackReportStore(prefs, dir)
        val r = record()
        r.noteFirstFrame()
        store.saveRunning(r.payload("abnormal_exit", PlaybackNetwork.Home, "1", "wifi", JsonObject(emptyMap()), 0, null, null, null, "引擎日志"))
        PlaybackReportStore.recordCrash(dir, IllegalStateException("surface lost"))

        val abnormal = store.takeAbnormal()!!
        assertEquals("abnormal_exit", abnormal.outcome)
        assertEquals(r.id, abnormal.attemptId)
        assertTrue(abnormal.logTail!!.contains("引擎日志") && abnormal.logTail!!.contains("surface lost"))
        assertNull(store.takeAbnormal()) // 只补报一次
        assertFalse(File(dir, PlaybackReportStore.CRASH_FILE).exists())

        store.enqueue(abnormal)
        assertEquals(1, store.queued().size)
        store.remove(abnormal.attemptId)
        assertTrue(store.queued().isEmpty())
    }

    @Test
    fun engineLogTailKeepsTheNewestLinesWithinThirtyTwoKilobytes() {
        EngineLog.clear()
        repeat(1000) { EngineLog.add("exo", "第 $it 行 " + "x".repeat(200)) }
        val tail = EngineLog.tail()
        assertTrue(tail.toByteArray().size <= 32 * 1024)
        assertTrue(tail.endsWith("x".repeat(200)) && tail.contains("第 999 行"))
        assertFalse(tail.contains("第 600 行"))
    }
}

class PlaybackRouteTest {
    @Test
    fun routesFollowTheWebQoeVocabulary() {
        assertEquals("direct", PlaybackRoute.of(original = true, tier = 0, degraded = false, userCapped = false))
        // 档 2 只转音轨、视频原样：不是转码，不算规格损失（曾被报成 server_transcode，统计里全成了「可避免的损失」）
        assertEquals("server_remux", PlaybackRoute.of(original = false, tier = 2, degraded = false, userCapped = false))
        assertEquals("server_transcode_required", PlaybackRoute.of(original = false, tier = 3, degraded = false, userCapped = false))
        assertEquals("server_transcode", PlaybackRoute.of(original = false, tier = 4, degraded = true, userCapped = false))
        assertEquals("server_transcode", PlaybackRoute.of(original = false, tier = 3, degraded = false, userCapped = true))
    }
}

class StreamBitrateTest {
    @Test
    fun audioOnlyEngineBitrateFallsBackToTheSourceBitrate() {
        // 服务端流里 Exo 只认得音轨码率（640 kbps）：不能拿它当整路流的码率
        assertEquals(9_104_000.0, QualitySuggestion.streamBitrate(-1, 640_000, 9_104_000)!!, 0.0)
        assertEquals(6_640_000.0, QualitySuggestion.streamBitrate(6_000_000, 640_000, 9_104_000)!!, 0.0)
        assertEquals(6_000_000.0, QualitySuggestion.streamBitrate(6_000_000, -1, null)!!, 0.0)
        assertNull(QualitySuggestion.streamBitrate(null, 640_000, null))
    }
}
