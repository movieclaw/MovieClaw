package io.movieclaw.android.feature.detail

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.model.LibraryItemDetailView
import io.movieclaw.android.core.model.LibraryItemDetailView as DetailView
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.offline.OfflineDownloadChoices
import io.movieclaw.android.core.offline.OfflineDownloader
import io.movieclaw.android.core.offline.OfflineStore
import io.movieclaw.android.feature.offline.DownloadScopeSheet

/** 「⋯」菜单里点「下载」时要打开的面板：电影 = 单文件；剧集 = 先算范围（iOS `downloadingMovie` / `downloadingSeries`） */
sealed interface DownloadSheetTarget {
    data class Movie(val fileId: Long) : DownloadSheetTarget
    data object Series : DownloadSheetTarget
}

/**
 * 下载面板宿主（iOS 详情页里 `.sheet { OfflineProfileSheet(...) }` 的对应物）：
 * 打开时按当前详情与本机状态算出范围，再交给 [DownloadScopeSheet]；
 * 选了档位点「下载」→ [ItemDetailViewModel.startOfflineDownload]。
 *
 * 剧集范围规则照 iOS `OfflineDownloadChoices.make`（见 core/offline/OfflineDownloadChoices.kt）。
 */
@Composable
fun AndroidDownloadScopeHost(
    vm: ItemDetailViewModel,
    detail: LibraryItemDetailView?,
    episodes: Map<Int, List<EpisodeView>>,
    target: DownloadSheetTarget?,
    offlinePacks: List<OfflineStore.Pack>,
    offlineKnown: Map<Long, OfflineStore.Pack>,
    onDismiss: () -> Unit,
) {
    if (target == null || detail == null) return

    val activeFileIds = offlineKnown.keys
    val doneFileIds = offlinePacks.map { it.fileId }.toSet()
    val multiSeason = episodes.keys.count { episodes[it].orEmpty().isNotEmpty() } > 1

    // 本机状态：done > active > 没有
    fun localOf(fileId: Long?): String? = when {
        fileId == null -> null
        fileId in doneFileIds -> "done"
        fileId in activeFileIds -> "active"
        else -> null
    }

    val choices: OfflineDownloadChoices.Choices? = when (target) {
        is DownloadSheetTarget.Movie ->
            OfflineDownloadChoices.Choices(
                scopes = listOf(
                    OfflineDownloadChoices.Scope("file", detail.title, null, listOf(target.fileId), preferred = true),
                ),
                note = null,
            )
        DownloadSheetTarget.Series -> {
            val all = episodes.entries.sortedBy { it.key }.flatMap { (season, list) ->
                list.sortedBy { it.episodeNumber }.map { ep ->
                    OfflineDownloadChoices.Episode(
                        season = season,
                        episode = ep.episodeNumber,
                        file = ep.fileIds.firstOrNull(),
                        played = ep.played,
                        local = localOf(ep.fileIds.firstOrNull()),
                    )
                }
            }
            // 选中的集：用已看过 / 当前播放位置判断（iOS 用 selectedEpisode）
            val selected = all.firstOrNull { it.local == null }?.let { it.season to it.episode }
                ?: all.firstOrNull()?.let { it.season to it.episode }
            OfflineDownloadChoices.make(all, selected, null, multiSeason)
        }
    }

    if (choices == null || choices.scopes.isEmpty()) return

    val defaultProfile by vm.lastDownloadProfile.collectAsStateWithLifecycle()
    DownloadScopeSheet(
        title = detail.title,
        scopes = choices.scopes,
        note = choices.note,
        deviceName = vm.deviceName,
        defaultProfile = defaultProfile,
        freeBytes = vm.freeBytes(),
        loadProfiles = { ids -> vm.offlineProfiles(ids) },
        onDismiss = onDismiss,
        onStart = { fileIds, profile ->
            onDismiss()
            vm.startOfflineDownload(detail, fileIds, profile)
        },
    )
}
