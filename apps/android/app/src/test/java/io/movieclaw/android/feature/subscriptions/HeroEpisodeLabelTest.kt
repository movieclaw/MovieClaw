package io.movieclaw.android.feature.subscriptions

import io.movieclaw.android.core.model.TodayArrivalFull
import org.junit.Assert.assertEquals
import org.junit.Test

/** 订阅首页英雄位的集号：补旧番时不把几十段区间铺满半屏 */
class HeroEpisodeLabelTest {
    private fun group(episodes: List<Int>, season: Int = 1) = ArrivalGroup(
        subscriptionId = 1, daysAhead = 0, expectedDay = null, mediaTitle = "吞噬星空", mediaKind = "tv",
        units = episodes.map { TodayArrivalFull(subscriptionId = 1, seasonNumber = season, episodeNumber = it) },
        task = null, presentation = ArrivalPresentation("下载中", null, androidx.compose.ui.graphics.Color.White, glows = true), progress = null,
    )

    @Test fun shortRunsKeepRanges() {
        assertEquals("S01E05", group(listOf(5)).heroLabel)
        assertEquals("S01E01–E03、E05", group(listOf(1, 2, 3, 5)).heroLabel)
    }

    @Test fun fragmentedBackfillCollapsesToCount() {
        // 截图里的那一批：E01–E27、E39–E44、E51、E56、E58–E70、E72–E78、E80、E82–E88、E91–E92、E97、E99、E210、E238
        val eps = (1..27) + (39..44) + listOf(51, 56) + (58..70) + (72..78) + listOf(80) + (82..88) + listOf(91, 92, 97, 99, 210, 238)
        assertEquals("S01 · 共 ${eps.size} 集", group(eps).heroLabel)
        // 日程行仍是完整区间（那里是单行省略）
        assertEquals(true, group(eps).episodeLabel.startsWith("S01E01–E27、E39–E44"))
    }
}
