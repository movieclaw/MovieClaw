@file:OptIn(UnstableApi::class)

package io.movieclaw.core.playback

import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer

/** 实验台注入的播放故障：只由调试包的启动参数设置（MainActivity），正式包里恒为空、什么都不包 */
object LabFaults {
    /**
     * 音轨是这些 MIME（如 `audio/ac3`）时音频输出不再收数据：播放头停在原地、缓冲照涨，与小米电视放 AC3 时
     * 一样（#906）。模拟器靠 FFmpeg 软解放 AC3 一切正常，没有它复现不了那条降档阶梯。播放器建好时生效
     */
    @Volatile var stallAudioMimes: Set<String> = emptySet()

    internal fun audioStall(): AudioStall? = stallAudioMimes.takeIf { it.isNotEmpty() }?.let(::AudioStall)

    /** 一个播放器一份：音轨格式由 [listener] 记下，[wrap] 出来的输出据此决定收不收数据 */
    internal class AudioStall(private val mimes: Set<String>) {
        // 格式事件晚于头几块数据到达：先卡着，认出不是要卡的格式再放行，免得卡的那一路先出几百毫秒声
        @Volatile private var stalled = true

        val listener = object : AnalyticsListener {
            override fun onAudioInputFormatChanged(
                eventTime: AnalyticsListener.EventTime, format: Format, decoderReuseEvaluation: DecoderReuseEvaluation?,
            ) {
                stalled = format.sampleMimeType in mimes
                if (stalled) EngineLog.add("lab", "实验台：${format.sampleMimeType} 的音频输出卡住")
            }
        }

        fun wrap(sink: AudioSink): AudioSink = object : ForwardingAudioSink(sink) {
            override fun handleBuffer(buffer: ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean =
                !stalled && super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
        }
    }
}
