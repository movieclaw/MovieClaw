@file:OptIn(UnstableApi::class)

package io.movieclaw.core.playback.disc

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.common.util.TimestampAdjuster
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.DiscardingTrackOutput
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.ForwardingTrackOutput
import androidx.media3.extractor.IndexSeekMap
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.TrackOutput
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.ts.Ac3Reader
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import androidx.media3.extractor.ts.ElementaryStreamReader
import androidx.media3.extractor.ts.PesReader
import androidx.media3.extractor.ts.TsExtractor
import androidx.media3.extractor.ts.TsPayloadReader
import io.movieclaw.core.model.generated.PlaybackBlurayClipView
import io.movieclaw.core.model.generated.PlaybackBlurayStreamView
import io.movieclaw.core.playback.embeddedIndexOf

/**
 * 一段蓝光剪辑的解复用（disc-clip-play.md §4）：Exo 的 TS 解析器读 [M2tsDataSource] 去过头的字节，外加三样——
 *
 * - **时间戳不平移**：样本时间就是剪辑里的 PTS，与播放列表的 IN / OUT、入口点表同一口径，裁剪与定位不用换算；
 * - **定位查入口点表**：服务端从 CLPI 读出的关键帧表（PTS → 源包号）一次按字节到位，不在几十 GB 的剪辑里按时间二分；
 * - **轨按服务端的清单认**：PID 对上服务端的编号与语言（蓝光的 PMT 里没有语言），杜比视界增强层与画中画视频不出轨。
 */
internal class BluRayClipExtractor(private val seekMap: SeekMap, private val streams: BluRayStreams) : Extractor {
    private val ts = TsExtractor(
        TsExtractor.MODE_SINGLE_PMT,
        0,
        DefaultSubtitleParserFactory(),
        TimestampAdjuster(TimestampAdjuster.MODE_NO_OFFSET),
        BluRayPayloadReaderFactory(streams),
        TsExtractor.DEFAULT_TIMESTAMP_SEARCH_BYTES,
    )

    override fun sniff(input: ExtractorInput): Boolean = true

    override fun init(output: ExtractorOutput) {
        ts.init(StreamOutput(output, streams))
        output.seekMap(seekMap)
    }

    override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int = ts.read(input, seekPosition)

    override fun seek(position: Long, timeUs: Long) = ts.seek(position, timeUs)

    override fun release() = ts.release()

    internal class StreamOutput(private val output: ExtractorOutput, private val streams: BluRayStreams) : ExtractorOutput {
        override fun track(id: Int, type: Int): TrackOutput {
            // 主视频固定是 0x1011；0x1015 是杜比视界增强层（单独解不了），0x1B00 起是画中画
            if (type == C.TRACK_TYPE_VIDEO && id != PRIMARY_VIDEO_PID) return DiscardingTrackOutput()
            val stream = when (type) {
                C.TRACK_TYPE_AUDIO -> streams.audio(id)
                C.TRACK_TYPE_TEXT -> streams.subtitle(id)
                else -> null
            }
            val track = output.track(id, type)
            return if (stream == null) track else Labeled(track, stream)
        }

        override fun endTracks() = output.endTracks()

        /** TS 解析器不知道长度，报的是「不能定位」：定位用 init 里给的入口点表 */
        override fun seekMap(seekMap: SeekMap) = Unit
    }

    /** 轨 id 换成服务端的编号（播放器按它对应 embedded:N），补上语言 */
    private class Labeled(delegate: TrackOutput, private val stream: BluRayStreams.Stream) : ForwardingTrackOutput(delegate) {
        override fun format(format: Format) {
            super.format(format.buildUpon().setId(stream.index.toString()).setLanguage(stream.language ?: format.language).build())
        }
    }

    companion object {
        const val PRIMARY_VIDEO_PID = 0x1011

        /** 入口点表 → 定位表：PTS（45 kHz）换微秒，源包号换去头后的字节位置；时长到剪辑的 OUT 点 */
        fun seekMap(clip: PlaybackBlurayClipView): SeekMap {
            val count = minOf(clip.entryPts.size, clip.entrySpn.size)
            val positions = LongArray(count) { clip.entrySpn[it] * M2tsDataSource.TS }
            val times = LongArray(count) { ptsToUs(clip.entryPts[it]) }
            return IndexSeekMap(positions, times, ptsToUs(clip.outTime))
        }

        fun ptsToUs(pts45k: Long): Long = pts45k * 1_000_000L / 45_000L
    }
}

/**
 * 服务端清单里的轨：PID → 服务端的编号（`embedded:N` 的 N）、语言、声道。
 * TrueHD 的 PID 上另有一条 AC-3 核心，按 [CORE_TRACK_OFFSET] 区分。
 */
internal class BluRayStreams(audio: List<PlaybackBlurayStreamView>, subtitles: List<PlaybackBlurayStreamView>) {
    data class Stream(val index: Int, val language: String?, val channels: Int?)

    private val audioByTrack = HashMap<Int, Stream>()
    private val subtitleByPid = HashMap<Int, Stream>()
    val trueHdPids: Set<Int> = audio.filter { it.codec == "truehd" }.mapNotNull { it.pid?.toInt() }.toSet()

    init {
        audio.forEachIndexed { i, s ->
            val pid = s.pid?.toInt() ?: return@forEachIndexed
            val track = if (pid in trueHdPids && s.codec != "truehd") pid + CORE_TRACK_OFFSET else pid
            audioByTrack.putIfAbsent(track, Stream(embeddedIndexOf(s.ref) ?: i, s.language, s.channels?.toInt()))
        }
        subtitles.forEachIndexed { i, s ->
            val pid = s.pid?.toInt() ?: return@forEachIndexed
            subtitleByPid.putIfAbsent(pid, Stream(embeddedIndexOf(s.ref) ?: i, s.language, null))
        }
    }

    fun audio(track: Int): Stream? = audioByTrack[track]

    fun subtitle(pid: Int): Stream? = subtitleByPid[pid]
}

/**
 * 蓝光的流类型 → 读取器。Exo 认得的照用（H.264 / HEVC / MPEG-2、AC-3 / E-AC-3、DTS 核心）；它不认的
 * LPCM、TrueHD、DTS-HD、PGS 用 BluRayStreamReaders.kt 里的。
 *
 * 注意 Exo 读 PMT 时见到「AC-3」注册描述符会把流类型改报成 0x81：蓝光的 TrueHD（0x83）与 E-AC-3（0x84）
 * 到这里都是 0x81，只能按服务端清单里的编码认出 TrueHD 的 PID（读取器建轨时才知道 PID）。
 */
internal class BluRayPayloadReaderFactory(private val streams: BluRayStreams) : TsPayloadReader.Factory {
    private val default = DefaultTsPayloadReaderFactory(DefaultTsPayloadReaderFactory.FLAG_ENABLE_HDMV_DTS_AUDIO_STREAMS)

    override fun createInitialPayloadReaders() = default.createInitialPayloadReaders()

    override fun createPayloadReader(streamType: Int, esInfo: TsPayloadReader.EsInfo): TsPayloadReader? = when (streamType) {
        STREAM_LPCM -> PesReader(BdLpcmReader())
        TsExtractor.TS_STREAM_TYPE_AC3, STREAM_TRUEHD, STREAM_E_AC3 -> PesReader(DolbyReader(streams, esInfo))
        STREAM_DTS_HD_HRA, STREAM_DTS_HD_MA -> PesReader(DtsHdReader())
        STREAM_PGS -> PesReader(PgsReader())
        else -> default.createPayloadReader(streamType, esInfo)
    }

    private companion object {
        const val STREAM_LPCM = 0x80
        const val STREAM_TRUEHD = 0x83
        const val STREAM_E_AC3 = 0x84
        const val STREAM_DTS_HD_HRA = 0x85
        const val STREAM_DTS_HD_MA = 0x86
        const val STREAM_PGS = 0x90
    }
}

/** 杜比流：服务端清单里是 TrueHD 的 PID 交给 [TrueHdReader]，其余（AC-3 / E-AC-3）交给 Exo 的 [Ac3Reader] */
private class DolbyReader(private val streams: BluRayStreams, private val esInfo: TsPayloadReader.EsInfo) : ElementaryStreamReader {
    private lateinit var reader: ElementaryStreamReader

    override fun createTracks(extractorOutput: ExtractorOutput, idGenerator: TsPayloadReader.TrackIdGenerator) {
        // 建轨时才知道 PID：先取号认出是哪种，再给真正的读取器一个从这个 PID 起号的生成器
        idGenerator.generateNewId()
        val pid = idGenerator.trackId
        reader = if (pid in streams.trueHdPids) {
            TrueHdReader(streams.audio(pid)?.channels ?: 6, hasCore = streams.audio(pid + CORE_TRACK_OFFSET) != null)
        } else {
            Ac3Reader(esInfo.language, esInfo.getRoleFlags(), MimeTypes.VIDEO_MP2T)
        }
        reader.createTracks(extractorOutput, TsPayloadReader.TrackIdGenerator(pid, 1))
    }

    override fun seek() = reader.seek()
    override fun packetStarted(pesTimeUs: Long, flags: Int) = reader.packetStarted(pesTimeUs, flags)
    override fun consume(data: ParsableByteArray) = reader.consume(data)
    override fun packetFinished() = reader.packetFinished()
    override fun endOfInputReached() = reader.endOfInputReached()
}
