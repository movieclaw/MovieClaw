package io.movieclaw.android.feature.activity

import io.movieclaw.android.core.designsystem.LocalFeedback
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Icon
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import androidx.compose.material.icons.rounded.Search
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.FlatCard
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McTabBarContentPadding
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.Ok
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Accent2
import androidx.compose.foundation.layout.fillMaxHeight
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.ProgressBar
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.tabGlassSource
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.ActiveFileDownload
import io.movieclaw.android.core.model.ActivePlaybackSession
import io.movieclaw.android.core.model.DownloadTask
import io.movieclaw.android.core.model.JobView
import kotlin.math.max
import kotlin.math.roundToInt

/** 活动中心:后台任务(jobs SSE 实时)+ 下载任务 + 播放监控 */
@Composable
fun ActivityScreen(
    onOpenAgentSession: (String) -> Unit = {},
    /** 进二级页（网页 `/activity?view=`）：active / history / plays / stats */
    onOpenActivityDetail: (String) -> Unit = {},
    vm: ActivityViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val origin = vm.origin
    // 分区与摘要行读同一份派生结果（口径见 ActivityDerive.kt）——两处各算各的
    // 就会出现「进行中 22」但列表里全是已完成任务那种数字与内容对不上
    val activity = deriveTaskActivity(state.downloads, state.jobs)
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    io.movieclaw.android.core.designsystem.TrackTabBarMinimize(listState)

    val feedback = LocalFeedback.current

    LaunchedEffect(state.notice) {
        state.notice?.let {
            feedback.show(it)
            vm.consumeNotice()
        }
    }

    // 工单备好、会话已建 → 跳到那个会话（网页 HandoffButton 的 router.push(`/sessions/{id}`)）
    LaunchedEffect(state.handoffSessionId) {
        state.handoffSessionId?.let { sessionId ->
            onOpenAgentSession(sessionId)
            vm.consumeHandoff()
        }
    }

    // 顶栏是浮层：内容要自己让开「状态栏 + 52dp」，否则首行会压在大标题下面
    val topBarTotal = WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + McMetrics.topBarHeight

    Box(Modifier.fillMaxSize().background(Bg)) {
        Column(Modifier.fillMaxSize()) {
            when {
                state.loading -> Box(Modifier.fillMaxSize().padding(top = topBarTotal), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted)
                }
                state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::loadSnapshot)
                else -> LazyColumn(state = listState,
                    contentPadding = PaddingValues(
                        top = topBarTotal + 6.dp,
                        bottom = McTabBarContentPadding,
                    ),
                    modifier = Modifier.fillMaxSize()
                        // 液态底栏的背景模糊源（Local 为 null 时原样返回，零代价）
                        .tabGlassSource(),
                ) {
                    // ── 需要处理（HTML 活动页第一个分区）──
                    // 数据不是单独接口：网页也是从下载任务 + 后台任务里派生的（useTaskActivity）。
                    // 分流口径全在 ActivityDerive.kt：刷流先摘掉、外部种子从不进这条、
                    // 用户忽略过的失败任务不再出现、入库失败的种子会整组顶上来。
                    if (activity.attentionTotal > 0) {
                        // 「下载过程按作品合并后计一条」（网页原话），所以这里数的是组数。
                        // 有失败任务时标题右侧是「全部忽略」——那是这一屏唯一能一次清干净的动作
                        item {
                            SectionLabel(
                                text = "需要处理 · ${activity.attentionTotal}",
                                trailing = activity.attentionJobs
                                    .takeIf { it.any { job -> job.status == "failed" } }
                                    ?.let { "全部忽略" to { vm.dismissAllFailed() } },
                                // 就地动作（清干净这一屏），不是去下一页——照 iOS `chevron: false` 不带箭头
                                trailingChevron = false,
                            )
                        }
                        items(activity.attentionGroups, key = { "att-grp-${it.key}" }) { group ->
                            AttentionGroupCard(
                                title = group.title,
                                kind = group.kind,
                                posterUrl = group.posterUrl,
                                origin = origin,
                                tasks = group.tasks,
                                onReplace = vm::replaceTask,
                                onDelete = vm::deleteTask,
                                onUpgrade = vm::upgradeSubscription,
                                onAnalyze = vm::analyzeTask,
                                llmGate = state.llmGate,
                                analyzingKey = state.analyzingKey,
                            )
                        }
                        items(activity.attentionJobs, key = { "att-job-${it.id}" }) { job ->
                            AttentionCard(
                                // 需要处理的卡片：标题给作品名、副行给任务类型的人话名
                                // （以前副行是 `library.skip_segments` 这种原始键）
                                title = job.subject ?: jobTypeLabel(job.jobType),
                                subtitle = jobTypeLabel(job.jobType),
                                reason = job.error?.message?.takeIf { it.isNotBlank() }
                                    ?: job.progress.message.ifBlank { "任务失败" },
                                meta = "第 ${job.attempt}/${job.maxAttempts} 次尝试",
                                onReplace = null,
                                onDelete = { vm.dismissJob(job) },
                                deleteLabel = "忽略",
                                actions = jobCardActions(job, state.llmGate, vm, analyzingKey = state.analyzingKey),
                            )
                        }
                    }

                    // 摘要行（大标题下一行实时摘要）+ 实时连接状态
                    item { ActivitySummary(activity, state) }
                    item {
                        Row(
                            Modifier.padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(Modifier.size(7.dp).clip(CircleShape).background(if (state.liveConnected) Ok else TextFaint))
                            Spacer(Modifier.width(8.dp))
                            Text(if (state.liveConnected) "任务流已连接" else "任务流连接中…", style = McType.sub, color = TextMuted)
                        }
                    }

                    // 分区顺序照网页总览：需要处理 → 正在播放 → 正在下载 → 进行中（含刷流）
                    if (state.sessions.isNotEmpty()) {
                        item { SectionLabel("正在播放 · ${state.sessions.size}") }
                        items(state.sessions, key = { "sess-${it.deviceId}" }) { session ->
                            PlaybackSessionCard(session) { vm.endSession(session) }
                        }
                    }
                    // 「正在下载」是**设备在拉整文件**（播放器离线缓存），与下载器里的种子任务是两件事
                    if (state.fileDownloads.isNotEmpty()) {
                        item { SectionLabel("正在下载 · ${state.fileDownloads.size}") }
                        items(state.fileDownloads, key = { "fdl-${it.deviceId}-${it.fileName}" }) { download ->
                            DeviceDownloadRow(download, origin)
                        }
                    }
                    // 「进行中」= 不需要处理的下载分组 + 活跃的后台任务；已串进种子的入库任务不重复出现。
                    // 总览只露 5 条（网页 ACTIVE_LIMIT），其余进二级页
                    if (activity.activeTotal > 0) {
                        item {
                            SectionLabel(
                                text = "进行中 · ${activity.activeTotal}",
                                trailing = "查看全部" to { onOpenActivityDetail("active") },
                            )
                        }
                        items(activity.activeGroups.take(ACTIVE_LIMIT), key = { "act-grp-${it.key}" }) { group ->
                            ActiveDownloadRow(group, activity.ingestJobs)
                        }
                        val jobBudget = (ACTIVE_LIMIT - activity.activeGroups.size).coerceAtLeast(0)
                        items(activity.activeJobs.take(jobBudget), key = { "act-job-${it.id}" }) { job ->
                            JobCard(
                                job = job,
                                onCancel = { vm.cancelJob(job) },
                                onRetry = { vm.retryJob(job) },
                                onDismiss = { vm.dismissJob(job) },
                            )
                        }
                    }

                    // ── 最近播放（只露 3 条，其余进二级页；网页 RECENT_LIMIT）──
                    if (state.history.isNotEmpty()) {
                        item {
                            SectionLabel(
                                text = "最近播放",
                                trailing = "查看全部" to { onOpenActivityDetail("plays") },
                            )
                        }
                        items(state.history.take(RECENT_LIMIT), key = { "hist-${it.id}" }) { entry ->
                            HistoryRow(entry, origin)
                        }
                    }

                    // ── 观看统计（网页总览的顺序：…最近播放 → 观看统计 → 最近完成）──
                    state.watchStats?.let { stats ->
                        item {
                            SectionLabel(
                                text = "观看统计",
                                trailing = "查看全部" to { onOpenActivityDetail("stats") },
                            )
                        }
                        item { WatchStatsCard(stats) }
                    }

                    // ── 最近完成（已结束的后台作业；只露 3 条，其余进二级页）──
                    if (activity.historyJobs.isNotEmpty()) {
                        item {
                            SectionLabel(
                                text = "最近完成",
                                trailing = "查看全部 ${activity.historyJobs.size} 个" to { onOpenActivityDetail("history") },
                            )
                        }
                        items(activity.historyJobs.take(RECENT_LIMIT), key = { "fin-job-${it.id}" }) { job ->
                            FinishedJobRow(job, onClick = { onOpenActivityDetail("history") })
                        }
                    }
                }
            }
        }

        // 根页大标题「活动」（网页 `setTopBarTitle("活动", { large: true })`，28px/700；
        // 手机端点进二级页时换成带返回键的小标题）
        McTopBar(
            variant = McTopBarVariant.Root,
            title = "活动",
            largeTitle = true,
            modifier = Modifier.align(Alignment.TopCenter),
        )
    }
}

/** 总览「进行中」最多露几条，其余进二级页（网页 `ACTIVE_LIMIT`） */
private const val ACTIVE_LIMIT = 5

/** 总览「最近播放 / 最近完成」露几条（网页 `RECENT_LIMIT`） */
private const val RECENT_LIMIT = 3

/**
 * 总览「最近完成」的一行（网页 `FinishedJobRow`）：对勾/叉 + 标题 + 摘要 + 相对时间。
 * 整行点进「已结束」二级页——补救动作都在那里的完整行上。
 */
@Composable
private fun FinishedJobRow(job: JobView, onClick: () -> Unit) {
    val succeeded = job.status == "succeeded"
    val stamp = job.finishedAt ?: job.createdAt
    Row(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .padding(vertical = 4.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(7.dp).background(if (succeeded) Ok else TextFaint, CircleShape))
        Spacer(Modifier.width(9.dp))
        Column(Modifier.weight(1f)) {
            Text(
                historicalJobTitle(job),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                historicalJobSummary(job),
                style = McType.sub,
                color = TextMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(McFormat.relative(stamp), fontSize = 11.sp, color = TextFaint)
    }
}

/**
 * 分区标题：实测 16/600、左内距 20（比卡片多 4，卡片是 16）。
 *
 * 右侧出口的两种形态照网页 `ActivityGroup` 的 `trailing` 与 iOS `ActivitySectionHeader`：
 * **去二级页的（「查看全部」）带一枚右箭头**，「就地动作」（「全部忽略」）不带——
 * 箭头是「点进去还有一页」的信号，就地动作加上它会误导。两端都是这个口径。
 * 出口一律贴右边缘（以前用两个 weight，标题与出口各占一半空档，看着偏在中间）。
 */
@Composable
internal fun SectionLabel(
    text: String,
    /** 分区标题右侧的出口（网页 `ActivityGroup` 的 `trailing`），如「查看全部」 */
    trailing: Pair<String, () -> Unit>? = null,
    /** 出口是不是「去往下一页」：是就带箭头（「全部忽略」这类就地动作传 false） */
    trailingChevron: Boolean = true,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, top = McMetrics.sectionTopTight, bottom = McMetrics.sectionBottomTight),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = McType.bodySemibold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.weight(1f))
        trailing?.let { (label, run) ->
            Row(
                Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = run)
                    .padding(start = 12.dp, top = 3.dp, bottom = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(label, fontSize = 12.5.sp, color = Accent)
                if (trailingChevron) {
                    // 与标题基线对齐的一枚小箭头（iOS chevron.right caption/semibold、网页 size-3.5）
                    Spacer(Modifier.width(2.dp))
                    Icon(
                        Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                        contentDescription = null,
                        tint = Accent,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun PlaybackSessionCard(session: ActivePlaybackSession, onEnd: () -> Unit) {
    FlatCard(Modifier.padding(horizontal = McMetrics.pagePadding).fillMaxWidth()) {
        // FlatCard 只有底色与描边，内边距由调用方给（网页 `ActivityCard` 手机档 p-3 / pb-3.5；
        // 本端统一 14dp，与「进行中」任务卡同款）。此前这张卡漏了内距：设备行贴着卡片左边、
        // 顶到圆角上，进度条还压着底边——看着像被裁了一刀（实机反馈）。
        Column(Modifier.padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    "${session.client.ifEmpty { "客户端" }} · ${session.deviceName.ifEmpty { session.deviceId.take(12) }}",
                    fontSize = 11.5.sp,
                    color = TextFaint,
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    session.media.title,
                    fontSize = 13.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    buildString {
                        if (session.media.kind == "tv" && session.media.seasonNumber > 0) {
                            append("S%02dE%02d · ".format(session.media.seasonNumber, session.media.episodeNumber))
                        }
                        append(session.memberName)
                        append(" · ")
                        append(session.playMethod.ifEmpty { "播放中" })
                        session.rateBytesPerSecond?.takeIf { it > 0 }?.let {
                            append(" · " + McFormat.speed(it.toDouble()))
                        }
                    },
                    fontSize = 11.sp,
                    color = TextMuted,
                )
            }
            TextButton(onClick = onEnd) { Text("结束", fontSize = 12.sp, color = Danger) }
        }
        session.progressPercent?.let { percent ->
            Spacer(Modifier.height(8.dp))
            ProgressBar(fraction = percent / 100f, tint = if (session.paused) Warning else Accent)
        }
        }
    }
}

@Composable
/**
 * 下载器里的状态文案，照网页 `DOWNLOAD_STATE_META` 逐条搬
 * （`completed` 是「等待入库」而不是「已完成」——文件下完了，库还没认领它）。
 */
private fun downloadStateLabel(task: DownloadTask): String = when (task.state) {
    "downloading" -> "下载中"
    "stalled" -> "等待连接"
    "paused" -> "已暂停"
    "queued" -> "排队中"
    "checking" -> "校验中"
    "completed" -> "等待入库"
    "error" -> "下载异常"
    "missing" -> "任务缺失"
    else -> "状态未知"
}

private fun downloadStateColor(task: DownloadTask): Color = when (task.state) {
    "downloading", "checking" -> Info
    "stalled", "paused" -> Warning
    "completed" -> Ok
    "error", "missing" -> Danger
    else -> TextMuted
}

/** 入库任务的状态文案，照网页 `INGEST_STATE_META` */
private fun ingestStateLabel(job: JobView): String = when (job.status) {
    "queued" -> "等待入库"
    "running" -> "正在入库"
    "retry_wait" -> "等待重试"
    "cancelling" -> "正在停止"
    "waiting" -> "等待条件"
    "blocked", "failed" -> "入库待处理"
    "succeeded" -> "入库完成"
    "cancelled" -> "入库已取消"
    else -> "入库中"
}

/**
 * 「进行中」里的一个下载分组（网页 `ActiveDownloadRow`）：标题 + 几个资源 + 百分比 + 状态行。
 *
 * 主状态有两条轴：下载轴的事实源是下载器，入库轴的事实源是逐集工单。
 * 只有整包已下完、或入库受阻需要人处理时，入库轴才接管主状态（网页 `ingestOwnsTaskState`）。
 */
@Composable
internal fun ActiveDownloadRow(
    group: DownloadGroup,
    ingestJobs: Map<String, JobView>,
) {
    val task = group.tasks.firstOrNull() ?: return
    val ingestJob = ingestJobs[task.infoHash.lowercase()]
    val ingesting = ingestOwnsTaskState(task, ingestJob) && ingestJob != null
    val percent = if (ingesting) {
        ingestJob?.progress?.percent
    } else {
        task.progress?.let { it * 100f }
    }
    val meta = if (ingesting) ingestStateLabel(ingestJob!!) else downloadStateLabel(task)
    val metaColor = if (ingesting) {
        if (ingestJob?.status == "failed" || ingestJob?.status == "blocked") Danger else Ok
    } else {
        downloadStateColor(task)
    }
    val status = buildList {
        add(meta)
        if (ingesting) {
            ingestJob?.progress?.message?.takeIf { it.isNotBlank() }?.let { add(it) }
        } else {
            task.dlspeedBytes?.takeIf { it > 0 }?.let { add("↓ " + McFormat.rate(it.toDouble()) + "/s") }
            if (task.state == "downloading") {
                task.etaSeconds?.takeIf { it > 0 }?.let { add("剩 " + McFormat.durationMinutes((it / 60).toInt())) }
            }
        }
    }
    FlatCard(Modifier.padding(horizontal = McMetrics.pagePadding).fillMaxWidth()) {
        // 内边距由调用方给（FlatCard 只有底色与描边）：此前漏了，标题/状态贴着卡片边缘
        Column(Modifier.padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(7.dp).background(metaColor, CircleShape))
            Spacer(Modifier.width(8.dp))
            Text(
                group.title,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (group.tasks.size > 1) {
                Spacer(Modifier.width(6.dp))
                Text("${group.tasks.size} 个资源", fontSize = 10.5.sp, color = TextFaint)
            }
            percent?.let {
                Spacer(Modifier.weight(1f))
                Text(
                    "${it.toInt()}%",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = TextMuted,
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        Text(status.joinToString(" · "), fontSize = 10.5.sp, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/**
 * 「正在下载」里的一条设备下载（网页 `DownloadCard variant="row"`）：
 * 海报 + 标题（没有媒体条目就退回文件名）+ 谁在哪台设备上拉 + 速度/进度 + 文件名。
 * `progress_percent` 为 null 时不画进度条——宁可不画，也不画一条假的。
 */
@Composable
private fun DeviceDownloadRow(download: ActiveFileDownload, origin: String?) {
    val media = download.media
    FlatCard(Modifier.padding(horizontal = McMetrics.pagePadding).fillMaxWidth()) {
        // 内边距由调用方给（FlatCard 只有底色与描边）：此前漏了，海报上下贴边、被圆角切
        Column(Modifier.padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            media?.posterUrl?.let { poster ->
                Box(Modifier.width(34.dp).height(50.dp).clip(RoundedCornerShape(6.dp))) {
                    RemoteImage(poster, origin, contentDescription = media.title, modifier = Modifier.fillMaxSize())
                }
                Spacer(Modifier.width(10.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(
                    media?.title?.takeIf { it.isNotBlank() } ?: download.fileName,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    listOfNotNull(
                        download.memberName.takeIf { it.isNotBlank() },
                        listOf(download.client, download.deviceName).filter { it.isNotBlank() }.joinToString(" ").takeIf { it.isNotBlank() },
                    ).joinToString(" · "),
                    fontSize = 10.5.sp,
                    color = TextMuted,
                    maxLines = 1,
                )
                Spacer(Modifier.height(3.dp))
                Row {
                    download.rateBytesPerSecond?.takeIf { it > 0 }?.let {
                        Text(McFormat.rate(it.toDouble()) + "/s", fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, color = Info)
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(
                        buildString {
                            append(McFormat.bytes(download.positionBytes))
                            if (download.sizeBytes > 0) append(" / " + McFormat.bytes(download.sizeBytes))
                            download.progressPercent?.let { append("  $it%") }
                        },
                        fontSize = 10.5.sp,
                        color = TextMuted,
                    )
                    if (download.connections > 1) {
                        Spacer(Modifier.width(8.dp))
                        Text("${download.connections} 条连接", fontSize = 10.5.sp, color = TextFaint)
                    }
                }
                if (media != null && download.fileName.isNotBlank()) {
                    Spacer(Modifier.height(3.dp))
                    Text(download.fileName, fontSize = 10.sp, color = TextFaint, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        }
    }
}

/**
 * 任务进度条（网页 `ActiveJobFeedItem`）：有百分比画定长条；**跑着但还没有百分比画不确定态**
 * ——三分之一宽的脉冲段（网页就是 `w-1/3 animate-pulse`，不来回移动）。
 * 以前没有百分比就整条不画，正在跑的识别任务看着像卡住了。
 */
@Composable
private fun JobProgressBar(percent: Float?, tint: Color) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(3.dp)
            .clip(RoundedCornerShape(3.dp))
            .background(Color.White.copy(alpha = 0.12f)),
    ) {
        if (percent != null) {
            Box(
                Modifier
                    .fillMaxWidth((percent / 100f).coerceIn(0f, 1f))
                    .height(3.dp)
                    .background(tint),
            )
        } else {
            val pulse = rememberInfiniteTransition(label = "job-pulse")
            val alpha by pulse.animateFloat(
                initialValue = 0.65f,
                targetValue = 0.28f,
                animationSpec = infiniteRepeatable(
                    animation = tween(700),
                    repeatMode = RepeatMode.Reverse,
                ),
                label = "job-pulse-alpha",
            )
            Box(
                Modifier
                    .fillMaxWidth(1f / 3f)
                    .height(3.dp)
                    .background(tint.copy(alpha = alpha)),
            )
        }
    }
}

/**
 * 「进行中」里的一个后台任务（网页 `ActiveJobFeedItem`）：作品名（认不出就用任务类型的人话名）
 * + 状态行（进行中说动作、其余说状态名，后面跟百分比）+ 进度消息（两行）+ 进度条。
 *
 * 两处与网页对齐、以前做得不对的地方：卡片**内容溢出**（`FlatCard` 自己不带上内边距，
 * 这一处忘了补，文字贴着卡片边框、压到圆角上）；进度条**没有百分比就整条不画**
 * （识别片头片尾这类任务没有百分比），现在与网页一样给不确定态脉冲条。
 */
@Composable
internal fun JobCard(job: JobView, onCancel: () -> Unit, onRetry: () -> Unit, onDismiss: () -> Unit) {
    val color = when (job.status) {
        "running" -> Accent
        "succeeded", "done", "completed" -> Success
        "failed", "error" -> Danger
        "cancelled", "canceled" -> Warning
        else -> Info
    }
    FlatCard(Modifier.padding(horizontal = McMetrics.pagePadding).fillMaxWidth()) {
        // FlatCard 只有底色与描边，内边距由调用方给（同 AttentionGroupCard 那张卡片）
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(7.dp).background(color, CircleShape))
                Spacer(Modifier.width(8.dp))
                Text(
                    job.subject ?: jobTypeLabel(job.jobType),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    when (job.status) {
                        "running", "queued", "waiting" -> TextButton(onClick = onCancel) {
                            Text("取消", fontSize = 11.5.sp, color = Danger)
                        }
                        "failed", "error", "cancelled", "canceled" -> {
                            TextButton(onClick = onRetry) { Text("重试", fontSize = 11.5.sp, color = Accent) }
                            TextButton(onClick = onDismiss) { Text("忽略", fontSize = 11.5.sp, color = TextFaint) }
                        }
                        else -> TextButton(onClick = onDismiss) { Text("忽略", fontSize = 11.5.sp, color = TextFaint) }
                    }
                }
            }
            Spacer(Modifier.height(6.dp))
            val percent = job.progress.percent
            Text(
                buildString {
                    append(activeJobStatus(job))
                    percent?.let { append(" · ").append(Math.round(it)).append("%") }
                    if (job.attempt > 1) append(" · 第 ${job.attempt}/${job.maxAttempts} 次")
                },
                fontSize = 11.5.sp,
                color = TextMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            job.progress.message.takeIf { it.isNotEmpty() }?.let {
                Spacer(Modifier.height(6.dp))
                Text(
                    it,
                    fontSize = 11.5.sp,
                    color = TextFaint,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    lineHeight = 16.sp,
                )
            }
            // 有百分比画定长条；正在跑但没百分比画不确定态；排队 / 等待 / 已结束的不画
            if (percent != null || job.status == "running") {
                Spacer(Modifier.height(8.dp))
                JobProgressBar(percent = percent, tint = color)
            }
        }
    }
}

/** 状态行文案（实测：「一切正常 · 现在没有人在看」） */
/** 摘要行里的一段：`alert` 的那段标红（网页 `activitySummaryParts` 的 `part.alert`） */
private data class SummaryPart(val text: String, val alert: Boolean = false)

/**
 * 大标题下一行实时摘要（网页 `lib/activity-overview.ts` 的 `activitySummaryParts`，逐条同口径）：
 * 「N 项需要处理 · N 台设备在播放 · N 台设备在下载 · N 个任务进行中」——只写非零的段，
 * 「需要处理」标红（那是要人动手的）；全为零时是「一切正常 · 现在没有人在看」；
 * 只要没人在播，末尾就补一句「现在没有人在看」。
 */
private fun activitySummaryParts(activity: TaskActivity, state: ActivityViewModel.UiState): List<SummaryPart> {
    val parts = buildList {
        if (activity.attentionTotal > 0) add(SummaryPart("${activity.attentionTotal} 项需要处理", alert = true))
        if (state.sessions.isNotEmpty()) add(SummaryPart("${state.sessions.size} 台设备在播放"))
        if (state.fileDownloads.isNotEmpty()) add(SummaryPart("${state.fileDownloads.size} 台设备在下载"))
        if (activity.activeTotal > 0) add(SummaryPart("${activity.activeTotal} 个任务进行中"))
    }
    if (parts.isEmpty()) return listOf(SummaryPart("一切正常"), SummaryPart("现在没有人在看"))
    return if (state.sessions.isEmpty()) parts + SummaryPart("现在没有人在看") else parts
}

@Composable
private fun ActivitySummary(activity: TaskActivity, state: ActivityViewModel.UiState) {
    Row(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .padding(top = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        activitySummaryParts(activity, state).forEachIndexed { index, part ->
            if (index > 0) Text(" · ", style = McType.sub, color = TextMuted)
            Text(
                part.text,
                style = McType.sub,
                color = if (part.alert) Danger else TextMuted,
                fontWeight = if (part.alert) FontWeight.SemiBold else null,
            )
        }
    }
}

/**
 * 观看统计卡（HTML 活动页「观看统计」）：最近 7 天总时长 + 与上周对比 + 逐日柱状图。
 * 数据来自 `GET /playback/stats/watch`（管理员专属；非管理员整块不显示）。
 */
@Composable
internal fun WatchStatsCard(stats: io.movieclaw.android.core.model.PlaybackWatchStatsView) {
    Column(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.05f))
            .padding(14.dp),
    ) {
        // 服务端按「含今天往前 N 天」给，可能多出一天；只画最近 7 根（网页 `WeeklyWatchCard`）
        val bars = stats.byDay.takeLast(7)
        val maxMs = bars.maxOfOrNull { it.watchedMs }?.coerceAtLeast(1L) ?: 1L
        val minutes = (stats.current.watchedMs / 60_000)
        val hours = minutes / 60L
        val (deltaText, deltaTone) = weeklyDelta(stats)

        Row(verticalAlignment = Alignment.Bottom) {
            Column(Modifier.weight(1f)) {
                Text("最近 7 天", style = McType.sub, color = TextMuted)
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.Bottom) {
                    if (hours > 0) {
                        Text("$hours", fontSize = 30.sp, fontWeight = FontWeight.Bold)
                        Text("小时", style = McType.sub, color = TextMuted, modifier = Modifier.padding(bottom = 3.dp))
                    }
                    if (hours > 0 && minutes % 60 > 0) Spacer(Modifier.width(6.dp))
                    if (minutes % 60L > 0L || hours == 0L) {
                        Text("${minutes % 60}", fontSize = 30.sp, fontWeight = FontWeight.Bold)
                        Text("分钟", style = McType.sub, color = TextMuted, modifier = Modifier.padding(bottom = 3.dp))
                    }
                }
            }
            deltaText?.let { text ->
                Text(
                    text,
                    style = McType.sub,
                    fontWeight = FontWeight.SemiBold,
                    color = deltaTone ?: TextMuted,
                    modifier = Modifier.padding(bottom = 2.dp),
                )
            }
        }
        if (bars.isNotEmpty()) {
            Spacer(Modifier.height(12.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                bars.forEachIndexed { index, day ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(Modifier.height(56.dp).fillMaxWidth(), contentAlignment = Alignment.BottomCenter) {
                            Box(
                                Modifier
                                    .fillMaxWidth(0.55f)
                                    .height(
                                        (56f * max(if (day.watchedMs > 0) 0.06f else 0.02f, day.watchedMs.toFloat() / maxMs)).dp
                                    )
                                    .clip(RoundedCornerShape(4.dp))
                                    // 最后一根是今天：其余压暗，一眼看出最新的一天
                                    .background(Info.copy(alpha = if (index == bars.lastIndex) 1f else 0.45f)),
                            )
                        }
                        Spacer(Modifier.height(6.dp))
                        Text(weekdayLabel(day.date), fontSize = 11.sp, color = TextFaint)
                    }
                }
            }
        }
    }
}

/**
 * 与前一周期比：网页 `weeklyDelta` —— 「比前 7 天 ↑ 12% / ↓ 8% / 持平」，
 * 上期是 0 而本期有则是「比前 7 天新增」；拿不到上期就整句不出（没有参照系的话只是数字）。
 */
private fun weeklyDelta(stats: io.movieclaw.android.core.model.PlaybackWatchStatsView): Pair<String?, Color?> {
    if (!stats.previousAvailable) return null to null
    val current = stats.current.watchedMs
    val previous = stats.previous.watchedMs
    if (previous <= 0) return if (current > 0) "比前 7 天新增" to Success else null to null
    val ratio = (((current - previous).toDouble() / previous) * 100).roundToInt()
    return when {
        ratio == 0 -> "与前 7 天持平" to TextFaint
        ratio > 0 -> "比前 7 天 ↑ $ratio%" to Success
        else -> "比前 7 天 ↓ ${-ratio}%" to TextMuted
    }
}

/** 一条播放流水（HTML「最近播放」）：海报 + 集名 + 设备 + 看完 ✓ / 时间 */
@Composable
internal fun HistoryRow(entry: io.movieclaw.android.core.model.PlaybackLogEntry, origin: String?) {
    val media = entry.media
    Row(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(34.dp).height(50.dp).clip(RoundedCornerShape(6.dp))) {
            RemoteImage(media.posterUrl, origin, contentDescription = media.title, modifier = Modifier.fillMaxSize())
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            val suffix = if (media.kind == "tv") " S${media.seasonNumber}E${media.episodeNumber}" else ""
            Text(media.title + suffix, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            Text(
                listOfNotNull(entry.memberName.takeIf { it.isNotBlank() }, entry.deviceName.takeIf { it.isNotBlank() })
                    .joinToString(" · "),
                fontSize = 12.sp,
                color = TextMuted,
                maxLines = 1,
            )
        }
        Column(horizontalAlignment = Alignment.End) {
            if (entry.completed) {
                Text("看完 ✓", fontSize = 13.sp, color = Success)
            } else {
                entry.progressPercent?.let { Text("看到 $it%", fontSize = 13.sp, color = TextMuted) }
            }
            Text(McFormat.relativeFromNow(entry.startedAt).orEmpty(), fontSize = 11.sp, color = TextFaint)
        }
    }
}

/** 毫秒 → 「14 小时 18 分」/「23 分」 */
private fun humanDuration(ms: Long): String {
    val minutes = ms / 60_000
    val hours = minutes / 60L
    return when {
        hours > 0 -> "$hours 小时 ${minutes % 60} 分"
        minutes > 0 -> "$minutes 分"
        else -> "不足 1 分"
    }
}

/** ISO 时间 → 周几（HTML 柱图下方那排「日一二三四五六」） */
private fun weekdayLabel(isoDate: String): String {
    val d = runCatching { java.time.LocalDate.parse(isoDate) }.getOrNull() ?: return ""
    val names = arrayOf("一", "二", "三", "四", "五", "六", "日")
    return names[d.dayOfWeek.value - 1]
}

/**
 * 「需要处理」卡（HTML 活动页 act-card 的语义）：
 * 标题 + 类别/来源 + **原因那一行**（这是它存在的意义） + 规格/进度 + 处置动作。
 *
 * 两个下载类动作与网页同源：`POST …/torrents/{hash}/replace`（立即换种）与
 * `DELETE …/torrents/{hash}`（删除任务，默认不删文件）。
 */
/**
 * 卡片上的一个可直接派发的动作：**文案全部来自服务端**（`job.error.actions[].label`）。
 * 前端只把动作名翻译成调用，不替后端写「交给 Agent」这类文案。
 */
internal data class CardAction(
    val id: String,
    val label: String,
    val busyLabel: String,
    val busy: Boolean,
    val run: () -> Unit,
)

/**
 * 失败后台任务的动作清单（网页 `JobCard` 的 `SUPPORTED_ACTIONS` 子集）：
 * 派发的是 `job.error.actions` 里后端给的动作名——
 * `retry_job`（重新执行）与 `handoff_agent`（交给 Agent）。
 * `handoff_agent` 与网页同口径：只在 AI 能力为 configured/unavailable 时出现。
 * `open_settings` / `inspect_logs` / `update_runtime` 要设置页的分区路由，安卓端暂无。
 */
internal fun jobCardActions(
    job: JobView,
    llmGate: LlmGate,
    vm: ActivityViewModel,
    analyzingKey: String?,
): List<CardAction> {
    val analyzeBusy = analyzingKey == job.id
    return buildList {
        job.error?.actions.orEmpty().forEach { action ->
            when (action.type) {
                "retry_job" -> add(
                    CardAction(
                        id = action.type,
                        label = action.label.ifBlank { "重新执行" },
                        busyLabel = "处理中…",
                        busy = false,
                        run = { vm.retryJob(job) },
                    ),
                )
                "handoff_agent" -> if (llmGate == LlmGate.CONFIGURED || llmGate == LlmGate.UNAVAILABLE) {
                    add(
                        CardAction(
                            id = action.type,
                            label = action.label.ifBlank { "交给 Agent" },
                            busyLabel = "处理中…",
                            busy = analyzeBusy,
                            run = { vm.analyzeJob(job) },
                        ),
                    )
                }
            }
        }
    }
}

@Composable
internal fun AttentionCard(
    title: String,
    subtitle: String,
    reason: String,
    meta: String,
    onReplace: (() -> Unit)?,
    onDelete: (() -> Unit)?,
    deleteLabel: String = "删除下载任务",
    actions: List<CardAction> = emptyList(),
) {
    Column(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.05f))
            .border(1.dp, Danger.copy(alpha = 0.25f), RoundedCornerShape(16.dp))
            .padding(14.dp),
    ) {
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (subtitle.isNotBlank()) {
            Spacer(Modifier.height(2.dp))
            Text(subtitle, fontSize = 12.sp, color = TextMuted, maxLines = 1)
        }
        Spacer(Modifier.height(8.dp))
        Text("需要处理：$reason", fontSize = 12.5.sp, color = Danger.copy(alpha = 0.9f))
        if (meta.isNotBlank()) {
            Spacer(Modifier.height(6.dp))
            Text(meta, fontSize = 12.sp, color = TextFaint)
        }
        // 补救动作在前、出口（忽略/删除）在后——网页原话：「先给出路，最后才给出口」
        if (onReplace != null || actions.isNotEmpty() || onDelete != null) {
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                onReplace?.let {
                    Text("立即换种", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Accent, modifier = Modifier.clickable(onClick = it))
                }
                actions.forEach { action ->
                    Text(
                        if (action.busy) action.busyLabel else action.label,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (action.busy) TextMuted else Accent2,
                        modifier = Modifier.clickable(enabled = !action.busy, onClick = action.run),
                    )
                }
                onDelete?.let {
                    Text(deleteLabel, fontSize = 13.sp, color = TextMuted, modifier = Modifier.clickable(onClick = it))
                }
            }
        }
    }
}

/**
 * 「需要处理」的分组卡（网页 `DownloadTaskGroupCard` 的语义）：
 * 海报 + 标题 + `剧集 · N 个下载资源`，下面挂该组里**每条**待处理任务的原因与动作。
 *
 * 分组只按媒体条目 id（未识别的资源各自独立）——网页原话：「同名但未识别的资源
 * 必须各自保留，不能因为标题解析相似就把两个版本或两部同名作品错误折叠」。
 */
@Composable
internal fun AttentionGroupCard(
    title: String,
    kind: String?,
    posterUrl: String?,
    origin: String?,
    tasks: List<io.movieclaw.android.core.model.DownloadTask>,
    onReplace: (io.movieclaw.android.core.model.DownloadTask) -> Unit,
    onDelete: (io.movieclaw.android.core.model.DownloadTask) -> Unit,
    onUpgrade: (Long) -> Unit,
    onAnalyze: (io.movieclaw.android.core.model.DownloadTask) -> Unit,
    llmGate: LlmGate,
    analyzingKey: String?,
) {
    Column(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.05f))
            .border(1.dp, Danger.copy(alpha = 0.25f), RoundedCornerShape(16.dp))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(38.dp).height(56.dp).clip(RoundedCornerShape(6.dp))) {
                RemoteImage(posterUrl, origin, contentDescription = title, modifier = Modifier.fillMaxSize())
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    listOfNotNull(
                        kind?.let { if (it == "tv") "剧集" else "电影" },
                        "${tasks.size} 个下载资源",
                    ).joinToString(" · "),
                    fontSize = 12.sp,
                    color = TextMuted,
                )
            }
        }
        tasks.forEach { task ->
            val reason = task.contentMissingLabel()?.let { "种子里没有 $it，已退回重新寻找资源" }
                ?: task.landingError ?: task.errorMessage
                ?: if (task.state == "missing") "下载器里找不到这个任务" else "下载器报告异常"
            Spacer(Modifier.height(10.dp))
            Text("需要处理：$reason", fontSize = 12.5.sp, color = Danger.copy(alpha = 0.9f))
            // 覆盖与入库进度（逐集状态，分批入库时也说得清"覆盖 10 集、已入库 2 集"）
            task.unitSummary()?.let { (total, done) ->
                Text(
                    "覆盖 $total 集 · 已入库 $done",
                    fontSize = 12.sp,
                    color = TextMuted,
                )
            }
            Text(
                listOfNotNull(
                    task.name?.take(40),
                    task.siteName,
                    task.downloaderName,
                    task.sizeBytes?.let { McFormat.bytes(it) },
                ).joinToString("  "),
                fontSize = 12.sp,
                color = TextFaint,
                maxLines = 1,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                if (task.canReplace && task.downloaderId != null) {
                    Text(
                        "立即换种",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Accent,
                        modifier = Modifier.clickable { onReplace(task) },
                    )
                }
                // 洗版：这条任务挂在某个订阅下才有意义（接口是订阅级的洗一轮版）
                task.subscriptions.firstOrNull()?.id?.takeIf { it > 0 }?.let { subId ->
                    Text(
                        "洗版",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Warning,
                        modifier = Modifier.clickable { onUpgrade(subId) },
                    )
                }
                // 「交给 AI 分析」：需要处理的任务一律给的第二出口（网页 HandoffButton 原话：
                // 确定性动作仍是第一按钮；用户不知道该选哪个时，AI 拿到的是带现场自检的完整工单）。
                // 未配置模型时整个不渲染。
                if (llmGate == LlmGate.CONFIGURED || llmGate == LlmGate.UNAVAILABLE) {
                    val busy = analyzingKey == task.infoHash
                    Text(
                        if (busy) "正在整理上下文…" else "交给 AI 分析",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (busy) TextMuted else Accent2,
                        modifier = Modifier.clickable(enabled = !busy) { onAnalyze(task) },
                    )
                }
                if (task.downloaderId != null) {
                    Text(
                        "删除下载任务",
                        fontSize = 13.sp,
                        color = TextMuted,
                        modifier = Modifier.clickable { onDelete(task) },
                    )
                }
            }
        }
    }
}
