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

/** GET /playback/items/{media_item_id}（服务端 `PlaybackItemView`：播放页/条目卡要的条目信息） */
@Serializable
data class PlaybackItemView(
    val mediaItemId: Long = 0,
    /** 库归属由服务端按成员可见性解析（播放路由只带 media_item_id） */
    val libraryId: Long = 0,
    /** movie / tv */
    val kind: String = "movie",
    val title: String = "",
    val year: Int? = null,
    /** 海报（本地刮削资产优先、TMDB 兜底） */
    val posterUrl: String? = null,
)
