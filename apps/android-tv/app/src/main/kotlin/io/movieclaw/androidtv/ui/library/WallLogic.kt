package io.movieclaw.androidtv.ui.library

import io.movieclaw.androidtv.ui.shell.WallSource
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** 排序选择：档位 + 是否反转了自然方向（WallSortState） */
data class WallSort(val sort: String, val reversed: Boolean = false)

/**
 * 一面墙怎么取数（与首页那一行同一套参数）：哪个接口 + 查询参数。界面按它调接口，单测按它核对参数。
 */
data class WallQuery(
    val endpoint: Endpoint,
    val id: Long? = null,
    val kind: String? = null,
    val sort: String? = null,
    val order: String? = null,
    val w: String? = null,
    val g: String? = null,
    val unwatchedFirst: Boolean? = null,
) {
    enum class Endpoint { Library, MediaKind, Collection, Favorites }
}

/** 海报墙排序与取数的纯逻辑（LibraryShared.swift WallSortDirections / TVRowWallView.reload） */
object WallLogic {
    /** 电视上媒体库墙提供的排序档 */
    val LIBRARY_SORTS = listOf("added_at", "release_date", "rating", "title")

    /** 一档排序的自然方向是不是升序；null = 没有方向（随便看看、未看优先） */
    fun naturalAscending(sort: String): Boolean? = when (sort) {
        "title", "probing", "runtime" -> true
        "added_at", "release_date", "favorited_at", "rating", "size", "last_played" -> false
        else -> null
    }

    /** 反转了自然方向才带 order：自然升序（片名）反转是 desc，其余反转是 asc */
    fun orderParam(sort: String, reversed: Boolean): String? {
        if (!reversed) return null
        val asc = naturalAscending(sort) ?: return null
        return if (asc) "desc" else "asc"
    }

    /** 「最近观看」只要播过的（w=seen）；只看未看是 w=unwatched；否则不带 */
    fun watchParam(sort: String, unwatched: Boolean): String? = when {
        sort == "last_played" -> "seen"
        unwatched -> "unwatched"
        else -> null
    }

    /** 不带库名的短标签（HomeRows.preset(sort).short） */
    fun shortLabel(sort: String, reversed: Boolean = false): String = when (sort) {
        "release_date" -> if (reversed) "最早上映" else "最近上映"
        "last_played" -> if (reversed) "很久没看" else "最近观看"
        "rating" -> if (reversed) "评分最低" else "评分最高"
        "random" -> "随便看看"
        "title" -> if (reversed) "Z–A" else "A–Z"
        else -> if (reversed) "最早添加" else "最近添加"
    }

    /** 排序按钮上的字：「最近添加」「评分最高 · 未看」 */
    fun sortButtonLabel(sort: String, unwatched: Boolean): String = shortLabel(sort) + if (unwatched) " · 未看" else ""

    /** 媒体库墙的请求：排序、反转才带 order、只看未看带 w */
    fun libraryQuery(libraryId: Long, sort: WallSort, unwatched: Boolean) = WallQuery(
        WallQuery.Endpoint.Library,
        id = libraryId,
        sort = sort.sort,
        order = orderParam(sort.sort, sort.reversed),
        w = if (unwatched) "unwatched" else null,
    )

    /** 首页一行「查看全部」/ 按类型墙的请求（TVRowWallView.reload） */
    fun rowQuery(source: WallSource): WallQuery = when (source) {
        is WallSource.Library -> WallQuery(
            WallQuery.Endpoint.Library,
            id = source.id,
            sort = source.sort,
            order = orderParam(source.sort, source.reversed),
            w = watchParam(source.sort, source.unwatched),
        )
        is WallSource.MediaKind -> WallQuery(
            WallQuery.Endpoint.MediaKind,
            kind = source.kind,
            sort = source.sort,
            order = orderParam(source.sort, source.reversed),
            w = watchParam(source.sort, source.unwatched),
        )
        is WallSource.Collection -> WallQuery(
            WallQuery.Endpoint.Collection,
            id = source.id,
            sort = source.sort,
            order = orderParam(source.sort, source.reversed),
        )
        is WallSource.Genre -> WallQuery(WallQuery.Endpoint.MediaKind, kind = source.kind, sort = "added_at", g = source.genre.toString())
        is WallSource.Favorites -> {
            // 「未看优先」是首页收藏行的一档：同首页取数（sort 改成收藏时间、加 unwatched_first）
            val unwatchedFirst = source.sort == "unwatched_first"
            WallQuery(
                WallQuery.Endpoint.Favorites,
                sort = if (unwatchedFirst) "favorited_at" else source.sort,
                order = orderParam(source.sort, source.reversed),
                unwatchedFirst = unwatchedFirst,
            )
        }
    }

    /**
     * 标题旁的总数：只在确切知道时写——媒体库没加筛选（不是只看未看、不是最近观看）时用库的统计，收藏用接口给的总数，类型墙用色块上的部数。
     */
    fun rowCount(source: WallSource, libraryItemCount: Long?): Long? = when (source) {
        is WallSource.Library -> if (source.unwatched || source.sort == "last_played") null else source.count ?: libraryItemCount
        is WallSource.Favorites -> source.total
        is WallSource.Genre -> source.count
        is WallSource.MediaKind, is WallSource.Collection -> null
    }

    /** 本机记忆的键（同 Apple 端 movieclaw.tv.wall-sort.{id} 与 .unwatched） */
    fun sortKey(libraryId: Long) = "movieclaw.tv.wall-sort.$libraryId"

    fun encodeSort(sort: WallSort): String = buildJsonObject {
        put("sort", sort.sort)
        put("reversed", sort.reversed)
    }.toString()

    /** 读记忆的排序；坏数据或电视上不提供的档位退回默认（最近添加） */
    fun decodeSort(raw: String?, allowed: List<String> = LIBRARY_SORTS, fallback: WallSort = WallSort("added_at")): WallSort {
        if (raw == null) return fallback
        return runCatching {
            val obj = Json.parseToJsonElement(raw).jsonObject
            val sort = (obj["sort"] as? JsonPrimitive)?.content ?: return fallback
            val reversed = obj["reversed"]?.jsonPrimitive?.booleanOrNull ?: false
            if (sort in allowed) WallSort(sort, reversed) else fallback
        }.getOrDefault(fallback)
    }
}
