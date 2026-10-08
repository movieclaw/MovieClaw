package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/** GET /share/{slug} 的探测结果 */
@Serializable
data class SharePublic(
    val requiresPassword: Boolean = false,
    val unlocked: Boolean = false,
    val expiresAt: String? = null,
    val mediaItemId: Long? = null,
    val collectionId: Long? = null,
)

@Serializable
data class ShareUnlockRequest(val password: String)

@Serializable
data class SharedFile(
    val id: Long,
    val sizeBytes: Long = 0,
    val container: String? = null,
    val resolution: String? = null,
    val videoCodec: String? = null,
    val hdr: String? = null,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
)

/** 访客能看到的条目(只有可分享的信息,没有库内路径) */
@Serializable
data class SharedItem(
    val mediaItemId: Long,
    val kind: String = "movie",
    val title: String = "",
    val originalTitle: String? = null,
    val year: Int? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val primaryAspect: Float = 0.6667f,
    val localMeta: LocalMetaView? = null,
    val files: List<SharedFile> = emptyList(),
    val seasons: List<Int> = emptyList(),
    val expiresAt: String? = null,
)

@Serializable
data class SharedCollectionItem(
    val mediaItemId: Long,
    val title: String = "",
    val year: Int? = null,
    val kind: String = "movie",
    val posterUrl: String? = null,
)

@Serializable
data class SharedCollection(
    val id: Long? = null,
    val name: String = "",
    val description: String? = null,
    val items: List<SharedCollectionItem> = emptyList(),
    val expiresAt: String? = null,
)

/** 分享深链解析结果 */
data class ShareLink(val origin: String, val slug: String)
