@file:OptIn(UnstableApi::class)

package io.movieclaw.core.playback

import android.content.Context
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.BandwidthMeter
import androidx.media3.extractor.DefaultExtractorsFactory
import io.github.peerless2012.ass.media.AssHandler
import io.github.peerless2012.ass.media.kt.withAssMkvSupport
import io.github.peerless2012.ass.media.kt.withAssSupport
import io.github.peerless2012.ass.media.parser.AssSubtitleParserFactory

/**
 * 统一引擎的 Exo 配置（唯一一处）：正片（[PlaybackController]）与刷片片段（[ClipPlayer]）都从这里建播放器，
 * 解码器挑选、FFmpeg 音频软解、ASS 字幕、缓冲上限两边一致。
 */
object UnifiedExo {

    /** 缓冲档：内存上限只在这里管 */
    enum class Buffer {
        /** 正片与当前片段：字节上限跟着本进程的堆走，时长用 Exo 默认 */
        Main,

        /** 预起的下一条片段：装载到起点停着就好，不往前多吃（12 MB / 最长 4 秒） */
        Standby,
    }

    fun build(
        context: Context,
        dataSource: DataSource.Factory,
        denylist: DecoderDenylist,
        /** ASS / SSA 特效字幕走 libass；片段不画内封字幕时传 null */
        ass: AssHandler?,
        bandwidth: BandwidthMeter? = null,
        buffer: Buffer = Buffer.Main,
    ): ExoPlayer {
        val renderers = DefaultRenderersFactory(context)
            // 扩展（FFmpeg 音频软解）排在系统解码器之后：系统能解、或能透传给电视 / 功放的（AC3 / E-AC-3 全景声 /
            // TrueHD）照旧走系统，FFmpeg 只兜底两者都不行的。PREFER 会让 FFmpeg 抢先解成 PCM，透传就没了
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)
            // 这台机器上实测坏过的解码器不再选（DecoderDenylist）
            .setMediaCodecSelector { mime, secure, tunneling ->
                MediaCodecSelector.DEFAULT.getDecoderInfos(mime, secure, tunneling).filterNot { denylist.isDenied(it.name) }
            }
            .let { if (ass != null) it.withAssSupport(ass) else it }
        val sources = if (ass != null) {
            // MKV 里的 ASS 轨与外挂的 .ass 都交给 libass 解析（其余字幕照旧走 Exo）
            val parsers = AssSubtitleParserFactory(ass)
            DefaultMediaSourceFactory(dataSource, DefaultExtractorsFactory().withAssMkvSupport(parsers, ass))
                .setSubtitleParserFactory(parsers)
        } else {
            DefaultMediaSourceFactory(dataSource)
        }
        val loadControl = when (buffer) {
            // 缓冲字节上限跟着本进程的堆走（Exo 的缓冲在 Java 堆里）：默认上限约 130 MB，小堆的盒子放高码率片直接
            // 内存溢出（Android 6 镜像堆上限 48 MB，《老友记》播放即崩）
            Buffer.Main -> DefaultLoadControl.Builder()
                .setTargetBufferBytes(BufferBudget.targetBytes(Runtime.getRuntime().maxMemory()))
                .setPrioritizeTimeOverSizeThresholds(false)
                .build()
            Buffer.Standby -> DefaultLoadControl.Builder()
                .setTargetBufferBytes(BufferBudget.STANDBY_BYTES)
                .setBufferDurationsMs(2_000, 4_000, 1_000, 2_000)
                .setPrioritizeTimeOverSizeThresholds(false)
                .build()
        }
        return ExoPlayer.Builder(context, renderers)
            .setMediaSourceFactory(sources)
            .apply { if (bandwidth != null) setBandwidthMeter(bandwidth) }
            .setLoadControl(loadControl)
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                true,
            )
            .build()
            .also { player -> ass?.init(player) }
    }
}
