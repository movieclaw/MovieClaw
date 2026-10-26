package io.movieclaw.android.feature.subscriptions

import io.movieclaw.android.core.model.SubscriptionDownloadView
import io.movieclaw.android.core.model.WantedView
import org.junit.Assert.assertEquals
import org.junit.Test

/** 订阅详情的在途下载：一个种子一行（《牧神记》实例：E84–E102 同一个全集包） */
class DownloadGroupingTest {
    private fun unit(ep: Int, hash: String?) = WantedView(id = ep.toLong(), seasonNumber = 1, episodeNumber = ep, status = "grabbed", infoHash = hash)
    private fun dl(hash: String) = SubscriptionDownloadView(infoHash = hash, state = "downloading", progress = 0.0011)

    @Test fun packEpisodesCollapseIntoOneRow() {
        val units = (84..102).map { unit(it, "pack") } + unit(103, "a") + unit(104, "b") + unit(105, null)
        val rows = liveDownloads(units, mapOf("pack" to dl("pack"), "a" to dl("a"), "b" to dl("b")))
        assertEquals(3, rows.size)
        assertEquals(listOf("E84–E102 · 19 集", "E103", "E104"), rows.map { downloadUnitsLabel(it.first) })
    }

    @Test fun episodesAlreadyImportedFromThePackDropOut() {
        // 大包分批入库：E84–E89 已经单集入库，仍带着同一个种子 hash
        val units = (84..102).map { ep ->
            if (ep <= 89) unit(ep, "pack").copy(status = "imported", importedAt = "2026-10-11T03:30:00") else unit(ep, "pack")
        }
        val rows = liveDownloads(units, mapOf("pack" to dl("pack")))
        assertEquals(listOf("E90–E102 · 13 集"), rows.map { downloadUnitsLabel(it.first) })
    }

    @Test fun packEpisodesCarryTheirOwnProgress() {
        val units = (84..86).map { unit(it, "pack") }
        val snap = dl("pack").copy(
            units = listOf(
                io.movieclaw.android.core.model.DownloadUnitView(1, 84, 1.0),
                io.movieclaw.android.core.model.DownloadUnitView(1, 85, 0.45),
                io.movieclaw.android.core.model.DownloadUnitView(1, 86, null),  // 认不出集号：不给
            ),
        )
        assertEquals(listOf(84 to 1.0, 85 to 0.45), packEpisodeProgress(units, snap))
        // 单集种子不出格子：整包进度就是这一集的
        assertEquals(emptyList<Pair<Int, Double>>(), packEpisodeProgress(listOf(unit(104, "b")), dl("b")))
    }

    @Test fun absurdEtaReadsAsSlow() {
        val note = downloadNote(SubscriptionDownloadView(infoHash = "x", state = "downloading", progress = 0.0, dlspeedBytes = 3, etaSeconds = 6_369_840))
        assertEquals(true, note.contains("速度很慢"))
        assertEquals(false, note.contains("小时"))
    }
}
