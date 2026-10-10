package io.movieclaw.androidtv.ui.detail

import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.movieclaw.androidtv.core.model.generated.CollectionSeriesView
import io.movieclaw.androidtv.core.model.generated.EpisodeView
import io.movieclaw.androidtv.core.model.generated.LibraryItemDetailView
import io.movieclaw.androidtv.core.model.generated.PlaybackMarksRequest
import io.movieclaw.androidtv.core.model.generated.PlaybackStateView
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.CancellationException

/**
 * 首页「接下来继续」里这一部讲到第几季第几集（剧集打开时首屏直接讲它）。由首页那边注入；不注入时按片源挑季。
 * 参数是媒体条目 id，返回 (季, 集)。
 */
val LocalUpNextUnit = compositionLocalOf<(Long) -> Pair<Long, Long>?> { { null } }

/** 跑一个请求，失败给 null；取消照常往外抛（页面离开时不再往下写状态） */
internal suspend inline fun <T> attempt(crossinline block: suspend () -> T): T? = try {
    block()
} catch (e: CancellationException) {
    throw e
} catch (e: Exception) {
    null
}

/**
 * 一页按页面实例记住的状态：同一页从上层退回来时（外壳只组合栈顶，下面的页会被拆掉）直接拿回来，
 * 不转圈、焦点能落回原处；新压进来的页是新的实例。最多留 [MAX] 份。
 */
internal object PageStates {
    private const val MAX = 12
    private val map = object : LinkedHashMap<String, Any>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Any>?) = size > MAX
    }

    @Suppress("UNCHECKED_CAST")
    fun <T : Any> getOrPut(key: String, create: () -> T): T = synchronized(map) { map.getOrPut(key, create) as T }
}

/** 详情页的数据与动作（TVItemDetailView 的 @State + 加载函数） */
@Stable
internal class DetailState(
    private val api: McApi,
    val libraryId: Long,
    val itemId: Long,
    private val deviceId: String,
) {
    var detail by mutableStateOf<LibraryItemDetailView?>(null)
        private set
    var failed by mutableStateOf(false)
        private set
    /** 首屏讲的那一季、那一集（接着看的） */
    var season by mutableStateOf<Long?>(null)
        private set
    var episodes by mutableStateOf<List<EpisodeView>>(emptyList())
        private set
    var selectedEpisode by mutableStateOf<EpisodeView?>(null)
        private set
    /** 下半截正在看的那一季（换季只换下面的分集横排，首屏还讲接着看的那一集） */
    var browseSeason by mutableStateOf<Long?>(null)
        private set
    var browseEpisodes by mutableStateOf<List<EpisodeView>>(emptyList())
        private set
    /** 每次换季（或首次读到分集）+1：分集横排据此滚到要落焦点的那一集 */
    var browseScrollRequest by mutableIntStateOf(0)
        private set
    /** 下半截那一季服务端给的锚点（resume_episode）；没播放过或旧服务端为 null */
    var browseResume by mutableStateOf<Long?>(null)
        private set
    /** 刷新后锚点变了 +1：分集横排跳到 [browseJumpTarget]，焦点在横排里就跟过去 */
    var browseJumpRequest by mutableIntStateOf(0)
        private set
    var browseJumpTarget: Long? = null
        private set
    /** 分集横排现在停在哪一集（焦点所在、或刚跳过去的那一集）：段页签的「当前段」跟着它，从上面的页签往下进横排落在它 */
    var rowEpisode by mutableStateOf<Long?>(null)
    /** 首屏那一季上次读到的锚点：刷新后变了就改讲新锚点 */
    private var stageResume: Long? = null
    var watched by mutableStateOf<PlaybackStateView?>(null)
        private set
    /** 电影所属的作品系列；没有、只有一部或拉不到上游档案时为 null */
    var series by mutableStateOf<CollectionSeriesView?>(null)
        private set
    var favorite by mutableStateOf<Boolean?>(null)
        private set
    var marking by mutableStateOf(false)
        private set
    /** 在下半截点播的那一集：播完退回详情时首屏改讲它 */
    var playedElsewhere: Pair<Long, Long>? = null

    val isMovie: Boolean get() = detail?.kind != "tv"
    val canPlay: Boolean get() = detail?.let { DetailLogic.canPlay(it, selectedEpisode) } ?: false
    val hasSeasonTabs: Boolean get() = !isMovie && (detail?.seasons?.size ?: 0) > 1

    /** 续播点按「哪一集」取：换了首屏那一集就重拉 */
    val unitKey: String
        get() {
            if (isMovie) return if (detail == null) "-" else "movie"
            val s = season ?: return "-"
            val e = selectedEpisode?.episodeNumber ?: return "-"
            return "$s/$e"
        }

    /** 下半截分集横排进来时落在哪一集：首屏那一季是首屏那一集，别的季是那一季接着看的那一集 */
    val entryEpisode: Long?
        get() {
            val selected = selectedEpisode
            if (browseSeason == season && selected != null) return selected.episodeNumber
            return browseAnchor
        }

    /** 下半截那一季接着看的那一集（服务端锚点优先，没有退回客户端规则） */
    val browseAnchor: Long?
        get() = EpisodeRanges.anchor(browseEpisodes, browseResume)?.episodeNumber

    suspend fun reload(upNext: Pair<Long, Long>?) {
        val fresh = try {
            api.libraryItemsGet(libraryId, itemId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (detail == null) failed = true
            return
        }
        if (fresh.kind == "tv" && season == null) {
            // 在「接下来继续」里的剧打开接着看的那一季那一集；别的打开第一个有片源的季。分集读完再出页面，免得闪一下「没有可播放的分集」
            val start = DetailLogic.startingSeason(fresh, upNext?.first)
            if (start != null) {
                loadEpisodes(start, keepSelection = false, preferred = upNext?.takeIf { it.first == start }?.second)
                browseSeason = start
                browseEpisodes = episodes
                browseResume = stageResume
                browseScrollRequest++
            }
        }
        // 系列读完再出页面：首屏要按有没有系列决定底下露不露
        loadSeries(fresh)
        detail = fresh
        failed = false
    }

    suspend fun loadFavorite() {
        attempt { api.playbackMarksGet(itemId) }?.let { favorite = it.isFavorite }
    }

    private suspend fun loadSeries(fresh: LibraryItemDetailView) {
        val id = fresh.seriesCollectionId
        if (fresh.kind == "tv" || id == null) {
            series = null
            return
        }
        val result = attempt { api.collectionSeriesGet(id) }
        series = result?.takeIf { it.available && it.parts.size > 1 }
    }

    /**
     * 读首屏那一季的分集；不保留选择时选指定的那一集，没有就接着看的那一集。
     * 刷新后锚点变了（看完 1050 → 1051）：不管保不保留、指定没指定，都改讲新锚点
     */
    suspend fun loadEpisodes(number: Long, keepSelection: Boolean, preferred: Long? = null) {
        val result = attempt { api.libraryItemsListEpisodes(libraryId, itemId, number) } ?: return
        val anchorMoved = season == number && anchorMoved(stageResume, result.resumeEpisode)
        season = number
        episodes = result.episodes
        stageResume = result.resumeEpisode
        val current = selectedEpisode
        if (keepSelection && current != null && !anchorMoved) {
            result.episodes.firstOrNull { it.episodeNumber == current.episodeNumber }?.let {
                selectedEpisode = it
                return
            }
        }
        selectedEpisode = DetailLogic.chooseEpisode(result.episodes, preferred.takeUnless { anchorMoved }, result.resumeEpisode)
    }

    /** 同一季重读后服务端锚点换了一集（长季短季都算） */
    private fun anchorMoved(before: Long?, after: Long?): Boolean = after != null && after != before

    /** 下半截换一季：分集横排换成那一季，滚到那一季接着看的那一集 */
    suspend fun loadBrowse(number: Long) {
        val result = attempt { api.libraryItemsListEpisodes(libraryId, itemId, number) } ?: return
        browseSeason = number
        browseEpisodes = result.episodes
        browseResume = result.resumeEpisode
        browseScrollRequest++
    }

    /** 只换下半截的进度，不动滚动位置（播完退回来、标记已看之后）；锚点变了就跳到新锚点 */
    suspend fun refreshBrowse() {
        val number = browseSeason ?: return
        val result = attempt { api.libraryItemsListEpisodes(libraryId, itemId, number) } ?: return
        val moved = anchorMoved(browseResume, result.resumeEpisode)
        browseEpisodes = result.episodes
        browseResume = result.resumeEpisode
        if (moved) {
            browseJumpTarget = result.resumeEpisode
            browseJumpRequest++
        }
    }

    /** 上一次拉续播点时是哪一集：同一集再拉（退回页面时）保留现有值，不闪「播放」 */
    private var resumeKey: String? = null

    suspend fun loadResumeFor(key: String) {
        val same = key == resumeKey
        resumeKey = key
        loadResume(keepCurrent = same)
    }

    suspend fun loadResume(keepCurrent: Boolean = false) {
        if (detail == null) return
        val unit = currentUnit()
        if (unit == null) {
            watched = null
            return
        }
        if (!keepCurrent) watched = null
        val fresh = attempt { api.playbackResume(itemId, unit.first, unit.second) }
        if (fresh != null || !keepCurrent) watched = fresh
    }

    /** 电影是 (0, 0)，剧集是首屏那一集 */
    private fun currentUnit(): Pair<Long, Long>? {
        if (isMovie) return 0L to 0L
        val s = season ?: return null
        val e = selectedEpisode?.episodeNumber ?: return null
        return s to e
    }

    suspend fun toggleFavorite() {
        if (marking) return
        val next = !(favorite ?: false)
        marking = true
        favorite = next
        try {
            favorite = attempt { api.playbackMarksSet(PlaybackMarksRequest(itemId, favorite = next, deviceId = deviceId)) }?.isFavorite ?: !next
        } finally {
            marking = false
        }
    }

    suspend fun togglePlayed() {
        if (marking) return
        val next = !(watched?.played ?: false)
        marking = true
        try {
            val (s, e) = currentUnit() ?: (0L to 0L)
            attempt { api.playbackMarksSet(PlaybackMarksRequest(itemId, seasonNumber = s, episodeNumber = e, played = next, deviceId = deviceId)) }
            watched = attempt { api.playbackResume(itemId, s, e) }
            season?.let { loadEpisodes(it, keepSelection = true) }
            refreshBrowse()
        } finally {
            marking = false
        }
    }

    /** 分集卡长按：标为已看 / 未看 */
    suspend fun markEpisode(episode: EpisodeView, played: Boolean) {
        val number = browseSeason ?: return
        attempt { api.playbackMarksSet(PlaybackMarksRequest(itemId, seasonNumber = number, episodeNumber = episode.episodeNumber, played = played, deviceId = deviceId)) }
        refreshBrowse()
        if (number == season) {
            loadEpisodes(number, keepSelection = true)
            loadResume(keepCurrent = true)
        }
    }

    /** 播放器关掉之后（TVItemDetailView 的 playbackStopReported）：重拉分集进度与续播点；在下半截播了别的集，首屏改讲它 */
    suspend fun afterPlayback() {
        refreshBrowse()
        val unit = playedElsewhere
        playedElsewhere = null
        if (unit != null && (unit.first != season || unit.second != selectedEpisode?.episodeNumber)) {
            // 首屏那一集变了：续播点随 unitKey 重拉
            loadEpisodes(unit.first, keepSelection = false, preferred = unit.second)
            return
        }
        loadResume(keepCurrent = true)
        season?.let { loadEpisodes(it, keepSelection = true) }
    }
}
