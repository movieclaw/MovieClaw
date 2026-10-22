package io.movieclaw.androidtv.ui.library

import io.movieclaw.core.model.generated.FacetValueView
import io.movieclaw.core.model.generated.LibraryFacetsView
import io.movieclaw.core.model.generated.LibraryIndexEntryView
import io.movieclaw.core.model.generated.RelaxSuggestionView
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WallIndexTest {
    private fun raw(vararg entries: Triple<String, Long, Long>) = entries.map { LibraryIndexEntryView(it.first, it.second, it.third) }

    @Test
    fun lettersListTheWholeAlphabetWithEmptyOnesDimmed() {
        val entries = WallIndex.entries("title", false, raw(Triple("A", 10, 0), Triple("C", 5, 10), Triple("#", 2, 15)))
        assertEquals(27, entries.size)
        assertEquals("A", entries.first().key)
        assertEquals("#", entries.last().key)
        assertEquals(0, entries.first { it.key == "B" }.count)
        assertNull(entries.first { it.key == "B" }.offset)
        assertEquals(10, entries.first { it.key == "C" }.offset)
        // Z–A：整条倒过来，# 在最前
        assertEquals("#", WallIndex.entries("title", true, emptyList()).first().key)
    }

    @Test
    fun yearsMergeMonthsAndFoldOldOnesIntoDecades() {
        // 旧服务端回月份档：同一年的几档挨着，并起来部数相加、起点取最前
        val entries = WallIndex.entries(
            "release_date",
            false,
            raw(
                Triple("2024-11", 3, 0), Triple("2024-02", 2, 3),
                Triple("2021", 4, 5),
                Triple("1998-05", 1, 9), Triple("1993", 2, 10), Triple("1987", 1, 12),
                Triple("未知", 6, 13),
            ),
        )
        assertEquals(listOf("2024", "2023", "2022", "2021", "1990s", "1980s", "unknown"), entries.map { it.key })
        assertEquals(WallIndexEntry("2024", "2024", "2024", 5, 0), entries[0])
        assertEquals(0, entries[1].count)
        assertEquals(WallIndexEntry("1990s", "90s", "1990 年代", 3, 9), entries[4])
        assertEquals(WallIndexEntry("unknown", "?", "未知年份", 6, 13), entries.last())
        // 最早上映：年份倒过来，未知仍在最后
        val reversed = WallIndex.entries("release_date", true, raw(Triple("1985", 1, 0), Triple("2001", 1, 1), Triple("未知", 1, 2)))
        assertEquals(listOf("1980s", "2001", "unknown"), reversed.map { it.key })
    }

    @Test
    fun ratingBuckets() {
        val entries = WallIndex.entries("rating", false, raw(Triple("9+", 3, 0), Triple("更低", 10, 3), Triple("未评分", 2, 13)))
        assertEquals(listOf("9+", "<7", "—"), entries.map { it.label })
        assertEquals(listOf("9 分以上", "7 分以下", "未评分"), entries.map { it.title })
    }

    @Test
    fun onlyTitleReleaseAndRatingHaveAnIndex() {
        assertTrue(WallIndex.supports("title"))
        assertTrue(WallIndex.supports("release_date"))
        assertTrue(WallIndex.supports("rating"))
        assertFalse(WallIndex.supports("added_at"))
        assertEquals(emptyList<WallIndexEntry>(), WallIndex.entries("added_at", false, raw(Triple("A", 1, 0))))
    }

    @Test
    fun entryAtFindsTheBucketAnOffsetFallsIn() {
        val entries = WallIndex.entries("title", false, raw(Triple("A", 10, 0), Triple("C", 5, 10), Triple("#", 2, 15)))
        assertEquals("A", WallIndex.entryAt(0, entries)?.key)
        assertEquals("A", WallIndex.entryAt(9, entries)?.key)
        assertEquals("C", WallIndex.entryAt(10, entries)?.key)
        assertEquals("#", WallIndex.entryAt(16, entries)?.key)
    }

    @Test
    fun conditionsUseTvNames() {
        val facets = LibraryFacetsView(
            total = 49,
            genres = listOf(FacetValueView("37", "西部", 137)),
            decades = listOf(FacetValueView("2010s", "2010s", 20)),
            resolutions = listOf(FacetValueView("2160p", "2160p", 49), FacetValueView("1080p", "1080p", 52)),
            hdr = listOf(FacetValueView("1", "HDR", 27), FacetValueView("0", "SDR", 100)),
        )
        val picks = WallPicks(genre = 37, decade = "2010s", quality = "2160p")
        assertEquals(listOf("西部", "2010 年代", "4K", "未看"), WallFilters.conditions(picks, true, facets))
        assertEquals("西部 · 4K · 49 部", WallFilters.summary(listOf("西部", "4K"), 49))
        assertNull(WallFilters.summary(emptyList(), null))
        // 画质：分辨率 + 一档 HDR；年代改成「年代」
        assertEquals(listOf("4K", "1080p", "HDR"), WallFilters.qualityOptions(facets)?.map { it.label })
        assertEquals(WallPicks.HDR, WallFilters.qualityOptions(facets)?.last()?.value)
        assertEquals(listOf("2010 年代"), WallFilters.decadeOptions(facets)?.map { it.label })
        assertEquals("HDR", WallFilters.qualityLabel(WallPicks.HDR, null))
    }

    @Test
    fun relaxRemovesOneDimension() {
        val picks = WallPicks(genre = 37, decade = "2010s", quality = WallPicks.HDR)
        assertEquals(picks.copy(genre = null) to true, WallFilters.remove("genres", picks, true))
        assertEquals(picks.copy(quality = null) to true, WallFilters.remove("hdr", picks, true))
        assertEquals(picks to false, WallFilters.remove("watch", picks, true))
        assertEquals("4K", WallFilters.relaxLabel(RelaxSuggestionView(dim = "resolutions", value = "2160p", label = "2160p", count = 58)))
        assertEquals("2010 年代", WallFilters.relaxLabel(RelaxSuggestionView(dim = "decades", value = "2010s", label = "2010s", count = 1)))
        assertEquals("未看", WallFilters.relaxLabel(RelaxSuggestionView(dim = "watch", value = "unwatched", label = "未看", count = 49)))
    }

    @Test
    fun addedMonth() {
        assertEquals("2026 年 8 月", WallFilters.addedMonth("2026-08-03T10:00:00"))
        assertNull(WallFilters.addedMonth(null))
        assertNull(WallFilters.addedMonth("bad"))
    }

    /** 3000 部、按 offset 切片的假数据源 */
    private fun source(total: Int = 3000): suspend (Long, Long) -> List<WallItem> = { offset, limit ->
        (offset until minOf(offset + limit, total.toLong())).map { WallItem(it, 1, "片 $it", null, null, null) }
    }

    @Test
    fun pagerJumpsThenFillsUpwards() = runBlocking {
        val pager = WallPager()
        pager.reset("k", source())
        assertEquals(0, pager.start)
        assertEquals(60, pager.items?.size)
        // 跳到库中间：窗口换成从那里开始的一页
        pager.jump(1200)
        assertEquals(1200, pager.start)
        assertEquals(1200L, pager.items?.first()?.id)
        assertEquals(1259, pager.offsetOf(1259))
        assertNull(pager.offsetOf(1260))
        // 往上补一页：起点前移一页，原来的条目还在后面
        assertEquals(60, pager.loadPrevious())
        assertEquals(1140, pager.start)
        assertEquals(120, pager.items?.size)
        assertEquals(1200, pager.offsetOf(1200))
        // 往下接着取
        pager.loadMore()
        assertEquals(180, pager.items?.size)
        // 从头补到 0 就停
        pager.jump(30)
        assertEquals(30, pager.loadPrevious())
        assertEquals(0, pager.start)
        assertEquals(0, pager.loadPrevious())
    }

    @Test
    fun pagerStopsAtTheEnd() = runBlocking {
        val pager = WallPager()
        pager.reset("k", source(total = 70))
        pager.loadMore()
        assertEquals(70, pager.items?.size)
        pager.loadMore()
        assertEquals(70, pager.items?.size)
    }

    @Test
    fun pagerResetClearsWindowAndReportsFailure() = runBlocking {
        val pager = WallPager()
        pager.reset("k", source())
        pager.jump(600)
        pager.reset("other") { _, _ -> throw java.io.IOException("断网") }
        assertEquals(0, pager.start)
        assertEquals(emptyList<WallItem>(), pager.items)
        assertEquals("断网", pager.failed)
        assertEquals("other", pager.loadedKey)
    }

    /** 数据源里请求可以被扣住：按 offset 放行，模拟两页同时在路上、先后不定 */
    private class HeldSource {
        val held = HashMap<Long, kotlinx.coroutines.CompletableDeferred<Unit>>()
        var holding = false
        val fetch: suspend (Long, Long) -> List<WallItem> = { offset, limit ->
            if (holding) held.getOrPut(offset) { kotlinx.coroutines.CompletableDeferred() }.await()
            (offset until minOf(offset + limit, 3000L)).map { WallItem(it, 1, "片 $it", null, null, null) }
        }
    }

    @Test
    fun pagerKeepsBothPagesWhenUpAndDownLoadsOverlap() = runBlocking {
        val source = HeldSource()
        val pager = WallPager()
        pager.reset("k", source.fetch)
        pager.jump(1200)
        source.holding = true
        // 往下与往上同时在路上：先回往下的那页，再回往上的那页
        val down = launch { pager.loadMore() }
        val up = async { pager.loadPrevious() }
        kotlinx.coroutines.yield()
        source.held.getValue(1260).complete(Unit)
        down.join()
        source.held.getValue(1140).complete(Unit)
        assertEquals(60, up.await())
        assertEquals(1140, pager.start)
        assertEquals((1140L until 1320L).toList(), pager.items?.map { it.id })
    }

    @Test
    fun pagerDropsAnEarlierPageThatArrivesAfterAJump() = runBlocking {
        val source = HeldSource()
        val pager = WallPager()
        pager.reset("k", source.fetch)
        pager.jump(1200)
        source.holding = true
        val up = async { pager.loadPrevious() }
        kotlinx.coroutines.yield()
        // 补页还没回来就跳到了别处：晚到的那页作废，新窗口的起点不被挪动
        val jump = launch { pager.jump(600) }
        kotlinx.coroutines.yield()
        source.held.getValue(600).complete(Unit)
        jump.join()
        source.held.getValue(1140).complete(Unit)
        assertEquals(0, up.await())
        assertEquals(600, pager.start)
        assertEquals(600L, pager.items?.first()?.id)
        assertEquals(60, pager.items?.size)
    }
}
