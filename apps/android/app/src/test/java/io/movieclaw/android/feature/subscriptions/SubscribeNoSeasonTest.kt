package io.movieclaw.android.feature.subscriptions

import io.movieclaw.android.core.model.MediaBrief
import io.movieclaw.android.core.model.PrepareView
import io.movieclaw.android.core.model.SubscriptionView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** 剧集订阅「一季都不勾」：弹层守卫与海报下文案 */
class SubscribeNoSeasonTest {
    private fun sheet(status: String?, seasons: Set<Int>, follow: Boolean, kind: String = "tv") =
        SubscribeViewModel.UiState(
            loading = false,
            preview = PrepareView(status = "ok", media = MediaBrief(kind = kind, title = "暗潮之下", status = status)),
            selectedSeasons = seasons,
            followFuture = follow,
        )

    @Test fun endedShowWithoutSeasonsCannotSubmitEvenWithAutoRenew() {
        // 用户报的场景：完结剧、一季不勾、自动续订开着 → 以前会落下一条 0 集、立刻「已收齐」的空订阅
        assertNotNull(submitBlockReason(sheet("Ended", emptySet(), follow = true)))
        assertNotNull(submitBlockReason(sheet("Canceled", emptySet(), follow = true)))
    }

    @Test fun noSeasonsNeedsAutoRenewOnAiringShow() {
        assertNotNull(submitBlockReason(sheet("Returning Series", emptySet(), follow = false)))
        assertNull(submitBlockReason(sheet("Returning Series", emptySet(), follow = true)))
    }

    @Test fun selectedSeasonOrMovieAlwaysSubmits() {
        assertNull(submitBlockReason(sheet("Ended", setOf(1), follow = false)))
        assertNull(submitBlockReason(sheet("Released", emptySet(), follow = false, kind = "movie")))
    }

    private fun sub(seasons: List<Int>, follow: Boolean, status: String, imported: Int = 0, total: Int = 0) =
        SubscriptionView(
            id = 1,
            media = MediaBrief(kind = "tv", title = "暗潮之下", year = 2024),
            status = status,
            selectedSeasons = seasons,
            followFuture = follow,
            progress = io.movieclaw.android.core.model.ProgressView(imported = imported, total = total),
        )

    @Test fun shelfMetaNeverInventsSeasonOne() {
        assertEquals("第 2 季 · 3 / 8", tvShelfMeta(sub(listOf(2), false, "active", 3, 8)))
        assertEquals("仅追新集", tvShelfMeta(sub(emptyList(), true, "active")))
        // 截图里的「第 1 季 · 0 / 0」：没勾季、已收齐 → 只写年份
        assertEquals("2024", tvShelfMeta(sub(emptyList(), true, "completed")))
    }
}
