package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * 首页「我的收藏」的一格（服务端 `FavoriteItemView` = 单库海报墙条目 + 收藏上下文）。
 *
 * 收藏层级来自最近一次收藏的那一行：整剧季集皆空，整季只有季号，单集季集都有；
 * 电影恒为空（内部 (0,0) 哨兵不外泄）。
 */
@Serializable
data class FavoriteItemView(
    val mediaItemId: Long,
    val kind: String = "movie",
    /** 卡片的详情落点库（同一作品跨库时取首页顺序第一个可见库） */
    val libraryId: Long? = null,
    val title: String = "",
    val year: Int? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val primaryAspect: Float = 0.6667f,
    val rating: Float? = null,
    val favoriteSeasonNumber: Int? = null,
    val favoriteEpisodeNumber: Int? = null,
    /** 最近一次收藏的时间（默认排序「最近收藏」的依据） */
    val favoritedAt: String? = null,
)

/** `GET /playback/favorites` 的载荷：`total` 是去重后的收藏作品总数，`items` 受 limit 截断 */
@Serializable
data class FavoritesPageView(
    val items: List<FavoriteItemView> = emptyList(),
    val total: Int = 0,
)

/**
 * 收藏层级说明（iOS `favoriteLevelLabel` / 网页同名函数）：整剧与电影不解释——
 * 只有「收藏的是某一季 / 某一集」才值得在卡片上说出来。
 */
fun favoriteLevelLabel(kind: String, season: Int?, episode: Int?): String? {
    if (kind != "tv" || season == null) return null
    if (episode != null) return "收藏了 S%02dE%02d".format(season, episode)
    return if (season == 0) "收藏了特别篇" else "收藏了第 $season 季"
}
