package io.movieclaw.android.core.offline

import java.io.File
import java.nio.file.Files
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 离线下载的纯逻辑（与 iOS `OfflineDownloadTests.swift` 逐条对应） */
class ReachabilityJudgeTest {
    private val t0 = 1_000_000L

    @Test
    fun slowNetworkWithOccasionalSuccessNeverTrips() {
        // 网慢：失败之间总有成功，每次成功都重新建一个判定器
        repeat(20) { round ->
            val judge = ReachabilityJudge()
            val time = t0 + round * 20_000L
            assertFalse(judge.failure(false, time))
            assertFalse(judge.failure(false, time + 9_000))
        }
    }

    @Test
    fun timeoutsNeedThreeFailuresAndThirtySeconds() {
        val judge = ReachabilityJudge()
        assertFalse(judge.failure(false, t0))
        assertFalse(judge.failure(false, t0 + 8_000))
        assertFalse("三次了但还不到 30 秒", judge.failure(false, t0 + 19_000))
        assertFalse(judge.failure(false, t0 + 29_000))
        assertTrue(judge.failure(false, t0 + 31_000))
    }

    @Test
    fun spanCountsFromWhenTheFirstFailedRequestWasSent() {
        val judge = ReachabilityJudge()
        assertFalse(judge.failure(false, t0 + 8_000, startedAt = t0 + 3_000))
        assertFalse(judge.failure(false, t0 + 15_000, startedAt = t0 + 10_000))
        assertTrue("服务器已经 31 秒没回过话", judge.failure(false, t0 + 34_000, startedAt = t0 + 29_000))
    }

    @Test
    fun threeQuickTimeoutsAreNotEnough() {
        val judge = ReachabilityJudge()
        for (i in 0 until 10) assertFalse("10 秒内十次超时也不判", judge.failure(false, t0 + i * 1_000L))
    }

    @Test
    fun twoHardFailuresThreeSecondsApart() {
        val judge = ReachabilityJudge()
        assertFalse(judge.failure(true, t0))
        assertFalse("同一瞬间的两次不算", judge.failure(true, t0 + 50))
        assertTrue(judge.failure(true, t0 + 3_100))
    }

    @Test
    fun softFailureBreaksHardStreak() {
        val judge = ReachabilityJudge()
        assertFalse(judge.failure(true, t0))
        assertFalse(judge.failure(false, t0 + 4_000))
        assertFalse("中间夹了一次软失败：硬失败不连续", judge.failure(true, t0 + 8_000))
    }

    @Test
    fun ioErrorClassification() {
        assertEquals(ReachabilityOutcome.SOFT, ReachabilityOutcome.of(java.net.SocketTimeoutException()))
        assertEquals(ReachabilityOutcome.SOFT, ReachabilityOutcome.of(java.net.UnknownHostException()))
        assertEquals(ReachabilityOutcome.HARD, ReachabilityOutcome.of(java.net.ConnectException()))
        assertEquals(ReachabilityOutcome.HARD, ReachabilityOutcome.of(javax.net.ssl.SSLHandshakeException("x")))
        assertEquals(ReachabilityOutcome.IGNORED, ReachabilityOutcome.of(java.io.IOException("Canceled")))
    }

    @Test
    fun responseWithoutServerHeaderIsForeign() {
        fun response(header: Boolean, code: Int) = okhttp3.Response.Builder()
            .request(okhttp3.Request.Builder().url("http://10.0.0.2:8000/api/v1/health").build())
            .protocol(okhttp3.Protocol.HTTP_1_1).code(code).message("")
            .apply { if (header) header("x-movieclaw-spec-hash", "abc") }
            .build()
        assertEquals("我家服务器回的 500 也是「连得上」", ReachabilityOutcome.SUCCESS, ReachabilityOutcome.of(response(true, 500)))
        assertEquals("机场门户页的 200 不是我家服务器", ReachabilityOutcome.HARD, ReachabilityOutcome.of(response(false, 200)))
    }
}

class OfflineImagesTest {
    @Test
    fun keyIgnoresServerAddressAndWidth() {
        val lan = "http://192.168.1.10:8000/api/v1/images/assets/12/poster.jpg?v=3&w=300".toHttpUrl()
        val domain = "https://mc.example.com/api/v1/images/assets/12/poster.jpg?w=780&v=3".toHttpUrl()
        assertEquals(OfflineImages.key(lan), OfflineImages.key(domain))
        assertEquals("/images/assets/12/poster.jpg?v=3", OfflineImages.key(lan))
    }

    @Test
    fun tmdbSizeSegmentIsNormalized() {
        val small = "http://h/api/v1/images/proxy?url=https://image.tmdb.org/t/p/w300/abc.jpg&w=300".toHttpUrl()
        val large = "http://h/api/v1/images/proxy?url=https://image.tmdb.org/t/p/original/abc.jpg&w=1920".toHttpUrl()
        assertEquals(OfflineImages.key(small), OfflineImages.key(large))
    }

    @Test
    fun differentVersionsAreDifferentImages() {
        val v3 = "http://h/api/v1/images/assets/12/poster.jpg?v=3".toHttpUrl()
        val v4 = "http://h/api/v1/images/assets/12/poster.jpg?v=4".toHttpUrl()
        assertNotEquals("换了图（v 是文件修改时间）就是另一张", OfflineImages.key(v3), OfflineImages.key(v4))
    }
}

class OfflineArchiveTest {
    private fun unit(fileId: Long, state: OfflineUnit.State) = OfflineUnit(
        fileId = fileId, mediaItemId = 7, season = 1, episode = fileId.toInt(), profile = "original", profileLabel = "原画",
        state = state, expectedBytes = 10, fileExtension = "mp4", createdAt = 0,
    )

    /** 视频已改名进来但状态没来得及写（改名与写状态之间被杀）：启动读存档时补标完成；空条目收拾掉 */
    @Test
    fun snapshotRepairsCompletedButUnmarkedUnits() {
        val dir = Files.createTempDirectory("mc-offline").toFile()
        OfflineDisk.init(dir)
        val key = "test-${System.nanoTime()}"
        val summary = OfflineItemSummary(
            mediaItemId = 7, libraryId = 1, libraryName = "剧集", libraryKind = "tv", kind = "tv", title = "示例", addedAt = 0,
        )
        OfflineDisk.write(OfflineItemSummary.serializer(), summary, OfflineDisk.summaryFile(key, 7))
        OfflineDisk.write(OfflineUnit.serializer(), unit(1, OfflineUnit.State.downloading), OfflineDisk.unitFile(key, 7, 1))
        OfflineDisk.write(OfflineUnit.serializer(), unit(2, OfflineUnit.State.downloading), OfflineDisk.unitFile(key, 7, 2))
        File(OfflineDisk.unitDir(key, 7, 1), "media.mp4").writeBytes(ByteArray(4096))
        File(OfflineDisk.unitDir(key, 7, 2), "media.part").writeBytes(ByteArray(100))
        // 一个只剩摘要、单元都删光了的条目
        OfflineDisk.write(OfflineItemSummary.serializer(), summary.copy(mediaItemId = 8), OfflineDisk.summaryFile(key, 8))

        val snapshot = OfflineDisk.loadSnapshot(key)
        assertEquals(OfflineUnit.State.done, snapshot.units[1]?.state)
        assertEquals(4096L, snapshot.units[1]?.receivedBytes)
        assertEquals("没有视频文件的照旧，接着从 media.part 续传", OfflineUnit.State.downloading, snapshot.units[2]?.state)
        assertEquals(100L, snapshot.units[2]?.receivedBytes)
        assertNotNull(snapshot.items[7])
        assertNull(snapshot.items[8])
        assertFalse(OfflineDisk.itemDir(key, 8).exists())
        assertEquals(OfflineUnit.State.done, OfflineDisk.read(OfflineUnit.serializer(), OfflineDisk.unitFile(key, 7, 1))?.state)
        dir.deleteRecursively()
    }

    @Test
    fun unknownFormatIsSkippedNotCrashed() {
        val dir = Files.createTempDirectory("mc-offline").toFile()
        OfflineDisk.init(dir)
        val key = "test-${System.nanoTime()}"
        OfflineDisk.writeText("""{"format":2,"mediaItemId":7}""", OfflineDisk.summaryFile(key, 7))
        assertTrue(OfflineDisk.loadSnapshot(key).items.isEmpty())
        dir.deleteRecursively()
    }

    @Test
    fun ownerKeyIgnoresAddress() {
        val lan = OfflineOwner(instanceId = "abc", username = "me", origin = "http://192.168.1.10:8000")
        val domain = OfflineOwner(instanceId = "abc", username = "me", origin = "https://mc.example.com")
        val other = OfflineOwner(instanceId = "xyz", username = "me", origin = "http://192.168.1.10:8000")
        assertEquals("同一台服务器换了地址，副本不丢", lan.key, domain.key)
        assertNotEquals("同一个地址上换了一台服务器，不串", lan.key, other.key)
    }
}

class OfflineViewingThresholdTest {
    @Test
    fun matchesServerThresholds() {
        val movie = 360_000L
        assertEquals("不足 5%", 0L to false, OfflineViewingRecorder.resolve(12_000, movie, false))
        assertEquals(60_000L to false, OfflineViewingRecorder.resolve(60_000, movie, false))
        assertEquals("超过 90%", 0L to true, OfflineViewingRecorder.resolve(340_000, movie, false))
        assertEquals("播到片尾", 0L to true, OfflineViewingRecorder.resolve(null, movie, false))
        assertEquals("短片过了开头就算看完", 0L to true, OfflineViewingRecorder.resolve(60_000, 240_000, false))
        assertEquals("拖回开头：已看不变", 0L to true, OfflineViewingRecorder.resolve(0, movie, true))
    }

    @Test
    fun transcodeWaitNotes() {
        assertEquals("等待转码器空闲", OfflineDownloader.transcodeWaitNote("transcoder", 2))
        assertEquals("等待转码，前面还有 2 个", OfflineDownloader.transcodeWaitNote("queue", 2))
        assertEquals("即将开始转码", OfflineDownloader.transcodeWaitNote("queue", 0))
        assertEquals("等待转码", OfflineDownloader.transcodeWaitNote(null, null))
    }
}

/** 剧集「下载」面板的范围规则（`OfflineDownloadChoices.make`） */
class OfflineDownloadChoicesTest {
    private fun episodes(count: Int, season: Int = 1, local: Map<Int, String> = emptyMap(), played: Set<Int> = emptySet()) =
        (1..count).map { OfflineDownloadChoices.Episode(season, it, season * 1000L + it, it in played, local[it]) }

    @Test
    fun selectedDownloadedOffersNextFiveAndRemaining() {
        val choices = OfflineDownloadChoices.make(episodes(47, local = mapOf(1 to "done")), 1 to 1, null, false)
        assertEquals(listOf("接下来 5 集", "剩余 46 集"), choices.scopes.map { it.label })
        assertEquals("next", choices.scopes.first { it.preferred }.id)
        assertEquals("第 2～6 集，共 5 集", choices.scopes[0].detail)
        assertEquals("第 2～47 集，共 46 集", choices.scopes[1].detail)
        assertEquals("第 1 集已下载 · 已下载 1 集，不会重复下载", choices.note)
    }

    @Test
    fun freshShowKeepsSelectedUnwatchedAndAll() {
        val choices = OfflineDownloadChoices.make(episodes(3, played = setOf(1)), 1 to 2, 1002, false)
        assertEquals(listOf("第 2 集", "未看 2 集", "全部 3 集"), choices.scopes.map { it.label })
        assertEquals("unwatched", choices.scopes.first { it.preferred }.id)
        assertEquals("第 2～3 集，共 2 集", choices.scopes[1].detail)
        assertNull(choices.note)
    }

    @Test
    fun onlySelectedLeftIsASingleScope() {
        val choices = OfflineDownloadChoices.make(episodes(3, local = mapOf(2 to "done", 3 to "active"), played = setOf(1)), 1 to 1, 1001, false)
        assertEquals(listOf("第 1 集"), choices.scopes.map { it.label })
        assertEquals("已下载 1 集、正在下载 1 集，不会重复下载", choices.note)
    }

    @Test
    fun nextThatCoversEverythingLeftIsJustRemaining() {
        val choices = OfflineDownloadChoices.make(episodes(4, local = mapOf(1 to "active")), 1 to 1, null, false)
        assertEquals(listOf("剩余 3 集"), choices.scopes.map { it.label })
        assertTrue(choices.scopes[0].preferred)
        assertEquals("第 1 集正在下载 · 正在下载 1 集，不会重复下载", choices.note)
    }

    @Test
    fun multiSeasonNamesAndNonContiguousRanges() {
        val list = episodes(3, season = 1, local = mapOf(2 to "done")) + episodes(2, season = 2)
        val choices = OfflineDownloadChoices.make(list, 1 to 2, null, true)
        assertTrue(choices.note!!.startsWith("第 1 季第 2 集已下载"))
        assertEquals(listOf("接下来 3 集", "剩余 4 集"), choices.scopes.map { it.label })
        assertEquals("第 1 季第 3 集 起，共 3 集", choices.scopes[0].detail)
        assertEquals("第 1 季第 1 集 起，共 4 集", choices.scopes[1].detail)
    }

    @Test
    fun everythingLocalHasNoScopes() {
        val choices = OfflineDownloadChoices.make(episodes(2, local = mapOf(1 to "done", 2 to "done")), 1 to 1, null, false)
        assertTrue(choices.scopes.isEmpty())
    }
}

class Fmp4FixupTest {
    private fun box(type: String, body: ByteArray): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val data = java.io.DataOutputStream(out)
        data.writeInt(8 + body.size)
        data.writeBytes(type)
        data.write(body)
        return out.toByteArray()
    }

    private fun tfdt(value: Long) = box("tfdt", java.nio.ByteBuffer.allocate(12).put(1).put(byteArrayOf(0, 0, 0)).putLong(value).array())

    /** 导出的第一个音频分片 tfdt = −1024：改成 0；视频与后面的分片不动 */
    @Test
    fun negativeTfdtIsClampedOthersUntouched() {
        val file = Files.createTempFile("fmp4", ".mp4").toFile()
        val moof1 = box("moof", box("mfhd", ByteArray(8)) + box("traf", box("tfhd", ByteArray(8)) + tfdt(-1024)) + box("traf", tfdt(90_000)))
        val moof2 = box("moof", box("traf", tfdt(48_000)))
        file.writeBytes(box("ftyp", ByteArray(8)) + box("moov", ByteArray(16)) + moof1 + box("mdat", ByteArray(32)) + moof2 + box("mdat", ByteArray(8)))
        assertEquals(1, Fmp4Fixup.clampNegativeTfdt(file))
        assertEquals("再跑一次没有要改的", 0, Fmp4Fixup.clampNegativeTfdt(file))
        val bytes = file.readBytes()
        fun valueAfter(index: Int) = java.nio.ByteBuffer.wrap(bytes, index + 8, 8).long
        val positions = Regex("tfdt").findAll(String(bytes, Charsets.ISO_8859_1)).map { it.range.first }.toList()
        assertEquals(listOf(0L, 90_000L, 48_000L), positions.map { valueAfter(it) })
        file.delete()
    }
}

class Fmp4IndexTest {
    private fun box(type: String, body: ByteArray): ByteArray {
        val buf = java.nio.ByteBuffer.allocate(8 + body.size)
        buf.putInt(8 + body.size).put(type.toByteArray(Charsets.ISO_8859_1)).put(body)
        return buf.array()
    }

    private fun full(type: String, version: Int, flags: Int, body: ByteArray): ByteArray =
        box(type, java.nio.ByteBuffer.allocate(4 + body.size).putInt((version shl 24) or flags).put(body).array())

    private fun track(id: Int, handler: String, scale: Int): ByteArray {
        val tkhd = full("tkhd", 0, 3, java.nio.ByteBuffer.allocate(80).putInt(0).putInt(0).putInt(id).array())
        val mdhd = full("mdhd", 0, 0, java.nio.ByteBuffer.allocate(20).putInt(0).putInt(0).putInt(scale).array())
        val hdlr = full("hdlr", 0, 0, java.nio.ByteBuffer.allocate(20).putInt(0).put(handler.toByteArray()).array())
        return box("trak", tkhd + box("mdia", mdhd + hdlr))
    }

    private fun traf(id: Int, time: Long, samples: Int, sampleDuration: Int): ByteArray {
        // default-base-is-moof + default-sample-duration
        val tfhd = full("tfhd", 0, 0x020008, java.nio.ByteBuffer.allocate(8).putInt(id).putInt(sampleDuration).array())
        val tfdt = full("tfdt", 1, 0, java.nio.ByteBuffer.allocate(8).putLong(time).array())
        val trun = full("trun", 0, 0x000001, java.nio.ByteBuffer.allocate(8).putInt(samples).putInt(0).array())
        return box("traf", tfhd + tfdt + trun)
    }

    /** 每个分片一条：大小 = styp + moof + mdat，时长 = 视频轨样本数 × 默认时长；插在 moov 之后，其余字节原样后移 */
    @Test
    fun indexIsInsertedAfterMoov() {
        val file = Files.createTempFile("fmp4", ".mp4").toFile()
        val head = box("ftyp", ByteArray(8)) + box("moov", track(1, "vide", 12288) + track(2, "soun", 48000))
        fun fragment(n: Int) = box("styp", ByteArray(8)) +
            box("moof", traf(1, n * 49152L, 96, 512) + traf(2, n * 192000L, 188, 1024)) + box("mdat", ByteArray(100 + n))
        val fragments = (0 until 3).map(::fragment)
        file.writeBytes(head + fragments.reduce(ByteArray::plus))
        assertTrue(Fmp4Fixup.addSegmentIndex(file))
        assertFalse("已经有索引就不再补", Fmp4Fixup.addSegmentIndex(file))
        val bytes = file.readBytes()
        val sidx = java.nio.ByteBuffer.wrap(bytes, head.size, bytes.size - head.size)
        val size = sidx.int
        assertEquals("sidx", String(ByteArray(4).also { sidx.get(it) }, Charsets.ISO_8859_1))
        sidx.int // version + flags
        assertEquals(1, sidx.int)
        assertEquals(12288, sidx.int)
        assertEquals(0L, sidx.long)
        assertEquals(0L, sidx.long)
        sidx.short
        assertEquals(3, sidx.short.toInt())
        fragments.forEach { f ->
            assertEquals(f.size, sidx.int)
            assertEquals(96 * 512, sidx.int)
            sidx.int
        }
        assertEquals(44 + 36, size)
        assertTrue("其余字节原样", bytes.copyOfRange(head.size + size, bytes.size).contentEquals(fragments.reduce(ByteArray::plus)))
        file.delete()
    }
}
