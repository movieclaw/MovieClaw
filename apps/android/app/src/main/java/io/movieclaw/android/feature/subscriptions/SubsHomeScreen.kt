package io.movieclaw.android.feature.subscriptions

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.material.icons.rounded.BookmarkBorder
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.combinedClickable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.GridOn
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.core.api.McApi
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.ImageAspect
import io.movieclaw.android.core.designsystem.ImageWidth
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McTabBarContentPadding
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.tabGlassSource
import io.movieclaw.android.core.designsystem.Ok
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warn
import io.movieclaw.android.core.discovery.rememberAmbientColor
import io.movieclaw.android.core.model.DownloadTask
import io.movieclaw.android.core.model.MediaBrief
import io.movieclaw.android.core.model.RecentArrivalView
import io.movieclaw.android.core.model.SubscriptionView
import io.movieclaw.android.core.model.TodayArrivalFull
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import androidx.compose.material3.pulltorefresh.pullToRefresh
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.launch
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.time.LocalDate
import java.time.LocalTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import javax.inject.Inject

/* ══════════ 数据模型（对齐 iOS SubsHomeModel） ══════════ */

enum class SubsStage { Downloading, Organizing, Arrived, Today, Upcoming, Resting }

data class SubsHeroSlide(
    val subscriptionId: Long,
    val media: MediaBrief,
    val stage: SubsStage,
    val eyebrow: String? = null,
    val eyebrowDot: Color? = null,
    val clockLabel: String? = null,
    val clock: String? = null,
    val detail: String? = null,
    val footnote: String? = null,
    val play: PlayTarget? = null,
    val resumePercent: Int? = null,
    /** 下载中：下载器给的平均进度 0..1（iOS 组内下载中单元的平均值）；没有就不画实段 */
    val progress: Double? = null,
)

/** 日程一行：一部订阅当天的全部更新合成一行（同一部剧当天多集 →「S01E01–E03」，iOS ArrivalGroup 同口径），
 *  组内一切「时刻 / 状态」以完成最慢的那一集为准 */
data class SubsScheduleEntry(
    val subscriptionId: Long,
    val mediaTitle: String,
    val mediaKind: String,
    /** 「S01E01–E03」/「电影」 */
    val episodeLabel: String,
    val presentation: ArrivalPresentation,
    /** 组内下载中单元的进度 0..1（没在下载就 null） */
    val progress: Double?,
)

/** 预告行按（订阅, 日期）合成的一批（iOS `ArrivalGroup`）：整组共用一条进度、一个入库时刻 */
internal data class ArrivalGroup(
    val subscriptionId: Long,
    val daysAhead: Int,
    val expectedDay: String?,
    val mediaTitle: String,
    val mediaKind: String,
    val units: List<TodayArrivalFull>,
    /** 匹配到的下载器任务（按 info_hash，iOS `taskByHash`） */
    val task: DownloadTask?,
    val presentation: ArrivalPresentation,
    val progress: Double?,
) {
    val episodeLabel: String
        get() = if (mediaKind == "movie") {
            "电影"
        } else {
            units.groupBy { it.seasonNumber }.toSortedMap()
                .map { (season, eps) -> "S%02d%s".format(season, episodeRanges(eps.map { it.episodeNumber })) }
                .joinToString(" · ")
        }

    /** 组内代表集（时刻文案用）：最慢的一集 */
    val representative: TodayArrivalFull get() = units.first()
}

/** 集号压成区间：[1,2,3,5] →「E01–E03、E05」（iOS TodayArrivals.episodeRanges） */
internal fun episodeRanges(episodes: List<Int>): String {
    val ranges = mutableListOf<Pair<Int, Int>>()
    episodes.toSortedSet().forEach { ep ->
        val last = ranges.lastOrNull()
        if (last != null && ep == last.second + 1) ranges[ranges.size - 1] = last.first to ep
        else ranges += ep to ep
    }
    return ranges.joinToString("、") { (a, b) ->
        if (a == b) "E%02d".format(a) else "E%02d–E%02d".format(a, b)
    }
}

/** 预告行按（订阅, 日期）分组并套上下载器的实时进度 / ETA（iOS `SubscriptionsHomeModel.arrivalGroups`） */
internal fun arrivalGroups(
    arrivals: List<TodayArrivalFull>,
    tasks: List<DownloadTask>,
    now: java.time.LocalDateTime = java.time.LocalDateTime.now(),
): List<ArrivalGroup> {
    val taskByHash = tasks.filter { it.infoHash.isNotBlank() }.associateBy { it.infoHash.lowercase() }
    val order = mutableListOf<Pair<Long, Int>>()
    val rows = mutableMapOf<Pair<Long, Int>, MutableList<TodayArrivalFull>>()
    arrivals.forEach { arr ->
        val key = arr.subscriptionId to arr.daysAhead
        if (!rows.containsKey(key)) order += key
        rows.getOrPut(key) { mutableListOf() } += arr
    }
    return order.mapNotNull { key ->
        val units = rows[key] ?: return@mapNotNull null
        val first = units.firstOrNull() ?: return@mapNotNull null
        val task = first.infoHash?.lowercase()?.let { taskByHash[it] }
        ArrivalGroup(
            subscriptionId = key.first,
            daysAhead = key.second,
            expectedDay = first.expectedDay,
            mediaTitle = first.mediaTitle,
            mediaKind = first.mediaKind,
            units = units,
            task = task,
            presentation = SubsHomeViewModel.groupPresentation(units, task, now),
            progress = SubsHomeViewModel.groupProgress(units, task),
        )
    }
}

data class SubsDay(
    val date: LocalDate,
    val label: String,
    val dayNum: Int,
    val isToday: Boolean,
    val entries: List<SubsScheduleEntry>,
)

/** 日程一行的展示口径：状态文字 + 左侧时刻（nil = 待定）+ 语气色（iOS `TodayArrivalPresentation`） */
data class ArrivalPresentation(
    val statusLabel: String,
    val timeText: String?,
    val tone: Color,
    /** 「正在发生」（下载中 / 整理中）：日期条小圆点用语气色、状态行的小点呼吸 */
    val glows: Boolean,
)

data class SubsHomeState(
    val loading: Boolean = true,
    val error: String? = null,
    val slides: List<SubsHeroSlide> = emptyList(),
    val recent: List<RecentArrivalView> = emptyList(),
    val days: List<SubsDay> = emptyList(),
    val tv: List<SubscriptionView> = emptyList(),
    val movie: List<SubscriptionView> = emptyList(),
    val all: List<SubscriptionView> = emptyList(),
)

/* ══════════ ViewModel：订阅首页聚合 ══════════ */

@HiltViewModel
class SubsHomeViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val playbackEvents: io.movieclaw.android.core.playback.PlaybackDataEvents,
) : ViewModel() {

    private val _ui = MutableStateFlow(SubsHomeState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    private val loadMutex = kotlinx.coroutines.sync.Mutex()
    private var arrivalSnapshot: List<ArrivalGroup> = emptyList()

    init {
        load()
        viewModelScope.launch {
            playbackEvents.changes.collect { change ->
                if (change != null && repository.isCurrentIdentity(change.identity)) {
                    loadMutex.withLock {
                        val recent = runCatching {
                            apiFactory.forIdentity(change.identity.origin, change.identity).recentArrivals().dataOrThrow()
                        }.getOrNull() ?: return@withLock
                        if (repository.isCurrentIdentity(change.identity)) _ui.update {
                            it.copy(recent = recent, slides = buildSlides(it.all, arrivalSnapshot, recent))
                        }
                    }
                }
            }
        }
    }

    /** 取消/新增订阅后从别处回来时重新拉（详情页是独立导航目标，列表不会自己重建） */
    fun reloadIfChanged(revision: Int) {
        if (revision != lastSeenRevision) {
            lastSeenRevision = revision
            load()
        }
    }

    private var lastSeenRevision = SubscriptionEvents.revision

    /** 下拉刷新转圈（iOS `.refreshable` 的对应物） */
    private val _refreshing = MutableStateFlow(false)
    val refreshing: kotlinx.coroutines.flow.StateFlow<Boolean> = _refreshing.asStateFlow()

    /** 下拉刷新：内容留着，转圈到新数据到齐 */
    fun pullRefresh() {
        if (_refreshing.value) return
        viewModelScope.launch {
            _refreshing.value = true
            try {
                load()
                kotlinx.coroutines.withTimeoutOrNull(12_000) {
                    _ui.first { !it.loading }
                }
            } finally {
                _refreshing.value = false
            }
        }
    }

    fun load() {
        viewModelScope.launch {
            loadMutex.withLock {
                val origin = origin
                if (origin == null) { _ui.update { it.copy(loading = false, error = "尚未连接服务器") }; return@withLock }
                _ui.update { it.copy(loading = true, error = null) }
                try {
                    val api = apiFactory.forOrigin(origin)
                    val subs: List<SubscriptionView>
                    val arrivals: List<TodayArrivalFull>
                    val recent: List<RecentArrivalView>
                    val tasks: List<DownloadTask>
                    coroutineScope {
                        val a = async { runCatching { api.subscriptions().dataOrThrow() }.getOrDefault(emptyList()) }
                        val b = async { runCatching { api.todayArrivalsFull().dataOrThrow() }.getOrDefault(emptyList()) }
                        val c = async { runCatching { api.recentArrivals().dataOrThrow() }.getOrDefault(emptyList()) }
                        // 下载器的实时进度 / ETA（iOS 订阅首页同一份任务快照）：按 info_hash 对到预告行上；
                        // 拉不到就当作没有，不挡页面
                        val d = async {
                            runCatching { api.downloadTasks().dataOrThrow().items }.getOrDefault(emptyList())
                        }
                        subs = a.await(); arrivals = b.await(); recent = c.await(); tasks = d.await()
                    }
                    val now = LocalDate.now()
                    val groups = arrivalGroups(arrivals, tasks)
                    arrivalSnapshot = groups
                    _ui.update {
                        it.copy(
                            loading = false,
                            slides = buildSlides(subs, groups, recent),
                            recent = recent,
                            days = buildDays(groups, now),
                            tv = subs.filter { s -> s.media.kind == "tv" },
                            movie = subs.filter { s -> s.media.kind == "movie" },
                            all = subs,
                        )
                    }
                } catch (e: Exception) {
                    _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
                }
            }
        }
    }

    /** 入库管线：下载中 → 整理中 → 刚入库 → 今天 → 排期；全空时回退「在追的前三」 */
    private fun buildSlides(
        subs: List<SubscriptionView>,
        groups: List<ArrivalGroup>,
        recent: List<RecentArrivalView>,
    ): List<SubsHeroSlide> {
        val slides = mutableListOf<SubsHeroSlide>()
        val byId = subs.associateBy { it.id }
        val now = java.time.LocalDateTime.now()

        groups.forEach { group ->
            val arr = group.representative
            val pres = group.presentation
            val media = byId[arr.subscriptionId]?.media ?: MediaBrief(title = arr.mediaTitle, kind = arr.mediaKind)
            val label = if (arr.mediaKind == "tv") group.episodeLabel else null
            when {
                pres.statusLabel.startsWith("下载中") -> {
                    // 时刻与进度都来自下载器任务（iOS：`task.etaSeconds` + 「下载完成 → 入库」中位耗时）
                    slides += SubsHeroSlide(
                        arr.subscriptionId, media, SubsStage.Downloading,
                        eyebrow = "下载中", eyebrowDot = Color(0xFF7FB0FF),
                        clockLabel = if (arr.mediaKind == "movie") "预计可看" else "$label · 预计可看",
                        clock = pres.timeText?.takeIf { it != "稍后" }?.let { "约 $it" },
                        detail = if (pres.timeText == "稍后" || pres.timeText == null)
                            (if (arr.mediaKind == "movie") "正在下载" else "$label · 正在下载") else null,
                        footnote = if (pres.timeText == "稍后" || pres.timeText == null) "下载完成后自动整理入库" else null,
                        progress = group.progress,
                    )
                }
                pres.statusLabel == "整理中" -> slides += SubsHeroSlide(
                    arr.subscriptionId, media, SubsStage.Organizing,
                    eyebrow = "整理中", eyebrowDot = Ok,
                    clockLabel = if (arr.mediaKind == "movie") "下载完成" else "$label · 下载完成",
                    clock = if (pres.timeText == "即将") "马上就好" else pres.timeText,
                )
                arr.daysAhead > 0 -> slides += SubsHeroSlide(
                    arr.subscriptionId, media, SubsStage.Upcoming,
                    eyebrow = null,  // calm 态：状态文字只进读屏，不显示
                    clockLabel = listOfNotNull(label, formatCalendarDay(arr.expectedDay)).joinToString(" · "),
                    clock = if (arr.daysAhead == 1) "明天" else weekday(arr.expectedDay) ?: "${arr.daysAhead} 天后",
                )
                else -> slides += SubsHeroSlide(
                    arr.subscriptionId, media, SubsStage.Today,
                    eyebrow = "今天更新", eyebrowDot = Color(0xFFD9D6FF),
                    clockLabel = "$label · 预计入库",
                    clock = pres.timeText,
                )
            }
        }

        recent.forEach { card ->
            // RecentArrivalView 暂无 imported_at 字段：脚注显示「已入库」；接口补充后接相对时间
            val fresh = false
            val eyebrow = if (fresh) "刚刚入库" else if (card.media.kind == "tv") "新一集" else "新入库"
            val footnote = buildString {
                append("已入库")
                if (card.units.size > 1) append(" · 共 ${card.units.size} 集新内容")
            }
            slides += SubsHeroSlide(
                card.subscriptionId, card.media, SubsStage.Arrived,
                eyebrow = eyebrow, eyebrowDot = Ok,
                detail = recentDetail(card),
                footnote = footnote,
                play = PlayTarget(
                    mediaItemId = card.media.mediaItemId,
                    libraryId = 0,
                    kind = card.media.kind,
                    title = card.media.title,
                    seasonNumber = card.seasonNumber,
                    episodeNumber = card.episodeNumber,
                ),
                resumePercent = card.progressPercent,
            )
        }

        if (slides.isEmpty()) {
            subs.filter { it.status == "active" }.take(3).forEach { sub ->
                val movie = sub.media.kind == "movie"
                slides += SubsHeroSlide(
                    sub.id, sub.media, SubsStage.Resting,
                    eyebrow = null,  // 追踪中：calm，不显示
                    detail = if (movie) listOfNotNull(sub.media.year?.toString(), "电影").joinToString(" · ") else "剧集",
                    footnote = if (movie) (if (sub.progress.imported > 0) "已在媒体库里" else "上映后开始找资源") else "有新一集会自动下载入库",
                )
            }
        }
        // iOS SubsHomeState.maxHeroSlides：轮播最多 5 张，且按订阅去重——
        // 同一部剧既在预告又在「刚刚入库」时只留最要紧的那张（前面的优先级高，去重保先出现的）
        return slides.distinctBy { it.subscriptionId }.take(5)
    }

    /** 一周的日期条：今天起 7 天（第 8 天有安排才补），每天挂着**合成好的**当天议程（iOS scheduleDays） */
    private fun buildDays(groups: List<ArrivalGroup>, today: LocalDate): List<SubsDay> {
        val days = (0..6L).map { today.plusDays(it) }
        val extra = groups.mapNotNull { g -> g.expectedDay?.let { runCatching { LocalDate.parse(it) }.getOrNull() } }
            .filter { it.isAfter(today.plusDays(6)) }
        return (days + extra).map { date ->
            SubsDay(
                date = date,
                label = if (date == today) "今天" else chineseWeekday(date),
                dayNum = date.dayOfMonth,
                isToday = date == today,
                entries = groups.filter { it.expectedDay == date.toString() }.map { g ->
                    SubsScheduleEntry(
                        subscriptionId = g.subscriptionId,
                        mediaTitle = g.mediaTitle,
                        mediaKind = g.mediaKind,
                        episodeLabel = g.episodeLabel,
                        presentation = g.presentation,
                        progress = g.progress,
                    )
                },
            )
        }
    }

    companion object {
        fun recentDetail(card: RecentArrivalView): String =
            if (card.media.kind != "tv") {
                listOfNotNull(card.media.year?.toString(), "电影").joinToString(" · ")
            } else {
                val code = "S%02dE%02d".format(card.seasonNumber, card.episodeNumber)
                if (card.episodeName.isNullOrBlank()) code else "$code · ${card.episodeName}"
            }

        fun clockText(eta: java.time.LocalDateTime, now: java.time.LocalDateTime = java.time.LocalDateTime.now()): String {
            val hm = eta.format(DateTimeFormatter.ofPattern("HH:mm"))
            return when {
                eta.toLocalDate() == now.toLocalDate() -> hm
                eta.toLocalDate() == now.toLocalDate().plusDays(1) -> "明天 $hm"
                else -> eta.format(DateTimeFormatter.ofPattern("M/d HH:mm"))
            }
        }

        /** ISO 时间串 → 本机 LocalDateTime（服务端的 grabbed/downloaded/next_probe_at 都是 UTC ISO） */
        private fun parseIso(value: String?): java.time.LocalDateTime? =
            value?.let { runCatching { OffsetDateTime.parse(it).atZoneSameInstant(ZoneId.systemDefault()).toLocalDateTime() }.getOrNull() }

        /**
         * 日程一行的「状态 + 时刻 + 语气」（iOS `TodayArrivals.presentation`）：
         * 整理中 → 下载完成时刻 + 本订阅读书「下载完成 → 入库」中位耗时（过去了就「即将」）；
         * 下载中 → 下载器 ETA + 同一耗时算出的入库时刻（下载器给不出就「稍后」）+ 实时进度写进状态；
         * 还没抓到 → 按出种预测算预计入库时刻，预测已过就是「等待资源」。
         */
        fun arrivalPresentation(
            arr: TodayArrivalFull,
            task: DownloadTask? = null,
            now: java.time.LocalDateTime = java.time.LocalDateTime.now(),
        ): ArrivalPresentation {
            val importMinutes = (arr.estimatedDownloadToImportMinutes ?: 0).toLong()
            if (arr.status == "downloaded" || arr.downloadedAt != null) {
                val readyAt = parseIso(arr.downloadedAt)?.plusMinutes(importMinutes)
                return ArrivalPresentation(
                    statusLabel = "整理中",
                    timeText = readyAt?.takeIf { it.isAfter(now) }?.format(DateTimeFormatter.ofPattern("HH:mm")) ?: "即将",
                    tone = Ok,
                    glows = true,
                )
            }
            if (arr.status == "grabbed" || arr.grabbedAt != null) {
                val eta = task?.etaSeconds?.takeIf { task.state == "downloading" && it >= 0 }
                val estimated = eta?.let { now.plusSeconds(it).plusMinutes(importMinutes) }
                val percent = task?.progress?.let { (it * 100).toInt().coerceIn(0, 100) }
                return ArrivalPresentation(
                    statusLabel = if (percent != null) "下载中 $percent%" else "下载中",
                    timeText = estimated?.format(DateTimeFormatter.ofPattern("HH:mm")) ?: "稍后",
                    tone = Color(0xFF7FB0FF),
                    glows = true,
                )
            }
            val forecast = arr.releaseForecast
            val predicted = forecast?.get("predicted_at")?.jsonPrimitive?.contentOrNull?.let { parseIso(it) }
            val volatile = forecast?.get("confidence")?.jsonPrimitive?.contentOrNull == "volatile"
            val delay = (arr.estimatedReleaseToImportMinutes ?: 0).toLong()
            var estimated: java.time.LocalDateTime? = null
            if (predicted != null && !volatile) {
                val initial = predicted.plusMinutes(delay)
                estimated = if (!initial.isBefore(now)) initial else {
                    // 预测时刻过去了就顺延到下一次探测（iOS estimatedWantedArrival 同口径）
                    val probe = parseIso(arr.nextProbeAt)?.takeIf { it.isAfter(now) } ?: now
                    probe.plusMinutes(delay)
                }
            }
            val waiting = predicted != null && !predicted.isAfter(now)
            return ArrivalPresentation(
                statusLabel = if (waiting) "等待资源" else "预计入库",
                timeText = estimated?.format(DateTimeFormatter.ofPattern("HH:mm")),
                tone = if (waiting) Warn else TextMuted,
                glows = false,
            )
        }

        /** 组口径：以完成最慢的一集为准（整理中 > 下载中 > 其余；同级取最晚的入库时刻），iOS ArrivalGroup.presentation */
        fun groupPresentation(
            units: List<TodayArrivalFull>,
            task: DownloadTask?,
            now: java.time.LocalDateTime = java.time.LocalDateTime.now(),
        ): ArrivalPresentation {
            fun stageOrder(p: ArrivalPresentation) = when (p.statusLabel) {
                "下载中" -> 1
                "整理中" -> 2
                else -> 0
            }
            return units.map { arrivalPresentation(it, task, now) }
                .sortedWith(compareByDescending<ArrivalPresentation> { stageOrder(it) })
                .firstOrNull() ?: ArrivalPresentation("预计入库", null, TextMuted, glows = false)
        }

        /** 组内下载中单元的进度（同一组的几集共用同一个任务，所以直接取任务的进度） */
        fun groupProgress(units: List<TodayArrivalFull>, task: DownloadTask?): Double? =
            if (units.any { it.status == "grabbed" || (it.grabbedAt != null && it.downloadedAt == null) }) {
                task?.progress?.toDouble()
            } else null

        fun weekday(day: String?): String? {
            val d = day?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: return null
            return chineseWeekday(d)
        }

        fun formatCalendarDay(day: String?): String? {
            val d = day?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: return null
            return "${d.monthValue}月${d.dayOfMonth}日"
        }

        fun chineseWeekday(d: LocalDate): String =
            arrayOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")[d.dayOfWeek.value - 1]

        fun fromNow(dt: java.time.LocalDateTime, now: java.time.LocalDateTime = java.time.LocalDateTime.now()): String {
            val mins = java.time.Duration.between(dt, now).toMinutes()
            return when {
                mins < 60 -> "${mins} 分钟前"
                mins < 60 * 24 -> "${mins / 60} 小时前"
                else -> "${mins / 60 / 24} 天前"
            }
        }
    }
}

/* ══════════ 界面 ══════════ */

private val Dots = mapOf("ok" to Ok, "warn" to Warn, "live" to Color(0xFF7FB0FF), "today" to Color(0xFFD9D6FF))

@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
fun SubsHomeScreen(
    onOpenSubscription: (Long) -> Unit,
    onPlay: (PlayTarget) -> Unit,
    onOpenTitle: (String) -> Unit = {},
    /** 空态那颗「去发现剧集」：切到发现页 */
    onOpenDiscover: () -> Unit = {},
    /** 「剧集订阅 ⌄」「电影订阅 ⌄」与一排末尾的「查看全部」→ 订阅海报墙（kind = tv / movie） */
    onOpenWall: (String) -> Unit = {},
    vm: SubsHomeViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val refreshing by vm.refreshing.collectAsStateWithLifecycle()
    // 订阅数据在别处被改动（详情页取消订阅 / 新建订阅）后，回到这里要能看到最新结果
    androidx.compose.runtime.LaunchedEffect(SubscriptionEvents.revision) {
        vm.reloadIfChanged(SubscriptionEvents.revision)
    }
    val scroll = rememberScrollState()
    io.movieclaw.android.core.designsystem.TrackTabBarMinimize(scroll)

    Box(Modifier.fillMaxSize().background(Bg)) {
        // 氛围底 = 当前英雄剧照主色，随滚动退淡（下限 0.35，900dp 淡尽）
        val slide = state.slides.getOrNull(0)
        val ambient = rememberAmbientColor(slide?.media?.backdropUrl, vm.origin)
        val ambAlpha = (1f - scroll.value / 900f).coerceIn(0.35f, 1f)
        Box(
            Modifier.fillMaxSize().alpha(ambAlpha).background(
                Brush.verticalGradient(
                    0f to (ambient ?: Color(0xFF20221C)).copy(alpha = 0.85f),
                    0.42f to (ambient ?: Color(0xFF20221C)).copy(alpha = 0.5f),
                    0.72f to (ambient ?: Color(0xFF20221C)).copy(alpha = 0.14f),
                    1f to Color.Transparent,
                )
            )
        )

        Text(
            "我的订阅",
            fontSize = 34.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.4).sp,
            color = TextPrimary,
            modifier = Modifier
                .align(Alignment.TopStart)
                .statusBarsPadding()
                .padding(start = McMetrics.pagePadding, top = 2.dp)
                .zIndex(3f),
        )
        Column(
            Modifier
                .fillMaxSize()
                // 下拉刷新（iOS `.refreshable`）：**必须排在 verticalScroll 之前**（修饰符自外向内包，
                // 挂在内侧收不到滚动节点的嵌套滚动事件——发现页就是这么「没生效」的）
                .pullToRefresh(
                    isRefreshing = refreshing,
                    state = rememberPullToRefreshState(),
                    onRefresh = { vm.pullRefresh() },
                )
                .verticalScroll(scroll)
                // 液态底栏的背景模糊源（Local 为 null 时原样返回，零代价）
                .tabGlassSource()
                .padding(bottom = McTabBarContentPadding),
        ) {
            if (state.loading && state.slides.isEmpty()) {
                Spacer(Modifier.height(300.dp))
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted)
                }
            } else if (state.all.isEmpty()) {
                // 一条订阅都没有：空数据不是故障，用与全站一致的银玻璃展台承接
                // （网页 `ContentEmptyState variant="subscription"`）
                Spacer(Modifier.height(McMetrics.topBarHeight + 40.dp))
                SubscriptionEmptyState(onOpenDiscover = onOpenDiscover)
            } else if (state.error != null && state.slides.isEmpty()) {
                Spacer(Modifier.height(200.dp))
                Text(state.error!!, color = TextMuted, modifier = Modifier.padding(horizontal = 24.dp))
            } else if (state.slides.isNotEmpty()) {
                SubsHero(
                    slides = state.slides,
                    scrollValue = scroll.value,
                    // 订阅的图是服务端相对路径，不留 origin 就一张都画不出来
                    // （实机报「hero 大图没了」的根因）
                    origin = vm.origin,
                    onPlay = onPlay,
                    onOpenSubscription = onOpenSubscription,
                )
            }

            Column(Modifier.padding(top = 22.dp)) {
                if (state.recent.isNotEmpty()) {
                    SectionHeader("刚刚入库", if (state.recent.size > 1) "${state.recent.size} 部" else null)
                    Spacer(Modifier.height(12.dp))
                    LazyRow(
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        items(state.recent, key = { it.subscriptionId.toString() + "-" + it.episodeNumber }) { card ->
                            ArrivalCard(
                                card = card, origin = vm.origin, onPlay = onPlay,
                                onOpenSubscription = onOpenSubscription, onOpenTitle = onOpenTitle,
                            )
                        }
                    }
                    Spacer(Modifier.height(36.dp))
                }

                val dayWithEntries = state.days.firstOrNull { it.entries.isNotEmpty() }
                if (dayWithEntries != null) {
                    ScheduleSection(
                        days = state.days,
                        default = dayWithEntries,
                        subs = state.all,
                        origin = vm.origin,
                        onOpenSubscription = onOpenSubscription,
                    )
                    Spacer(Modifier.height(36.dp))
                }

                if (state.tv.isNotEmpty()) {
                    val active = state.tv.filter { it.status == "active" }
                    val resting = state.tv.filterNot { it.status == "active" }
                    ShelfHeader("剧集订阅", countSummary(state.tv, active.size), onOpenWall = { onOpenWall("tv") })
                    Spacer(Modifier.height(12.dp))
                    LazyRow(
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        items(active, key = { it.id }) { sub -> SubCard(sub, dim = false, origin = vm.origin) { onOpenSubscription(sub.id) } }
                        if (resting.isNotEmpty()) {
                            item(key = "div-tv") { RestingDivider(restingLabel(resting), height = 189.dp) }
                            items(resting, key = { "r-${it.id}" }) { sub -> SubCard(sub, dim = true, origin = vm.origin) { onOpenSubscription(sub.id) } }
                        }
                        // 「查看全部」卡只在**一排放不下**（iOS `if hidden > 0`）时才出现——
                        // 订阅少的时候末尾不该多一张大卡（用户反馈）
                        if (state.tv.size > 20) {
                            item(key = "seeall-tv") { SeeAllCard(state.tv.size) { onOpenWall("tv") } }
                        }
                    }
                    Spacer(Modifier.height(36.dp))
                }

                if (state.movie.isNotEmpty()) {
                    val active = state.movie.filter { it.status == "active" }
                    val resting = state.movie.filterNot { it.status == "active" }
                    ShelfHeader("电影订阅", countSummary(state.movie, active.size), onOpenWall = { onOpenWall("movie") })
                    Spacer(Modifier.height(12.dp))
                    LazyRow(
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        items(active, key = { it.id }) { sub -> SubCard(sub, dim = false, origin = vm.origin) { onOpenSubscription(sub.id) } }
                        if (resting.isNotEmpty()) {
                            item(key = "div-mv") { RestingDivider(restingLabel(resting), height = 189.dp) }
                            items(resting, key = { "rm-${it.id}" }) { sub -> SubCard(sub, dim = true, origin = vm.origin) { onOpenSubscription(sub.id) } }
                        }
                        if (state.movie.size > 20) {
                            item(key = "seeall-mv") { SeeAllCard(state.movie.size) { onOpenWall("movie") } }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SubsHero(
    slides: List<SubsHeroSlide>,
    scrollValue: Int,
    origin: String?,
    onPlay: (PlayTarget) -> Unit,
    onOpenSubscription: (Long) -> Unit,
) {
    val pager = rememberPagerState(pageCount = { slides.size })
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current.density
    // 轮播节奏同 iOS `SubsHomeHero.interval`：一张停 8s，期间把指示条线性填满，满了再切。
    // 键必须用 `settledPage`：翻页动画过半时 `currentPage` 就会变，拿它当键会把效果协程重启、
    // 把进行中的翻页动画取消掉，轮播就卡在「左右各半张」（实机反馈）。
    // settledPage 只在滚动停稳后才更新——手动滑动也会因此自然重新计时（同 iOS）。
    val fill = remember { Animatable(0f) }
    LaunchedEffect(pager.settledPage, slides.size) {
        fill.snapTo(0f)
        if (slides.size <= 1) return@LaunchedEffect
        fill.animateTo(1f, tween(8000, easing = LinearEasing))
        // 用户正在拖的时候让位；停稳后本次效果会重排，再重新计时
        if (pager.isScrollInProgress) return@LaunchedEffect
        pager.animateScrollToPage(
            (pager.settledPage + 1) % slides.size,
            animationSpec = tween(800, easing = EaseInOut),
        )
    }
    val fade = (1f - scrollValue / 260f).coerceIn(0f, 1f)
    Box(Modifier.fillMaxWidth().height(500.dp)) {
        HorizontalPager(state = pager, modifier = Modifier.fillMaxSize()) { page ->
            val s = slides[page]
            val active = page == pager.currentPage
            val zoom = remember(page) { Animatable(1f) }
            LaunchedEffect(active) {
                if (active) {
                    zoom.snapTo(1f)
                    zoom.animateTo(1.1f, tween(12000, easing = LinearEasing))
                } else zoom.snapTo(1f)
            }
            // 整屏可点进订阅详情（iOS SubsHomeHeroSlideView：点哪都进）；
            // 无涟漪——一张大图上扫过水波很出戏
            Box(
                Modifier
                    .fillMaxSize()
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { onOpenSubscription(s.subscriptionId) }
                    // clipToBounds：视差下移的剧照裁在 Hero 内，不压到下面的板块
                    .clipToBounds(),
            ) {
                Box(
                    Modifier
                        .fillMaxSize()
                        // 视差两档（iOS ImmersiveHeroBackdrop）：画面跟 0.4、文字跟 0.15
                        .graphicsLayer {
                            translationY = scrollValue * 0.4f
                            // DstIn 渐隐遮罩必须限定在本图层内：不限定会连下面的氛围渐变一起「挖掉」，
                            // 上下滚动时底边出现一块流动的跳变（实机反馈的「hero 底部跳动」）
                            compositingStrategy = CompositingStrategy.Offscreen
                        }
                        .drawWithContent {
                            drawContent()
                            // 底部渐隐进页面氛围色：不渐隐的话 Hero 下沿会在氛围色上切出一道横线
                            drawRect(
                                brush = Brush.verticalGradient(
                                    0f to Color.Black,
                                    0.56f to Color.Black,
                                    0.8f to Color.Black.copy(alpha = 0.6f),
                                    1f to Color.Transparent,
                                ),
                                blendMode = BlendMode.DstIn,
                            )
                        },
                ) {
                    RemoteImage(
                        // 剧照：TMDB 图先升到 original 档再经代理按 Hero 需要的宽度缩
                        // （iOS SubsHomeHeroImage.url）——发现接口给的 w1280 铺 500dp 高的框会糊；
                        // 没有剧照退回海报铺满
                        url = tmdbOriginal(s.media.backdropUrl) ?: s.media.posterUrl,
                        origin = origin,
                        contentDescription = s.media.title,
                        // 竖框铺 16:9 剧照按高算 + 慢推 1.1 倍预放大（iOS phoneHero 同口径）
                        aspect = ImageAspect.backdrop,
                        zoom = 1.1f,
                        modifier = Modifier.fillMaxSize().graphicsLayer {
                            scaleX = zoom.value; scaleY = zoom.value
                        },
                        contentScale = ContentScale.Crop,
                    )
                    // 压暗层留在渐隐遮罩里（iOS 注释：压暗层若在遮罩外，Hero 底边比氛围色暗一截，切出一道横线）
                    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.5f), 0.26f to Color.Transparent)))
                    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.36f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.5f))))
                }
                Column(
                    Modifier
                        .fillMaxSize()
                        .graphicsLayer { alpha = fade; translationY = scrollValue * 0.15f }
                        .padding(start = 28.dp, end = 28.dp, bottom = 44.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Bottom,
                ) {
                    if (!s.media.logoUrl.isNullOrBlank()) {
                        RemoteImage(
                            url = s.media.logoUrl!!,
                            origin = origin,
                            contentDescription = null,
                            // iOS：Logo 等比装进 240×88 的框，按框宽取图
                            widthHint = ImageWidth.pixels(240f, density),
                            modifier = Modifier.fillMaxWidth().height(88.dp),
                            contentScale = ContentScale.Fit,
                        )
                    } else {
                        Text(
                            s.media.title,
                            fontSize = 34.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.3).sp,
                            color = Color.White, maxLines = 2,
                            modifier = Modifier.fillMaxWidth(0.8f),
                        )
                    }
                    if (!s.eyebrow.isNullOrBlank()) {
                        Spacer(Modifier.height(16.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            s.eyebrowDot?.let { Box(Modifier.size(7.dp).clip(CircleShape).background(it)) ; Spacer(Modifier.width(7.dp)) }
                            Text(s.eyebrow, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.9f))
                        }
                    }
                    if (!s.detail.isNullOrBlank()) {
                        Spacer(Modifier.height(8.dp))
                        Text(s.detail, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.9f))
                    }
                    if (!s.footnote.isNullOrBlank()) {
                        Spacer(Modifier.height(4.dp))
                        Text(s.footnote, fontSize = 13.sp, color = Color.White.copy(alpha = 0.6f))
                    }
                    if (!s.clockLabel.isNullOrBlank()) {
                        Spacer(Modifier.height(10.dp))
                        Text(s.clockLabel, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.9f))
                    }
                    if (!s.clock.isNullOrBlank()) {
                        val hasDigit = s.clock.any { it.isDigit() }
                        Spacer(Modifier.height(2.dp))
                        Text(
                            s.clock,
                            fontSize = if (hasDigit) 48.sp else 36.sp,
                            fontWeight = if (hasDigit) FontWeight.Thin else FontWeight.Light,
                            color = Color.White,
                        )
                    }
                    if (s.stage == SubsStage.Downloading && s.play == null) {
                        // 发丝进度线（iOS SubsHomeProgressLine，168 宽）：下载器给得出进度才画实段
                        Spacer(Modifier.height(10.dp))
                        Box(Modifier.width(168.dp).height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = 0.2f))) {
                            s.progress?.let { p ->
                                Box(
                                    Modifier
                                        .width(168.dp * p.toFloat().coerceIn(0f, 1f))
                                        .height(3.dp)
                                        .clip(RoundedCornerShape(2.dp))
                                        .background(Color(0xFF7FB0FF)),
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(20.dp))
                    val play = s.play
                    if (play != null) {
                        Box(
                            Modifier
                                .height(44.dp)
                                .clip(RoundedCornerShape(999.dp))
                                .background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))))
                                .clickable { onPlay(play) }
                                .padding(horizontal = 22.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Color(0xFF141821), modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    if (s.resumePercent == null || s.resumePercent == 0) "播放" else "继续播放",
                                    fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF141821),
                                )
                            }
                        }
                    } else {
                        Box(
                            Modifier
                                .height(44.dp)
                                .clip(RoundedCornerShape(999.dp))
                                .background(Color.White.copy(alpha = 0.14f))
                                .border(1.dp, LineSoft, RoundedCornerShape(999.dp))
                                .clickable { onOpenSubscription(s.subscriptionId) }
                                .padding(horizontal = 22.dp),
                            contentAlignment = Alignment.Center,
                        ) { Text("查看订阅", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White) }
                    }
                }
            }
        }
        // 指示器：底部居中、单屏不显示。当前颗是「底胶囊 + 进度填充」（iOS ImmersiveHeroIndicator），
        // 其余小圆点可点跳页
        if (slides.size > 1) {
            Row(
                Modifier.align(Alignment.BottomCenter).padding(bottom = 16.dp).graphicsLayer { alpha = fade },
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                slides.indices.forEach { i ->
                    if (i == pager.currentPage) {
                        Box(
                            Modifier.width(26.dp).height(5.dp).clip(RoundedCornerShape(999.dp))
                                .background(Color.White.copy(alpha = 0.26f)),
                        ) {
                            Box(
                                Modifier.width(26.dp * fill.value).height(5.dp)
                                    .clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.95f)),
                            )
                        }
                    } else {
                        Box(
                            Modifier.size(5.dp).clip(CircleShape)
                                .background(Color.White.copy(alpha = 0.34f))
                                .clickable {
                                    scope.launch {
                                        pager.animateScrollToPage(i, animationSpec = tween(600, easing = EaseInOut))
                                    }
                                }
                                .semantics { contentDescription = "切换到《${slides[i].media.title}》" },
                        )
                    }
                }
            }
        }
    }
}

/** TMDB 图升到 original 档（iOS `originalTMDBImageURL`）：代理不替你换档，源图只有 w1280 时铺 Hero 会糊 */
private val tmdbWidthSegment = Regex("/t/p/w\\d+/")

private fun tmdbOriginal(raw: String?): String? = raw?.replace(tmdbWidthSegment, "/t/p/original/")

/** 状态小签推导（iOS SubsHomeShelfItem.chip 的简化口径） */
internal fun subChip(sub: SubscriptionView): Pair<String, Color> = when {
    sub.status == "paused" -> "已暂停" to TextMuted
    sub.status == "completed" -> (if (sub.media.kind == "movie") "已入库" else "已收齐") to Ok
    sub.progress.upgrading > 0 -> "洗版中" to Color(0xFF2DD4BF)
    sub.progress.grabbed > 0 -> "下载中" to Color(0xFF7FB0FF)
    sub.progress.imported > 0 && sub.progress.imported < sub.progress.total -> "缺 ${sub.progress.total - sub.progress.imported} 集" to Warn
    else -> "找资源中" to Warn
}

private fun restingLabel(resting: List<SubscriptionView>): String {
    val paused = resting.any { it.status == "paused" }
    val done = resting.any { it.status == "completed" }
    return when {
        paused && done -> "暂停·收齐"
        paused -> "已暂停"
        done -> if (resting.all { it.media.kind == "movie" }) "已入库" else "已收齐"
        else -> "已结束"
    }
}

@Composable
private fun SectionHeader(title: String, count: String?) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
        Spacer(Modifier.weight(1f))
        if (count != null) Text(count, fontSize = 13.sp, color = TextFaint)
    }
}

@Composable
private fun ShelfHeader(title: String, count: String, onOpenWall: () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier.clickable(onClick = onOpenWall),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
            Icon(
                Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null,
                tint = TextFaint, modifier = Modifier.size(16.dp),
            )
        }
        Spacer(Modifier.weight(1f))
        Text(count, fontSize = 13.sp, color = TextFaint)
    }
}

/** iOS countSummary：「N 部进行中 · 共 M 部」（全部进行中或没有时只说总数） */
private fun countSummary(all: List<SubscriptionView>, active: Int): String =
    if (active > 0 && active < all.size) "$active 部进行中 · 共 ${all.size} 部" else "共 ${all.size} 部"

@Composable
private fun ArrivalCard(
    card: RecentArrivalView,
    origin: String?,
    onPlay: (PlayTarget) -> Unit,
    onOpenSubscription: (Long) -> Unit = {},
    onOpenTitle: (String) -> Unit = {},
) {
    var menuOpen by remember { mutableStateOf(false) }
    Column(Modifier.width(264.dp)) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(148.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color(0xFF101219))
                .combinedClickable(
                    onClick = {
                    onPlay(
                        PlayTarget(
                            mediaItemId = card.media.mediaItemId, libraryId = 0, kind = card.media.kind,
                            title = card.media.title, seasonNumber = card.seasonNumber, episodeNumber = card.episodeNumber,
                        )
                    )
                    },
                    onLongClick = { menuOpen = true },
                ),
        ) {
            RemoteImage(
                url = card.stillUrl ?: card.media.backdropUrl ?: card.media.posterUrl,
                origin = origin,
                contentDescription = card.media.title,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.5f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.6f))))
            // iOS：多集才挂「新 N 集」小签
            if (card.units.size > 1) {
                Row(
                    Modifier.align(Alignment.TopStart).padding(9.dp).clip(RoundedCornerShape(999.dp))
                        .background(Color(0xFF06281C)).padding(horizontal = 7.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.size(5.dp).clip(CircleShape).background(Ok))
                    Spacer(Modifier.width(4.dp))
                    Text("新 ${card.units.size} 集", fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, color = Ok)
                }
            }
            if (!card.media.logoUrl.isNullOrBlank()) {
                RemoteImage(
                    url = card.media.logoUrl!!,
                    origin = origin,
                    contentDescription = null,
                    // iOS：maxWidth 118 × maxHeight 34，内距 12，左下
                    modifier = Modifier.align(Alignment.BottomStart).padding(12.dp).width(118.dp).height(34.dp),
                    contentScale = ContentScale.Fit,
                )
            }
            Box(
                Modifier.align(Alignment.BottomEnd).padding(10.dp).size(36.dp).clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.16f)),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.PlayArrow, contentDescription = "播放", tint = Color.White, modifier = Modifier.size(18.dp)) }
            card.progressPercent?.takeIf { it > 0 }?.let { pct ->
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(3.dp).background(Color.White.copy(alpha = 0.25f))) {
                    Box(Modifier.fillMaxWidth(pct / 100f).height(3.dp).background(Color.White))
                }
            }
        }
        Text(card.media.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 9.dp))
        Text(
            SubsHomeViewModel.recentDetail(card),
            fontSize = 12.sp, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 2.dp),
        )
        // iOS note：X 入库 · 共 N 集新内容 · 看到 N%
        val note = buildList {
            add("已入库")
            if (card.units.size > 1) add("共 ${card.units.size} 集新内容")
            card.progressPercent?.takeIf { it > 0 }?.let { add("看到 $it%") }
        }.joinToString(" · ")
        Text(note, fontSize = 12.sp, color = TextFaint, modifier = Modifier.padding(top = 2.dp))

        // 长按菜单（iOS contextMenu：播放 / 查看订阅详情 / 查看影片详情）
        androidx.compose.material3.DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            androidx.compose.material3.DropdownMenuItem(
                text = { Text("播放") },
                onClick = {
                    menuOpen = false
                    onPlay(
                        PlayTarget(
                            mediaItemId = card.media.mediaItemId, libraryId = 0, kind = card.media.kind,
                            title = card.media.title, seasonNumber = card.seasonNumber, episodeNumber = card.episodeNumber,
                        )
                    )
                },
            )
            androidx.compose.material3.DropdownMenuItem(
                text = { Text("查看订阅详情") },
                onClick = { menuOpen = false; onOpenSubscription(card.subscriptionId) },
            )
            val ref = card.media.tmdbId?.let { "tmdb:${card.media.kind}:$it" }
            if (ref != null) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text("查看影片详情") },
                    onClick = { menuOpen = false; onOpenTitle(ref) },
                )
            }
        }
    }
}

@Composable
private fun ScheduleSection(
    days: List<SubsDay>,
    default: SubsDay,
    subs: List<SubscriptionView>,
    origin: String?,
    onOpenSubscription: (Long) -> Unit,
) {
    var selected by remember { mutableIntStateOf(days.indexOfFirst { it.date == default.date }.coerceAtLeast(0)) }
    val now = java.time.LocalDateTime.now()
    val density = LocalDensity.current.density
    val subsById = remember(subs) { subs.associateBy { it.id } }
    val current = days.getOrNull(selected) ?: days.firstOrNull()
    Column {
        Row(Modifier.padding(horizontal = McMetrics.pagePadding), verticalAlignment = Alignment.CenterVertically) {
            Text("日程", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
            Spacer(Modifier.weight(1f))
            // 计数跟着**选中的那天**走（iOS SubsHomeSectionHeader 的 trailing）
            current?.let { day ->
                val label = "${day.date.monthValue}月${day.date.dayOfMonth}日"
                Text(
                    if (day.entries.isEmpty()) label else "$label · ${day.entries.size} 部",
                    fontSize = 13.sp, color = TextMuted,
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        Row(Modifier.padding(horizontal = McMetrics.pagePadding), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            days.forEach { day ->
                val on = day == current
                // 日期条小圆点：当天有正在发生的（下载 / 整理）就亮状态色，否则中性白（iOS dotColor）
                val glow = day.entries.firstOrNull { it.presentation.glows }?.presentation?.tone
                Column(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(15.dp))
                        .background(if (on) Color.White else Color.White.copy(alpha = 0.05f))
                        .border(1.dp, if (on) Color.Transparent else Color.White.copy(alpha = 0.07f), RoundedCornerShape(15.dp))
                        .clickable(enabled = day.entries.isNotEmpty()) { selected = days.indexOf(day) }
                        .alpha(if (day.entries.isEmpty()) 0.36f else 1f)
                        .padding(vertical = 9.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        day.label,
                        fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                        color = if (on) Color.Black.copy(alpha = 0.55f) else TextMuted,
                    )
                    Text(
                        "${day.dayNum}",
                        fontSize = 19.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Medium,
                        color = if (on) Color(0xFF000000) else TextPrimary,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.height(4.dp)) {
                        day.entries.take(3).forEach {
                            Box(
                                Modifier.size(4.dp).clip(CircleShape)
                                    .background(if (on) Color.Black.copy(alpha = 0.4f) else glow ?: Color.White.copy(alpha = 0.45f)),
                            )
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        Column(
            Modifier
                .padding(horizontal = McMetrics.pagePadding)
                .fillMaxWidth()
                .clip(RoundedCornerShape(22.dp))
                .background(Color.White.copy(alpha = 0.045f))
                .border(1.dp, Color.White.copy(alpha = 0.07f), RoundedCornerShape(22.dp)),
        ) {
            // 排序：正在发生的（下载 / 整理）在前，其余按时刻排（iOS 日程同口径）
            val entries = current?.entries.orEmpty()
                .sortedWith(
                    compareByDescending<SubsScheduleEntry> { it.presentation.glows }
                        .thenBy { it.presentation.timeText ?: "99" },
                )
            if (entries.isEmpty()) {
                Text("这一天没有入库安排", fontSize = 13.sp, color = TextFaint, modifier = Modifier.padding(14.dp))
            }
            entries.forEachIndexed { i, e ->
                val pres = e.presentation
                if (i > 0) Box(
                    Modifier.padding(start = 86.dp).fillMaxWidth().height(1.dp)
                        .background(Color.White.copy(alpha = 0.06f)),
                )
                Row(
                    Modifier.clickable { onOpenSubscription(e.subscriptionId) }.padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // 左列 62 宽：上「时刻 / 待定」，下「● 状态」（iOS：状态在时间下方，不在右侧）
                    Column(Modifier.width(62.dp)) {
                        Text(
                            pres.timeText ?: "待定",
                            fontSize = 20.sp,
                            fontWeight = if (pres.timeText != null) FontWeight.SemiBold else FontWeight.Normal,
                            color = if (pres.timeText != null) TextPrimary else TextFaint,
                        )
                        Spacer(Modifier.height(3.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(5.dp).clip(CircleShape).background(pres.tone))
                            Spacer(Modifier.width(4.dp))
                            Text(pres.statusLabel, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = pres.tone, maxLines = 1)
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    // 剧照 92×52（iOS 同尺寸）：画面取订阅条目的剧照，没有就海报；下载中底部内嵌发丝进度线
                    val media = subsById[e.subscriptionId]?.media
                    Box(Modifier.width(92.dp).height(52.dp).clip(RoundedCornerShape(9.dp))) {
                        RemoteImage(
                            url = media?.backdropUrl ?: media?.posterUrl,
                            origin = origin,
                            widthHint = ImageWidth.pixels(92f, density),
                            contentDescription = null,
                            modifier = Modifier.fillMaxSize(),
                        )
                        e.progress?.let { p ->
                            Box(
                                Modifier
                                    .align(Alignment.BottomStart)
                                    .padding(start = 6.dp, end = 6.dp, bottom = 5.dp)
                                    .fillMaxWidth().height(2.5.dp)
                                    .clip(RoundedCornerShape(2.dp))
                                    .background(Color.White.copy(alpha = 0.25f)),
                            ) {
                                Box(
                                    Modifier
                                        .fillMaxWidth(p.toFloat().coerceIn(0f, 1f))
                                        .height(2.5.dp)
                                        .background(Color(0xFF7FB0FF)),
                                )
                            }
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(e.mediaTitle, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(e.episodeLabel, fontSize = 13.sp, color = TextMuted, maxLines = 1)
                    }
                    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = TextFaint, modifier = Modifier.size(14.dp))
                }
            }
        }
    }
}

/** iOS SubsHomeRestingDivider：上下发丝线 + 中间竖排小字（宽 18、10/600 faint） */
@Composable
private fun RestingDivider(label: String, height: androidx.compose.ui.unit.Dp) {
    Column(
        Modifier.width(18.dp).height(height),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(Modifier.width(1.dp).height(28.dp).background(Color.White.copy(alpha = 0.12f)))
        Spacer(Modifier.height(8.dp))
        Text(
            // 中文竖排：逐字换行即可（iOS 用 fixedSize 让它自然竖排）
            label.toCharArray().joinToString("\n"),
            fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = TextFaint,
            lineHeight = 11.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Box(Modifier.width(1.dp).height(28.dp).background(Color.White.copy(alpha = 0.12f)))
    }
}

/** iOS SubsHomeSeeAllCard：与海报同尺寸的透明玻璃 + 2×2 图标 + 「查看全部」+ 「N 部」 */
@Composable
private fun SeeAllCard(total: Int, onClick: () -> Unit) {
    Column(
        Modifier
            .width(126.dp).height(189.dp)
            .clip(RoundedCornerShape(McMetrics.posterRadius))
            .background(Color.White.copy(alpha = 0.045f))
            .border(1.dp, Color.White.copy(alpha = 0.09f), RoundedCornerShape(McMetrics.posterRadius))
            .clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Rounded.GridOn, contentDescription = null, tint = TextMuted, modifier = Modifier.size(22.dp))
        Spacer(Modifier.height(8.dp))
        Text("查看全部", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
        Spacer(Modifier.height(2.dp))
        Text("$total 部", fontSize = 12.sp, color = TextFaint)
    }
}

@Composable
private fun SubCard(sub: SubscriptionView, dim: Boolean, origin: String?, onClick: () -> Unit) {
    Column(Modifier.width(126.dp).clickable(onClick = onClick)) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(189.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFF101219))
                .graphicsLayer { if (dim) { alpha = 0.5f } },
        ) {
            RemoteImage(
                url = sub.media.posterUrl,
                // 必须给 origin：服务端海报是相对路径（/images/assets/…），传 null 会直接回落占位图
                // ——「电影订阅没有封面图」就是这么来的（剧集那条恰好是 TMDB 绝对地址才蒙对）
                origin = origin,
                contentDescription = sub.media.title,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.6f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.6f))))
            // 状态小签（左上，内距 7）：黑 38% 胶囊 + 状态色圆点 + 10.5/600 文字（iOS SubsHomeChipView）
            val (chipText, chipColor) = subChip(sub)
            if (chipText.isNotEmpty()) {
                Row(
                    Modifier.align(Alignment.TopStart).padding(7.dp).clip(RoundedCornerShape(999.dp))
                        .background(Color.Black.copy(alpha = 0.38f)).padding(horizontal = 7.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.size(5.dp).clip(CircleShape).background(chipColor))
                    Spacer(Modifier.width(4.dp))
                    Text(chipText, fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, color = chipColor)
                }
            }
            val imported = sub.progress.imported
            val total = sub.progress.total
            if (imported in 1 until total) {
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(2.5.dp).background(Color.White.copy(alpha = 0.3f))) {
                    Box(Modifier.fillMaxWidth(imported.toFloat() / total.toFloat()).height(2.5.dp).background(Color.White.copy(alpha = 0.92f)))
                }
            }
        }
        Text(sub.media.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = if (dim) TextMuted else TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
        val meta = if (sub.media.kind == "tv") {
            val season = sub.selectedSeasons.firstOrNull()
            "第 ${season ?: 1} 季 · ${sub.progress.imported} / ${sub.progress.total}"
        } else {
            listOfNotNull(sub.media.year?.toString(), if (sub.progress.imported > 0) "已入库" else "未入库").joinToString(" · ")
        }
        Text(meta, fontSize = 12.sp, color = TextFaint, modifier = Modifier.padding(top = 2.dp))
    }
}

/**
 * 订阅页空态 —— 照移动端网页的 `ContentEmptyState variant="subscription"` 搬：
 * 一张银玻璃展台（圆环 + 两张斜着的胶片/电视小卡 + 中间圆形书签座 + 右下角铃铛与
 * 呼吸绿点），一句「从一部想看的作品开始」与去发现的动线。
 *
 * 空数据不是故障：这里不用警告式面板，也不用「暂无数据」这种什么都没说的话——
 * 网页原话是「空数据不是故障」，说明白了下一步该去哪。
 */
@Composable
private fun SubscriptionEmptyState(onOpenDiscover: () -> Unit) {
    Column(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Color.White.copy(alpha = 0.03f))
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(24.dp))
            .padding(horizontal = 20.dp, vertical = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // 装饰图（读屏不朗读）
        Box(Modifier.height(140.dp).fillMaxWidth(), contentAlignment = Alignment.Center) {
            Box(Modifier.size(140.dp).clip(CircleShape).border(1.dp, Color.White.copy(alpha = 0.06f), CircleShape))
            Box(
                Modifier
                    .size(96.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.025f))
                    .border(1.dp, Color.White.copy(alpha = 0.09f), CircleShape),
            )
            // 左胶片 / 右电视：各自斜一点
            Box(
                Modifier
                    .offset(x = (-78).dp, y = (-28).dp)
                    .rotate(-6f)
                    .size(44.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color.White.copy(alpha = 0.04f))
                    .border(1.dp, Color.White.copy(alpha = 0.09f), RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.Movie, contentDescription = null, tint = Color.White.copy(alpha = 0.35f), modifier = Modifier.size(20.dp)) }
            Box(
                Modifier
                    .offset(x = 78.dp, y = (-28).dp)
                    .rotate(6f)
                    .size(44.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color.White.copy(alpha = 0.04f))
                    .border(1.dp, Color.White.copy(alpha = 0.09f), RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.Tv, contentDescription = null, tint = Color.White.copy(alpha = 0.35f), modifier = Modifier.size(20.dp)) }
            // 中间的圆形玻璃座：书签
            Box(
                Modifier
                    .size(76.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF202530).copy(alpha = 0.9f))
                    .border(1.dp, Color.White.copy(alpha = 0.16f), CircleShape),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.BookmarkBorder, contentDescription = null, tint = Color.White.copy(alpha = 0.75f), modifier = Modifier.size(32.dp)) }
            // 右下角小圆钮：铃铛 + 呼吸的绿点（有合适资源时会通知）
            Box(
                Modifier
                    .offset(x = 34.dp, y = 44.dp)
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF303743))
                    .border(1.dp, Color.White.copy(alpha = 0.15f), CircleShape),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.Notifications, contentDescription = null, tint = Color.White.copy(alpha = 0.7f), modifier = Modifier.size(16.dp)) }
            Box(
                Modifier
                    .offset(x = 46.dp, y = 58.dp)
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(Ok),
            )
        }
        Spacer(Modifier.height(10.dp))
        Text("从一部想看的作品开始", style = McType.headline, color = TextPrimary)
        Spacer(Modifier.height(8.dp))
        Text(
            "去发现页挑选一部剧集或电影，打开详情并点击「订阅追踪」，有合适资源时会自动下载入库。",
            style = McType.body,
            color = TextMuted,
            textAlign = TextAlign.Center,
            lineHeight = 26.sp,
        )
        Spacer(Modifier.height(18.dp))
        Row(
            Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(Accent)
                .clickable(onClick = onOpenDiscover)
                .padding(horizontal = 16.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Rounded.Explore, contentDescription = null, tint = Color(0xFF0A0E12), modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text("去发现剧集", style = McType.subSemibold, color = Color(0xFF0A0E12))
        }
    }
}
