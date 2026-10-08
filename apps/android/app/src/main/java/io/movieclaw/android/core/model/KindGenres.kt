package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * 首页「按类型找电影 / 剧集」的一格（v0.31 `GET /libraries/kinds/{kind}/genres`）。
 *
 * 封面是这个类型**最近入库**、有剧照的那部片——色块同时是「这个类型新来了什么」的提示。
 * 部数多的类型先挑，同一部片不会贴在两个类型上。`value` 是 TMDB genre id，
 * 点进去带 `g=value` 开跨库墙。
 */
@Serializable
data class LibraryKindGenreView(
    val value: String = "",
    /** 类型中文名（唯一真相源在后端，客户端不内置） */
    val label: String = "",
    /** 跨库去重后的部数 */
    val count: Int = 0,
    val coverItemId: Long? = null,
    val coverTitle: String? = null,
    /** 封面剧照（横版）；本地资产优先，回落 TMDB 图床 */
    val coverUrl: String? = null,
)
