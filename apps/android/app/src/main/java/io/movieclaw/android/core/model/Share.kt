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

/* ---------------- 管理侧分享（媒体库详情页 ⋯ 菜单的「分享…」，iOS `LibraryShareSheet`） ---------------- */

/**
 * 一条有效分享（服务端 `ShareView`）。
 * `password` 是**密码原文**（服务端就是这么下发的，好在分享页要能把它显示给分享人核对）；
 * `url` 未配外部访问地址时是相对路径 `/s/{slug}`，展示前要拼上当前 origin。
 */
@Serializable
data class ShareView(
    val id: Long = 0,
    val slug: String = "",
    val url: String = "",
    val mediaItemId: Long? = null,
    val collectionId: Long? = null,
    val libraryId: Long? = null,
    val title: String = "",
    val kind: String? = null,
    val year: Int? = null,
    val posterUrl: String? = null,
    val itemCount: Int? = null,
    val password: String? = null,
    val expiresAt: String? = null,
    val createdAt: String? = null,
    val viewCount: Int = 0,
    val lastAccessedAt: String? = null,
)

/**
 * 创建分享的请求体（服务端 `ShareCreateRequest`）。
 * 有效期业务上只接受 1 / 3 / 7 / 30 天（没有「永久」）；密码可空，最长 64。
 */
@Serializable
data class ShareCreateRequest(
    val expiresInDays: Int = 7,
    val password: String? = null,
)

/** `DELETE .../share` 的 `data` */
@Serializable
data class ShareRevokedView(val revoked: Boolean = false)
