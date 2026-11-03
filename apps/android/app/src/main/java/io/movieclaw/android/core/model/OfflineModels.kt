package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/* ---------------- 离线下载（docs/design/offline-download.md；服务端 routes/offline.py） ---------------- */

/**
 * GET /offline/manifest：一个播放单元打包所需的一切。展示数据（详情、库、这一季的分集）与播放数据
 * （章节、片段、音轨）原样留成 JSON，打包时原样存盘，离线时由同一个页面 / 播放器解码（iOS 同做法）。
 */
@Serializable
data class OfflineManifest(
    val fileId: Long = 0,
    val mediaItemId: Long = 0,
    val libraryId: Long = 0,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val container: String? = null,
    val sizeBytes: Long = 0,
    val durationMs: Long? = null,
    /** LibraryItemDetailView 原样 */
    val item: JsonElement? = null,
    /** LibraryView 原样 */
    val library: JsonElement? = null,
    /** 剧集：这一集所在季的 SeasonEpisodesView 原样 */
    val season: JsonElement? = null,
    val chapters: JsonElement? = null,
    val segments: JsonElement? = null,
    val audioTracks: JsonElement? = null,
    val defaultAudio: String? = null,
    val defaultSubtitle: String? = null,
    val subtitles: List<OfflineSubtitleRef> = emptyList(),
    val fontsUrl: String? = null,
    val profiles: List<OfflineProfile> = emptyList(),
    val unavailableReason: String? = null,
    val resumePositionMs: Long? = null,
)

@Serializable
data class OfflineSubtitleRef(
    val trackRef: String = "",
    /** 存盘格式：srt / ass / ssa / vtt */
    val format: String = "",
    val language: String? = null,
    val title: String? = null,
    val isDefault: Boolean = false,
    val isForced: Boolean = false,
    val isAi: Boolean = false,
    /** 内封轨抽出来的（原画档不用下，引擎直接读文件里的） */
    val embedded: Boolean = false,
    val url: String? = null,
)

@Serializable
data class OfflineProfile(
    val profile: String = "",
    val label: String = "",
    val height: Int? = null,
    val expectedBytes: Long = 0,
)

/** POST /offline/profiles：选档表单一次问一批文件的可选档位与预计大小 */
@Serializable
data class OfflineProfilesRequest(
    val fileIds: List<Long>,
)

@Serializable
data class OfflineFileProfiles(
    val fileId: Long = 0,
    val mediaItemId: Long = 0,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val container: String? = null,
    val profiles: List<OfflineProfile>? = null,
    val unavailableReason: String? = null,
)

@Serializable
data class OfflineProfilesView(
    val files: List<OfflineFileProfiles>? = null,
)

/** POST /offline/exports：建或复用一个转码导出 */
@Serializable
data class OfflineExportRequest(
    val fileId: Long,
    val profile: String,
    val audioTrack: String? = null,
)

@Serializable
data class OfflineExport(
    val exportId: String = "",
    val status: String = "",
    val etag: String = "",
    val expectedBytes: Long = 0,
    val finalBytes: Long? = null,
    val error: String? = null,
    val queuePosition: Int? = null,
    val contentUrl: String = "",
)

/** POST /playback/viewings：本机播放的观看记录补传（按 viewing_id 幂等合并） */
@Serializable
data class OfflineViewingRecord(
    val viewingId: String,
    val mediaItemId: Long,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val fileId: Long? = null,
    val startedAt: String,
    val updatedAt: String,
    val startPositionMs: Long = 0,
    val positionMs: Long,
    val watchedMs: Long = 0,
    val completed: Boolean = false,
    val ended: Boolean = false,
    val durationMs: Long? = null,
)

@Serializable
data class OfflineViewingsRequest(
    val sentAt: String,
    val records: List<OfflineViewingRecord>,
)

@Serializable
data class OfflineViewingResult(
    val viewingId: String = "",
    /** applied / stale / rejected：三种都算服务端处理过了 */
    val status: String = "",
)

@Serializable
data class OfflineViewingsView(
    val results: List<OfflineViewingResult> = emptyList(),
)
