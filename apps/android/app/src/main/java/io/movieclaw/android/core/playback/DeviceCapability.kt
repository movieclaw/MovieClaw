package io.movieclaw.android.core.playback

import android.content.Context
import android.media.MediaCodecList
import android.media.MediaFormat
import io.movieclaw.android.core.model.AudioSupportIn
import io.movieclaw.android.core.model.ClientCapabilityIn
import io.movieclaw.android.core.model.VideoSupportIn

/**
 * 设备解码能力探测,映射为服务端 capability(codec 用归一化家族名,
 * 服务端与 ffprobe codec_name 比对)。
 *
 * **按「能不能直读原文件」如实申报**（iOS `PlayerCapability` 同款两档）——服务端拿它
 * 决定档位:报少了**白白转码**,报多了会把放不了的原片直通回来。
 *
 * · [universal] = true(默认):本机有 mpv 内核,直读原文件、硬解不了的编码由它软解,
 *   属于"全解码播放器"。服务端直接给**档 0 原文件地址**,不逐项比对、不采样关键帧、
 *   不为一路用不上的换封装拉起 ffmpeg(NAS 实测冷启动白花 1.6 秒)。
 * · [universal] = false:只在**用户限了画质上限**时用——这时本来就要服务端压码率,
 *   按 Exo 内核真实能解的编码申报。
 *
 * 旧版一直报的是下面那套窄清单(注释里写着"MPV 内核就位后 universal 改为 true",
 * 一直没做),后果是:音轨里没有 ac3/eac3/dts(蓝光压制片最常见的三种)、
 * `hdrPassthrough=false`(任何 HDR 片都要服务端 tone-map)、容器只有 mkv/ts 没有
 * m2ts/avi —— 于是**几乎每部片都被判成转码**,播放页一直挂着"转码"。
 */
object DeviceCapability {

    fun probe(context: Context, universal: Boolean = true): ClientCapabilityIn =
        if (universal) universalCapability() else exoCapability()

    /**
     * 全解码(mpv 直读原文件)的能力清单。这些清单只在服务端不认 `universal` 时
     * (老服务端)才起作用,所以按引擎实际能解的解、报满即可。
     */
    private fun universalCapability() = ClientCapabilityIn(
        video = listOf("h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "mpeg4", "vc1").map {
            VideoSupportIn(
                codec = it,
                maxHeight = 2160,
                smooth = true,
                powerEfficient = it == "h264" || it == "hevc",
            )
        },
        // 只报「能原样装进 fMP4 分片」的编码(对应服务端 FMP4_COPY_AUDIO_CODECS):服务端
        // 据此给出的换封装计划才起得来。**不报 TrueHD**——报了服务端会计划"换壳成 HLS
        // fMP4 并原样拷贝 TrueHD",而 ffmpeg 的 MP4 封装不支持 TrueHD,转码进程启动即失败
        // (iOS 端在 NAS 上实测踩过;mpv 本机照样解 TrueHD/DTS/LPCM,不需要服务端知道)。
        audio = listOf("aac", "ac3", "eac3", "dts", "flac", "alac", "opus", "mp3").map {
            AudioSupportIn(codec = it, maxChannels = 8)
        },
        containers = listOf("mp4", "hls-fmp4", "mkv", "webm", "ts", "m2ts", "avi"),
        // HDR 不需要服务端 tone-map:屏幕是 HDR 时原样显示,屏幕不是时由本机处理
        // (mpv 内核做 tone-mapping;平台解码路径上 MediaCodec/SurfaceFlinger 也会把
        // HDR 映射到 SDR 输出)。报 false 的代价是**每部 HDR 片都被服务端转码一遍**。
        hdrPassthrough = true,
        isMobile = false,
        nativeHls = false,
        universal = true,
        // 镜像能读（`IsoBridge`：libudfread 解 UDF + 本机 m2ts 代理，见 cpp/iso_native.cpp），
        // 所以申报 discImage——服务端给原字节，我们在本机读盘内结构。
        discImage = true,
        // 目录**不申报**：那要求客户端解析 BDMV 目录清单与 MPLS 时间轴（iOS 自研引擎的能力），
        // 我们没做；不报则服务端按主播放列表拼成 HLS（只换封装、不重编码），放得动。
        discFolder = false,
    )

    /**
     * 用户限了画质上限时申报的能力:此时服务端必须转码压码率,别报 `universal`
     * (报了就直通原文件、上限形同虚设),按 Exo 内核真实能解的编码如实报。
     */
    private fun exoCapability(): ClientCapabilityIn {
        val decoders = runCatching {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.filter { !it.isEncoder }
        }.getOrDefault(emptyList())

        fun supports(mime: String): Boolean = decoders.any { info ->
            runCatching { info.supportedTypes.contains(mime) }.getOrDefault(false)
        }

        val video = buildList {
            add(VideoSupportIn(codec = "h264", maxHeight = 2160, smooth = true, powerEfficient = true))
            if (supports(MediaFormat.MIMETYPE_VIDEO_HEVC)) {
                add(VideoSupportIn(codec = "hevc", maxHeight = 2160, smooth = true, powerEfficient = true))
            }
            if (supports("video/x-vnd.on2.vp9")) {
                add(VideoSupportIn(codec = "vp9", maxHeight = 2160, smooth = true, powerEfficient = true))
            }
            if (supports("video/av01")) {
                add(VideoSupportIn(codec = "av1", maxHeight = 2160, smooth = true, powerEfficient = true))
            }
            if (supports(MediaFormat.MIMETYPE_VIDEO_MPEG2)) {
                add(VideoSupportIn(codec = "mpeg2video", maxHeight = 1080, smooth = false, powerEfficient = false))
            }
        }
        val audio = buildList {
            add(AudioSupportIn(codec = "aac", maxChannels = 8))
            add(AudioSupportIn(codec = "mp3", maxChannels = 2))
            // AC-3 / E-AC-3 在 Android 上没有保证（看机型有没有带杜比解码器），所以**探测**而不是猜：
            // 猜"没有"会让蓝光压制片在限了画质上限时白转一路音轨（档 2）
            if (supports(MediaFormat.MIMETYPE_AUDIO_AC3)) add(AudioSupportIn(codec = "ac3", maxChannels = 6))
            if (supports(MediaFormat.MIMETYPE_AUDIO_EAC3)) add(AudioSupportIn(codec = "eac3", maxChannels = 8))
            if (supports(MediaFormat.MIMETYPE_AUDIO_FLAC)) add(AudioSupportIn(codec = "flac", maxChannels = 8))
            if (supports(MediaFormat.MIMETYPE_AUDIO_OPUS)) add(AudioSupportIn(codec = "opus", maxChannels = 8))
        }
        return ClientCapabilityIn(
            video = video,
            audio = audio,
            containers = listOf("mp4", "m4v", "mkv", "webm", "ts", "mov", "flv"),
            hdrPassthrough = true,
            isMobile = true,
            nativeHls = true,
            universal = false,
            discImage = false,
            discFolder = false,
        )
    }
}
