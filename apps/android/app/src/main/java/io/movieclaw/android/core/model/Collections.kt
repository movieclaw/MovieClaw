package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * 一个合集 —— 照抄服务端 `schemas.library.CollectionView`（iOS `API.CollectionView` 同源）。
 *
 * 合集是**存好的筛选**：`rules` 与 `library.match_rules` 同构。形态（会不会自己长、
 * 能不能改）由后端**推导**出来给 `kind` / `rule_driven` / `editable`，前端不要再按
 * name / builtin 自己猜一遍。
 */
@Serializable
data class CollectionView(
    val id: Long,
    val name: String = "",
    /** 所属库；null = 跨库合集 */
    val libraryId: Long? = null,
    /** 合集内默认排序 */
    val sort: String = "added_at",
    /** household = 全家可见 / private = 只有我 */
    val visibility: String = "household",
    /** 内置合集标识（如 favorites:12）；null = 用户创建 */
    val builtin: String? = null,
    /** 合集从哪来：user = 用户自建 / builtin = 内置 / series = 按作品系列自动生成 */
    val kind: String = "user",
    /** 已隐藏。自动生成的合集删不掉（下次 ensure 又长回来） */
    val hidden: Boolean = false,
    /** 能不能改规则 */
    val editable: Boolean = true,
    /** 规则驱动（会自己长）还是名单驱动（固定的一份名单） */
    val ruleDriven: Boolean = false,
    /** 当前观看者能看到的成员数 */
    val itemCount: Int = 0,
    /** 封面取哪部作品；null = 取首个成员 */
    val coverItemId: Long? = null,
    /** 卡片封面素材（前若干个成员的海报），服务端随列表一并给出 */
    val covers: List<CollectionCover> = emptyList(),
    val position: Int = 0,
)

/** 合集卡片的一张封面图：合集自己没有图，封面就是成员的海报。 */
@Serializable
data class CollectionCover(
    val url: String = "",
    /** 微缩占位图 data URI；缺图时为 null */
    val blur: String? = null,
)

/** 系列里的一部作品：库里有没有、在追没在追（服务端 `SeriesPartView`） */
@Serializable
data class SeriesPartView(
    val tmdbId: Long,
    val title: String,
    val releaseDate: String? = null,
    val posterUrl: String? = null,
    /** 库里已有的那条；null = 缺这一部 */
    val mediaItemId: Long? = null,
    /** 已经在追（有订阅） */
    val subscribed: Boolean = false,
)

/** 系列合集的「已有 N / 共 M」与缺片名单（服务端 `CollectionSeriesView`） */
@Serializable
data class CollectionSeriesView(
    val seriesName: String? = null,
    val ownedCount: Int = 0,
    val total: Int = 0,
    val imageUrl: String? = null,
    val parts: List<SeriesPartView> = emptyList(),
    /** 拉到上游档案了吗；false = 没配 TMDB / 网络不通 / 本地系列没有上游档案 */
    val available: Boolean = false,
)

/* ---------------- 写入侧（详情页 ⋯ 菜单的「加入合集…」，iOS `AddToCollectionSheet`） ---------------- */

/** `POST /collections/{id}/items` 的请求体（服务端 `CollectionItemsPayload`）；幂等，已在里面不会报错 */
@Serializable
data class CollectionItemsPayload(
    val mediaItemIds: List<Long> = emptyList(),
)

/**
 * `POST /collections` 的请求体（服务端 `CollectionPayload`，字段全部可选）。
 * 从详情页新建时只用 `{name, libraryId, itemIds}`：建完顺手把这部片放进去。
 */
@Serializable
data class CollectionPayload(
    val name: String? = null,
    val libraryId: Long? = null,
    val rules: kotlinx.serialization.json.JsonElement? = null,
    val sort: String? = null,
    val visibility: String? = null,
    val hidden: Boolean? = null,
    val itemIds: List<Long>? = null,
    val snapshot: Boolean? = null,
)
