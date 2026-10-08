package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * 播放协议模型,字段与服务端 schemas/playback.py 一一对应。
 * capability.codec 用归一化编码家族名(h264/hevc/aac…),服务端与 ffprobe codec_name 比对。
 */

@Serializable
data class VideoSupportIn(
    val codec: String,
    val maxHeight: Int = 2160,
    val smooth: Boolean = true,
    val powerEfficient: Boolean = true,
)

@Serializable
data class AudioSupportIn(
    val codec: String,
    val maxChannels: Int = 8,
)

@Serializable
data class ClientCapabilityIn(
    val video: List<VideoSupportIn> = emptyList(),
    val audio: List<AudioSupportIn> = emptyList(),
    val containers: List<String> = emptyList(),
    val hdrPassthrough: Boolean = false,
    val mse: String = "full",
    val isMobile: Boolean = true,
    val nativeHls: Boolean = true,
    /** 全解码引擎(MPV 内核就位后 = true);Exo 单内核如实报 false 走逐项比对 */
    val universal: Boolean = false,
    val discImage: Boolean = false,
    val discFolder: Boolean = false,
)

@Serializable
data class PlaybackDecideRequest(
    val fileId: Long? = null,
    val mediaItemId: Long? = null,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val capability: ClientCapabilityIn,
    val failedTiers: List<Int> = emptyList(),
    val audioTrack: String? = null,
    val subtitleTrack: String? = null,
    val maxHeight: Int? = null,
    val deviceId: String? = null,
    val downlinkBps: Long? = null,
)

/** 服务端 PlaybackSessionRequest 继承 DecideRequest;客户端发扁平 JSON */
@Serializable
data class PlaybackSessionRequest(
    val fileId: Long? = null,
    val mediaItemId: Long? = null,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val capability: ClientCapabilityIn,
    val failedTiers: List<Int> = emptyList(),
    val audioTrack: String? = null,
    val subtitleTrack: String? = null,
    val maxHeight: Int? = null,
    val deviceId: String? = null,
    val downlinkBps: Long? = null,
    /** null = 服务端按观看状态定续播点;显式 0 = 从头播 */
    val startMs: Long? = null,
    val attemptId: String? = null,
    val client: String = "android",
)

@Serializable
data class VideoPlanView(
    val action: String? = null,
    val codec: String? = null,
    val height: Int? = null,
    val toneMap: Boolean = false,
    val bitrateCapBps: Long? = null,
    val burnSubtitle: String? = null,
)

@Serializable
data class AudioPlanView(
    val action: String? = null,
    val trackRef: String? = null,
    val codec: String? = null,
    val channels: Int? = null,
    val downmix: Boolean? = null,
)

@Serializable
data class AudioTrackView(
    // 服务端这条是 `ref`（不是 `track_ref`，与字幕的 SubtitlePlanView 故意不同）：
    // 不加这一行，track_ref 永远解不出来 → 音轨只能退回"按序号猜"的 embedded:N
    @kotlinx.serialization.SerialName("ref")
    val trackRef: String? = null,
    val language: String? = null,
    /** 标签要显示编码（H264 · 5.1 这类），服务端这条字段是真的 */
    val codec: String? = null,
    val channels: Int? = null,
    val isDefault: Boolean = false,
)

@Serializable
data class SubtitlePlanView(
    val trackRef: String? = null,
    val kind: String? = null,
    val language: String? = null,
    val isDefault: Boolean = false,
    val isAi: Boolean = false,
    /** 文件自带的轨标题（「简体中文」「简英双语」这类，比语言码更准）；旧服务端没有这个字段 */
    val title: String? = null,
    /** 强制轨（forced）。可选字段：旧服务端缺字段时按非强制展示（同 iOS 口径） */
    val isForced: Boolean? = null,
)

@Serializable
data class PlaybackDecisionView(
    val outcome: String,
    val tier: Int? = null,
    val fileId: Long? = null,
    val container: String? = null,
    val video: VideoPlanView? = null,
    val audio: AudioPlanView? = null,
    val audioTracks: List<AudioTrackView> = emptyList(),
    val subtitles: List<SubtitlePlanView> = emptyList(),
    val degradedFrom: Int? = null,
    val disc: String? = null,
    val discPlaylist: String? = null,
    val costHint: String? = null,
    val canSelfEnable: Boolean? = null,
    val reason: String = "",
    val suggestion: String? = null,
)

@Serializable
data class PlaybackStateView(
    val positionMs: Long = 0,
    val played: Boolean = false,
    val playCount: Int = 0,
    val durationMs: Long? = null,
    val audioTrack: String? = null,
    val subtitleTrack: String? = null,
    val endedByAdmin: Boolean = false,
)

@Serializable
data class PlaybackSourceView(
    val container: String? = null,
    val resolution: String? = null,
    val videoCodec: String? = null,
    val hdr: String? = null,
    /** 总码率(bps);探测不出为 null */
    val bitRate: Long? = null,
    val frameRate: Float? = null,
    val sizeBytes: Long? = null,
) {
    /** "3840x2160" → 2160 */
    fun height(): Int? = resolution?.substringAfterLast('x')?.toIntOrNull()
}

/**
 * 可跳过的一段（服务端整季比对认出来的，客户端只管用；docs/design/skip-intro.md）：
 * - `intro` 片头：区间里显示「跳过片头」，点了跳到 end_ms；
 * - `outro` 片尾：到 start_ms 提前显示「即将播放下一集」；to_end 为假时片尾后面
 *   还有内容（下集预告、彩蛋），按钮是「跳过片尾」；
 * - `other` 其他重复段（片头前的冠名广告、发行许可）：观众眼里也是片头，同「跳过片头」。
 */
@Serializable
data class PlaybackSegmentView(
    val type: String = "",
    val startMs: Long = 0,
    val endMs: Long = 0,
    /** 片尾一直放到文件结尾（只有 outro 有意义） */
    val toEnd: Boolean = false,
)

/**
 * MKV 精简索引（只含视频轨索引点的 Cues 元素）：档 0 直出的 MKV 随会话下发，
 * 引擎解复用器读 SeekHead 登记的 Cues 位置时直接给这份，不必再下载原索引
 * （字幕轨多的片子原索引有几百 KB 到几 MB）。索引点数值与原文件逐位一致。
 */
@Serializable
data class MatroskaCuesView(
    /** Cues 元素在文件里的绝对位置；核对它与文件头里 SeekHead 登记的位置一致才用 */
    val offset: Long = 0,
    /** 精简后的整个 Cues 元素（含元素头），base64 */
    val data: String = "",
    /** 原 Cues 元素多少字节（诊断用） */
    val originalBytes: Long = 0,
)

@Serializable
data class PlaybackSessionView(
    val decision: PlaybackDecisionView,
    val sessionId: String? = null,
    val streamUrl: String? = null,
    val startMs: Long = 0,
    /** session = 流从 0 起(文件时间 = startMs + position);file = 分片即文件绝对时间 */
    val timeline: String = "session",
    val subtitleUrls: List<String> = emptyList(),
    val masterUrl: String? = null,
    val hwBackend: String? = null,
    val watch: PlaybackStateView? = null,
    /** 源文件客观规格(诊断与降质建议的「需要的码率」来源) */
    val source: PlaybackSourceView? = null,
    /**
     * 片头/片尾/其他可跳过的段（剧集库开了「识别片头片尾」且这一季识别过才有）。
     * 新服务端恒为数组（没有就是空表）；声明成可空只为对旧服务端宽容——
     * 非可选字段缺失会让整个会话解码失败、起不了播
     */
    val segments: List<PlaybackSegmentView>? = null,
    /** 档 0 直出的 MKV：服务端缓存里有精简索引时随会话下发（没有就在后台生成，给下次用） */
    val matroskaCues: MatroskaCuesView? = null,
)

@Serializable
data class PlaybackProgressRequest(
    val mediaItemId: Long,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val event: String = "progress",
    /** null = 没报(视同播完);与报 0(拖回开头)语义不同 */
    val positionMs: Long? = null,
    val audioTrack: String? = null,
    val subtitleTrack: String? = null,
    val fileId: Long? = null,
    val deviceId: String? = null,
    val paused: Boolean? = null,
)

@Serializable
data class PlaybackPolicyPatch(
    val softwareTranscodeEnabled: Boolean,
)

/** QoE 上报载荷(字段与服务端 PlaybackMetricPayload 对齐;未采集项留空/0) */
@Serializable
data class PlaybackMetricPayload(
    val tier: Int = 0,
    val degradedFrom: Int? = null,
    val engine: String = "",
    val hwBackend: String = "",
    val ttffMs: Int? = null,
    val rebufferMs: Long = 0,
    val rebufferCount: Int = 0,
    val seekCount: Int = 0,
    val droppedFrames: Int? = null,
    val totalFrames: Int? = null,
    val watchedMs: Long = 0,
    val attemptId: String? = null,
    val outcome: String = "",
    val mediaItemId: Long? = null,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val origin: String = "",
    val client: String = "android",
    val networkClass: String = "",
    val appVersion: String = "",
    val firstFrameMs: Int? = null,
    val playingMs: Int? = null,
    val userWaitMs: Long = 0,
    val errorKind: String = "",
    val errorCategory: String = "",
    val errorStage: String = "",
)

/** trickplay 雪碧图信息 */
@Serializable
data class TrickplayView(
    val ready: Boolean = false,
    val intervalMs: Int = 0,
    val tileWidth: Int = 0,
    val tileHeight: Int = 0,
    val columns: Int = 0,
    val rows: Int = 0,
    val count: Int = 0,
    val sheets: List<String> = emptyList(),
)

/** GET/POST /playback/marks */
@Serializable
data class PlaybackMarks(
    val played: Boolean = false,
    val isFavorite: Boolean = false,
    /** 整剧 / 整季尚未看完的集数；电影与单集为 null */
    val unplayedCount: Int? = null,
)

@Serializable
data class PlaybackMarksRequest(
    val mediaItemId: Long,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val played: Boolean? = null,
    val favorite: Boolean? = null,
    val deviceId: String? = null,
)
