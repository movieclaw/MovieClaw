package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/** 发现页服务端编排的一个分区 */
@Serializable
data class DiscoverySection(
    val collectionRef: String = "",
    val title: String = "",
    /** hero / ranked-row / poster-row */
    val presentation: String = "poster-row",
    val previewLimit: Int = 12,
    val supportsFullListing: Boolean = false,
)

@Serializable
data class DiscoveryPage(
    val provider: String = "tmdb",
    val mediaType: String = "movie",
    val sections: List<DiscoverySection> = emptyList(),
)

@Serializable
data class DiscoveryCollectionInfo(
    val collectionRef: String = "",
    val name: String = "",
    val description: String = "",
    val isRanked: Boolean = false,
    val defaultLimit: Int = 20,
    val supportsFullListing: Boolean = false,
)

@Serializable
data class CollectionTitles(
    val collection: DiscoveryCollectionInfo = DiscoveryCollectionInfo(),
    val titles: List<DiscoveredTitle> = emptyList(),
    val page: Int = 1,
    val totalPages: Int = 1,
    val totalResults: Int = 0,
    val hasMore: Boolean = false,
)

@Serializable
data class CastMember(
    val name: String = "",
    val role: String? = null,
    val character: String? = null,
    /** 服务端字段是 avatar_url（全局 SnakeCase 映射：avatarUrl 正好对应） */
    val avatarUrl: String? = null,
    val tmdbPersonId: Int? = null,
)

@Serializable
data class TitleMetadata(
    val plot: String? = null,
    val runtimeMinutes: Int? = null,
    val genres: List<String> = emptyList(),
    val directors: List<String> = emptyList(),
    val cast: List<CastMember> = emptyList(),
    val country: String = "",
    val language: String = "",
    val released: String = "",
    val network: String? = null,
)

/** 剧照/海报一张(服务端 MediaImage:预览用于列表,原图用于灯箱) */
@Serializable
data class MediaImage(
    val previewUrl: String = "",
    val fullUrl: String = "",
    val width: Int = 0,
    val height: Int = 0,
) {
    val aspect: Float get() = if (height > 0) width.toFloat() / height else 16f / 9f
}

@Serializable
data class MediaVideo(
    val key: String = "",
    val name: String = "",
)

/** 本库已入库入口(有值即可直接播/进剧集页) */
@Serializable
data class MediaLibraryLink(
    val libraryId: Long = 0,
    val libraryName: String = "",
    val mediaItemId: Long = 0,
)

/** GET /discover/titles/{title_ref} */
@Serializable
data class TitleDetails(
    val title: DiscoveredTitle = DiscoveredTitle(),
    val metadata: TitleMetadata = TitleMetadata(),
    val backdropOriginalUrl: String? = null,
    val recommendations: List<DiscoveredTitle> = emptyList(),
    val libraryLinks: List<MediaLibraryLink> = emptyList(),
    val backdrops: List<MediaImage> = emptyList(),
    val posters: List<MediaImage> = emptyList(),
    val videos: List<MediaVideo> = emptyList(),
)
