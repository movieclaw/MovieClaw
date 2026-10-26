package io.movieclaw.android.core.offline

/**
 * 剧集下载的范围（iOS `OfflineDownloadChoices` 的逐条对应物，docs/design/offline-download.md §8）：
 * 「第 N 集 / 接下来 5 集 / 未看 N 集 / 全部或剩余 N 集」四类候选，规则与文案照 iOS。
 *
 * 候选 = 有文件、本机还没有的集（下完的、在下的都不算）：
 * - 选中的集没下过 → 「第 N 集」；已下 / 在下 → 换成「接下来 5 集」（追剧边看边下）
 * - 「未看 N 集」：有没看的、且比剩余的少时才给，有它默认选它
 * - 「全部 N 集」（一集都没下过）/「剩余 N 集」（下过一些）
 * 内容相同的范围只留一个；只剩一个时面板不显示分段。
 */
object OfflineDownloadChoices {

    /** 一个范围：分段上给的字 + 要下的文件 + 下方说明 */
    data class Scope(
        val id: String,
        val label: String,
        val detail: String?,
        val fileIds: List<Long>,
        var preferred: Boolean = false,
    )

    /** 「这部剧为什么下载面板里只有这几集」的一句说明（已下载 N 集不会重复下载） */
    data class Choices(val scopes: List<Scope>, val note: String?)

    /**
     * 一集在库里的文件与本机状态
     * @param local null = 本机没有；"done" = 下完；"active" = 正在下（排队/下载中/暂停/失败）
     */
    data class Episode(
        val season: Int,
        val episode: Int,
        val file: Long?,
        val played: Boolean,
        val local: String?,
    )

    fun make(
        episodes: List<Episode>,
        selected: Pair<Int, Int>?,
        selectedFile: Long?,
        multiSeason: Boolean,
        nextCount: Int = 5,
    ): Choices {
        fun name(season: Int, episode: Int): String =
            if (multiSeason) "第 $season 季第 $episode 集" else "第 $episode 集"

        fun describe(list: List<Episode>): String {
            if (list.isEmpty()) return ""
            val first = list.first()
            val last = list.last()
            if (list.size == 1) return name(first.season, first.episode)
            if (first.season == last.season && last.episode - first.episode + 1 == list.size) {
                return "${if (multiSeason) "第 ${first.season} 季" else ""}第 ${first.episode}～${last.episode} 集，共 ${list.size} 集"
            }
            return "${name(first.season, first.episode)} 起，共 ${list.size} 集"
        }

        val candidates = episodes.filter { it.file != null && it.local == null }
        val done = episodes.count { it.local == "done" }
        val active = episodes.count { it.local == "active" }
        val scopes = mutableListOf<Scope>()
        val notes = mutableListOf<String>()

        if (selected != null) {
            val index = episodes.indexOfFirst { it.season == selected.first && it.episode == selected.second }
            if (index >= 0) {
                val current = episodes[index]
                if (current.local != null) {
                    notes += "${name(current.season, current.episode)}${if (current.local == "done") "已下载" else "正在下载"}"
                    val next = episodes.drop(index + 1)
                        .filter { it.file != null && it.local == null }
                        .take(nextCount)
                    // 正好是剩下的全部：只留「剩余」
                    if (next.isNotEmpty() && next.size < candidates.size) {
                        scopes += Scope("next", "接下来 ${next.size} 集", describe(next), next.mapNotNull { it.file })
                    }
                } else {
                    val file = selectedFile ?: current.file
                    if (file != null) {
                        scopes += Scope("selected", name(current.season, current.episode), name(current.season, current.episode), listOf(file))
                    }
                }
            }
        }

        if (done + active > 0) {
            val parts = buildList {
                if (done > 0) add("已下载 $done 集")
                if (active > 0) add("正在下载 $active 集")
            }
            notes += parts.joinToString("、") + "，不会重复下载"
        }

        val unwatched = candidates.filter { !it.played }
        if (unwatched.isNotEmpty() && unwatched.size < candidates.size) {
            scopes += Scope("unwatched", "未看 ${unwatched.size} 集", describe(unwatched), unwatched.mapNotNull { it.file }, preferred = true)
        }

        if (candidates.isNotEmpty()) {
            val label = if (done + active == 0) "全部 ${candidates.size} 集" else "剩余 ${candidates.size} 集"
            scopes += Scope("all", label, describe(candidates), candidates.mapNotNull { it.file })
        }

        // 内容相同的只留前一个（比如只剩选中的这一集）
        val seen = mutableSetOf<List<Long>>()
        val deduped = scopes.filter { seen.add(it.fileIds) }

        // 默认：有「未看」选未看；否则「接下来」；剩下的都没看过时选全部 / 剩余；都不是就第一个
        if (deduped.none { it.preferred }) {
            val fallback = deduped.indexOfFirst { it.id == "next" }
                .takeIf { it >= 0 }
                ?: if (unwatched.size == candidates.size) deduped.indexOfFirst { it.id == "all" }.takeIf { it >= 0 } else null
            if (fallback != null) deduped[fallback].preferred = true
        }
        return Choices(deduped, notes.takeIf { it.isNotEmpty() }?.joinToString(" · "))
    }
}
