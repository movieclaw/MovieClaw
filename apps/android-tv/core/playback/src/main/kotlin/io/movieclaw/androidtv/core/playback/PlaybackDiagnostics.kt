@file:OptIn(UnstableApi::class)

package io.movieclaw.androidtv.core.playback

import android.app.ActivityManager
import android.content.Context
import android.hardware.display.DisplayManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import android.view.Display
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioCapabilities
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

/**
 * 真机诊断的现场材料（种子用户的电视上出了问题，靠这些还原）：
 *
 * - [EngineLog]：播放器关键事件的环形缓冲（最近 300 行，每行 ≤ 400 字），失败 / 卡顿 / 异常退出时取最近 ≤ 32 KB 随记录上报；
 * - [DeviceFacts]：机型、芯片、系统、显示器（分辨率 / 刷新率 / HDR 类型）、音频输出设备与 HDMI 能透传的编码、解码器清单；
 * - [EngineFacts]：Exo 实际选的解码器、输入格式、音频是透传还是解码（从分析回调里拿，平时只是记几个字段）。
 *
 * 开销：都是事件驱动的字段赋值与一行字符串；设备快照每个进程只算一次。
 */
object EngineLog {
    private const val MAX_LINES = 300
    private const val MAX_LINE = 400
    private const val MAX_TAIL = 32 * 1024
    private val lines = ArrayDeque<String>()
    private val clock = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    @Synchronized
    fun add(tag: String, text: String) {
        val line = "${clock.format(Date())} [$tag] $text".take(MAX_LINE)
        if (lines.size >= MAX_LINES) lines.removeFirst()
        lines.addLast(line)
    }

    /** 最近的若干行，总长不超过 32 KB（UTF-8） */
    @Synchronized
    fun tail(): String {
        val out = ArrayDeque<String>()
        var bytes = 0
        for (line in lines.descendingIterator()) {
            val size = line.toByteArray().size + 1
            if (bytes + size > MAX_TAIL) break
            bytes += size
            out.addFirst(line)
        }
        return out.joinToString("\n")
    }

    @Synchronized
    fun clear() = lines.clear()
}

/** Exo 实际在用的东西（分析回调里拿），规格快照与日志都从这里取 */
class EngineFacts : AnalyticsListener {
    var videoDecoder: String? = null
        private set
    var audioDecoder: String? = null
        private set
    var videoFormat: Format? = null
        private set
    var audioFormat: Format? = null
        private set

    /** 音频交给系统时的编码：PCM = 本机解码；AC3 / E-AC-3 / DTS / TrueHD = 透传给电视 / 功放 */
    var audioOutputEncoding: Int? = null
        private set
    var audioOutputChannels: Int? = null
        private set
    var audioTunneling = false
        private set
    var audioUnderruns = 0
        private set

    fun reset() {
        videoDecoder = null
        audioDecoder = null
        videoFormat = null
        audioFormat = null
        audioOutputEncoding = null
        audioOutputChannels = null
        audioTunneling = false
        audioUnderruns = 0
    }

    override fun onVideoDecoderInitialized(eventTime: AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
        videoDecoder = decoderName
        EngineLog.add("exo", "视频解码器 $decoderName（初始化 $initializationDurationMs 毫秒）")
    }

    override fun onAudioDecoderInitialized(eventTime: AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
        audioDecoder = decoderName
        EngineLog.add("exo", "音频解码器 $decoderName")
    }

    override fun onVideoInputFormatChanged(eventTime: AnalyticsListener.EventTime, format: Format, decoderReuseEvaluation: DecoderReuseEvaluation?) {
        videoFormat = format
        EngineLog.add("exo", "视频格式 ${describe(format)}")
    }

    override fun onAudioInputFormatChanged(eventTime: AnalyticsListener.EventTime, format: Format, decoderReuseEvaluation: DecoderReuseEvaluation?) {
        audioFormat = format
        EngineLog.add("exo", "音频格式 ${describe(format)}")
    }

    override fun onAudioTrackInitialized(eventTime: AnalyticsListener.EventTime, audioTrackConfig: AudioSink.AudioTrackConfig) {
        audioOutputEncoding = audioTrackConfig.encoding
        audioOutputChannels = Integer.bitCount(audioTrackConfig.channelConfig)
        audioTunneling = audioTrackConfig.tunneling
        EngineLog.add(
            "exo",
            "音频输出 ${encodingName(audioTrackConfig.encoding)} ${audioOutputChannels}ch ${audioTrackConfig.sampleRate}Hz" +
                (if (audioTrackConfig.tunneling) " tunneling" else "") + (if (audioTrackConfig.offload) " offload" else ""),
        )
    }

    override fun onAudioUnderrun(eventTime: AnalyticsListener.EventTime, bufferSize: Int, bufferSizeMs: Long, elapsedSinceLastFeedMs: Long) {
        audioUnderruns += 1
        if (audioUnderruns <= 20) EngineLog.add("exo", "音频欠载（缓冲 $bufferSizeMs 毫秒，距上次喂数据 $elapsedSinceLastFeedMs 毫秒）")
    }

    override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
        EngineLog.add("exo", "掉帧 $droppedFrames（$elapsedMs 毫秒内）")
    }

    override fun onAudioSinkError(eventTime: AnalyticsListener.EventTime, audioSinkError: Exception) {
        EngineLog.add("exo", "音频输出出错：${chain(audioSinkError)}")
    }

    override fun onVideoCodecError(eventTime: AnalyticsListener.EventTime, videoCodecError: Exception) {
        EngineLog.add("exo", "视频解码出错：${chain(videoCodecError)}")
    }

    override fun onAudioCodecError(eventTime: AnalyticsListener.EventTime, audioCodecError: Exception) {
        EngineLog.add("exo", "音频解码出错：${chain(audioCodecError)}")
    }

    override fun onPlayerError(eventTime: AnalyticsListener.EventTime, error: PlaybackException) {
        EngineLog.add("exo", "播放器错误 ${error.errorCodeName}：${chain(error)}")
    }

    override fun onBandwidthEstimate(eventTime: AnalyticsListener.EventTime, totalLoadTimeMs: Int, totalBytesLoaded: Long, bitrateEstimate: Long) = Unit

    /** 当前视频的动态范围：sdr / hdr10 / hlg / dolbyvision（按 Exo 解码的那一路） */
    val videoRange: String?
        get() {
            val format = videoFormat ?: return null
            if (format.sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION) return "dolbyvision"
            return when (format.colorInfo?.colorTransfer) {
                C.COLOR_TRANSFER_ST2084 -> "hdr10"
                C.COLOR_TRANSFER_HLG -> "hlg"
                else -> "sdr"
            }
        }

    val audioPassthrough: Boolean
        get() = audioOutputEncoding?.let { it != C.ENCODING_PCM_16BIT && it != C.ENCODING_PCM_FLOAT && it != C.ENCODING_PCM_24BIT && it != C.ENCODING_PCM_32BIT && it != C.ENCODING_INVALID } ?: false

    companion object {
        fun describe(format: Format): String = buildString {
            append(format.sampleMimeType ?: "?")
            format.codecs?.let { append(" ").append(it) }
            if (format.width > 0) append(" ${format.width}x${format.height}")
            if (format.frameRate > 0) append(" ${"%.3f".format(Locale.US, format.frameRate)}fps")
            format.colorInfo?.let { append(" color(transfer=${it.colorTransfer} space=${it.colorSpace} range=${it.colorRange})") }
            if (format.channelCount > 0) append(" ${format.channelCount}ch")
            if (format.sampleRate > 0) append(" ${format.sampleRate}Hz")
            if (format.bitrate > 0) append(" ${format.bitrate / 1000}kbps")
            format.language?.let { append(" lang=$it") }
        }

        fun encodingName(encoding: Int): String = when (encoding) {
            C.ENCODING_PCM_16BIT -> "pcm16"
            C.ENCODING_PCM_FLOAT -> "pcm_float"
            C.ENCODING_PCM_24BIT -> "pcm24"
            C.ENCODING_PCM_32BIT -> "pcm32"
            C.ENCODING_AC3 -> "ac3"
            C.ENCODING_E_AC3 -> "eac3"
            C.ENCODING_E_AC3_JOC -> "eac3_joc"
            C.ENCODING_AC4 -> "ac4"
            C.ENCODING_DTS -> "dts"
            C.ENCODING_DTS_HD -> "dts_hd"
            C.ENCODING_DOLBY_TRUEHD -> "truehd"
            else -> "encoding_$encoding"
        }

        /** 异常链：类名 + 信息，逐层往下（真机上底层 MediaCodec 的诊断信息在里层） */
        fun chain(error: Throwable): String {
            val parts = mutableListOf<String>()
            var current: Throwable? = error
            while (current != null && parts.size < 5) {
                parts.add("${current.javaClass.simpleName}: ${current.message ?: ""}".trim())
                current = current.cause
            }
            return parts.joinToString(" ← ")
        }
    }
}

/** 设备级的事实（每个进程算一次；显示模式随帧率匹配会变，单独取 [currentDisplay]） */
class DeviceFacts(private val context: Context) {

    val snapshot: JsonObject by lazy {
        buildJsonObject {
            put("manufacturer", Build.MANUFACTURER)
            put("brand", Build.BRAND)
            put("model", Build.MODEL)
            put("device", Build.DEVICE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                put("soc", "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}")
            } else {
                put("soc", Build.HARDWARE)
            }
            put("sdk", Build.VERSION.SDK_INT)
            put("os", Build.VERSION.RELEASE)
            put("display", display())
            put("audio", audio())
            put("decoders", decoders())
            put("memory", memory())
        }
    }

    private fun defaultDisplay(): Display? =
        context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)

    @Suppress("DEPRECATION")
    private fun display(): JsonObject = buildJsonObject {
        val display = defaultDisplay() ?: return@buildJsonObject
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            put("modes", JsonArray(display.supportedModes.map { JsonPrimitive(modeLabel(it)) }.distinct()))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            put("hdr_types", JsonArray((display.hdrCapabilities?.supportedHdrTypes ?: IntArray(0)).map { JsonPrimitive(hdrTypeName(it)) }))
            display.hdrCapabilities?.let { put("max_luminance", it.desiredMaxLuminance) }
        }
    }

    /** 当前显示模式（「3840x2160@23.976」），帧率匹配切换后会变 */
    fun currentDisplay(): String? {
        val display = defaultDisplay() ?: return null
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) modeLabel(display.mode) else null
    }

    @Suppress("DEPRECATION")
    fun displayHdr(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        return defaultDisplay()?.hdrCapabilities?.supportedHdrTypes?.isNotEmpty() == true
    }

    /**
     * 当前音频输出：hdmi / hdmi_arc / bluetooth / usb / speaker / other。eARC 记 hdmi：它能传无损（TrueHD），服务端
     * 规格损失规则按 hdmi 判「无损变有损」；ARC 只能传有损的 DD / DTS 核心，单列，不算损失。原始设备类型在设备快照里
     */
    fun audioRoute(): String {
        val manager = context.getSystemService(AudioManager::class.java) ?: return "other"
        val types = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type }.toSet()
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && AudioDeviceInfo.TYPE_HDMI_EARC in types -> "hdmi"
            AudioDeviceInfo.TYPE_HDMI_ARC in types -> "hdmi_arc"
            AudioDeviceInfo.TYPE_HDMI in types -> "hdmi"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP in types -> "bluetooth"
            AudioDeviceInfo.TYPE_USB_DEVICE in types || AudioDeviceInfo.TYPE_USB_HEADSET in types -> "usb"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER in types -> "speaker"
            else -> "other"
        }
    }

    private fun audio(): JsonObject = buildJsonObject {
        val manager = context.getSystemService(AudioManager::class.java)
        val outputs = manager?.getDevices(AudioManager.GET_DEVICES_OUTPUTS).orEmpty()
        put("outputs", JsonArray(outputs.map { device ->
            buildJsonObject {
                put("type", device.type)
                put("name", device.productName?.toString() ?: "")
                put("encodings", JsonArray(device.encodings.map { JsonPrimitive(EngineFacts.encodingName(it)) }))
                put("channels", JsonArray(device.channelCounts.map { JsonPrimitive(it) }))
            }
        }))
        val caps = runCatching { AudioCapabilities.getCapabilities(context, AudioAttributes.DEFAULT, null) }.getOrNull()
        if (caps != null) {
            put("passthrough", JsonArray(PASSTHROUGH.filter { caps.supportsEncoding(it) }.map { JsonPrimitive(EngineFacts.encodingName(it)) }))
            put("max_channels", caps.maxChannelCount)
        }
    }

    private fun decoders(): JsonObject = buildJsonObject {
        for ((codec, mime) in DECODER_MIMES) {
            val infos = runCatching { MediaCodecUtil.getDecoderInfos(mime, false, false) }.getOrDefault(emptyList())
            if (infos.isEmpty()) continue
            put(codec, JsonArray(infos.map { info ->
                val heights = info.capabilities?.videoCapabilities?.supportedHeights?.upper
                JsonPrimitive(info.name + (if (info.hardwareAccelerated) " hw" else " sw") + (heights?.let { " ≤${it}p" } ?: ""))
            }))
        }
    }

    private fun memory(): JsonObject = buildJsonObject {
        val manager = context.getSystemService(ActivityManager::class.java) ?: return@buildJsonObject
        val info = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
        put("total_mb", info.totalMem / (1 shl 20))
        put("class_mb", manager.memoryClass)
        put("low_ram", manager.isLowRamDevice)
    }

    /** 当前网络接口：wifi / wired / cellular / other */
    fun networkInterface(): String {
        val manager = context.getSystemService(android.net.ConnectivityManager::class.java) ?: return "other"
        val caps = runCatching { manager.getNetworkCapabilities(manager.activeNetwork) }.getOrNull() ?: return "other"
        return when {
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) -> "wired"
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "other"
        }
    }

    /** 本进程用了多少内存（Java 堆 + 原生堆，毫秒级的轻量读数，不走 PSS） */
    fun memoryMb(): Long {
        val runtime = Runtime.getRuntime()
        val java = runtime.totalMemory() - runtime.freeMemory()
        return (java + android.os.Debug.getNativeHeapAllocatedSize()) / (1 shl 20)
    }

    /** 发热状态（0 正常 … 6 关机），API 29 以下 null */
    fun thermal(): Int? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) context.getSystemService(PowerManager::class.java)?.currentThermalStatus else null

    private companion object {
        val PASSTHROUGH = listOf(
            C.ENCODING_AC3, C.ENCODING_E_AC3, C.ENCODING_E_AC3_JOC, C.ENCODING_AC4, C.ENCODING_DTS, C.ENCODING_DTS_HD, C.ENCODING_DOLBY_TRUEHD,
        )
        val DECODER_MIMES = listOf(
            "h264" to MimeTypes.VIDEO_H264,
            "hevc" to MimeTypes.VIDEO_H265,
            "dolbyvision" to MimeTypes.VIDEO_DOLBY_VISION,
            "av1" to MimeTypes.VIDEO_AV1,
            "vp9" to MimeTypes.VIDEO_VP9,
            "mpeg2" to MimeTypes.VIDEO_MPEG2,
            "vc1" to MimeTypes.VIDEO_VC1,
            "eac3" to MimeTypes.AUDIO_E_AC3,
            "ac3" to MimeTypes.AUDIO_AC3,
            "dts" to MimeTypes.AUDIO_DTS,
            "truehd" to MimeTypes.AUDIO_TRUEHD,
        )

        fun modeLabel(mode: Display.Mode): String = "${mode.physicalWidth}x${mode.physicalHeight}@${"%.3f".format(Locale.US, mode.refreshRate)}"

        fun hdrTypeName(type: Int): String = when (type) {
            1 -> "dolbyvision"
            2 -> "hdr10"
            3 -> "hlg"
            4 -> "hdr10plus"
            else -> "type_$type"
        }
    }
}
