package io.movieclaw.core.playback.disc

import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.extractor.DefaultExtractorInput
import androidx.media3.extractor.DiscardingTrackOutput
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.PositionHolder
import io.movieclaw.core.model.generated.PlaybackBlurayClipView
import io.movieclaw.core.model.generated.PlaybackBlurayStreamView
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import okio.Buffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 夹具 bluray/clip.m2ts 是 ffmpeg 按蓝光的样子封的半秒剪辑（192 字节包、蓝光 PID、时间戳从 601.4 秒起）：
 * H.264 + TrueHD（0x1100）+ AC-3（0x1101）+ LPCM 单声道（0x1102）。入口点表是两个关键帧所在的源包号。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BluRayClipExtractorTest {
    private val clip = PlaybackBlurayClipView(
        url = "",
        inTime = 27_063_000,
        outTime = 27_063_000 + 22_500,
        entryPts = listOf(27_063_000, 27_074_250),
        entrySpn = listOf(3, 372),
    )
    private val streams = BluRayStreams(
        audio = listOf(
            PlaybackBlurayStreamView(ref = "embedded:0", pid = 0x1100, codec = "truehd", language = "zho", channels = 1),
            PlaybackBlurayStreamView(ref = "embedded:1", pid = 0x1101, codec = "ac3", language = "eng", channels = 1),
            PlaybackBlurayStreamView(ref = "embedded:2", pid = 0x1102, codec = "pcm_bluray", language = "jpn", channels = 1),
        ),
        subtitles = emptyList(),
    )
    private val bytes = resource("bluray/clip.m2ts")

    private fun extractor() = BluRayClipExtractor(BluRayClipExtractor.seekMap(clip), streams)

    @Test
    fun `reads every stream with the server numbering and the clip's own timestamps`() {
        val out = extractM2ts(extractor(), bytes)
        val video = out.tracks.getValue(0x1011)
        assertEquals(MimeTypes.VIDEO_H264, video.format?.sampleMimeType)
        // 时间戳不平移：就是剪辑里的 PTS（601.4 秒起），与播放列表的 IN / OUT 同一口径
        assertTrue(video.samples.first().isKey)
        assertEquals(601_400_000.0, video.samples.first().timeUs.toDouble(), 50_000.0)

        val trueHd = out.tracks.getValue(0x1100)
        assertEquals(MimeTypes.AUDIO_TRUEHD, trueHd.format?.sampleMimeType)
        // 语言码由 Exo 归一成两字母
        assertEquals("0" to "zh", trueHd.format?.id to trueHd.format?.language)
        assertTrue(trueHd.samples.first().isKey)
        assertTrue(trueHd.samples.all { it.timeUs >= 600_000_000 })
        // 清单里这个 PID 没有 AC-3 核心：不建那条轨（建了等不到数据会卡住准备）
        assertNull(out.tracks[0x1100 + CORE_TRACK_OFFSET])

        val ac3 = out.tracks.getValue(0x1101)
        assertEquals(MimeTypes.AUDIO_AC3, ac3.format?.sampleMimeType)
        assertEquals("1" to "en", ac3.format?.id to ac3.format?.language)

        val lpcm = out.tracks.getValue(0x1102)
        assertEquals(MimeTypes.AUDIO_RAW, lpcm.format?.sampleMimeType)
        assertEquals(C.ENCODING_PCM_16BIT, lpcm.format?.pcmEncoding)
        assertEquals(1, lpcm.format?.channelCount)
        assertEquals("2" to "ja", lpcm.format?.id to lpcm.format?.language)
        // 一个 PES 5 毫秒：240 个采样，补齐的空声道去掉后每个采样 2 字节
        assertEquals(480, lpcm.samples.first().data.size)
    }

    @Test
    fun `seeks through the entry point table`() {
        val seekMap = FakeOutput().also { extractor().init(it) }.seekMap!!
        assertTrue(seekMap.isSeekable)
        assertEquals(BluRayClipExtractor.ptsToUs(clip.outTime), seekMap.durationUs)
        val target = BluRayClipExtractor.ptsToUs(27_074_250) + 10_000
        assertEquals(372L * 188, seekMap.getSeekPoints(target).first.position)

        // 播放器先从头读出节目表，再按入口点跳过去（读取器跨跳转保留）
        val extractor = extractor()
        val out = extractM2ts(extractor, bytes)
        val video = out.tracks.getValue(0x1011)
        val before = video.samples.size
        extractor.seek(372L * 188, target)
        readM2ts(extractor, bytes, 372L * 188)
        val first = video.samples[before]
        assertTrue(first.isKey)
        assertEquals(BluRayClipExtractor.ptsToUs(27_074_250).toDouble(), first.timeUs.toDouble(), 1_000.0)
    }

    @Test(timeout = 30_000)
    fun `HTTP direct play discovers tracks then seeks once and preserves every sample`() {
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val start = request.headers["Range"]!!.removePrefix("bytes=").removeSuffix("-").toInt()
                return MockResponse.Builder().code(206)
                    .addHeader("Content-Range", "bytes $start-${bytes.lastIndex}/${bytes.size}")
                    .body(Buffer().write(bytes, start, bytes.size - start))
                    .build()
            }
        }
        server.start()
        val http = OkHttpClient()
        val source = M2tsDataSource(OkHttpDataSource.Factory(http).createDataSource())
        val extractor = extractor()
        try {
            val spec = DataSpec.Builder().setUri(server.url("/bluray/0").toString()).build()
            val out = FakeOutput()
            extractor.init(out)
            assertEquals(C.LENGTH_UNSET.toLong(), source.open(spec))
            val input = DefaultExtractorInput(source, 0, C.LENGTH_UNSET.toLong())
            val holder = PositionHolder()
            // 起播先读节目表和首个视频样本，模拟裁剪源随后按入口点定位。
            while (!out.tracksEnded || out.tracks[0x1011]?.samples.isNullOrEmpty()) {
                assertEquals(Extractor.RESULT_CONTINUE, extractor.read(input, holder))
            }
            source.close()

            val target = BluRayClipExtractor.ptsToUs(27_074_250) + 10_000
            val position = out.seekMap!!.getSeekPoints(target).first.position
            val before = out.tracks.mapValues { it.value.samples.size }
            extractor.seek(position, target)
            source.open(spec.buildUpon().setPosition(position).build())
            val seekInput = DefaultExtractorInput(source, position, C.LENGTH_UNSET.toLong())
            var result = Extractor.RESULT_CONTINUE
            while (result == Extractor.RESULT_CONTINUE) result = extractor.read(seekInput, holder)
            assertEquals(Extractor.RESULT_END_OF_INPUT, result)

            // 对照同一剪辑从头解出的样本，检查 Range + 去头 + 真实 TS/音频读取器的完整链路。
            val expected = extractM2ts(extractor(), bytes)
            assertEquals(expected.tracks.keys, out.tracks.keys)
            for ((pid, track) in out.tracks) {
                val samples = track.samples.drop(before.getValue(pid))
                assertTrue("seek 后轨 $pid 仍有数据", samples.isNotEmpty())
                val reference = expected.tracks.getValue(pid)
                assertEquals(reference.format, track.format)
                val tail = reference.samples.filter { it.timeUs >= samples.first().timeUs }
                assertEquals(tail.size, samples.size)
                samples.zip(tail).forEach { (actual, wanted) ->
                    assertEquals(wanted.timeUs, actual.timeUs)
                    assertEquals(wanted.flags, actual.flags)
                    assertArrayEquals(wanted.data, actual.data)
                }
            }
            assertTrue(out.tracks.getValue(0x1011).samples[before.getValue(0x1011)].isKey)
            assertEquals("只允许起播和显式 seek 两次请求", 2, server.requestCount)
            assertEquals("bytes=4-", server.takeRequest().headers["Range"])
            assertEquals("bytes=${M2tsDataSource.physical(position)}-", server.takeRequest().headers["Range"])
        } finally {
            source.close()
            extractor.release()
            http.connectionPool.evictAll()
            http.dispatcher.executorService.shutdown()
            server.close()
        }
    }

    @Test
    fun `drops the Dolby Vision enhancement layer and picture-in-picture video`() {
        val out = FakeOutput()
        val output = BluRayClipExtractor.StreamOutput(out, streams)
        assertTrue(output.track(0x1015, C.TRACK_TYPE_VIDEO) is DiscardingTrackOutput)
        assertTrue(output.track(0x1B00, C.TRACK_TYPE_VIDEO) is DiscardingTrackOutput)
        output.track(0x1011, C.TRACK_TYPE_VIDEO)
        assertEquals(setOf(0x1011), out.tracks.keys)
    }
}
