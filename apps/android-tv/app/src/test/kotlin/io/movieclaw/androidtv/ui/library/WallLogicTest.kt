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
            WallLogic.libraryQuery(3, WallSort("added_at"), unwatched = false),
        )
        assertEquals(
            WallQuery(WallQuery.Endpoint.Library, id = 3, sort = "title", order = "desc", w = "unwatched"),
            WallLogic.libraryQuery(3, WallSort("title", reversed = true), unwatched = true),
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
        assertEquals("最近添加", WallLogic.sortButtonLabel("added_at", false))
        assertEquals("评分最高 · 未看", WallLogic.sortButtonLabel("rating", true))
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
    fun wallLayout() {
        assertEquals(332.8f, WallLayout.POSTER_WIDTH, 0.001f)
    }
}
