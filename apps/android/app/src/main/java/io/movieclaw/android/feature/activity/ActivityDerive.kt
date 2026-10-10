package io.movieclaw.android.feature.activity

import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.model.DownloadTask
import io.movieclaw.android.core.model.JobView

/**
 * 活动页的派生口径 —— 逐条对齐网页 `lib/job-attention.ts` / `lib/task-activity.ts` /
 * `lib/download-attention.ts`。**只此一处**：总览的分区行与顶部摘要行都读这里的函数，
 * 否则「进行中」的数字和列表会各算各的（网页侧栏数字曾因此比页面大一号）。
 */

/** 网页 `ACTIVE_FEED_JOB_STATUSES`：算「进行中」的状态 */
val ACTIVE_FEED_JOB_STATUSES = setOf("queued", "running", "retry_wait", "cancelling", "waiting")

/** 网页 `HISTORY_JOB_STATUSES` */
private val HISTORY_JOB_STATUSES = setOf("succeeded", "cancelled")

/** 用户忽略过的失败任务不再出现（后端 `dismissed_at`） */
fun JobView.isDismissed(): Boolean = dismissedAt != null

/** 网页 `jobNeedsAttention`：失败且没被忽略 */
fun JobView.needsAttention(): Boolean = status == "failed" && !isDismissed()

/** 网页 `jobIsHistorical`：已结束 = succeeded/cancelled，或失败但已被忽略 */
fun JobView.isHistorical(): Boolean =
    status in HISTORY_JOB_STATUSES || (status == "failed" && isDismissed())

/**
 * 网页 `downloadTaskNeedsAttention`：外部（external）种子一律不算需要处理；
 * 刷流（boost）在调用前就已被分流出去。
 */
fun DownloadTask.needsAttention(linkedIngestJob: JobView?): Boolean {
    if (source == "external") return false
    return canReplace ||
        state == "error" ||
        state == "missing" ||
        !landingError.isNullOrBlank() ||
        contentMissingLabel() != null ||
        linkedIngestJob?.needsAttention() == true
}

/**
 * 网页 `ingestJobsByHash`：`library.ingest` 任务挂着的下载资源 → 那台任务的 info_hash。
 * 用它把「入库任务失败」归到对应种子上，也让这些任务不再作为第二件事重复出现在「进行中」。
 */
fun ingestJobsByHash(jobs: List<JobView>): Map<String, JobView> {
    val linked = mutableMapOf<String, JobView>()
    for (job in jobs) {
        if (job.jobType != "library.ingest") continue
        for (resource in job.resources) {
            if (resource.resourceType == "download" && !linked.containsKey(resource.resourceId.lowercase())) {
                linked[resource.resourceId.lowercase()] = job
            }
        }
    }
    return linked
}

/** 已串进下载生命周期的入库任务 id（既不重复渲染，也不重复计数） */
fun linkedIngestJobIds(tasks: List<DownloadTask>, ingestJobs: Map<String, JobView>): Set<String> =
    tasks.mapNotNull { ingestJobs[it.infoHash.lowercase()]?.id }.toSet()

/**
 * 网页 `ingestOwnsTaskState`：一个下载任务有两条独立进度轴（下载轴的事实源是下载器，
 * 入库轴的事实源是逐集工单）。**只有**整包已下完（入库确实是此刻唯一在推进的事）
 * 或入库受阻需要人处理时，入库轴才接管卡片主状态——否则「整季只下了 19%、其中先入库
 * 1 集」会被讲成「下载完成 + 入库完成」。
 */
fun ingestOwnsTaskState(task: DownloadTask, ingestJob: JobView?): Boolean {
    if (ingestJob == null || ingestJob.status == "cancelled") return false
    if (ingestJob.needsAttention()) return true
    return task.state == "completed"
}

/** 网页 `isSystemCancelled`：系统取消的任务不给「重新执行」——重跑了也是白跑 */
fun JobView.isSystemCancelled(): Boolean =
    status == "cancelled" && cancelRequestedBy?.startsWith("system:") == true

/**
 * 任务的三张文案表（网页 `JOB_TYPE_LABELS` / `JOB_STATUS_LABELS` / `ACTIVE_JOB_ACTIONS`
 * 与 iOS `TaskCenter` 的同名表，逐条照抄）。**全站唯一一份**：进行中的卡片、需要处理的
 * 卡片、历史标题都从这里取——以前三处各写各的，`library.skip_segments` 这种原始键就
 * 从没补过的表里漏到了界面上（用户看到的正是它）。
 */
internal fun jobTypeLabel(jobType: String): String = when (jobType) {
    "subtitle.generate" -> "生成 AI 字幕"
    "library.scan" -> "扫描媒体库"
    "library.metadata.refresh" -> "刷新媒体库元数据"
    "media.metadata.refresh" -> "刷新条目元数据"
    "library.chapter_images" -> "生成章节"
    "library.skip_segments", "media.skip_segments" -> "识别片头片尾"
    "reels.clips" -> "预切片段"
    "library.organize" -> "整理媒体库文件"
    "library.transfer" -> "转移媒体库条目"
    "library.ingest" -> "自动整理入库"
    // 认不出就给原始键（服务端加了新类型时至少不空白）
    else -> jobType
}

/** 状态的展示词（iOS `TaskCenter.jobStatusLabels`） */
internal fun jobStatusLabel(status: String): String = when (status) {
    "queued" -> "排队中"
    "running" -> "进行中"
    "retry_wait" -> "等待重试"
    "cancelling" -> "正在取消"
    "waiting" -> "等待前置任务"
    "blocked" -> "需要处理"
    "succeeded" -> "已完成"
    "failed" -> "未完成"
    "cancelled" -> "已取消"
    else -> status
}

/** 进行中的动作词（iOS `TaskCenter.activeJobStatus` / 网页 `activeJobStatus`） */
internal fun activeJobStatus(job: JobView): String = if (job.status == "running") {
    when (job.jobType) {
        "subtitle.generate" -> "正在生成字幕"
        "library.scan" -> "正在扫描"
        "library.metadata.refresh" -> "正在刷新媒体库元数据"
        "media.metadata.refresh" -> "正在刷新元数据"
        "library.chapter_images" -> "正在生成章节"
        "library.skip_segments", "media.skip_segments" -> "正在识别片头片尾"
        "reels.clips" -> "正在预切片段"
        "library.organize" -> "正在整理文件"
        "library.transfer" -> "正在转移文件"
        "library.ingest" -> "正在入库"
        else -> "正在处理"
    }
} else {
    jobStatusLabel(job.status)
}

/** 已完成任务的动作名，照网页 `COMPLETED_JOB_ACTIONS`（含「片头片尾识别」两项） */
private val COMPLETED_JOB_ACTIONS = mapOf(
    "subtitle.generate" to "字幕生成",
    "library.scan" to "扫描",
    "library.metadata.refresh" to "元数据刷新",
    "media.metadata.refresh" to "元数据刷新",
    "library.chapter_images" to "章节生成",
    "library.skip_segments" to "片头片尾识别",
    "media.skip_segments" to "片头片尾识别",
    "reels.clips" to "片段预切",
    "library.organize" to "文件整理",
    "library.transfer" to "文件转移",
    "library.ingest" to "入库",
)

/** 网页 `jobDetailString`：进度明细里的键，取不到再退回任务输入 */
private fun JobView.detailString(key: String): String? {
    val detail = progress.details?.get(key) ?: inputData?.get(key)
    return (detail as? kotlinx.serialization.json.JsonPrimitive)?.content?.takeIf { it.isNotBlank() }
}

/** 网页 `jobFeedIdentity`：书名号里的片名优先（进度消息里的《…》就是这部作品） */
private fun JobView.feedIdentity(): String? {
    val quoted = Regex("《([^》]+)》").find(progress.message)?.groupValues?.get(1)
    val title = quoted ?: detailString("media_title") ?: detailString("title") ?: subject ?: return null
    if (title.startsWith("《") || title.startsWith("「")) return title
    if (jobType == "library.scan") return "「$title」"
    if (jobType == "library.ingest" || jobType == "subtitle.generate" || jobType.contains("metadata.refresh")) {
        return "《$title》"
    }
    return title
}

/** 网页 `historicalJobTitle`：`身份 + 动作 + 结果` */
fun historicalJobTitle(job: JobView): String {
    val identity = job.feedIdentity()
    val action = COMPLETED_JOB_ACTIONS[job.jobType]
    // 忽略只是"不再提醒"，不是"做完了"：历史里如实写「未完成」
    val result = when (job.status) {
        "cancelled" -> "已取消"
        "failed" -> "未完成"
        else -> "完成"
    }
    return if (identity != null && action != null) "$identity$action$result" else "${identity ?: jobTypeLabel(job.jobType)}$result"
}

/** 网页 `historicalJobSummary` */
fun historicalJobSummary(job: JobView): String {
    if (job.jobType == "library.scan") {
        val parts = listOfNotNull(
            job.detailString("identified")?.let { "识别 $it 个" },
            job.detailString("unidentified")?.let { "待识别 $it 个" },
        )
        if (parts.isNotEmpty()) return parts.joinToString(" · ")
    }
    if (job.status == "failed" && job.isDismissed()) {
        return job.error?.message?.takeIf { it.isNotBlank() }
            ?: job.progress.message.takeIf { it.isNotBlank() }
            ?: "任务失败，已被忽略"
    }
    return job.progress.message.takeIf { it.isNotBlank() }
        ?: if (job.status == "cancelled") "任务已取消" else "任务已完成"
}

/** 历史任务的一天（网页 `HistoryDayGroup`） */
data class JobDayGroup(val key: String, val label: String, val jobs: List<JobView>)

/**
 * 网页 `groupHistoricalJobs`：按**结束那一刻所在的自然日**分组，组内保持原顺序
 * （接口已按更新时间倒序返回）。
 */
fun groupHistoricalJobs(jobs: List<JobView>): List<JobDayGroup> {
    val groups = LinkedHashMap<String, JobDayGroup>()
    for (job in jobs) {
        val stamp = job.finishedAt ?: job.createdAt
        val key = McFormat.dayKey(stamp)
        val existing = groups[key]
        groups[key] = if (existing != null) {
            existing.copy(jobs = existing.jobs + job)
        } else {
            JobDayGroup(key = key, label = McFormat.dayLabel(stamp), jobs = listOf(job))
        }
    }
    return groups.values.toList()
}

/** 一个下载分组（网页 `DownloadTaskGroup`） */
data class DownloadGroup(
    val key: String,
    val title: String,
    val kind: String?,
    val posterUrl: String?,
    val tasks: List<DownloadTask>,
)

/**
 * 网页 `groupDownloadTasks`：**只用媒体条目主键合并**。同名但未识别的资源必须各自保留，
 * 不能因为标题解析相似就把两个版本或两部同名作品错误折叠。
 */
fun groupDownloadTasks(tasks: List<DownloadTask>): List<DownloadGroup> {
    val groups = LinkedHashMap<String, DownloadGroup>()
    for (task in tasks) {
        val key = task.mediaItemId?.let { "media:$it" } ?: "task:${task.id}"
        val existing = groups[key]
        if (existing != null) {
            groups[key] = existing.copy(
                posterUrl = existing.posterUrl ?: task.posterUrl,
                tasks = existing.tasks + task,
            )
            continue
        }
        groups[key] = DownloadGroup(
            key = key,
            title = task.mediaTitle ?: task.name ?: task.infoHash,
            kind = task.mediaKind,
            posterUrl = task.posterUrl,
            tasks = listOf(task),
        )
    }
    return groups.values.toList()
}

/** 网页 `downloadGroupNeedsAttention`：组里有一条需要处理，整组就是需要处理 */
fun DownloadGroup.needsAttention(ingestJobs: Map<String, JobView>): Boolean =
    tasks.any { it.needsAttention(ingestJobs[it.infoHash.lowercase()]) }

/**
 * 活动总览的全部派生结果（网页 `useTaskActivity` 的返回）。
 *
 * 分流顺序照网页：先摘掉刷流（boost），再按是否需要处理把下载分组分成
 * 「需要处理」与「进行中」两拨；入库任务若已串进某个种子，就不再单独出现。
 */
data class TaskActivity(
    val ingestJobs: Map<String, JobView>,
    val attentionGroups: List<DownloadGroup>,
    val activeGroups: List<DownloadGroup>,
    val attentionJobs: List<JobView>,
    val activeJobs: List<JobView>,
    val historyJobs: List<JobView>,
) {
    val attentionTotal: Int get() = attentionGroups.size + attentionJobs.size
    val activeTotal: Int get() = activeGroups.size + activeJobs.size
}

fun deriveTaskActivity(tasks: List<DownloadTask>, jobs: List<JobView>): TaskActivity {
    val ingestJobs = ingestJobsByHash(jobs)
    val linked = linkedIngestJobIds(tasks, ingestJobs)
    // 刷流常年大量在跑，计入会让数字失去意义，先行分流
    val groups = groupDownloadTasks(tasks.filter { it.source != "boost" })
    val standalone = jobs.filter { it.id !in linked }
    return TaskActivity(
        ingestJobs = ingestJobs,
        attentionGroups = groups.filter { it.needsAttention(ingestJobs) },
        activeGroups = groups.filter { !it.needsAttention(ingestJobs) },
        attentionJobs = standalone.filter { it.needsAttention() },
        activeJobs = standalone.filter { it.status in ACTIVE_FEED_JOB_STATUSES },
        historyJobs = standalone.filter { it.isHistorical() },
    )
}
