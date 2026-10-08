package io.movieclaw.androidtv.ui.home

import io.movieclaw.androidtv.core.model.generated.CollectionView
import io.movieclaw.androidtv.core.model.generated.HomeRowPref
import io.movieclaw.androidtv.core.model.generated.LibraryView

/** 一档排序的方向（WallSortDirection）：反转了自然方向才带 order */
data class SortDirection(val naturalAsc: Boolean) {
    fun orderParam(reversed: Boolean): String? = if (!reversed) null else if (naturalAsc) "desc" else "asc"
    fun isReversed(order: String?): Boolean = order != null && (order == "asc") != naturalAsc
}

/**
 * 首页的「行清单」：合并规则、排序预设与命名推荐。逐行移植自 Apple 端 `Shared/Library/LibraryHomeRows.swift`
 * （它又移植自 Web `lib/home-rows.ts`）——三端共用同一份偏好，合并逻辑必须一致。
 */
object HomeRows {
    val allSorts = listOf("added_at", "release_date", "last_played", "rating", "random", "title")

    data class SortPreset(val name: (String, Boolean) -> String, val short: (Boolean) -> String, val direction: SortDirection?)

    fun preset(sort: String): SortPreset = when (sort) {
        "release_date" -> SortPreset({ l, r -> if (r) "最早上映的$l" else "最近上映的$l" }, { if (it) "最早上映" else "最近上映" }, SortDirection(false))
        "last_played" -> SortPreset({ l, r -> if (r) "很久没看的$l" else "最近观看的$l" }, { if (it) "很久没看" else "最近观看" }, SortDirection(false))
        "rating" -> SortPreset({ l, r -> if (r) "评分最低的$l" else "评分最高的$l" }, { if (it) "评分最低" else "评分最高" }, SortDirection(false))
        "random" -> SortPreset({ l, _ -> "随便看看 · $l" }, { "随便看看" }, null)
        "title" -> SortPreset({ l, r -> if (r) "$l Z–A" else "$l A–Z" }, { if (it) "Z–A" else "A–Z" }, SortDirection(true))
        else -> SortPreset({ l, r -> if (r) "最早添加的$l" else "最近添加的$l" }, { if (it) "最早添加" else "最近添加" }, SortDirection(false))
    }

    fun sorts(kind: String): List<String> = when (kind) {
        "photo" -> listOf("added_at", "title", "random")
        "video" -> listOf("added_at", "last_played", "title", "random")
        else -> allSorts
    }

    val mediaKinds = listOf("movie", "tv", "video")

    fun mediaKindLabel(kind: String) = when (kind) {
        "tv" -> "剧集"
        "video" -> "其他视频"
        else -> "电影"
    }

    fun mediaKindRowName(kind: String, sort: String, reversed: Boolean) = "全部${mediaKindLabel(kind)} · ${preset(sort).short(reversed)}"

    fun mediaKindGroups(libraries: List<LibraryView>): List<Pair<String, List<LibraryView>>> =
        mediaKinds.mapNotNull { kind ->
            val members = libraries.filter { it.kind == kind && !it.excludeFromHome }
            if (members.isEmpty()) null else kind to members
        }

    val favoritesSorts = listOf("unwatched_first", "favorited_at", "rating", "title")

    fun favoritesDirection(sort: String): SortDirection? = when (sort) {
        "favorited_at", "rating" -> SortDirection(false)
        "title" -> SortDirection(true)
        else -> null
    }

    sealed interface Kind {
        data object UpNext : Kind
        data class Favorites(val sort: String, val reversed: Boolean) : Kind
        data object Libraries : Kind
        data class Genres(val kind: String, val libraries: List<LibraryView>) : Kind
        data class Library(val library: LibraryView, val sort: String, val reversed: Boolean, val unwatched: Boolean, val name: String, val builtin: Boolean) : Kind
        data class MediaKind(val kind: String, val libraries: List<LibraryView>, val sort: String, val reversed: Boolean, val unwatched: Boolean, val name: String) : Kind
        data class Collection(val collection: CollectionView, val sort: String, val reversed: Boolean, val name: String) : Kind
    }

    data class Row(val id: String, val hidden: Boolean, val kind: Kind) {
        val title: String
            get() = when (kind) {
                Kind.UpNext -> "接下来继续"
                is Kind.Favorites -> "我的收藏"
                Kind.Libraries -> "我的媒体库"
                is Kind.Genres -> "按类型找${mediaKindLabel(kind.kind)}"
                is Kind.Library -> kind.name.ifEmpty { preset(kind.sort).name(kind.library.name, kind.reversed) }
                is Kind.MediaKind -> kind.name.ifEmpty { mediaKindRowName(kind.kind, kind.sort, kind.reversed) }
                is Kind.Collection -> kind.name.ifEmpty { kind.collection.name }
            }
    }

    fun pinnedCollections(rows: List<Row>): List<CollectionView> {
        val seen = mutableSetOf<Long>()
        return rows.mapNotNull { row ->
            val kind = row.kind as? Kind.Collection ?: return@mapNotNull null
            if (row.hidden || !seen.add(kind.collection.id)) null else kind.collection
        }
    }

    val genreKinds = listOf("movie", "tv")

    private fun genreRows(libraries: List<LibraryView>) = mediaKindGroups(libraries).mapNotNull { (kind, members) ->
        if (kind in genreKinds) Row("genres:$kind", false, Kind.Genres(kind, members)) else null
    }

    private fun defaultRows(libraries: List<LibraryView>): List<Row> =
        listOf(
            Row("up-next", false, Kind.UpNext),
            Row("favorites", false, Kind.Favorites("unwatched_first", false)),
            Row("libraries", false, Kind.Libraries),
        ) + genreRows(libraries) + libraries.filter { !it.excludeFromHome }.map {
            Row("lib:${it.id}", false, Kind.Library(it, "added_at", false, false, "", true))
        }

    private fun asRowSort(value: String?, order: String?, allowed: List<String>): Pair<String, Boolean> {
        if (value == "release_date_asc" && "release_date" in allowed) return "release_date" to true
        val sort = value?.takeIf { it in allowed } ?: allowed[0]
        return sort to (preset(sort).direction?.isReversed(order) ?: false)
    }

    /** 把存下来的清单与当前可见的库、合集合并成首页要渲染的行 */
    fun build(prefs: List<HomeRowPref>, libraries: List<LibraryView>, collections: List<CollectionView>): List<Row> {
        val visible = libraries.filter { it.viewerAccess }
        val defaults = defaultRows(visible)
        if (prefs.isEmpty()) return defaults
        val libById = visible.associateBy { it.id }
        val colById = collections.associateBy { it.id }
        val kindGroups = mediaKindGroups(visible).toMap()
        val seen = mutableSetOf<String>()
        val rows = mutableListOf<Row>()
        for (pref in prefs) {
            if (pref.id in seen) continue
            val row = resolve(pref, libById, colById, kindGroups) ?: continue
            seen += pref.id
            rows += row
        }
        for (row in defaults) {
            if (row.kind is Kind.Library || row.kind is Kind.Genres || row.id in seen) continue
            seen += row.id
            rows += row
        }
        val missingGenres = defaults.filter { it.kind is Kind.Genres && it.id !in seen }
        if (missingGenres.isNotEmpty()) {
            missingGenres.forEach { seen += it.id }
            val at = rows.indexOfFirst { it.kind == Kind.Libraries }.let { if (it >= 0) it + 1 else rows.size }
            rows.addAll(at, missingGenres)
        }
        val missing = defaults.filter { it.kind is Kind.Library && it.id !in seen }
        if (missing.isNotEmpty()) {
            var at = rows.size
            val last = rows.indexOfLast { it.kind is Kind.Library }
            val libs = rows.indexOfFirst { it.kind == Kind.Libraries }
            if (last >= 0) {
                at = last + 1
            } else if (libs >= 0) {
                at = libs + 1
                while (at < rows.size && rows[at].kind is Kind.Genres) at++
            }
            rows.addAll(at, missing)
        }
        return rows
    }

    private fun resolve(
        pref: HomeRowPref,
        libById: Map<Long, LibraryView>,
        colById: Map<Long, CollectionView>,
        kindGroups: Map<String, List<LibraryView>>,
    ): Row? {
        val hidden = pref.hidden == true
        when (pref.id) {
            "up-next" -> return Row("up-next", hidden, Kind.UpNext)
            "libraries" -> return Row("libraries", hidden, Kind.Libraries)
            "genres:movie", "genres:tv" -> {
                val kind = pref.id.removePrefix("genres:")
                val members = kindGroups[kind] ?: return null
                return Row(pref.id, hidden, Kind.Genres(kind, members))
            }
            "favorites" -> {
                val sort = pref.sort?.takeIf { it in favoritesSorts } ?: "unwatched_first"
                val reversed = favoritesDirection(sort)?.isReversed(pref.order) ?: false
                return Row("favorites", hidden, Kind.Favorites(sort, reversed))
            }
        }
        if (pref.id.startsWith("lib:")) {
            val library = pref.id.removePrefix("lib:").toLongOrNull()?.let(libById::get) ?: return null
            if (library.excludeFromHome) return null
            return libraryRow(pref, library, builtin = true)
        }
        if (pref.id.startsWith("kind:")) {
            if (hidden) return null
            val kind = pref.id.removePrefix("kind:")
            val members = kindGroups[kind] ?: return null
            return mediaKindRow(pref, kind, members)
        }
        if (!pref.id.startsWith("row:")) return null
        pref.mediaKind?.let { kind ->
            val members = kindGroups[kind] ?: return null
            return mediaKindRow(pref, kind, members)
        }
        pref.collectionId?.let { cid ->
            val collection = colById[cid] ?: return null
            val (sort, reversed) = if (pref.sort != null) asRowSort(pref.sort, pref.order, allSorts) else asRowSort(collection.sort, null, allSorts)
            return Row(pref.id, hidden, Kind.Collection(collection, sort, reversed, pref.name?.trim().orEmpty()))
        }
        pref.libraryId?.let { lid ->
            val library = libById[lid] ?: return null
            return libraryRow(pref, library, builtin = false)
        }
        return null
    }

    private fun libraryRow(pref: HomeRowPref, library: LibraryView, builtin: Boolean): Row {
        val (sort, reversed) = asRowSort(pref.sort, pref.order, sorts(library.kind))
        return Row(pref.id, pref.hidden == true, Kind.Library(library, sort, reversed, pref.unwatched == true && sort != "last_played", pref.name?.trim().orEmpty(), builtin))
    }

    private fun mediaKindRow(pref: HomeRowPref, kind: String, libraries: List<LibraryView>): Row {
        val (sort, reversed) = asRowSort(pref.sort, pref.order, sorts(kind))
        return Row(pref.id, pref.hidden == true, Kind.MediaKind(kind, libraries, sort, reversed, pref.unwatched == true && sort != "last_played", pref.name?.trim().orEmpty()))
    }

    /** 一行取数的缓存键：同一个库同一种排序同一方向（同一个未看开关）只请求一次 */
    fun fetchKey(row: Row): String = when (val k = row.kind) {
        is Kind.Library -> "lib:${k.library.id}:${k.sort}:${k.reversed}:${k.unwatched}"
        is Kind.MediaKind -> "kind:${k.kind}:${k.sort}:${k.reversed}:${k.unwatched}"
        is Kind.Collection -> "col:${k.collection.id}:${k.sort}:${k.reversed}"
        else -> row.id
    }
}
