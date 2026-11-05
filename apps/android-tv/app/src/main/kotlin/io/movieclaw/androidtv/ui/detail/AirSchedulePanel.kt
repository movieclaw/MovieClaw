@file:OptIn(ExperimentalFoundationApi::class)

package io.movieclaw.androidtv.ui.detail

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.components.layerFocus
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.core.model.generated.SeasonAirScheduleView
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/*
 * 播出日历（issue #547）的电视界面，交互按遥控器（同 Apple TV 的 TVAirSchedule.swift）：
 * - 入口是下半截选季下面的一条，一行写完，看一眼就知道下一集什么时候来；从分集横排往上就能落到它，按确认打开日程；
 * - 日程盖满整屏（同「全部分集」），打开时焦点落在今天 / 下一个更新日：上下一天一天走，往上一格是折叠的「已播出」
 *   （按确认展开）；往左是补缺集、订阅追更；返回键关面板、焦点回到入口。手机上行里的小按钮遥控器够不着，
 *   缺集那一行整行就是「补这一集」。
 */

/** 琥珀底上的深色字（大结局标签） */
private val OnWarning = Color(0xFF241A02)

/** 下半截选季下面的入口条（按确认打开日程） */
@Composable
internal fun AirScheduleStrip(episodes: List<EpisodeView>, schedule: SeasonAirScheduleView, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val summary = remember(episodes, schedule) { AirSummary(episodes, schedule) }
    var focused by remember { mutableStateOf(false) }
    val muted = if (focused) Color.Black.copy(alpha = 0.6f) else Color.White.copy(alpha = 0.6f)
    Surface(
        onClick = onClick,
        modifier = modifier.layerFocus().fillMaxWidth().height(AirStripHeight.pt).onFocusChanged { focused = it.isFocused },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(20.pt)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.White.copy(alpha = 0.1f),
            contentColor = Color.White,
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White,
            pressedContentColor = Color.Black,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f, pressedScale = 1f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Row(
            Modifier.fillMaxSize().padding(horizontal = 32.pt),
            horizontalArrangement = Arrangement.spacedBy(20.pt),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val next = summary.next
            if (next != null) {
                val today = next.today
                val tagColor = if (today) (if (focused) Color.White else Color.Black) else (if (focused) Color.Black else Color.White)
                val tagFill = if (today) (if (focused) Color.Black else Color.White) else (if (focused) Color.Black.copy(alpha = 0.1f) else Color.White.copy(alpha = 0.14f))
                Text(
                    summary.tag.orEmpty(),
                    style = McType.size(22, FontWeight.Bold),
                    color = tagColor,
                    modifier = Modifier.background(tagFill, RoundedCornerShape(8.pt)).padding(horizontal = 12.pt, vertical = 4.pt),
                )
                Text(summary.headline.orEmpty(), style = McType.size(30, FontWeight.SemiBold), maxLines = 1)
            }
            Text(summary.meta, style = McType.size(24), color = muted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            summary.side?.let { side ->
                Row(horizontalArrangement = Arrangement.spacedBy(14.pt), verticalAlignment = Alignment.CenterVertically) {
                    side.caption?.let { Text(it, style = McType.size(24), color = muted, maxLines = 1) }
                    Text(
                        side.value,
                        style = McType.size(if (side.large) 40 else 30, FontWeight.SemiBold),
                        color = if (focused) Color.Black else side.color,
                        maxLines = 1,
                    )
                }
            }
            Icon(McIcons.Forward, null, tint = muted, modifier = Modifier.size(36.pt))
        }
    }
}

/** 入口条高度与上下间距（页面据此给下半截的顶让位） */
internal const val AirStripHeight = 84
internal const val AirStripMargin = 8

/** 还没播的集的剧照位：今天播出描蓝边、写入库状态；之后的虚线框写播出日；没日期写待定档 */
@Composable
internal fun UnairedStill(episode: EpisodeView, schedule: SeasonAirScheduleView, today: Boolean, modifier: Modifier = Modifier) {
    val corner = McMetrics.CardCorner
    Box(modifier, contentAlignment = Alignment.Center) {
        if (today) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color(0xFF11151D), RoundedCornerShape(corner))
                    .border(3.pt, Color(0xFF3B82F6).copy(alpha = 0.75f), RoundedCornerShape(corner)),
            )
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.pt)) {
                Text("今天播出", style = McType.size(30, FontWeight.Bold), color = McColors.Text)
                AirSchedule.arrival(listOf(episode), schedule)?.let { (text, color) ->
                    Text(text, style = McType.size(24), color = color, maxLines = 1)
                }
            }
        } else {
            Canvas(Modifier.fillMaxSize()) {
                val radius = CornerRadius(corner.toPx())
                drawRoundRect(Color(0xFF0E0F13), cornerRadius = radius)
                val width = 2.pt.toPx()
                drawRoundRect(
                    Color.White.copy(alpha = 0.25f),
                    topLeft = Offset(width / 2, width / 2),
                    size = Size(size.width - width, size.height - width),
                    cornerRadius = radius,
                    style = Stroke(width, pathEffect = PathEffect.dashPathEffect(floatArrayOf(8.pt.toPx(), 6.pt.toPx()))),
                )
            }
            val air = AirDate.parse(episode.airDate)
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.pt)) {
                if (air != null) {
                    Text("${AirSchedule.shortDate(air)} ${AirSchedule.weekday(air)}", style = McType.size(30, FontWeight.SemiBold), color = McColors.Text.copy(alpha = 0.85f))
                    Text(AirSchedule.relative(air, schedule), style = McType.size(24), color = McColors.TextMuted)
                } else {
                    Text("待定档", style = McType.size(30, FontWeight.SemiBold), color = McColors.Text.copy(alpha = 0.85f))
                }
            }
        }
    }
}

/**
 * 整屏日程：左栏还剩几集、完结日、补集与订阅，右栏按天的时间线。焦点关在面板里（同「全部分集」）。
 * [changed] 是补了缺集、订阅成功后页面重读这一季（日历跟着更新）
 */
@Composable
internal fun AirSchedulePanel(
    title: String,
    seasonLabel: String,
    episodes: List<EpisodeView>,
    schedule: SeasonAirScheduleView,
    actions: AirScheduleActions,
    canSubscribe: Boolean,
    /** 这部剧在 TMDB 的 id：没有的（本地识别不出来的）不能订阅 */
    tmdbId: Long?,
    /** 管理员订阅时入哪个库（这部剧所在的库）；成员走服务端路由 */
    libraryId: Long?,
    changed: suspend () -> Unit,
    onClose: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val days = remember(episodes, schedule) { AirSchedule.days(episodes, schedule) }
    val past = days.filter { it.past }
    val coming = days.filterNot { it.past }
    val canFind = AirSchedule.canFind(schedule, canSubscribe)
    val canOfferSubscribe = schedule.subscriptionId == null && canSubscribe && (tmdbId ?: 0) > 0
    var pastOpen by remember { mutableStateOf(false) }
    val requesters = remember { HashMap<String, FocusRequester>() }
    fun req(key: String) = requesters.getOrPut(key) { FocusRequester() }
    // 从左栏往右回来落在上次停的那一行，一开始是今天 / 下一个更新日
    val entryKey = coming.firstOrNull()?.let { "day:${it.date.epochDay}" } ?: "past"
    var rowKey by remember { mutableStateOf(entryKey) }
    fun find() {
        scope.launch { if (actions.findMissing(schedule)) changed() }
    }

    BackHandler {
        // 确认订阅时返回键先退回「订阅追更」，再按一下才关面板
        if (actions.stage is AirSubscribeStage.Confirming) {
            actions.cancelSubscribe()
            req("subscribe").tryFocus()
        } else {
            onClose()
        }
    }
    LaunchedEffect(Unit) {
        repeat(5) {
            delay(16)
            if (req(entryKey).tryFocus()) return@LaunchedEffect
        }
    }
    // 订阅成功，左栏的按钮没了：焦点回到时间线
    LaunchedEffect(schedule.subscriptionId) {
        if (schedule.subscriptionId != null) req(rowKey).tryFocus()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFF0B0D12))
            .testTag("air-schedule-sheet")
            .focusProperties { onExit = { cancelFocusChange() } }
            .focusGroup(),
    ) {
        Row(Modifier.padding(start = McMetrics.Edge, top = 56.pt), verticalAlignment = Alignment.Bottom) {
            Text("播出日历", style = McType.size(44, FontWeight.Bold))
            Text(
                listOfNotNull(title, seasonLabel, AirSchedule.cadence(schedule.weekdays)).joinToString(" · "),
                style = McType.size(26),
                color = McColors.TextMuted,
                maxLines = 1,
                modifier = Modifier.padding(start = 24.pt, bottom = 6.pt),
            )
        }
        Row(
            Modifier.fillMaxSize().padding(start = McMetrics.Edge, end = McMetrics.Edge, top = 150.pt, bottom = 44.pt),
            horizontalArrangement = Arrangement.spacedBy(50.pt),
        ) {
            AirSide(
                episodes = episodes,
                schedule = schedule,
                actions = actions,
                canFind = canFind,
                canOfferSubscribe = canOfferSubscribe,
                req = ::req,
                onFind = ::find,
                onSubscribe = {
                    scope.launch {
                        when (actions.stage) {
                            AirSubscribeStage.Idle -> actions.beginSubscribe(tmdbId ?: 0)
                            is AirSubscribeStage.Confirming -> if (actions.confirmSubscribe(libraryId)) changed()
                            else -> Unit
                        }
                    }
                },
                onCancelSubscribe = {
                    actions.cancelSubscribe()
                    req("subscribe").tryFocus()
                },
                modifier = Modifier.width(500.pt).fillMaxHeight(),
            )
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalBringIntoViewSpec provides remember(density) { MarginBringIntoViewSpec(60 * density * 0.5f) }) {
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .testTag("air-schedule-list")
                        .focusProperties {
                            onEnter = { if (requestedFocusDirection == FocusDirection.Right) req(rowKey).tryFocus() }
                            // 上下到头不出去，往右没有东西了（程序给焦点的 Enter 要放行，否则左右进出时的转交会被拦下）
                            onExit = {
                                val direction = requestedFocusDirection
                                if (direction == FocusDirection.Up || direction == FocusDirection.Down || direction == FocusDirection.Right) cancelFocusChange()
                            }
                        }
                        .focusGroup(),
                    // 四周留余地：获得焦点放大不被裁
                    contentPadding = PaddingValues(14.pt),
                    verticalArrangement = Arrangement.spacedBy(6.pt),
                ) {
                    if (past.isNotEmpty()) {
                        item(key = "past") {
                            AirPastRow(
                                summary = remember(past, schedule) { AirPastSummary(past, schedule) },
                                open = pastOpen,
                                onClick = { pastOpen = !pastOpen },
                                modifier = Modifier
                                    .focusRequester(req("past"))
                                    .testTag("air-schedule-past")
                                    .onFocusChanged { if (it.isFocused) rowKey = "past" }
                                    .padding(bottom = 8.pt),
                            )
                        }
                    }
                    val rowModifier = { key: String, tag: String ->
                        Modifier
                            .focusRequester(req(key))
                            .testTag(tag)
                            .onFocusChanged { if (it.isFocused) rowKey = key }
                    }
                    if (pastOpen) airRows(AirSchedule.rows(past, schedule, grouped = false), schedule, canFind, rowModifier, ::find)
                    airRows(AirSchedule.rows(coming, schedule, grouped = true), schedule, canFind, rowModifier, ::find)
                }
            }
        }
    }
}

private fun LazyListScope.airRows(
    rows: List<AirRow>,
    schedule: SeasonAirScheduleView,
    canFind: Boolean,
    rowModifier: (String, String) -> Modifier,
    onFind: () -> Unit,
) {
    items(rows, key = { it.key }) { row ->
        when (row) {
            is AirRow.Group -> Text(
                AirSchedule.groupTitle(row.group),
                style = McType.size(26, FontWeight.SemiBold),
                color = McColors.TextMuted,
                modifier = Modifier.padding(start = 26.pt, top = 18.pt, bottom = 4.pt),
            )
            is AirRow.Gap -> Row(
                Modifier.fillMaxWidth().padding(horizontal = 26.pt, vertical = 4.pt),
                horizontalArrangement = Arrangement.spacedBy(18.pt),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                DashedLine(Modifier.weight(1f))
                Text(row.text, style = McType.size(22), color = McColors.TextMuted)
                DashedLine(Modifier.weight(1f))
            }
            is AirRow.Day -> AirDayRow(
                day = row.day,
                schedule = schedule,
                canFind = canFind,
                // 缺集那一行整行就是「补这一集」；别的行只读（能落焦点才滚得动）
                onClick = { if (canFind && AirSchedule.missing(row.day, schedule).isNotEmpty()) onFind() },
                modifier = rowModifier("day:${row.day.date.epochDay}", "air-day-${row.day.date.iso}"),
            )
        }
    }
}

/** 左栏：还剩几集、完结日、补集与订阅、脚注 */
@Composable
private fun AirSide(
    episodes: List<EpisodeView>,
    schedule: SeasonAirScheduleView,
    actions: AirScheduleActions,
    canFind: Boolean,
    canOfferSubscribe: Boolean,
    req: (String) -> FocusRequester,
    onFind: () -> Unit,
    onSubscribe: () -> Unit,
    onCancelSubscribe: () -> Unit,
    modifier: Modifier,
) {
    val counts = AirSchedule.counts(episodes, schedule)
    val finale = AirSchedule.finale(schedule)
    Column(
        modifier
            .focusProperties {
                // 上下到头不出去，往左没有东西了；往右回时间线（理由同时间线的 onExit）
                onExit = {
                    val direction = requestedFocusDirection
                    if (direction == FocusDirection.Up || direction == FocusDirection.Down || direction == FocusDirection.Left) cancelFocusChange()
                }
            }
            .focusGroup(),
    ) {
        if (counts.upcoming > 0) {
            Text("还剩 ${counts.upcoming} 集", style = McType.size(76, FontWeight.Bold), maxLines = 1)
            finale?.let { Text(it, style = McType.size(30), color = McColors.TextMuted, modifier = Modifier.padding(top = 10.pt)) }
        } else if (finale != null) {
            Text(finale, style = McType.size(76, FontWeight.Bold), maxLines = 1)
        }
        Column(Modifier.padding(top = 44.pt), verticalArrangement = Arrangement.spacedBy(24.pt)) {
            if (canFind) {
                PillButton(
                    onClick = onFind,
                    text = AirSchedule.findTitle(schedule),
                    modifier = Modifier.focusRequester(req("find")).testTag("air-schedule-find"),
                )
            }
            if (canOfferSubscribe) AirSubscribe(actions, req, onSubscribe, onCancelSubscribe)
            actions.message?.let { message ->
                Text(
                    message.text,
                    style = McType.size(24),
                    color = if (message.isError) McColors.Warning else McColors.Success,
                    modifier = Modifier.testTag("air-schedule-message"),
                )
            }
        }
        Spacer(Modifier.weight(1f))
        Column(verticalArrangement = Arrangement.spacedBy(10.pt)) {
            schedule.region?.let { Text("播出日期为${AirSchedule.regionName(it)}当地日期", style = McType.size(22), color = McColors.TextMuted) }
            if (schedule.subscriptionId != null) {
                Text("播出日期来自 TMDB · 入库时间是订阅按站点发布规律推算的", style = McType.size(22), color = McColors.TextMuted)
            }
        }
    }
}

/**
 * 「订阅追更」：按下读预检 → 列出默认值（追踪范围、品质）→ 同一颗按钮变「确认订阅」→ 建好。
 * 按钮一直是同一颗，焦点不会因为换状态掉走。要改选项到手机或网页
 */
@Composable
private fun AirSubscribe(
    actions: AirScheduleActions,
    req: (String) -> FocusRequester,
    onSubscribe: () -> Unit,
    onCancel: () -> Unit,
) {
    val stage = actions.stage
    val draft = (stage as? AirSubscribeStage.Confirming)?.draft ?: (stage as? AirSubscribeStage.Submitting)?.draft
    Column(verticalArrangement = Arrangement.spacedBy(18.pt)) {
        if (draft != null) {
            Column(Modifier.testTag("air-schedule-subscribe-draft"), verticalArrangement = Arrangement.spacedBy(6.pt)) {
                Text("追踪范围", style = McType.size(22), color = McColors.TextMuted)
                Text(draft.scope, style = McType.size(30, FontWeight.SemiBold))
                Text(draft.scopeNote, style = McType.size(24), color = McColors.TextMuted)
                draft.quality.forEach { Text(it, style = McType.size(24), color = McColors.TextMuted) }
            }
        }
        PillButton(
            onClick = onSubscribe,
            text = when (stage) {
                AirSubscribeStage.Idle -> "订阅追更"
                AirSubscribeStage.Preparing -> "正在获取条目信息…"
                else -> "确认订阅"
            },
            modifier = Modifier.focusRequester(req("subscribe")).testTag("air-schedule-subscribe"),
        )
        if (draft != null) {
            PillButton(onClick = onCancel, text = "取消", modifier = Modifier.focusRequester(req("cancel")).testTag("air-schedule-subscribe-cancel"))
        } else if (stage == AirSubscribeStage.Idle) {
            Text("之后每一集播出后都会自动下载入库", style = McType.size(24), color = McColors.TextMuted)
        }
    }
}

/** 已播出折叠成的一行：淡底；获得焦点白底黑字 */
@Composable
private fun AirPastRow(summary: AirPastSummary, open: Boolean, onClick: () -> Unit, modifier: Modifier) {
    var focused by remember { mutableStateOf(false) }
    val muted = if (focused) Color.Black.copy(alpha = 0.6f) else Color.White.copy(alpha = 0.6f)
    val accent = if (summary.missing.isEmpty()) McColors.Success else McColors.Warning
    Surface(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().height(92.pt).onFocusChanged { focused = it.isFocused },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(18.pt)),
        colors = rowColors(Color.White.copy(alpha = 0.08f)),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f, pressedScale = 1f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Row(
            Modifier.fillMaxSize().padding(horizontal = 26.pt),
            horizontalArrangement = Arrangement.spacedBy(20.pt),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(44.pt).background(accent.copy(alpha = if (focused) 0.3f else 0.18f), CircleShape), contentAlignment = Alignment.Center) {
                if (summary.missing.isEmpty()) {
                    Icon(McIcons.Check, null, tint = if (focused) Color.Black else accent, modifier = Modifier.size(26.pt))
                } else {
                    Text("!", style = McType.size(26, FontWeight.Bold), color = if (focused) Color.Black else accent)
                }
            }
            Column(Modifier.weight(1f)) {
                Text(summary.range, style = McType.size(30, FontWeight.SemiBold), maxLines = 1)
                Text(summary.aired, style = McType.size(24), color = muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            val missingText = AirSchedule.missingText(summary.missing)
            when {
                missingText != null -> Text(missingText, style = McType.size(26), color = if (focused) Color.Black else McColors.Warning)
                summary.allOwned -> Text("已入库", style = McType.size(26), color = if (focused) Color.Black else McColors.Success)
                else -> Text("已入库 ${summary.owned}", style = McType.size(26), color = muted)
            }
            Icon(McIcons.Forward, null, tint = muted, modifier = Modifier.size(36.pt).rotate(if (open) 90f else 0f))
        }
    }
}

/** 日程一行：星期、日期、圆点、集号（大结局标签）、缺集、右边状态。今天的行垫蓝底；获得焦点白底黑字 */
@Composable
private fun AirDayRow(day: AirDay, schedule: SeasonAirScheduleView, canFind: Boolean, onClick: () -> Unit, modifier: Modifier) {
    var focused by remember { mutableStateOf(false) }
    val muted = if (focused) Color.Black.copy(alpha = 0.6f) else Color.White.copy(alpha = 0.6f)
    val dayMissing = AirSchedule.missing(day, schedule)
    Surface(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().height(72.pt).onFocusChanged { focused = it.isFocused },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(16.pt)),
        colors = rowColors(if (day.today) McColors.Info.copy(alpha = 0.16f) else Color.Transparent),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f, pressedScale = 1f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Row(
            Modifier.fillMaxSize().padding(horizontal = 26.pt),
            horizontalArrangement = Arrangement.spacedBy(20.pt),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                if (day.today) "今天" else AirSchedule.weekday(day.date),
                style = McType.size(24, if (day.today) FontWeight.Bold else FontWeight.Normal),
                color = if (day.today && !focused) McColors.Info else muted,
                maxLines = 1,
                modifier = Modifier.width(76.pt),
            )
            // 定宽：「11月2日」与「10月28日」两行的集号要对齐
            Text(AirSchedule.shortDate(day.date), style = McType.size(28, FontWeight.SemiBold), maxLines = 1, modifier = Modifier.width(140.pt))
            AirDotMark(AirSchedule.dot(day, schedule), focused)
            Text(AirSchedule.rangeLabel(day.episodes), style = McType.size(30, FontWeight.SemiBold), maxLines = 1)
            if (day.finale) {
                Text(
                    "大结局",
                    style = McType.size(20, FontWeight.Bold),
                    color = OnWarning,
                    modifier = Modifier.background(McColors.Warning, RoundedCornerShape(8.pt)).padding(horizontal = 10.pt, vertical = 2.pt),
                )
            }
            if (day.past) {
                AirSchedule.missingText(dayMissing)?.let {
                    Text(it, style = McType.size(24), color = if (focused) Color.Black else McColors.Warning, maxLines = 1)
                }
            }
            Spacer(Modifier.weight(1f))
            when (val status = AirSchedule.status(day, schedule)) {
                AirDayStatus.Owned -> Row(horizontalArrangement = Arrangement.spacedBy(6.pt), verticalAlignment = Alignment.CenterVertically) {
                    Icon(McIcons.Check, null, tint = if (focused) Color.Black else McColors.Success, modifier = Modifier.size(26.pt))
                    Text("已入库", style = McType.size(24), color = if (focused) Color.Black else McColors.Success)
                }
                AirDayStatus.Absent -> Text("库里没有", style = McType.size(24), color = muted)
                AirDayStatus.Missing -> if (canFind) {
                    Text("补这一集", style = McType.size(24, FontWeight.SemiBold), color = if (focused) Color.Black else McColors.Warning)
                }
                is AirDayStatus.Arrival -> Text(status.text, style = McType.size(24, FontWeight.SemiBold), color = if (focused) Color.Black else status.color, maxLines = 1)
                is AirDayStatus.Relative -> Text(status.text, style = McType.size(24), color = muted)
                AirDayStatus.None -> Unit
            }
        }
    }
}

@Composable
private fun rowColors(container: Color) = ClickableSurfaceDefaults.colors(
    containerColor = container,
    contentColor = Color.White,
    focusedContainerColor = Color.White,
    focusedContentColor = Color.Black,
    pressedContainerColor = Color.White,
    pressedContentColor = Color.Black,
)

/** 时间线上的点（比手机大一倍，三米外也看得清） */
@Composable
private fun AirDotMark(kind: AirDot, focused: Boolean) {
    val base = Modifier.size(20.pt)
    Box(
        when (kind) {
            AirDot.Today -> base.background(McColors.Info, CircleShape)
            AirDot.Finale -> base.border(4.pt, McColors.Warning, CircleShape)
            AirDot.Missing -> base.background(McColors.Warning, CircleShape)
            AirDot.Owned -> base.background(McColors.Success, CircleShape)
            AirDot.Upcoming -> base.border(3.pt, (if (focused) Color.Black else Color.White).copy(alpha = 0.5f), CircleShape)
        },
    )
}

@Composable
private fun DashedLine(modifier: Modifier) {
    Canvas(modifier.height(2.pt)) {
        drawLine(
            color = Color.White.copy(alpha = 0.2f),
            start = Offset(0f, size.height / 2),
            end = Offset(size.width, size.height / 2),
            strokeWidth = size.height,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.pt.toPx(), 6.pt.toPx())),
        )
    }
}
