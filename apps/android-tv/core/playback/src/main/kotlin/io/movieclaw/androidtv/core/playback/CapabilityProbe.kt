@file:OptIn(UnstableApi::class)

package io.movieclaw.androidtv.core.playback

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.decoder.ffmpeg.FfmpegLibrary
import androidx.media3.exoplayer.audio.AudioCapabilities
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import io.movieclaw.androidtv.core.model.generated.AudioSupportIn
import io.movieclaw.androidtv.core.model.generated.ClientCapabilityIn
import io.movieclaw.androidtv.core.model.generated.VideoSupportIn

/**
 * 起播前查本机能做什么，作为能力快照随开会话上送（docs/design/androidtv-app.md §4.2）。
 *
 * 解码器按 Exo 自己会选的那份清单查（[MediaCodecUtil]），不是系统全量列表；
 * 音频再加上 HDMI 能透传的编码——透传的编码不需要本机能解。
 */
class CapabilityProbe(
    private val context: Context,
    /** 这台机器上实测坏过的解码器（[DecoderDenylist]）：不算进能力 */
    private val denied: (String) -> Boolean = { false },
) {

    fun probe(): ClientCapabilityIn {
        val (dolbyVision, baseLayer) = dolbyVision()
        return ClientCapabilityIn(
            video = videoSupport(),
            audio = audioSupport(),
            containers = CONTAINERS,
            hdrPassthrough = displaySupportsHdr(),
            mse = "none",
            isMobile = false,
            nativeHls = true,
            universal = false,
            discImage = false,
            discFolder = false,
            localTracks = true,
            dolbyVisionProfiles = dolbyVision.map(Int::toLong).sorted(),
            dolbyVisionBaseLayerProfiles = baseLayer.map(Int::toLong).sorted(),
        )
    }

    private fun decoders(mime: String) =
        runCatching { MediaCodecUtil.getDecoderInfos(mime, false, false) }.getOrDefault(emptyList()).filterNot { denied(it.name) }

    private fun videoSupport(): List<VideoSupportIn> = VIDEO_MIMES.mapNotNull { (codec, mime) ->
        val decoders = decoders(mime)
        val height = CapabilityRules.maxHeight(
            decoders.map { (it.capabilities?.videoCapabilities?.supportedHeights?.upper ?: 1080) to it.hardwareAccelerated },
        ) ?: return@mapNotNull null
        val hardware = decoders.any { it.hardwareAccelerated }
        VideoSupportIn(codec = codec, maxHeight = height.toLong(), smooth = true, powerEfficient = hardware)
    }

    /** （完整呈现的杜比视界 profile，能退回基础层的 profile） */
    private fun dolbyVision(): Pair<Set<Int>, Set<Int>> {
        val dv = decoders(MimeTypes.VIDEO_DOLBY_VISION)
        val profileBits = dv.flatMap { info -> info.capabilities?.profileLevels?.map { it.profile }.orEmpty() }
        val full = CapabilityRules.dolbyVisionProfiles(profileBits, displayHdrTypes().contains(HDR_TYPE_DOLBY_VISION))
        fun hardware(mime: String) = decoders(mime).any { it.hardwareAccelerated }
        val baseLayer = CapabilityRules.baseLayerProfiles(
            hevc = hardware(MimeTypes.VIDEO_H265), avc = hardware(MimeTypes.VIDEO_H264), av1 = hardware(MimeTypes.VIDEO_AV1),
        ) - full
        return full to baseLayer
    }

    @Suppress("DEPRECATION")
    private fun displayHdrTypes(): Set<Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return emptySet()
        val display = context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY) ?: return emptySet()
        return display.hdrCapabilities?.supportedHdrTypes?.toSet().orEmpty()
    }

    private fun audioSupport(): List<AudioSupportIn> {
        val passthrough = runCatching {
            AudioCapabilities.getCapabilities(context, AudioAttributes.DEFAULT, null)
        }.getOrNull()
        return AUDIO_CODECS.mapNotNull { (codec, mime, encoding) ->
            // 系统解码器、FFmpeg 软解（core:ffmpeg，编过 FFmpeg 才可用）、透传，三者有一样就能直放
            val decodable = decoders(mime).isNotEmpty() || ffmpegDecodes(mime)
            val passes = encoding != null && passthrough?.supportsEncoding(encoding) == true
            if (!decodable && !passes) return@mapNotNull null
            AudioSupportIn(codec = codec, maxChannels = 8)
        }
    }

    private fun displaySupportsHdr(): Boolean = displayHdrTypes().isNotEmpty()

    private fun ffmpegDecodes(mime: String): Boolean =
        runCatching { FfmpegLibrary.isAvailable() && FfmpegLibrary.supportsFormat(mime) }.getOrDefault(false)

    private data class AudioCodec(val codec: String, val mime: String, val encoding: Int?)

    private companion object {
        /** `Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION` */
        const val HDR_TYPE_DOLBY_VISION = 1

        /** Exo 能直接解封装的容器（服务端据此直连原文件，见 decide._resolve_tier）。 */
        val CONTAINERS = listOf("mp4", "mkv", "webm", "ts", "hls-fmp4")

        /** 服务端编码名（ffprobe 口径）→ MIME。 */
        val VIDEO_MIMES = listOf(
            "h264" to MimeTypes.VIDEO_H264,
            "hevc" to MimeTypes.VIDEO_H265,
            "av1" to MimeTypes.VIDEO_AV1,
            "vp9" to MimeTypes.VIDEO_VP9,
            "vp8" to MimeTypes.VIDEO_VP8,
            "mpeg2video" to MimeTypes.VIDEO_MPEG2,
            "mpeg4" to MimeTypes.VIDEO_MP4V,
            "vc1" to MimeTypes.VIDEO_VC1,
        )

        val AUDIO_CODECS = listOf(
            AudioCodec("aac", MimeTypes.AUDIO_AAC, null),
            AudioCodec("mp3", MimeTypes.AUDIO_MPEG, null),
            AudioCodec("mp2", MimeTypes.AUDIO_MPEG_L2, null),
            AudioCodec("opus", MimeTypes.AUDIO_OPUS, null),
            AudioCodec("vorbis", MimeTypes.AUDIO_VORBIS, null),
            AudioCodec("flac", MimeTypes.AUDIO_FLAC, null),
            AudioCodec("alac", MimeTypes.AUDIO_ALAC, null),
            AudioCodec("ac3", MimeTypes.AUDIO_AC3, C.ENCODING_AC3),
            AudioCodec("eac3", MimeTypes.AUDIO_E_AC3, C.ENCODING_E_AC3),
            AudioCodec("dts", MimeTypes.AUDIO_DTS, C.ENCODING_DTS),
            AudioCodec("truehd", MimeTypes.AUDIO_TRUEHD, C.ENCODING_DOLBY_TRUEHD),
        )
    }
}

/** 能力申报的纯规则（单测覆盖；取数的部分在 [CapabilityProbe]） */
object CapabilityRules {
    /** 软解码器最多申报到这个高度：电视 CPU 软解 1080p 的 H.264 / MPEG-2 尚可，软解 4K 必卡 */
    const val SOFTWARE_MAX_HEIGHT = 1080

    /** 一种编码能直放的最大高度：有硬解按硬解的上限，只有软解的封顶 1080p；一个解码器都没有返回 null */
    fun maxHeight(decoders: List<Pair<Int, Boolean>>): Int? {
        if (decoders.isEmpty()) return null
        val hardware = decoders.filter { it.second }.maxOfOrNull { it.first }
        val software = decoders.filter { !it.second }.maxOfOrNull { minOf(it.first, SOFTWARE_MAX_HEIGHT) }
        return listOfNotNull(hardware, software).max().coerceAtMost(4320)
    }

    /**
     * 杜比视界解码器申报的 profile（`CodecProfileLevel.DolbyVisionProfile*` 是按位的常量：P0 = 0x1 … P8 = 0x100，
     * profile 号 = 位序号）。屏幕不支持杜比视界时解出来也显示不对，一个都不算
     */
    fun dolbyVisionProfiles(profileBits: List<Int>, displaySupportsDolbyVision: Boolean): Set<Int> {
        if (!displaySupportsDolbyVision) return emptySet()
        return profileBits.filter { it > 0 && it and (it - 1) == 0 }.map(Integer::numberOfTrailingZeros).toSet()
    }

    /**
     * 解不了杜比视界时 Exo 会改用常规解码器解基础层的 profile（Media3 `MediaCodecUtil.getAlternativeCodecMimeType`：
     * P4 / P8 → HEVC、P9 → H.264、P10 → AV1）；要有对应的硬解码器
     */
    fun baseLayerProfiles(hevc: Boolean, avc: Boolean, av1: Boolean): Set<Int> = buildSet {
        if (hevc) addAll(listOf(4, 8))
        if (avc) add(9)
        if (av1) add(10)
    }
}
