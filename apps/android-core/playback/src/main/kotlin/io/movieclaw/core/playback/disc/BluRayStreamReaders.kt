@file:OptIn(UnstableApi::class)

package io.movieclaw.core.playback.disc

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.DtsUtil
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.TrackOutput
import androidx.media3.extractor.ts.Ac3Reader
import androidx.media3.extractor.ts.ElementaryStreamReader
import androidx.media3.extractor.ts.TsPayloadReader

/*
 * 蓝光专有的几种流（disc-clip-play.md §4.2）。Exo 的 TS 解析器按字节流找同步字，蓝光的这几种 PES 却是按帧对齐的、
 * 一个 PES 装一帧（或一帧的一部分）：这里一律按 PES 处理——PES 的时间戳就是样本时间，开头几个字节就能认出是什么。
 */

/** 剪辑里 TrueHD 轨的 AC-3 核心另起一条轨，轨号 = PID + 这个数（PID 只有 13 位，不会撞） */
internal const val CORE_TRACK_OFFSET = 0x10000

/**
 * TrueHD（流类型 0x83）：同一个 PID 里交替着两种 PES——AC-3 核心（0x0B77 开头）与 TrueHD 访问单元（蓝光上一个 PES
 * 一个，1/1200 秒；别的封装工具可能一个 PES 装好几个）。拆成两条轨，与服务端的音轨清单（ffprobe 同样拆成
 * truehd + ac3）一一对应：AC-3 核心交给 Exo 的 [Ac3Reader]；TrueHD 按访问单元切开，每 16 个合成一个样本交 FFmpeg 解
 * （一个样本一次 JNI 调用，一个单元一个样本就是每秒 1200 次），主同步（解码器只能从它开始）另起一个样本并标关键帧。
 * 清单里这个 PID 没有 AC-3 核心时不建那条轨——建了却永远等不到数据，Exo 会一直卡在准备阶段。
 */
internal class TrueHdReader(private val channels: Int, private val hasCore: Boolean) : ElementaryStreamReader {
    private val core = Ac3Reader(null, 0, MimeTypes.VIDEO_MP2T)
    private lateinit var output: TrackOutput
    private lateinit var formatId: String
    private var formatSent = false
    private var route = Route.Unknown
    private var pesTimeUs = C.TIME_UNSET
    private var pesFlags = 0
    /** 当前 PES 里还没切出来的字节（访问单元可能跨 PES） */
    private var buffer = ByteArray(4096)
    private var size = 0
    private var unitTimeUs = C.TIME_UNSET
    private var unitDurationUs = 833L
    private var synced = false
    private var units = 0
    private var pending = 0
    private var groupTimeUs = C.TIME_UNSET
    private var groupKey = false

    override fun createTracks(extractorOutput: ExtractorOutput, idGenerator: TsPayloadReader.TrackIdGenerator) {
        idGenerator.generateNewId()
        formatId = idGenerator.formatId
        output = extractorOutput.track(idGenerator.trackId, C.TRACK_TYPE_AUDIO)
        if (hasCore) core.createTracks(extractorOutput, TsPayloadReader.TrackIdGenerator(idGenerator.trackId + CORE_TRACK_OFFSET, 1))
    }

    override fun seek() {
        if (hasCore) core.seek()
        route = Route.Unknown
        size = 0
        synced = false
        units = 0
        pending = 0
    }

    override fun packetStarted(pesTimeUs: Long, flags: Int) {
        this.pesTimeUs = pesTimeUs
        pesFlags = flags
        route = Route.Unknown
    }

    override fun consume(data: ParsableByteArray) {
        if (route == Route.Unknown) {
            val at = data.position
            val ac3 = data.bytesLeft() >= 2 && data.data[at] == 0x0B.toByte() && data.data[at + 1] == 0x77.toByte()
            route = when {
                ac3 && hasCore -> Route.Core.also { core.packetStarted(pesTimeUs, pesFlags) }
                ac3 -> Route.Skip
                else -> Route.TrueHd.also { if (size == 0) unitTimeUs = pesTimeUs }
            }
        }
        when (route) {
            Route.Core -> core.consume(data)
            Route.TrueHd -> {
                val n = data.bytesLeft()
                if (size + n > buffer.size) buffer = buffer.copyOf(maxOf(buffer.size * 2, size + n))
                data.readBytes(buffer, size, n)
                size += n
            }
            else -> data.skipBytes(data.bytesLeft())
        }
    }

    override fun packetFinished() {
        when (route) {
            Route.Core -> core.packetFinished()
            Route.TrueHd -> splitUnits()
            else -> Unit
        }
        route = Route.Unknown
    }

    /** 访问单元头：4 位校验 + 12 位长度（以 2 字节为单位）+ 16 位时序；主同步单元的第 4～7 字节是 F8726FBA */
    private fun splitUnits() {
        var pos = 0
        while (pos + 4 <= size) {
            val length = ((buffer[pos].toInt() and 0x0F) shl 8 or (buffer[pos + 1].toInt() and 0xFF)) * 2
            if (length < 4) {
                size = 0 // 不是单元边界（数据坏了）：丢掉，等下一个 PES
                return
            }
            if (pos + length > size) break
            val major = length >= 9 && buffer.readInt(pos + 4) == MAJOR_SYNC
            if (major) onMajorSync(buffer[pos + 8].toInt() shr 4 and 0xF)
            // 解码器只能从主同步开始：定位之后、第一个主同步之前的单元丢掉
            if (synced) {
                if (major && units > 0) flush()
                if (units == 0) {
                    groupTimeUs = unitTimeUs
                    groupKey = major
                }
                output.sampleData(ParsableByteArray(buffer.copyOfRange(pos, pos + length)), length)
                pending += length
                if (++units == GROUP) flush()
            }
            if (unitTimeUs != C.TIME_UNSET) unitTimeUs += unitDurationUs
            pos += length
        }
        System.arraycopy(buffer, pos, buffer, 0, size - pos)
        size -= pos
    }

    private fun onMajorSync(rateCode: Int) {
        val rate = sampleRate(rateCode)
        // 一个访问单元是 1/1200 秒（44.1 kHz 系是 40 个采样）
        unitDurationUs = if (rate % 44_100 == 0) 40L * 1_000_000L * (rate / 44_100) / rate else 1_000_000L / 1200
        if (!formatSent) {
            output.format(
                Format.Builder()
                    .setId(formatId)
                    .setContainerMimeType(MimeTypes.VIDEO_MP2T)
                    .setSampleMimeType(MimeTypes.AUDIO_TRUEHD)
                    .setChannelCount(channels)
                    .setSampleRate(rate)
                    .build(),
            )
            formatSent = true
        }
        synced = true
    }

    private fun flush() {
        if (pending > 0) output.sampleMetadata(groupTimeUs, if (groupKey) C.BUFFER_FLAG_KEY_FRAME else 0, pending, 0, null)
        pending = 0
        units = 0
    }

    private enum class Route { Unknown, Core, TrueHd, Skip }

    private companion object {
        const val GROUP = 16
        const val MAJOR_SYNC = 0xF8726FBA.toInt()

        fun sampleRate(code: Int): Int = when (code) {
            1 -> 96_000
            2 -> 192_000
            8 -> 44_100
            9 -> 88_200
            10 -> 176_400
            else -> 48_000
        }
    }
}

/**
 * DTS-HD（流类型 0x85 / 0x86）：核心帧与扩展子流各是一个 PES、时间戳相同。按 MKV 里的样子把两者拼成一个样本：
 * 交 FFmpeg 的 dca 解码器能解出无损（DTS-HD MA）；电视接功放透传时，整帧送出去也是对的。
 */
internal class DtsHdReader : ElementaryStreamReader {
    private lateinit var output: TrackOutput
    private lateinit var formatId: String
    private var formatSent = false
    private var route = Route.Skip
    private var pesTimeUs = C.TIME_UNSET
    private var pending = 0
    private var sampleTimeUs = C.TIME_UNSET

    override fun createTracks(extractorOutput: ExtractorOutput, idGenerator: TsPayloadReader.TrackIdGenerator) {
        idGenerator.generateNewId()
        formatId = idGenerator.formatId
        output = extractorOutput.track(idGenerator.trackId, C.TRACK_TYPE_AUDIO)
    }

    override fun seek() {
        pending = 0
        route = Route.Skip
    }

    override fun packetStarted(pesTimeUs: Long, flags: Int) {
        this.pesTimeUs = pesTimeUs
        route = Route.Unknown
    }

    override fun consume(data: ParsableByteArray) {
        if (route == Route.Unknown) route = startPes(data)
        if (route == Route.Skip) {
            data.skipBytes(data.bytesLeft())
            return
        }
        val n = data.bytesLeft()
        output.sampleData(data, n)
        pending += n
    }

    override fun packetFinished() = Unit

    override fun endOfInputReached() = flush()

    private fun startPes(data: ParsableByteArray): Route {
        val at = data.position
        val sync = if (data.bytesLeft() >= 4) data.data.readInt(at) else 0
        if (sync == CORE_SYNC) {
            flush()
            if (!formatSent) {
                // 核心帧头里有采样率与声道；样本里拼着扩展子流，类型标 DTS-HD
                val header = data.data.copyOfRange(at, at + minOf(data.bytesLeft(), HEADER_BYTES))
                val core = DtsUtil.parseDtsFormat(header, formatId, null, 0, MimeTypes.VIDEO_MP2T, null)
                output.format(core.buildUpon().setSampleMimeType(MimeTypes.AUDIO_DTS_HD).build())
                formatSent = true
            }
            sampleTimeUs = pesTimeUs
            return Route.Frame
        }
        // 扩展子流只接在核心帧后面：定位之后第一个核心帧之前的丢掉
        return if (sync == EXTENSION_SYNC && pending > 0) Route.Frame else Route.Skip
    }

    private fun flush() {
        if (pending > 0) output.sampleMetadata(sampleTimeUs, C.BUFFER_FLAG_KEY_FRAME, pending, 0, null)
        pending = 0
    }

    private enum class Route { Unknown, Frame, Skip }

    private companion object {
        const val CORE_SYNC = 0x7FFE8001
        const val EXTENSION_SYNC = 0x64582025
        const val HEADER_BYTES = 18
    }
}

/**
 * 蓝光 LPCM（流类型 0x80）：每个 PES 是 4 字节头（声道布局、采样率、位深）加大端 PCM，声道数按偶数补齐
 * （单声道、3 / 5 / 7 声道多存一路空声道）。转成小端、去掉补齐的那一路再交给 Exo。
 */
internal class BdLpcmReader : ElementaryStreamReader {
    private lateinit var output: TrackOutput
    private lateinit var formatId: String
    private var format: Format? = null
    private var pesTimeUs = C.TIME_UNSET
    private var buffer = ByteArray(4096)
    private var size = 0
    private var started = false

    override fun createTracks(extractorOutput: ExtractorOutput, idGenerator: TsPayloadReader.TrackIdGenerator) {
        idGenerator.generateNewId()
        formatId = idGenerator.formatId
        output = extractorOutput.track(idGenerator.trackId, C.TRACK_TYPE_AUDIO)
    }

    override fun seek() {
        size = 0
        started = false
    }

    override fun packetStarted(pesTimeUs: Long, flags: Int) {
        this.pesTimeUs = pesTimeUs
        size = 0
        started = true
    }

    override fun consume(data: ParsableByteArray) {
        val n = data.bytesLeft()
        if (!started) {
            data.skipBytes(n)
            return
        }
        if (size + n > buffer.size) buffer = buffer.copyOf(maxOf(buffer.size * 2, size + n))
        data.readBytes(buffer, size, n)
        size += n
    }

    override fun packetFinished() {
        if (!started || size < 4) return
        started = false
        val channels = CHANNELS.getOrElse(buffer[2].toInt() shr 4 and 0xF) { 0 }
        val rate = when (buffer[2].toInt() and 0xF) {
            1 -> 48_000
            4 -> 96_000
            5 -> 192_000
            else -> 0
        }
        val bytes = when (buffer[3].toInt() shr 6 and 0x3) {
            1 -> 2
            2, 3 -> 3 // 20 位按 24 位存
            else -> 0
        }
        if (channels == 0 || rate == 0 || bytes == 0) return
        val coded = (channels + 1) and 1.inv()
        val next = Format.Builder()
            .setId(formatId)
            .setContainerMimeType(MimeTypes.VIDEO_MP2T)
            .setSampleMimeType(MimeTypes.AUDIO_RAW)
            .setPcmEncoding(if (bytes == 2) C.ENCODING_PCM_16BIT else C.ENCODING_PCM_24BIT)
            .setChannelCount(channels)
            .setSampleRate(rate)
            .build()
        if (next != format) {
            output.format(next)
            format = next
        }
        val frames = (size - 4) / (coded * bytes)
        val out = ByteArray(frames * channels * bytes)
        var src = 4
        var dst = 0
        repeat(frames) {
            repeat(channels) {
                for (b in 0 until bytes) out[dst + b] = buffer[src + bytes - 1 - b]
                src += bytes
                dst += bytes
            }
            src += (coded - channels) * bytes
        }
        output.sampleData(ParsableByteArray(out), out.size)
        output.sampleMetadata(pesTimeUs, C.BUFFER_FLAG_KEY_FRAME, out.size, 0, null)
    }

    private companion object {
        /** 声道布局编号 → 声道数（1 单声道、3 立体声、4 3/0 … 11 3/4+LFE） */
        val CHANNELS = intArrayOf(0, 1, 0, 2, 3, 3, 4, 4, 5, 6, 7, 8)
    }
}

/**
 * 蓝光图形字幕 PGS（流类型 0x90）：一组显示（PCS…END 几个段）拆在好几个 PES 里，攒齐到 END 段再作为一个样本交出
 * （与 MKV 里的 PGS 样本同一形态，Exo 的 PgsParser 直接解），时间取开头那个 PCS 的时间戳。
 */
internal class PgsReader : ElementaryStreamReader {
    private lateinit var output: TrackOutput
    private var buffer = ByteArray(16 * 1024)
    private var size = 0
    private var pesTimeUs = C.TIME_UNSET
    private var setTimeUs = C.TIME_UNSET

    override fun createTracks(extractorOutput: ExtractorOutput, idGenerator: TsPayloadReader.TrackIdGenerator) {
        idGenerator.generateNewId()
        output = extractorOutput.track(idGenerator.trackId, C.TRACK_TYPE_TEXT)
        output.format(
            Format.Builder()
                .setId(idGenerator.formatId)
                .setContainerMimeType(MimeTypes.VIDEO_MP2T)
                .setSampleMimeType(MimeTypes.APPLICATION_PGS)
                .build(),
        )
    }

    override fun seek() {
        size = 0
    }

    override fun packetStarted(pesTimeUs: Long, flags: Int) {
        this.pesTimeUs = pesTimeUs
    }

    override fun consume(data: ParsableByteArray) {
        val n = data.bytesLeft()
        // 一组显示从 PCS 段开始：定位之后半截的组丢掉
        if (size == 0 && (n == 0 || data.data[data.position].toInt() and 0xFF != SEGMENT_PCS)) {
            data.skipBytes(n)
            return
        }
        if (size == 0) setTimeUs = pesTimeUs
        if (size + n > buffer.size) buffer = buffer.copyOf(maxOf(buffer.size * 2, size + n))
        data.readBytes(buffer, size, n)
        size += n
    }

    override fun packetFinished() {
        var pos = 0
        while (pos + 3 <= size) {
            val type = buffer[pos].toInt() and 0xFF
            val end = pos + 3 + ((buffer[pos + 1].toInt() and 0xFF) shl 8 or (buffer[pos + 2].toInt() and 0xFF))
            if (end > size) return
            pos = end
            if (type == SEGMENT_END) {
                output.sampleData(ParsableByteArray(buffer.copyOf(pos)), pos)
                output.sampleMetadata(setTimeUs, C.BUFFER_FLAG_KEY_FRAME, pos, 0, null)
                System.arraycopy(buffer, pos, buffer, 0, size - pos)
                size -= pos
                pos = 0
                if (size > 0) setTimeUs = pesTimeUs
            }
        }
    }

    private companion object {
        const val SEGMENT_PCS = 0x16
        const val SEGMENT_END = 0x80
    }
}

private fun ByteArray.readInt(at: Int): Int =
    (this[at].toInt() and 0xFF shl 24) or (this[at + 1].toInt() and 0xFF shl 16) or
        (this[at + 2].toInt() and 0xFF shl 8) or (this[at + 3].toInt() and 0xFF)
