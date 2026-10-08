package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * 活动页的数据模型：后台任务（jobs）、下载器快照、正在播放的会话、播放活动汇总。
 *
 * 字段与服务端一一对应（`schemas/jobs.py`、`schemas/downloader.py`、`schemas/playback.py`），
 * 全局 SnakeCase 命名策略负责下划线映射。
 */

@Serializable
data class JobProgress(
    /** determinate / indeterminate / waiting / paused */
    val mode: String = "",
    val phase: String = "",
    val message: String = "",
    val current: Int? = null,
    val total: Int? = null,
    val percent: Float? = null,
    val phaseIndex: Int? = null,
    val phaseCount: Int? = null,
    /** 领域进度明细（历史行的标题/摘要从里面取 media_title、identified 这些键） */
    val details: JsonObject? = null,
)

/**
 * 失败任务的动作项。`type` 是后端约定的机器名（`retry_job` / `handoff_agent` /
 * `open_settings` / `inspect_logs` / `update_runtime`），`label` 由**后端给**
 * （如「交给 Agent」）——文案不归前端拼。
 */
@Serializable
data class JobErrorAction(
    val type: String = "",
    val label: String = "",
)

/** `job.error`：`{code, message, details, actions}`（后端 `JobControlError.as_error()`） */
@Serializable
data class JobErrorView(
    val code: String = "",
    val message: String = "",
    val actions: List<JobErrorAction> = emptyList(),
)

/**
 * 任务占用的资源（后端 `JobResourceView`）。
 * `library.ingest` 任务挂着 `download` 资源时，那条资源就是它正在入库的种子
 * （`resource_id` = info_hash），活动页据此把「入库失败」归到对应的下载任务上。
 */
@Serializable
data class JobResourceView(
    val resourceType: String = "",
    val resourceId: String = "",
    val relation: String = "",
)

@Serializable
data class JobView(
    val id: String,
    val jobType: String = "",
    val subject: String? = null,
    val status: String = "",
    val progress: JobProgress = JobProgress(),
    val error: JobErrorView? = null,
    val resources: List<JobResourceView> = emptyList(),
    /** 已确认的任务输入（永不包含密钥） */
    val inputData: JsonObject? = null,
    /** 结束结果（成功时的摘要等；服务端 `JobView.result`） */
    val result: JsonObject? = null,
    /** 用量：模型调用次数与 token（服务端 `JobView.usage`） */
    val usage: JobUsage = JobUsage(),
    /** 开始时间；「已用时」由它算出来（缺失按 0） */
    val startedAt: String? = null,
    /** 被用户忽略的时间；非空 = 不再出现在「需要处理」里 */
    val dismissedAt: String? = null,
    /** 取消是谁发起的；`system:` 前缀 = 系统取消（不给「重新执行」，重跑了也白跑） */
    val cancelRequestedBy: String? = null,
    /** 结束时间；历史行的时间戳与按天分组都用它，缺失时退回 createdAt */
    val finishedAt: String? = null,
    val origin: String = "",
    val actorName: String? = null,
    val attempt: Int = 1,
    val maxAttempts: Int = 1,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class JobListView(
    val items: List<JobView> = emptyList(),
    val running: Boolean = false,
)

/** 任务用量（服务端 `JobView.usage`）：模型调用次数与 token 数 */
@Serializable
data class JobUsage(
    val requestCount: Int = 0,
    val totalTokens: Long = 0,
)

/** `GET /jobs/events` 的 SSE 载荷（job_id + 事件类型 + 载荷） */
@Serializable
data class JobEventView(
    val id: Long = 0,
    val jobId: String = "",
    val revision: Int = 0,
    val eventType: String = "",
    val payload: JsonElement? = null,
)

@Serializable
data class DismissAllJobsRequest(val ids: List<String> = emptyList())

@Serializable
data class DownloadTask(
    val id: String,
    val infoHash: String = "",
    val name: String? = null,
    val downloaderId: Int? = null,
    val downloaderName: String? = null,
    /** 0..1；缺失任务为 null */
    val progress: Float? = null,
    val sizeBytes: Long? = null,
    val dlspeedBytes: Long? = null,
    val upspeedBytes: Long? = null,
    val etaSeconds: Long? = null,
    /** downloading / stalled / queued / paused / checking / completed / error / missing / unknown */
    val state: String = "",
    /** subscription / manual / boost / external */
    val source: String = "",
    val siteName: String? = null,
    val resolution: String? = null,
    val mediaSource: String? = null,
    val mediaTitle: String? = null,
    val mediaKind: String? = null,
    val posterUrl: String? = null,
    /** state == error 时下载器给出的可读原因（缺文件 / 出错详情） */
    val errorMessage: String? = null,
    /** 下载完成但看不到文件（落点核验失败）的说明——「需要处理」要说的就是它 */
    val landingError: String? = null,
    /** 能否立即换种（网页 card 的 can_replace 同源判定） */
    val canReplace: Boolean = false,
    /** 关联的媒体条目；null = 未识别（分组时各自独立，不按标题猜） */
    val mediaItemId: Long? = null,
    /** 这条任务关联的订阅摘要（含逐集覆盖与进度，卡片上的"覆盖 N 集 · 已入库 M"来自它） */
    val subscriptions: List<DownloadTaskSubscription> = emptyList(),
) {
    /**
     * 内容核验证明**种子里没有这几集**（声明覆盖与实际文件不符）。这一集已退回重找资源，
     * 不能再挂"等待下载完成"——网页把它当作「需要处理」的触发信号之一。
     * 形如 `S01E05` / `S01E05 等 3 集`。
     */
    fun contentMissingLabel(): String? {
        val units = subscriptions.firstOrNull()?.units.orEmpty().filter { it.contentMissing }
        val first = units.firstOrNull() ?: return null
        val label = "S%02dE%02d".format(first.seasonNumber, first.episodeNumber)
        return if (units.size == 1) label else "$label 等 ${units.size} 集"
    }

    /** 覆盖与入库进度：网页 `ingestUnitSummary` 的口径（分批入库时也只看得懂逐集状态） */
    fun unitSummary(): Pair<Int, Int>? {
        val units = subscriptions.firstOrNull()?.units ?: return null
        if (units.isEmpty()) return null
        return units.size to units.count { it.status == "imported" || it.replaced }
    }
}

@Serializable
data class DownloadTaskSubscription(
    val id: Long = 0,
    val mediaItemId: Long = 0,
    val mediaTitle: String = "",
    val mediaKind: String = "",
    val posterUrl: String? = null,
    /** download = 补缺下载；upgrade = 洗版（终点是"旧版本被换掉"） */
    val purpose: String = "download",
    val units: List<DownloadTaskUnit> = emptyList(),
)

@Serializable
data class DownloadTaskUnit(
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    /** wanted / grabbed / downloaded / imported */
    val status: String = "grabbed",
    val replaced: Boolean = false,
    val contentMissing: Boolean = false,
)

@Serializable
data class DownloadTaskList(val items: List<DownloadTask> = emptyList())

@Serializable
data class ActivePlaybackSession(
    val deviceId: String,
    val memberName: String = "",
    val client: String = "",
    val deviceName: String = "",
    val media: MediaActivityTarget = MediaActivityTarget(),
    val positionMs: Long? = null,
    val durationMs: Long? = null,
    val progressPercent: Int? = null,
    val paused: Boolean = false,
    /** local = 本机直连（速率可测）；remote = 网盘直链等不经过服务器的播放 */
    val playMethod: String = "",
    val rateBytesPerSecond: Float? = null,
)

/**
 * 一条正在进行的整文件下载（播放器的离线缓存，后端 `ActiveFileDownloadView`）。
 *
 * 注意它和 [DownloadTask] 是两件事：这里是**设备在拉整文件**（「正在下载」分区），
 * 下载器里的种子任务属于任务中心的「需要处理 / 进行中」。
 */
@Serializable
data class ActiveFileDownload(
    val deviceId: String,
    val memberName: String = "",
    val client: String = "",
    val deviceName: String = "",
    val revocable: Boolean = true,
    val media: MediaActivityTarget? = null,
    val fileName: String = "",
    val sizeBytes: Long = 0,
    val bytesSent: Long = 0,
    val rateBytesPerSecond: Float? = null,
    /** 同一设备对同一文件的多条 Range 连接（断点续传）聚合为一条展示 */
    val connections: Int = 1,
    /** 已下载到文件的哪个位置；[progressPercent] 为 null 时不画进度条而不是画一条假的 */
    val positionBytes: Long = 0,
    val progressPercent: Int? = null,
)

@Serializable
data class PlaybackActivityView(
    val sessions: List<ActivePlaybackSession> = emptyList(),
    val downloads: List<ActiveFileDownload> = emptyList(),
)

@Serializable
data class PlaybackStatsTotals(
    val plays: Int = 0,
    val watchedMs: Long = 0,
    val completed: Int = 0,
    val activeMembers: Int = 0,
)

@Serializable
data class PlaybackStatsDayRow(
    /** 按设备时区的日期 YYYY-MM-DD */
    val date: String = "",
    val plays: Int = 0,
    val watchedMs: Long = 0,
    val completed: Int = 0,
    /** 当天有播放的成员数 */
    val members: Int = 0,
)

@Serializable
data class PlaybackStatsMemberRow(
    val memberId: Int = 0,
    val memberName: String = "",
    val plays: Int = 0,
    val watchedMs: Long = 0,
    val completed: Int = 0,
)

@Serializable
data class PlaybackStatsClientRow(
    val client: String = "",
    val plays: Int = 0,
    val watchedMs: Long = 0,
)

/** 网页播放按档位；Jellyfin 客户端恒为直连，不在内 */
@Serializable
data class PlaybackStatsTierRow(
    val tier: Int = 0,
    val label: String = "",
    val plays: Int = 0,
)

@Serializable
data class PlaybackStatsTitleRow(
    val media: MediaActivityTarget = MediaActivityTarget(),
    val plays: Int = 0,
    val watchedMs: Long = 0,
    /** 看过这部作品的成员数 */
    val members: Int = 0,
)

/**
 * 观看统计：当前周期与上一周期成对返回（没有参照系的数字只是数据，不是洞察）。
 *
 * [byDay] 与 [previousByDay] 按天对齐，主图把两条线画在同一坐标系里；
 * [byHour] 是星期 × 小时的观看时长矩阵（0 行 = 周一），按设备时区分桶。
 */
@Serializable
data class PlaybackWatchStatsView(
    val days: Int = 7,
    val current: PlaybackStatsTotals = PlaybackStatsTotals(),
    val previous: PlaybackStatsTotals = PlaybackStatsTotals(),
    /** 上一周期有没有日志；日志刚开始记时没有，卡片上不该显示 0% */
    val previousAvailable: Boolean = false,
    val byDay: List<PlaybackStatsDayRow> = emptyList(),
    val previousByDay: List<PlaybackStatsDayRow> = emptyList(),
    /** 7×24 的观看时长矩阵（毫秒） */
    val byHour: List<List<Long>> = emptyList(),
    val byMember: List<PlaybackStatsMemberRow> = emptyList(),
    val byClient: List<PlaybackStatsClientRow> = emptyList(),
    val byTier: List<PlaybackStatsTierRow> = emptyList(),
    val topTitles: List<PlaybackStatsTitleRow> = emptyList(),
    /** 作品榜里不在浏览范围内的条数 */
    val hiddenTitleCount: Int = 0,
    /** 本期最受欢迎前三：看过的成员最多，并列取时长长的 */
    val favorites: List<PlaybackStatsTitleRow> = emptyList(),
    /** 上一周期的前三，用来标「蝉联 / 上期第 n / 新上榜」 */
    val previousFavorites: List<PlaybackStatsTitleRow> = emptyList(),
)

@Serializable
data class MediaActivityTarget(
    val mediaItemId: Long = 0,
    val libraryId: Long? = null,
    val browsable: Boolean = true,
    val kind: String = "movie",
    val title: String = "",
    val year: Int? = null,
    val posterUrl: String? = null,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
)

@Serializable
data class PlaybackLogEntry(
    val id: Long,
    val memberName: String = "",
    val media: MediaActivityTarget = MediaActivityTarget(),
    val client: String = "",
    val deviceName: String = "",
    val startedAt: String = "",
    val endedAt: String? = null,
    val watchedMs: Long = 0,
    val progressPercent: Int? = null,
    val completed: Boolean = false,
)

@Serializable
data class PlaybackHistoryView(
    val entries: List<PlaybackLogEntry> = emptyList(),
    val hiddenCount: Int = 0,
    val hasMore: Boolean = false,
    val nextCursor: Long? = null,
)
