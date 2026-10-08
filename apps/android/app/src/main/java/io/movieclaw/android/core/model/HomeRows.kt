package io.movieclaw.android.core.model

import kotlin.random.Random

/**
 * 媒体库首页的「行清单」：合并规则、排序预设与命名推荐。
 * **逐行移植**自 iOS `LibraryHomeRows.swift`（= Web `lib/home-rows.ts`）——两端合并逻辑
 * 必须一致，否则同一账号在网页 / iOS / 安卓看到的首页不同。
 *
 * 首页 = 每个成员一份有序的行清单；每一行 = 来源 × 排序 × 名字，存在 `ui.preferences.home.rows`。
 * 约定：**存下来的是提示，不是契约**——
 *  - 存过的行按存的顺序在前；
 *  - 没存过的内置行、每个可见库的默认行按出厂顺序补在后面（新版本加的内置行、新建的库一定看得到）；
 *  - 指向已删库 / 不可见合集的行直接忽略；
 *  - 空清单 = 出厂布局，「恢复默认」就是存一个空列表。
 */
object HomeRows {

    /** 库行 / 合集行可选的排序档（取值与海报墙同名，另含首页独有的 random） */
    val allSorts = listOf("added_at", "release_date", "last_played", "rating", "random", "title")

    /** 「我的收藏」行的排序档 */
    val favoritesSorts = listOf("unwatched_first", "favorited_at", "rating", "title")

    /**
     * 一档排序的方向档案（Web `SORT_DIRECTIONS`）：
     * 自然方向是升序还是降序 + 两个方向的人话。
     */
    data class Direction(val naturalAsc: Boolean, val asc: String, val desc: String) {
        /** 反转了自然方向才带 order（与 Web orderParam / iOS orderParam(reversed:) 同一条规矩） */
        fun orderParam(reversed: Boolean): String? =
            if (!reversed) null else if (naturalAsc) "desc" else "asc"

        /** 存下来的 order → 是否反转 */
        fun isReversed(order: String?): Boolean {
            if (order == null) return false
            return (order == "asc") != naturalAsc
        }

        /** 当前方向的人话 */
        fun label(reversed: Boolean): String = if (naturalAsc != reversed) asc else desc
    }

    /**
     * 一档排序的预设：推荐的行名（带库名 / 短标签）、方向档案、提示语。
     * name / short 都吃一个 `reversed`（是否反转自然方向）。
     */
    data class Preset(
        val name: (String, Boolean) -> String,
        val short: (Boolean) -> String,
        val direction: Direction?,
        val hint: String,
    )

    fun preset(sort: String): Preset = when (sort) {
        "release_date" -> Preset(
            name = { l, r -> if (r) "最早上映的$l" else "最近上映的$l" },
            short = { r -> if (r) "最早上映" else "最近上映" },
            direction = Direction(naturalAsc = false, asc = "旧→新", desc = "新→旧"),
            hint = "上映时间",
        )
        "last_played" -> Preset(
            // 反转 = 上次播放离现在最远的在前：「很久没看的」比「最早观看的」更像人话
            name = { l, r -> if (r) "很久没看的$l" else "最近观看的$l" },
            short = { r -> if (r) "很久没看" else "最近观看" },
            direction = Direction(naturalAsc = false, asc = "远→近", desc = "近→远"),
            hint = "我播放过的，按上次播放时间",
        )
        "rating" -> Preset(
            name = { l, r -> if (r) "评分最低的$l" else "评分最高的$l" },
            short = { r -> if (r) "评分最低" else "评分最高" },
            direction = Direction(naturalAsc = false, asc = "低→高", desc = "高→低"),
            hint = "评分",
        )
        "random" -> Preset(
            name = { l, _ -> "随便看看 · $l" },
            short = { _ -> "随便看看" },
            direction = null,
            hint = "每天换一批",
        )
        "title" -> Preset(
            name = { l, r -> if (r) "$l Z–A" else "$l A–Z" },
            short = { r -> if (r) "Z–A" else "A–Z" },
            direction = Direction(naturalAsc = true, asc = "A→Z", desc = "Z→A"),
            hint = "片名",
        )
        else -> Preset(   // added_at
            name = { l, r -> if (r) "最早添加的$l" else "最近添加的$l" },
            short = { r -> if (r) "最早添加" else "最近添加" },
            direction = Direction(naturalAsc = false, asc = "旧→新", desc = "新→旧"),
            hint = "入库时间",
        )
    }

    fun favoritesPreset(sort: String): Preset = when (sort) {
        "favorited_at" -> Preset(
            name = { _, r -> if (r) "最早收藏" else "最近收藏" },
            short = { r -> if (r) "最早收藏" else "最近收藏" },
            direction = Direction(naturalAsc = false, asc = "旧→新", desc = "新→旧"),
            hint = "收藏时间",
        )
        "rating" -> Preset(
            name = { _, r -> if (r) "评分最低" else "评分最高" },
            short = { r -> if (r) "评分最低" else "评分最高" },
            direction = Direction(naturalAsc = false, asc = "低→高", desc = "高→低"),
            hint = "评分",
        )
        "title" -> Preset(
            name = { _, r -> if (r) "片名 Z–A" else "片名 A–Z" },
            short = { r -> if (r) "片名 Z–A" else "片名 A–Z" },
            direction = Direction(naturalAsc = true, asc = "A→Z", desc = "Z→A"),
            hint = "片名",
        )
        else -> Preset(   // unwatched_first
            name = { _, _ -> "未看优先" },
            short = { _ -> "未看优先" },
            direction = null,
            hint = "没看完的在前，再按收藏时间",
        )
    }

    /** 排序档按类型裁剪：评分、上映对家庭录像与照片没有意义 */
    fun sortsFor(kind: String): List<String> = when (kind) {
        "photo" -> listOf("added_at", "title", "random")
        "video" -> listOf("added_at", "last_played", "title", "random")
        else -> allSorts
    }

    /* ---------------- 行模型 ---------------- */

    sealed interface Kind {
        data object UpNext : Kind
        data class Favorites(val sort: String, val reversed: Boolean) : Kind
        data object Libraries : Kind
        /** 「按类型找电影 / 剧集」类型色块行（出厂布局内置；id `genres:<kind>`，与 Web/iOS 同名同形） */
        data class Genres(val kind: String, val libraries: List<LibraryView>) : Kind
        data class Library(
            val library: LibraryView,
            val sort: String,
            val reversed: Boolean,
            val unwatched: Boolean,
            val name: String,
            val builtin: Boolean,
        ) : Kind
        data class Collection(
            val collection: CollectionView,
            val sort: String,
            val reversed: Boolean,
            val name: String,
        ) : Kind
    }

    /** 合并后的一行：来源已解析、排序与名字已落到具体值，首页与自定义页直接消费 */
    data class Row(val id: String, val hidden: Boolean, val kind: Kind) {
        val sort: String?
            get() = when (kind) {
                is Kind.Favorites -> kind.sort
                is Kind.Library -> kind.sort
                is Kind.Collection -> kind.sort
                else -> null
            }

        val reversed: Boolean
            get() = when (kind) {
                is Kind.Favorites -> kind.reversed
                is Kind.Library -> kind.reversed
                is Kind.Collection -> kind.reversed
                else -> false
            }

        /** 这一行显示的名字：用户起的优先，空则跟随默认（库行按排序推荐，合集行用合集名） */
        val title: String
            get() = when (val k = kind) {
                Kind.UpNext -> "接下来继续"
                is Kind.Favorites -> "我的收藏"
                Kind.Libraries -> "我的媒体库"
                is Kind.Genres -> if (k.kind == "tv") "按类型找剧集" else "按类型找电影"
                is Kind.Library -> if (k.name.isEmpty()) preset(k.sort).name(k.library.name, k.reversed) else k.name
                is Kind.Collection -> if (k.name.isEmpty()) k.collection.name else k.name
            }

        /** 自定义页里每行的小字：来源 · 排序 · 只看没看过的 */
        val meta: String
            get() = when (val k = kind) {
                Kind.UpNext -> "内置 · 我正在看的"
                is Kind.Favorites -> "内置 · ${favoritesPreset(k.sort).name("", k.reversed)}"
                Kind.Libraries -> "内置 · 管理页的库顺序"
                is Kind.Genres -> "内置 · 每个类型一格（${k.libraries.size} 个库）"
                is Kind.Library -> listOfNotNull(
                    "${k.library.name}库",
                    preset(k.sort).short(k.reversed),
                    if (k.unwatched) "只看没看过的" else null,
                ).joinToString(" · ")
                is Kind.Collection -> "合集 · ${preset(k.sort).short(k.reversed)}"
            }

        /** 库行 / 合集行的默认名（改名输入框的占位） */
        val defaultTitle: String
            get() = when (val k = kind) {
                is Kind.Library -> preset(k.sort).name(k.library.name, k.reversed)
                is Kind.Collection -> k.collection.name
                else -> title
            }

        val customName: String
            get() = when (val k = kind) {
                is Kind.Library -> k.name
                is Kind.Collection -> k.name
                else -> ""
            }

        /** 能否删除：自加的行（row:）与老版本存下的类型行（kind:）能删，内置行与每库默认行只能藏 */
        val removable: Boolean get() = id.startsWith("row:") || id.startsWith("kind:")
    }

    /* ---------------- 合并 ---------------- */

    /** 有类型色块行的库类型：TMDB 的类型表只分电影与剧集 */
    private val genreKinds = listOf("movie", "tv")

    /** 类型色块行（每种有库的类型一条），出厂布局里紧跟「我的媒体库」 */
    private fun genreRows(libraries: List<LibraryView>): List<Row> = genreKinds.mapNotNull { kind ->
        val libs = libraries.filter { it.kind == kind }
        if (libs.isEmpty()) null else Row("genres:$kind", false, Kind.Genres(kind, libs))
    }

    /**
     * 出厂布局：接下来继续 → 我的收藏 → 我的媒体库 → 按类型找电影 → 按类型找剧集 → 每个库一行「最近添加」。
     *
     * 不带类型行（「全部电影」）：它要用户在自定义页里主动添加才出现（上游 2db658de 的口径）。
     */
    private fun defaultRows(libraries: List<LibraryView>): List<Row> =
        listOf(
            Row("up-next", false, Kind.UpNext),
            Row("favorites", false, Kind.Favorites("unwatched_first", false)),
            Row("libraries", false, Kind.Libraries),
        ) + genreRows(libraries) + libraries.filter { !it.excludeFromHome }.map {
            Row(
                "lib:${it.id}", false,
                Kind.Library(it, "added_at", false, false, "", builtin = true),
            )
        }

    /**
     * 存下来的（sort, order）→（档位, 是否反转）。
     * 老偏好的 `release_date_asc` 归一成 `release_date` + 反转。
     */
    private fun asRowSort(value: String?, order: String?, allowed: List<String>): Pair<String, Boolean> {
        if (value == "release_date_asc" && allowed.contains("release_date")) return "release_date" to true
        val sort = if (value != null && allowed.contains(value)) value else allowed.first()
        return sort to (preset(sort).direction?.isReversed(order) ?: false)
    }

    /** 把存下来的清单与当前可见的库、合集合并成首页要渲染的行 */
    fun build(
        prefs: List<HomeRowPref>,
        libraries: List<LibraryView>,
        collections: List<CollectionView>,
    ): List<Row> {
        val visible = libraries.filter { it.viewerAccess }
        val defaults = defaultRows(visible)
        if (prefs.isEmpty()) return defaults
        val libById = visible.associateBy { it.id }
        val colById = collections.associateBy { it.id }
        val seen = mutableSetOf<String>()
        val rows = mutableListOf<Row>()
        for (pref in prefs) {
            if (pref.id in seen) continue
            val row = resolve(pref, libById, colById) ?: continue
            seen.add(pref.id)
            rows.add(row)
        }
        // 没存过的内置行追加在末尾（版本升级新增的入口不能消失）；类型色块行与库行另有落点
        for (row in defaults) {
            if (row.kind is Kind.Library) continue
            if (row.kind is Kind.Genres) continue
            if (row.id in seen) continue
            seen.add(row.id)
            rows.add(row)
        }
        // 没存过的类型色块行（版本升级新增）插在「我的媒体库」之后，与出厂布局同一位置
        // ——追加到队尾会落在一长串库行、合集行后面，老用户几乎看不到
        val missingGenres = defaults.filter { it.kind is Kind.Genres && it.id !in seen }
        if (missingGenres.isNotEmpty()) {
            missingGenres.forEach { seen.add(it.id) }
            val at = rows.indexOfFirst { it.kind == Kind.Libraries }.let { if (it >= 0) it + 1 else rows.size }
            rows.addAll(at.coerceIn(0, rows.size), missingGenres)
        }
        // 没存过的库补一条默认行，插在最后一条库行之后（没有库行时插在「我的媒体库」之后）
        val missing = defaults.filter { it.kind is Kind.Library && it.id !in seen }
        if (missing.isNotEmpty()) {
            var at = rows.size
            val last = rows.indexOfLast { it.kind is Kind.Library }
            if (last >= 0) {
                at = last + 1
            } else {
                val libs = rows.indexOfFirst { it.kind == Kind.Libraries }
                if (libs >= 0) {
                    at = libs + 1
                    // 出厂布局里类型色块行紧跟「我的媒体库」，库行在它们之后
                    while (at < rows.size && rows[at].kind is Kind.Genres) at++
                }
            }
            rows.addAll(at.coerceIn(0, rows.size), missing)
        }
        return rows
    }

    private fun resolve(
        pref: HomeRowPref,
        libById: Map<Long, LibraryView>,
        colById: Map<Long, CollectionView>,
    ): Row? {
        val hidden = pref.hidden == true
        when (pref.id) {
            "up-next" -> return Row("up-next", hidden, Kind.UpNext)
            "libraries" -> return Row("libraries", hidden, Kind.Libraries)
            "favorites" -> {
                val sort = if (pref.sort != null && favoritesSorts.contains(pref.sort)) pref.sort else "unwatched_first"
                val reversed = favoritesPreset(sort).direction?.isReversed(pref.order) ?: false
                return Row("favorites", hidden, Kind.Favorites(sort, reversed))
            }
        }
        if (pref.id.startsWith("lib:")) {
            // 管理员勾了「从首页排除」的库：默认行不出现，存过也一样
            val id = pref.id.removePrefix("lib:").toLongOrNull() ?: return null
            val library = libById[id] ?: return null
            if (library.excludeFromHome) return null
            return libraryRow(pref, library, builtin = true)
        }
        if (pref.id.startsWith("genres:")) {
            val kind = pref.id.removePrefix("genres:")
            if (kind !in genreKinds) return null
            val libs = libById.values.filter { it.kind == kind }
            if (libs.isEmpty()) return null
            return Row(pref.id, hidden, Kind.Genres(kind, libs))
        }
        if (!pref.id.startsWith("row:")) return null
        val cid = pref.collectionId
        if (cid != null) {
            val collection = colById[cid] ?: return null
            // 没存排序时沿用合集自己的序（含方向）
            val (sort, reversed) = if (pref.sort != null) {
                asRowSort(pref.sort, pref.order, allSorts)
            } else {
                asRowSort(collection.sort, null, allSorts)
            }
            return Row(
                pref.id, hidden,
                Kind.Collection(collection, sort, reversed, (pref.name ?: "").trim()),
            )
        }
        val lid = pref.libraryId
        if (lid != null) {
            val library = libById[lid] ?: return null
            return libraryRow(pref, library, builtin = false)
        }
        return null
    }

    private fun libraryRow(pref: HomeRowPref, library: LibraryView, builtin: Boolean): Row {
        val (sort, reversed) = asRowSort(pref.sort, pref.order, sortsFor(library.kind))
        // 「最近观看」只要播过的，与「只看没看过的」互斥：以排序为准，开关作废
        return Row(
            pref.id, pref.hidden == true,
            Kind.Library(
                library = library, sort = sort, reversed = reversed,
                unwatched = pref.unwatched == true && sort != "last_played",
                name = (pref.name ?: "").trim(), builtin = builtin,
            ),
        )
    }

    /** 反向：把合并后的行写回可存的形状。只存与默认不同的字段，空即默认 */
    fun toPrefs(rows: List<Row>): List<HomeRowPref> = rows.map { row ->
        var sort: String? = null
        var order: String? = null
        var name: String? = null
        var unwatched: Boolean? = null
        var libraryId: Long? = null
        var collectionId: Long? = null
        when (val k = row.kind) {
            is Kind.Favorites -> {
                if (k.sort != "unwatched_first") sort = k.sort
                order = favoritesPreset(k.sort).direction?.orderParam(k.reversed)
            }
            is Kind.Library -> {
                if (!k.builtin) libraryId = k.library.id
                sort = k.sort
                order = preset(k.sort).direction?.orderParam(k.reversed)
                if (k.unwatched) unwatched = true
                if (k.name.isNotEmpty()) name = k.name
            }
            is Kind.Collection -> {
                collectionId = k.collection.id
                sort = k.sort
                order = preset(k.sort).direction?.orderParam(k.reversed)
                if (k.name.isNotEmpty()) name = k.name
            }
            else -> Unit
        }
        HomeRowPref(
            id = row.id,
            sort = sort,
            order = order,
            name = name,
            unwatched = unwatched,
            hidden = if (row.hidden) true else null,
            libraryId = libraryId,
            collectionId = collectionId,
        )
    }

    /** 新加的行用随机 id：`row:` + 6 位 base36（与 Web / iOS 同形） */
    fun newRowId(): String {
        val chars = "0123456789abcdefghijklmnopqrstuvwxyz"
        return "row:" + (0 until 6).map { chars[Random.nextInt(chars.length)] }.joinToString("")
    }

    fun newLibraryRow(library: LibraryView): Row =
        Row(newRowId(), false, Kind.Library(library, "added_at", false, false, "", builtin = false))

    fun newCollectionRow(collection: CollectionView): Row {
        val (sort, reversed) = asRowSort(collection.sort, null, allSorts)
        return Row(newRowId(), false, Kind.Collection(collection, sort, reversed, ""))
    }
}
