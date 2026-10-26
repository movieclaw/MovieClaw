package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/* ---------------- 离线下载（docs/design/offline-download.md；服务端 routes/offline.py） ---------------- */

/** GET /offline/manifest：一个播放单元打包所需的一切（展示数据 + 档位 + 字幕清单） */
@Serializable
data class OfflineManifest(
    val fileId: Long = 0,
    val mediaItemId: Long = 0,
    val libraryId: Long = 0,
    @kotlinx.serialization.SerialName("season_number") val seasonNumber: Int = 0,
    @kotlinx.serialization.SerialName("episode_number") val episodeNumber: Int = 0,
    val container: String? = null,
    @kotlinx.serialization.SerialName("size_bytes") val sizeBytes: Long = 0,
    @kotlinx.serialization.SerialName("duration_ms") val durationMs: Long? = null,
    /** 展示数据原样存盘（海报、标题、分集等），离线渲染用 */
    val item: kotlinx.serialization.json.JsonElement? = null,
    val library: kotlinx.serialization.json.JsonElement? = null,
    @kotlinx.serialization.SerialName("default_audio") val defaultAudio: String? = null,
    @kotlinx.serialization.SerialName("default_subtitle") val defaultSubtitle: String? = null,
    val subtitles: List<OfflineSubtitleRef> = emptyList(),
    val profiles: List<OfflineProfile> = emptyList(),
    @kotlinx.serialization.SerialName("unavailable_reason") val unavailableReason: String? = null,
    @kotlinx.serialization.SerialName("resume_position_ms") val resumePositionMs: Long? = null,
)

@Serializable
data class OfflineSubtitleRef(
    @kotlinx.serialization.SerialName("track_ref") val trackRef: String = "",
    val format: String = "",
    val language: String? = null,
    val url: String? = null,
)

@Serializable
data class OfflineProfile(
    val profile: String = "",
    val label: String = "",
    val height: Int? = null,
    @kotlinx.serialization.SerialName("expected_bytes") val expectedBytes: Long = 0,
)

/** POST /offline/profiles：选档表单一次问一批文件的可选档位与预计大小 */
@Serializable
data class OfflineProfilesRequest(
    @kotlinx.serialization.SerialName("file_ids") val fileIds: List<Long>,
)

@Serializable
data class OfflineFileProfiles(
    val fileId: Long = 0,
    @kotlinx.serialization.SerialName("season_number") val seasonNumber: Int = 0,
    @kotlinx.serialization.SerialName("episode_number") val episodeNumber: Int = 0,
    val container: String? = null,
    val profiles: List<OfflineProfile>? = null,
    @kotlinx.serialization.SerialName("unavailable_reason") val unavailableReason: String? = null,
)

@Serializable
data class OfflineProfilesView(
    val files: List<OfflineFileProfiles>? = null,
)

/** POST /offline/exports：建或复用一个转码导出 */
@Serializable
data class OfflineExportRequest(
    @kotlinx.serialization.SerialName("file_id") val fileId: Long,
    val profile: String,
    @kotlinx.serialization.SerialName("audio_track") val audioTrack: String? = null,
)

@Serializable
data class OfflineExport(
    val exportId: String = "",
    val status: String = "",
    val etag: String = "",
    @kotlinx.serialization.SerialName("expected_bytes") val expectedBytes: Long = 0,
    @kotlinx.serialization.SerialName("final_bytes") val finalBytes: Long? = null,
    val error: String? = null,
    @kotlinx.serialization.SerialName("queue_position") val queuePosition: Int? = null,
    @kotlinx.serialization.SerialName("content_url") val contentUrl: String = "",
)

/** POST /playback/viewings：本机播放的观看记录补传（按 viewing_id 幂等合并） */
@Serializable
data class OfflineViewingRecord(
    @kotlinx.serialization.SerialName("viewing_id") val viewingId: String,
    @kotlinx.serialization.SerialName("media_item_id") val mediaItemId: Long,
    @kotlinx.serialization.SerialName("season_number") val seasonNumber: Int = 0,
    @kotlinx.serialization.SerialName("episode_number") val episodeNumber: Int = 0,
    @kotlinx.serialization.SerialName("file_id") val fileId: Long? = null,
    @kotlinx.serialization.SerialName("started_at") val startedAt: String,
    @kotlinx.serialization.SerialName("updated_at") val updatedAt: String,
    @kotlinx.serialization.SerialName("start_position_ms") val startPositionMs: Long = 0,
    @kotlinx.serialization.SerialName("position_ms") val positionMs: Long,
    @kotlinx.serialization.SerialName("watched_ms") val watchedMs: Long = 0,
    val completed: Boolean = false,
    val ended: Boolean = false,
    @kotlinx.serialization.SerialName("duration_ms") val durationMs: Long? = null,
)

@Serializable
data class OfflineViewingsRequest(
    @kotlinx.serialization.SerialName("sent_at") val sentAt: String,
    val records: List<OfflineViewingRecord>,
)
