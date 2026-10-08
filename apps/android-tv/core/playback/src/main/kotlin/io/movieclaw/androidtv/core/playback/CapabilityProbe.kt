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
class CapabilityProbe(private val context: Context) {

    fun probe(): ClientCapabilityIn = ClientCapabilityIn(
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
    )

    private fun videoSupport(): List<VideoSupportIn> = VIDEO_MIMES.mapNotNull { (codec, mime) ->
        val decoders = runCatching { MediaCodecUtil.getDecoderInfos(mime, false, false) }.getOrDefault(emptyList())
        if (decoders.isEmpty()) return@mapNotNull null
        val hardware = decoders.any { it.hardwareAccelerated }
        val maxHeight = decoders.maxOf { info ->
            info.capabilities?.videoCapabilities?.supportedHeights?.upper ?: 1080
        }
        VideoSupportIn(
            codec = codec,
            maxHeight = maxHeight.coerceAtMost(4320).toLong(),
            // 只有软解时 4K 多半跟不上，交给服务端按高度判断降档
            smooth = hardware || maxHeight <= 1080,
            powerEfficient = hardware,
        )
    }

    private fun audioSupport(): List<AudioSupportIn> {
        val passthrough = runCatching {
            AudioCapabilities.getCapabilities(context, AudioAttributes.DEFAULT, null)
        }.getOrNull()
        return AUDIO_CODECS.mapNotNull { (codec, mime, encoding) ->
            val decodable = runCatching { MediaCodecUtil.getDecoderInfos(mime, false, false).isNotEmpty() }
                .getOrDefault(false)
            val passes = encoding != null && passthrough?.supportsEncoding(encoding) == true
            if (!decodable && !passes) return@mapNotNull null
            AudioSupportIn(codec = codec, maxChannels = 8)
        }
    }

    @Suppress("DEPRECATION")
    private fun displaySupportsHdr(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        val display = context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)
            ?: return false
        return display.hdrCapabilities?.supportedHdrTypes?.isNotEmpty() == true
    }

    private data class AudioCodec(val codec: String, val mime: String, val encoding: Int?)

    private companion object {
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
