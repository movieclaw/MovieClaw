package io.movieclaw.android.feature.detail

import androidx.compose.runtime.Composable
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.model.LibraryItemDetailView
import io.movieclaw.android.core.offline.OfflineDownloadChoices
import io.movieclaw.android.feature.offline.OfflineProfileSheet
import io.movieclaw.android.feature.offline.rememberOffline

/** 要打开的选档面板：单个文件（电影、分集长按「下载这一集」、改下其他画质）/ 剧集按范围 */
sealed interface DownloadSheetTarget {
    data class File(val fileId: Long, val title: String) : DownloadSheetTarget
    data object Series : DownloadSheetTarget
}

/**
 * 下载面板宿主（iOS 详情页里 `.sheet { OfflineProfileSheet(...) }` 的对应物）。
 * 剧集范围照 iOS `downloadChoices`：在库的集、各自的本机状态，选中的集 = 详情页选中的那一集。
 */
@Composable
fun ItemDownloadHost(
    detail: LibraryItemDetailView?,
    episodes: Map<Int, List<EpisodeView>>,
    selected: ItemDetailViewModel.SelectedUnit?,
    target: DownloadSheetTarget?,
    onDismiss: () -> Unit,
) {
    if (target == null || detail == null) return
    val offline = rememberOffline()
    when (target) {
        is DownloadSheetTarget.File -> OfflineProfileSheet(
            title = target.title,
            ranged = false,
            loadChoices = {
                OfflineDownloadChoices.Choices(listOf(OfflineDownloadChoices.Scope("file", target.title, null, listOf(target.fileId))), null)
            },
            onDismiss = onDismiss,
        )
        DownloadSheetTarget.Series -> OfflineProfileSheet(
            title = detail.title,
            ranged = true,
            loadChoices = {
                val store = offline.store()
                val owned = detail.files.map { it.seasonNumber }.toSet()
                val all = episodes.entries.filter { it.key in owned }.sortedBy { it.key }.flatMap { (season, list) ->
                    list.filter { it.owned }.sortedBy { it.episodeNumber }.map { ep ->
                        val unit = store.unit(detail.mediaItemId, season, ep.episodeNumber)
                        OfflineDownloadChoices.Episode(
                            season = season,
                            episode = ep.episodeNumber,
                            file = ep.fileIds.firstOrNull(),
                            played = ep.played,
                            local = unit?.let { if (it.playable) "done" else "active" },
                        )
                    }
                }
                OfflineDownloadChoices.make(all, selected?.let { it.season to it.episode }, null, detail.seasons.size > 1)
            },
            onDismiss = onDismiss,
        )
    }
}
