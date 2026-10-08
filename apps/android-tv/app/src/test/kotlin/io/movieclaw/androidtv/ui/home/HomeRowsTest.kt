package io.movieclaw.androidtv.ui.home

import io.movieclaw.androidtv.core.model.generated.CollectionView
import io.movieclaw.androidtv.core.model.generated.HomeRowPref
import io.movieclaw.androidtv.core.model.generated.LibraryView
import org.junit.Assert.assertEquals
import org.junit.Test

/** 与 Web / Apple 端同一份合并规则（LibraryHomeRows.swift） */
class HomeRowsTest {
    private val movies = LibraryView(id = 1, name = "电影", kind = "movie", viewerAccess = true)
    private val shows = LibraryView(id = 2, name = "剧集", kind = "tv", viewerAccess = true)
    private val hiddenLib = LibraryView(id = 3, name = "私人", kind = "movie", viewerAccess = false)
    private val col = CollectionView(id = 9, name = "漫威", sort = "release_date")

    @Test
    fun factoryLayout() {
        val rows = HomeRows.build(emptyList(), listOf(movies, shows, hiddenLib), emptyList())
        assertEquals(listOf("up-next", "favorites", "libraries", "genres:movie", "genres:tv", "lib:1", "lib:2"), rows.map { it.id })
        assertEquals("最近添加的电影", rows.first { it.id == "lib:1" }.title)
    }

    @Test
    fun savedRowsFirstThenMissingInserted() {
        val prefs = listOf(
            HomeRowPref(id = "lib:2", sort = "rating"),
            HomeRowPref(id = "libraries"),
            HomeRowPref(id = "row:abc123", collectionId = 9),
        )
        val rows = HomeRows.build(prefs, listOf(movies, shows), listOf(col))
        assertEquals(
            listOf("lib:2", "lib:1", "libraries", "genres:movie", "genres:tv", "row:abc123", "up-next", "favorites"),
            rows.map { it.id },
        )
        assertEquals("评分最高的剧集", rows[0].title)
        assertEquals("漫威", rows.first { it.id == "row:abc123" }.title)
    }

    @Test
    fun reversedOrderAndLegacySort() {
        val rows = HomeRows.build(
            listOf(HomeRowPref(id = "lib:1", sort = "title", order = "desc"), HomeRowPref(id = "lib:2", sort = "release_date_asc")),
            listOf(movies, shows),
            emptyList(),
        )
        assertEquals("电影 Z–A", rows[0].title)
        assertEquals("最早上映的剧集", rows[1].title)
        assertEquals("lib:1:title:true:false", HomeRows.fetchKey(rows[0]))
    }

    @Test
    fun lastPlayedDisablesUnwatchedAndHiddenKindRowsDrop() {
        val rows = HomeRows.build(
            listOf(HomeRowPref(id = "lib:1", sort = "last_played", unwatched = true), HomeRowPref(id = "kind:movie", hidden = true)),
            listOf(movies),
            emptyList(),
        )
        val lib = rows.first { it.id == "lib:1" }.kind as HomeRows.Kind.Library
        assertEquals(false, lib.unwatched)
        assertEquals(false, rows.any { it.id == "kind:movie" })
    }
}
