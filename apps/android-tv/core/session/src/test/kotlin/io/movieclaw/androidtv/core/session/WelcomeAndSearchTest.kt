package io.movieclaw.androidtv.core.session

import io.movieclaw.androidtv.core.model.generated.LibraryItemView
import io.movieclaw.androidtv.core.model.generated.LibrarySearchHit
import io.movieclaw.androidtv.core.model.generated.LibrarySearchMatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WelcomeAndSearchTest {
    @Test
    fun quotesAreCompleteAndRotate() {
        val all = WelcomeScene.all
        assertEquals(68, all.size)
        assertEquals("毕竟，明天又是新的一天。", all.first().line)
        assertEquals("《流浪地球》2019", all.last().credit)
        assertTrue(all.all { it.line.isNotBlank() && it.film.isNotBlank() && it.year in 1930..2030 })
        assertTrue(all.none { it.original?.isBlank() == true })
        // 华语片没有原句
        assertNull(all.first { it.film == "让子弹飞" }.original)
        assertEquals(all.map { it.id }, all.indices.toList())
        // 轮播一直加一，转回开头
        assertEquals(all[0], WelcomeScene.at(all, all.size))
        assertEquals(all[1], WelcomeScene.at(all, all.size + 1))
        assertNull(WelcomeScene.at(emptyList(), 3))
    }

    private fun hit(id: Long, title: String = "t$id", personId: Long? = null, libraryId: Long? = null, libs: List<Long> = emptyList()) =
        LibrarySearchHit(
            item = LibraryItemView(mediaItemId = id, title = title, kind = "movie", year = 2014, libraryId = libraryId),
            libraryIds = libs,
            match = LibrarySearchMatch(label = "首字母匹配", personId = personId),
        )

    @Test
    fun pagesAppendWithoutDuplicates() {
        val first = listOf(hit(1), hit(2), hit(3))
        val merged = SearchResults.merge(first, listOf(hit(3, "新标题"), hit(4), hit(4), hit(5)))
        assertEquals(listOf(1L, 2L, 3L, 4L, 5L), merged.map { it.item.mediaItemId })
        // 已有的保持原样，不被下一页覆盖
        assertEquals("t3", merged[2].item.title)
    }

    @Test
    fun cardCaptions() {
        assertEquals("2014 · 电影", SearchResults.subtitle(hit(1)))
        assertEquals("剧集", SearchResults.subtitle(LibrarySearchHit(item = LibraryItemView(kind = "tv"))))
        assertEquals("", SearchResults.subtitle(LibrarySearchHit(item = LibraryItemView(kind = "photo"))))
        assertEquals(7L, SearchResults.libraryId(hit(1, libraryId = 7, libs = listOf(9))))
        assertEquals(9L, SearchResults.libraryId(hit(1, libs = listOf(9, 10))))
        assertNull(SearchResults.libraryId(hit(1)))
        assertTrue(SearchResults.matchedByPerson(hit(1, personId = 3)))
        assertFalse(SearchResults.matchedByPerson(hit(1)))
    }
}
