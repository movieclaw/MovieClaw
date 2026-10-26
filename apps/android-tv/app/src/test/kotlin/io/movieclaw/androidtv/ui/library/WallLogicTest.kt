package io.movieclaw.androidtv.ui.library

import io.movieclaw.androidtv.ui.detail.WallLayout
import io.movieclaw.androidtv.ui.shell.WallSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WallLogicTest {
    @Test
    fun orderOnlyWhenReversed() {
        assertNull(WallLogic.orderParam("added_at", false))
        assertEquals("asc", WallLogic.orderParam("added_at", true))
        assertEquals("asc", WallLogic.orderParam("rating", true))
        assertEquals("asc", WallLogic.orderParam("last_played", true))
        // 片名自然升序，反转是 desc
        assertNull(WallLogic.orderParam("title", false))
        assertEquals("desc", WallLogic.orderParam("title", true))
        // 没有方向的档位从不带 order
        assertNull(WallLogic.orderParam("random", true))
        assertNull(WallLogic.orderParam("unwatched_first", true))
    }

    @Test
    fun watchParam() {
        assertEquals("seen", WallLogic.watchParam("last_played", false))
        assertEquals("seen", WallLogic.watchParam("last_played", true))
        assertEquals("unwatched", WallLogic.watchParam("added_at", true))
        assertNull(WallLogic.watchParam("added_at", false))
    }

    @Test
    fun libraryWallQuery() {
        assertEquals(
            WallQuery(WallQuery.Endpoint.Library, id = 3, sort = "added_at"),
            WallLogic.libraryQuery(3, WallSort("added_at")),
        )
        assertEquals(
            WallQuery(WallQuery.Endpoint.Library, id = 3, sort = "title", order = "desc", w = "unwatched"),
            WallLogic.libraryQuery(3, WallSort("title", reversed = true), WallFilters.of(WallPicks(), unwatched = true)),
        )
        // 类型 / 年代 / 画质：画质里的 HDR 是 hdr=true，其余是分辨率
        assertEquals(
            WallQuery(WallQuery.Endpoint.Library, id = 3, sort = "rating", g = "37", d = "1990s", res = "2160p"),
            WallLogic.libraryQuery(3, WallSort("rating"), WallFilters.of(WallPicks(37, "1990s", "2160p"), unwatched = false)),
        )
        assertEquals(
            WallQuery(WallQuery.Endpoint.Library, id = 3, sort = "rating", hdr = true),
            WallLogic.libraryQuery(3, WallSort("rating"), WallFilters.of(WallPicks(quality = WallPicks.HDR), unwatched = false)),
        )
    }

    @Test
    fun rowWallQueries() {
        assertEquals(
            WallQuery(WallQuery.Endpoint.Library, id = 2, sort = "last_played", w = "seen"),
            WallLogic.rowQuery(WallSource.Library(2, "last_played", reversed = false, unwatched = true)),
        )
        assertEquals(
            WallQuery(WallQuery.Endpoint.Library, id = 2, sort = "release_date", order = "asc", w = "unwatched"),
            WallLogic.rowQuery(WallSource.Library(2, "release_date", reversed = true, unwatched = true)),
        )
        assertEquals(
            WallQuery(WallQuery.Endpoint.MediaKind, kind = "movie", sort = "rating"),
            WallLogic.rowQuery(WallSource.MediaKind("movie", "rating", reversed = false, unwatched = false)),
        )
        assertEquals(
            WallQuery(WallQuery.Endpoint.Collection, id = 9, sort = "title", order = "desc"),
            WallLogic.rowQuery(WallSource.Collection(9, "title", reversed = true)),
        )
        assertEquals(
            WallQuery(WallQuery.Endpoint.MediaKind, kind = "tv", sort = "added_at", g = "18"),
            WallLogic.rowQuery(WallSource.Genre("tv", 18, 42)),
        )
        // 未看优先：sort 换成收藏时间、带 unwatched_first，不带 order
        assertEquals(
            WallQuery(WallQuery.Endpoint.Favorites, sort = "favorited_at", unwatchedFirst = true),
            WallLogic.rowQuery(WallSource.Favorites("unwatched_first", reversed = true, total = 5)),
        )
        assertEquals(
            WallQuery(WallQuery.Endpoint.Favorites, sort = "favorited_at", order = "asc", unwatchedFirst = false),
            WallLogic.rowQuery(WallSource.Favorites("favorited_at", reversed = true, total = 5)),
        )
    }

    @Test
    fun rowCount() {
        assertEquals(120L, WallLogic.rowCount(WallSource.Library(1, "added_at", false, false), 120))
        assertEquals(80L, WallLogic.rowCount(WallSource.Library(1, "added_at", false, false, count = 80), 120))
        assertNull(WallLogic.rowCount(WallSource.Library(1, "added_at", false, true), 120))
        assertNull(WallLogic.rowCount(WallSource.Library(1, "last_played", false, false), 120))
        assertEquals(5L, WallLogic.rowCount(WallSource.Favorites("favorited_at", false, 5), null))
        assertEquals(42L, WallLogic.rowCount(WallSource.Genre("movie", 28, 42), null))
        assertNull(WallLogic.rowCount(WallSource.MediaKind("movie", "added_at", false, false), 10))
        assertNull(WallLogic.rowCount(WallSource.Collection(1, "added_at", false), 10))
    }

    @Test
    fun labels() {
        assertEquals("排序与筛选 · 最近添加", WallLogic.sortButtonLabel("added_at"))
        assertEquals("排序与筛选 · A–Z", WallLogic.sortButtonLabel("title"))
        assertEquals(listOf("最近添加", "最近上映", "评分最高", "A–Z"), WallLogic.LIBRARY_SORTS.map { WallLogic.shortLabel(it) })
        assertEquals("Z–A", WallLogic.shortLabel("title", true))
    }

    @Test
    fun sortPersistence() {
        assertEquals("movieclaw.tv.wall-sort.7", WallLogic.sortKey(7))
        val saved = WallLogic.encodeSort(WallSort("rating", true))
        assertEquals(WallSort("rating", true), WallLogic.decodeSort(saved))
        assertEquals(WallSort("added_at"), WallLogic.decodeSort(null))
        assertEquals(WallSort("added_at"), WallLogic.decodeSort("not json"))
        // 电视上不提供的档位退回默认
        assertEquals(WallSort("added_at"), WallLogic.decodeSort(WallLogic.encodeSort(WallSort("random"))))
        assertEquals(WallSort("title"), WallLogic.decodeSort("""{"sort":"title"}"""))
    }

    @Test
    fun collectionSort() {
        // 「合集顺序」不传排序，由服务端按合集自己的顺序给
        assertEquals(WallQuery(WallQuery.Endpoint.Collection, id = 4), WallLogic.collectionQuery(4, WallSort(WallLogic.COLLECTION_ORDER)))
        assertEquals(
            WallQuery(WallQuery.Endpoint.Collection, id = 4, sort = "release_date", order = "asc"),
            WallLogic.collectionQuery(4, WallSort("release_date", reversed = true)),
        )
        assertEquals(listOf("合集顺序", "最近添加", "最近上映", "评分最高", "A–Z"), WallLogic.COLLECTION_SORTS.map(WallLogic::collectionLabel))
        assertEquals("movieclaw.tv.collection-sort.4", WallLogic.collectionSortKey(4))
        val fallback = WallSort(WallLogic.COLLECTION_ORDER)
        assertEquals(fallback, WallLogic.decodeSort(null, WallLogic.COLLECTION_SORTS, fallback))
        assertEquals(WallSort("title"), WallLogic.decodeSort("""{"sort":"title"}""", WallLogic.COLLECTION_SORTS, fallback))
    }

    @Test
    fun wallLayout() {
        assertEquals(332.8f, WallLayout.POSTER_WIDTH, 0.001f)
    }
}
