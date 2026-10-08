package io.movieclaw.android.feature.activity

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
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
import io.movieclaw.android.core.designsystem.Accent2
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Ok
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.JobView

/**
 * 活动二级页（网页 `/activity?view=`）：进行中 / 已结束 / 最近播放 / 观看统计。
 *
 * 网页的活动页是「一页总览 + 二级页」（`lib/task-center.ts` 的 `ACTIVITY_PAGES`）：
 * 总览里每个分区只露几条，剩下的都进这里。**需要处理与正在播放不另开页**——它们
 * 就在总览最上面，所以这里也没有这两个入口。
 */
@Composable
fun ActivityDetailScreen(
    view: String,
    onBack: () -> Unit,
    vm: ActivityViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val origin = vm.origin
    val activity = deriveTaskActivity(state.downloads, state.jobs)
    // 历史按天折叠：折叠的日期集合（网页 `<details>`，首段默认展开）
    var collapsedDays by remember { mutableStateOf(emptySet<String>()) }


    Box(Modifier.fillMaxSize().background(Bg)) {
        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            state.error != null && state.jobs.isEmpty() ->
                ErrorPane(message = state.error!!, onRetry = vm::loadSnapshot)
            else -> LazyColumn(
                contentPadding = PaddingValues(
                    // 顶栏是压在上面的雾层，且只吃掉「状态栏 + 52dp」——内容要把这段整个让开，
                    // 少让状态栏那一段的话，首行（周期切换那一排）会跟标题叠在一起
                    top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding() +
                        McMetrics.topBarHeight + 10.dp,
                    bottom = McMetrics.tabBarBottom + 96.dp,
                ),
                modifier = Modifier.fillMaxSize(),
            ) {
                when (view) {
                    "active" -> activeView(activity, vm)
                    "history" -> historyView(
                        activity = activity,
                        vm = vm,
                        collapsedDays = collapsedDays,
                        onToggleDay = { key ->
                            collapsedDays = if (key in collapsedDays) collapsedDays - key else collapsedDays + key
                        },
                    )
                    "plays" -> playsView(state, origin)
                    "stats" -> statsView(state, origin, vm)
                    else -> item { EmptyNote("没有这个视角", "总览里有需要处理、正在播放、正在下载、进行中。") }
                }
            }
        }
        ActivityDetailTopBar(
            title = pageTitle(view),
            onBack = onBack,
            modifier = Modifier.align(Alignment.TopCenter),
        )
    }
}

private fun pageTitle(view: String): String = when (view) {
    "active" -> "进行中"
    "history" -> "已结束"
    "plays" -> "最近播放"
    "stats" -> "观看统计"
    else -> "活动"
}

/* ---------------------------------------------------------------- 进行中 */

private fun LazyListScope.activeView(activity: TaskActivity, vm: ActivityViewModel) {
    if (activity.activeTotal == 0) {
        item { EmptyNote("当前没有进行中的任务", "新任务启动后会自动进入实时过程。") }
        return
    }
    item { SectionLabel("现在 · ${activity.activeTotal}") }
    items(activity.activeGroups, key = { "act-grp-${it.key}" }) { group ->
        ActiveDownloadRow(group, activity.ingestJobs)
    }
    items(activity.activeJobs, key = { "act-job-${it.id}" }) { job ->
        JobCard(
            job = job,
            onCancel = { vm.cancelJob(job) },
            onRetry = { vm.retryJob(job) },
            onDismiss = { vm.dismissJob(job) },
        )
    }
}

/* ---------------------------------------------------------------- 已结束 */

private fun LazyListScope.historyView(
    activity: TaskActivity,
    vm: ActivityViewModel,
    collapsedDays: Set<String>,
    onToggleDay: (String) -> Unit,
) {
    val jobs = activity.historyJobs
    if (jobs.isEmpty()) {
        item { EmptyNote("还没有历史记录", "完成、取消，以及被你忽略的后台作业都会保留在这里。") }
        return
    }
    groupHistoricalJobs(jobs).forEach { group ->
        val open = group.key !in collapsedDays
        item(key = "day-${group.key}") {
            HistoryDayHeader(
                label = group.label,
                count = group.jobs.size,
                open = open,
                onToggle = { onToggleDay(group.key) },
            )
        }
        if (open) {
            items(group.jobs, key = { "hist-job-${it.id}" }) { job ->
                HistoryJobRow(
                    job = job,
                    onRetry = { vm.retryJob(job) },
                    onUndismiss = { vm.undismissJob(job) },
                )
            }
        }
    }
}

/** 一天一段，点头部折叠（网页 `TaskHistorySection` 的 `<details>`；首段默认展开） */
@Composable
private fun HistoryDayHeader(label: String, count: Int, open: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .padding(top = 8.dp, bottom = 4.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onToggle)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextMuted)
        Spacer(Modifier.width(8.dp))
        Text("$count 项", fontSize = 11.sp, color = TextFaint)
        Spacer(Modifier.weight(1f))
        Text(if (open) "收起" else "展开", fontSize = 11.sp, color = TextFaint)
    }
}

/**
 * 已结束的一条（网页 `FinishedJobRow` + `HistoricalJobFeedItem`）：标题、摘要、时刻，
 * 以及这条记录上唯一有意义的补救动作——被忽略的失败可以「撤销忽略」，
 * 用户自己取消的可以「重新执行」（系统取消的不给，重跑了也是白跑）。
 */
@Composable
private fun HistoryJobRow(
    job: JobView,
    onRetry: () -> Unit,
    onUndismiss: () -> Unit,
) {
    val succeeded = job.status == "succeeded"
    Column(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .padding(vertical = 5.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Box(Modifier.padding(top = 4.dp).size(7.dp).background(if (succeeded) Ok else TextFaint, CircleShape))
            Spacer(Modifier.width(9.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    historicalJobTitle(job),
                    fontSize = 13.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    historicalJobSummary(job),
                    style = McType.sub,
                    color = TextMuted,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(8.dp))
            Column(horizontalAlignment = Alignment.End) {
                Text(McFormat.clockTime(job.finishedAt ?: job.createdAt), fontSize = 11.sp, color = TextFaint)
                Text(McFormat.relative(job.finishedAt ?: job.createdAt), fontSize = 11.sp, color = TextFaint)
            }
        }
        val action: Pair<String, () -> Unit>? = when {
            job.status == "failed" && job.isDismissed() -> "撤销忽略" to onUndismiss
            job.status == "cancelled" && !job.isSystemCancelled() -> "重新执行" to onRetry
            else -> null
        }
        action?.let { (label, run) ->
            Spacer(Modifier.height(8.dp))
            Text(
                label,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = Accent2,
                modifier = Modifier
                    .padding(start = 16.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = run)
                    .padding(horizontal = 6.dp, vertical = 4.dp),
            )
        }
    }
}

/* ------------------------------------------------------------ 最近播放 */

private fun LazyListScope.playsView(state: ActivityViewModel.UiState, origin: String?) {
    if (state.history.isEmpty()) {
        item { EmptyNote("还没有播放记录", "成员看过的每一场都会记在这里。") }
        return
    }
    item { SectionLabel("最近播放 · ${state.history.size}") }
    items(state.history, key = { "hist-${it.id}" }) { entry -> HistoryRow(entry, origin) }
}

/* ------------------------------------------------------------ 观看统计 */

private fun LazyListScope.statsView(state: ActivityViewModel.UiState, origin: String?, vm: ActivityViewModel) {
    val stats = state.watchStats
    if (stats == null) {
        item { EmptyNote("看不到观看统计", "这个视图是管理员专属；非管理员账号看不到。") }
        return
    }
    item {
        // 周期与钻取挂在页内（网页挂在二级页顶栏右上角的筛选菜单里）。
        // 副标题同网页：「最近 N 天 · <成员>」，钻取中把成员名写出来
        Column(Modifier.padding(horizontal = McMetrics.pagePadding).padding(bottom = 12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(7, 30, 90).forEach { days ->
                    val selected = state.watchStatsDays == days
                    Text(
                        "最近 $days 天",
                        fontSize = 12.5.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (selected) Color.White else TextMuted,
                        modifier = Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .background(if (selected) Color.White.copy(alpha = 0.14f) else Color.White.copy(alpha = 0.04f))
                            .clickable { vm.setWatchStatsDays(days) }
                            .padding(horizontal = 12.dp, vertical = 7.dp),
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            val drilled = stats.byMember.firstOrNull { it.memberId == state.watchStatsMemberId }?.memberName
            Text(
                listOfNotNull("最近 ${state.watchStatsDays} 天", drilled ?: "全部成员").joinToString(" · "),
                fontSize = 11.5.sp,
                color = TextMuted,
            )
        }
    }
    item {
        WatchStatsPanel(
            stats = stats,
            origin = origin,
            memberId = state.watchStatsMemberId,
            onDrillMember = vm::drillWatchStatsMember,
            // 安卓端还没有「浏览范围」开关，所以不给一个点了没反应的「显示全部」
            onShowAll = null,
            onWidenDays = { vm.setWatchStatsDays(90) },
        )
    }
}

/* ------------------------------------------------------------------ 公共 */

/** 子页顶栏用全局那一个（返回钮 36×36 在 x=8、标题 20/600 在 x=48、雾层向下渐隐） */
@Composable
private fun ActivityDetailTopBar(title: String, onBack: () -> Unit, modifier: Modifier = Modifier) {
    McTopBar(variant = McTopBarVariant.Sub, title = title, onBack = onBack, modifier = modifier)
}

/** 空态（网页 `EmptyView` 的两行文案） */
@Composable
internal fun EmptyNote(title: String, note: String) {
    Column(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .padding(top = 40.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .border(1.dp, Color.White.copy(alpha = 0.07f), RoundedCornerShape(18.dp))
            .background(Color.Black.copy(alpha = 0.2f))
            .padding(vertical = 42.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.75f))
        Spacer(Modifier.height(6.dp))
        Text(note, style = McType.sub, color = TextMuted)
    }
}
