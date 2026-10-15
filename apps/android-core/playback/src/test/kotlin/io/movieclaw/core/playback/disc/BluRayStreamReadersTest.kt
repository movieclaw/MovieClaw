package io.movieclaw.core.playback.disc

import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.extractor.ts.ElementaryStreamReader
import androidx.media3.extractor.ts.TsPayloadReader
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BluRayStreamReadersTest {
    private val output = FakeOutput()

    private fun ElementaryStreamReader.start(pid: Int = 0x1100) = apply { createTracks(output, TsPayloadReader.TrackIdGenerator(pid, 1)) }

    /** 一个 PES：按两段喂进去（像跨了 TS 包），再收尾 */
    private fun ElementaryStreamReader.pes(timeUs: Long, payload: ByteArray) {
        packetStarted(timeUs, 0)
        val half = payload.size / 2
        consume(ParsableByteArray(payload.copyOfRange(0, half)))
        consume(ParsableByteArray(payload.copyOfRange(half, payload.size)))
        packetFinished()
    }

    @Test
    fun `LPCM drops the padding channel and turns big-endian into little-endian`() {
        val reader = BdLpcmReader().start(0x1101)
        // 单声道 48 kHz 16 位：按偶数补成两路，第二路是空的
        reader.pes(1_000, byteArrayOf(0, 8, 0x11, 0x40) + byteArrayOf(0x12, 0x34, 0, 0, 0x56, 0x78, 0, 0))
        // 立体声 96 kHz 24 位
        reader.pes(2_000, byteArrayOf(0, 6, 0x34, 0xC0.toByte()) + byteArrayOf(1, 2, 3, 4, 5, 6))
        val track = output.tracks.getValue(0x1101)
        assertArrayEquals(byteArrayOf(0x34, 0x12, 0x78, 0x56), track.samples[0].data)
        assertArrayEquals(byteArrayOf(3, 2, 1, 6, 5, 4), track.samples[1].data)
        val format = track.format!!
        assertEquals(MimeTypes.AUDIO_RAW, format.sampleMimeType)
        assertEquals(C.ENCODING_PCM_24BIT, format.pcmEncoding)
        assertEquals(2 to 96_000, format.channelCount to format.sampleRate)
    }

    @Test
    fun `PGS collects a display set across PES packets into one sample`() {
        val reader = PgsReader().start(0x1200)
        val pcs = byteArrayOf(0x16, 0, 2, 9, 9)
        val wds = byteArrayOf(0x17, 0, 1, 7)
        val end = byteArrayOf(0x80.toByte(), 0, 0)
        reader.pes(500, byteArrayOf(0x15, 0, 1, 5)) // 定位后的半截组（没有 PCS）：丢掉
        reader.pes(1_000, pcs)
        reader.pes(1_010, wds)
        reader.pes(1_020, end)
        val track = output.tracks.getValue(0x1200)
        assertEquals(MimeTypes.APPLICATION_PGS, track.format?.sampleMimeType)
        assertEquals(1, track.samples.size)
        assertEquals(1_000L, track.samples[0].timeUs)
        assertArrayEquals(pcs + wds + end, track.samples[0].data)
    }

    @Test
    fun `DTS-HD joins the core frame and its extension substream`() {
        val reader = DtsHdReader().start()
        val core = hex("7ffe8001fc3c75b276c005380009ef7b") + ByteArray(16)
        val extension = hex("64582025") + ByteArray(12) { 1 }
        reader.pes(500, extension) // 第一个核心帧之前的扩展子流：丢掉
        reader.pes(1_000, core)
        reader.pes(1_000, extension)
        reader.pes(11_667, core)
        reader.endOfInputReached()
        val track = output.tracks.getValue(0x1100)
        assertEquals(MimeTypes.AUDIO_DTS_HD, track.format?.sampleMimeType)
        assertEquals(48_000, track.format?.sampleRate)
        assertEquals(listOf(1_000L, 11_667L), track.samples.map { it.timeUs })
        assertArrayEquals(core + extension, track.samples[0].data)
        assertArrayEquals(core, track.samples[1].data)
    }

    /** 一个 TrueHD 访问单元：12 位长度（以 2 字节计）；主同步单元第 4～7 字节是 F8726FBA，第 8 字节高 4 位是采样率 */
    private fun unit(major: Boolean, fill: Int): ByteArray {
        val bytes = ByteArray(20) { fill.toByte() }
        bytes[0] = 0xF0.toByte()
        bytes[1] = 10
        if (major) {
            hex("f8726fba").copyInto(bytes, 4)
            bytes[8] = 0x10 // 96 kHz
        }
        return bytes
    }

    @Test
    fun `TrueHD splits the AC-3 core into its own track and groups access units from a major sync`() {
        val reader = TrueHdReader(channels = 6, hasCore = true).start()
        val ac3 = hex(AC3_FRAME)
        reader.pes(0, unit(major = false, fill = 1)) // 第一个主同步之前：解码器用不上，丢掉
        reader.pes(1_000, ac3)
        for (i in 0 until 18) reader.pes(1_000L + i * 833, unit(major = i == 0 || i == 17, fill = i))

        val trueHd = output.tracks.getValue(0x1100)
        assertEquals(MimeTypes.AUDIO_TRUEHD, trueHd.format?.sampleMimeType)
        assertEquals(6 to 96_000, trueHd.format?.channelCount to trueHd.format?.sampleRate)
        // 前 16 个单元一个样本（关键帧）；第 17 个单元赶上下一个主同步，单独成一个非关键样本
        assertEquals(2, trueHd.samples.size)
        assertEquals(16 * 20, trueHd.samples[0].data.size)
        assertTrue(trueHd.samples[0].isKey)
        assertEquals(1_000L, trueHd.samples[0].timeUs)
        assertEquals(20, trueHd.samples[1].data.size)
        assertFalse(trueHd.samples[1].isKey)
        assertEquals(1_000L + 16 * 833, trueHd.samples[1].timeUs)

        val core = output.tracks.getValue(0x1100 + CORE_TRACK_OFFSET)
        assertEquals(MimeTypes.AUDIO_AC3, core.format?.sampleMimeType)
        assertArrayEquals(ac3, core.samples.single().data)
        assertEquals(1_000L, core.samples.single().timeUs)
    }

    @Test
    fun `TrueHD access units packed several to a PES are split too`() {
        val reader = TrueHdReader(channels = 2, hasCore = false).start()
        reader.pes(5_000, unit(true, 0) + unit(false, 1) + unit(false, 2).copyOf(10))
        reader.pes(7_500, unit(false, 2).copyOfRange(10, 20) + unit(true, 3))
        val track = output.tracks.getValue(0x1100)
        // 跨 PES 的半个单元接上；第二个主同步把前三个单元收成一个样本
        assertEquals(1, track.samples.size)
        assertEquals(60, track.samples[0].data.size)
        assertEquals(5_000L, track.samples[0].timeUs)
        assertEquals(setOf(0x1100), output.tracks.keys)
    }

    private companion object {
        /** ffmpeg 编的一帧 AC-3（单声道静音，64 kbps，256 字节） */
        const val AC3_FRAME =
            "0b77903108402f842943fe757cf9f3e7cf9f3e7cf9f3e7cf9f3e7cf9f3e7cf9f3e7cf9f3e7cf9f3e7cf9f3e7cf8cbfc1100000000daf9f3e7cdb6db6" +
                "dbc78f1e3c78f1e3c78f1e3c6edb6dbe7cd6b528000000006d7cf9f3e6db6db6de3c78f1e3c78f1e3c78f1e376db6df3e6b5a940000000036be7cf9f" +
                "36db6db6f1e3c78f1e3c78f1e3c78f1bb6db6f9f35ad4a000000001b5f3e7cf9b6db6db78f1e3c78f1e3c78f1e3c78ddb6db7cf9ad6a5000000000da" +
                "f9f3e7cdb6db6dbc78f1e3c78f1e3c78f1e3c6edb6dbe7cd6b528000000006d7cf9f3e6db6db6de3c78f1e3c78f1e3c78f1e376db6df3e6b5a900000" +
                "00000000000000000000000000004b0a"
    }
}
