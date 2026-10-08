package io.movieclaw.android.feature.activity

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.Ok
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.PlaybackStatsDayRow
import io.movieclaw.android.core.model.PlaybackStatsTitleRow
import io.movieclaw.android.core.model.PlaybackStatsTotals
import io.movieclaw.android.core.model.PlaybackWatchStatsView
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * 观看统计面板 —— 照网页 `components/watch-stats-panel.tsx` 逐块搬：
 * 四张指标卡（可点，选中项决定主图的量）→ TOP 3 最受欢迎 → 走势图（本期柱子 +
 * 上期虚线，宽度摆不下时按周折桶）→ 四块分解（成员 / 客户端 / 看得最多 / 播放方式）
 * → 星期 × 小时热力图。
 *
 * 服务端给的是「当前周期 + 上一周期」成对数据：没有参照系的数字只是数据，不是洞察，
 * 所以每张卡都带「较上一周期」的变化。
 */
@Composable
fun WatchStatsPanel(
    stats: PlaybackWatchStatsView,
    origin: String?,
    memberId: Int?,
    onDrillMember: (Int?) -> Unit,
    /** 范围外的作品「显示全部」出口；null = 不渲染那个按钮（当前只看得到自己范围时没有意义）*/
    onShowAll: (() -> Unit)? = null,
    onWidenDays: () -> Unit,
) {
    var metricKey by remember { mutableStateOf(MetricKey.WATCHED_MS) }
    val metric = metricKey.def

    // 两个周期都没有日志：整块用一个空状态承接，不摆一排 0
    if (stats.current.plays == 0 && !stats.previousAvailable) {
        EmptyNote(
            title = if (memberId != null) "最近 ${stats.days} 天这位成员没有播放" else "最近 ${stats.days} 天没有播放记录",
            note = "统计从播放日志来：从现在起每一场播放都会计入，看得越久这里越有得看。",
        )
        return
    }

    val totalWatched = stats.current.watchedMs
    val tierTotal = stats.byTier.sumOf { it.plays.toLong() }

    Column(Modifier.fillMaxWidth()) {
        // ── 指标卡（2×2；手机上不是四列并排）──
        Column(Modifier.padding(horizontal = McMetrics.pagePadding), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                MetricCard(MetricKey.WATCHED_MS, stats, metricKey, Modifier.weight(1f)) { metricKey = MetricKey.WATCHED_MS }
                MetricCard(MetricKey.PLAYS, stats, metricKey, Modifier.weight(1f)) { metricKey = MetricKey.PLAYS }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                MetricCard(MetricKey.COMPLETION, stats, metricKey, Modifier.weight(1f)) { metricKey = MetricKey.COMPLETION }
                MetricCard(MetricKey.ACTIVE_MEMBERS, stats, metricKey, Modifier.weight(1f)) { metricKey = MetricKey.ACTIVE_MEMBERS }
            }
        }

        if (stats.current.plays == 0) {
            // 本期一场都没有、上期有：指标卡与主图仍有对照价值，其余分解没有内容
            Spacer(Modifier.height(14.dp))
            TrendChart(stats, metric)
            Spacer(Modifier.height(14.dp))
            EmptyNote(
                title = "本周期没有播放",
                note = "上一周期有 ${stats.previous.plays} 场；本周期一场都没有，没有可以分解的数据。",
            )
            return@Column
        }

        // ── TOP 3 紧跟指标卡：先给结论（谁在被看），走势与分解在后 ──
        Spacer(Modifier.height(14.dp))
        FavoritePodium(
            favorites = stats.favorites,
            previous = stats.previousFavorites,
            memberId = memberId,
            hiddenCount = stats.hiddenTitleCount,
            origin = origin,
            onShowAll = onShowAll,
        )

        Spacer(Modifier.height(14.dp))
        TrendChart(stats, metric)

        // ── 四块分解 ──
        Spacer(Modifier.height(14.dp))
        Column(Modifier.padding(horizontal = McMetrics.pagePadding), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            BreakdownPanel(
                title = "按成员",
                note = if (memberId != null) "已钻取到一个成员，再点一次取消" else "点成员名钻取",
                total = totalWatched,
                unit = "个成员",
                rows = stats.byMember.map { row ->
                    BreakdownRow(
                        key = "m-${row.memberId}",
                        label = row.memberName,
                        value = row.watchedMs,
                        valueLabel = formatWatched(row.watchedMs),
                        secondary = "${row.plays} 场 · 看完 ${row.completed}",
                        selected = memberId == row.memberId,
                        onSelect = { onDrillMember(if (memberId == row.memberId) null else row.memberId) },
                    )
                },
            )
            BreakdownPanel(
                title = "按客户端",
                total = totalWatched,
                unit = "个客户端",
                rows = stats.byClient.map { row ->
                    BreakdownRow(
                        key = "c-${row.client}",
                        label = row.client,
                        value = row.watchedMs,
                        valueLabel = formatWatched(row.watchedMs),
                        secondary = "${row.plays} 场",
                    )
                },
            )
            BreakdownPanel(
                title = "看得最多",
                total = totalWatched,
                unit = "部",
                foldExpand = true,
                rows = stats.topTitles.mapIndexed { index, row ->
                    BreakdownRow(
                        key = "t-$index-${row.media.mediaItemId}",
                        label = statsTitle(row.media),
                        value = row.watchedMs,
                        valueLabel = formatWatched(row.watchedMs),
                        secondary = "${row.plays} 场",
                        poster = row.media.posterUrl,
                        origin = origin,
                    )
                },
                emptyText = if (stats.hiddenTitleCount > 0) null else "播放过的条目已被删除",
                footer = if (stats.hiddenTitleCount > 0) "hidden:${stats.hiddenTitleCount}" else null,
                onShowAll = onShowAll,
            )
            BreakdownPanel(
                title = "按播放方式",
                note = "仅网页播放；Jellyfin 客户端恒为直连",
                total = tierTotal,
                unit = "种",
                rows = stats.byTier.map { row ->
                    BreakdownRow(
                        key = "tier-${row.tier}",
                        label = row.label,
                        value = row.plays.toLong(),
                        valueLabel = "${row.plays} 场",
                    )
                },
                emptyText = "本周期没有网页播放；Jellyfin 客户端不经过转码，不在这里分解",
            )
        }

        // ── 星期 × 小时热力图 ──
        Spacer(Modifier.height(14.dp))
        HourHeatmap(stats.byHour)
    }
}

/* ------------------------------------------------------------ 指标卡 */

private enum class MetricKey(val def: MetricDef) {
    WATCHED_MS(MetricDef("观看时长", true, false, "小时", "分钟")),
    PLAYS(MetricDef("播放场次", false, false, "场")),
    COMPLETION(MetricDef("看完率", false, true, "%")),
    ACTIVE_MEMBERS(MetricDef("活跃成员", false, false, "人", bucketNote = "日均")),
}

/** 一张指标卡的算法（网页 `METRICS` 的每一条） */
private class MetricDef(
    val label: String,
    val isDuration: Boolean,
    /** 变化按「百分点」比而不是按比例（看完率） */
    val deltaInPoints: Boolean,
    val unit: String,
    val secondUnit: String? = null,
    val bucketNote: String? = null,
) {
    fun ofTotals(t: PlaybackStatsTotals): Float = when (this) {
        MetricKey.WATCHED_MS.def -> t.watchedMs.toFloat()
        MetricKey.PLAYS.def -> t.plays.toFloat()
        MetricKey.COMPLETION.def -> if (t.plays > 0) t.completed.toFloat() / t.plays else 0f
        else -> t.activeMembers.toFloat()
    }

    fun ofDays(rows: List<PlaybackStatsDayRow>): Float = when (this) {
        MetricKey.WATCHED_MS.def -> rows.sumOf { it.watchedMs }.toFloat()
        MetricKey.PLAYS.def -> rows.sumOf { it.plays }.toFloat()
        MetricKey.COMPLETION.def -> {
            val plays = rows.sumOf { it.plays }
            if (plays > 0) rows.sumOf { it.completed }.toFloat() / plays else 0f
        }
        // 按天是当天去重人数；折成一周没法从日数据里去重，退而取日均
        else -> if (rows.isEmpty()) 0f else rows.sumOf { it.members }.toFloat() / rows.size
    }

    fun format(value: Float): String = when (this) {
        MetricKey.WATCHED_MS.def -> formatWatched(value.toLong())
        MetricKey.PLAYS.def -> "${value.roundToInt()} 场"
        MetricKey.COMPLETION.def -> "${(value * 100).roundToInt()}%"
        else -> "${round1(value)} 人"
    }

    /** 指标卡上的大字与单位（「45.5 小时」占地太大，满一小时就改小数） */
    fun parts(value: Float): Pair<String, String> = when (this) {
        MetricKey.WATCHED_MS.def ->
            if (value >= 3_600_000) hours(value.toLong()) to "小时"
            else max(if (value > 0) 1 else 0, (value / 60_000).roundToInt()).toString() to "分钟"
        MetricKey.PLAYS.def -> value.roundToInt().toString() to "场"
        MetricKey.COMPLETION.def -> (value * 100).roundToInt().toString() to "%"
        else -> round1(value).toString() to "人"
    }

    fun axis(value: Float): String = when (this) {
        MetricKey.WATCHED_MS.def -> "${hours(value.toLong(), forceOneDecimal = value < 36_000_000)}h"
        MetricKey.PLAYS.def -> value.roundToInt().toString()
        MetricKey.COMPLETION.def -> "${(value * 100).roundToInt()}%"
        else -> value.roundToInt().toString()
    }
}

private fun round1(value: Float): Float = (value * 10).roundToInt() / 10f

/** 「2 小时 6 分钟」；不足一分钟按一分钟，零显示「—」 */
internal fun formatWatched(ms: Long): String {
    if (ms <= 0) return "—"
    val minutes = max(1, (ms / 60_000).toInt())
    val h = minutes / 60
    val m = minutes % 60
    return when {
        h == 0 -> "$m 分钟"
        m == 0 -> "$h 小时"
        else -> "$h 小时 $m 分钟"
    }
}

/** 网页 `hours()`：够大就不带小数 */
private fun hours(ms: Long, forceOneDecimal: Boolean = false): String {
    val value = ms / 3_600_000.0
    return if (!forceOneDecimal && ms >= 360_000_000L) "%.0f".format(value) else "%.1f".format(value)
}

@Composable
private fun MetricCard(
    key: MetricKey,
    stats: PlaybackWatchStatsView,
    selectedKey: MetricKey,
    modifier: Modifier = Modifier,
    onSelect: () -> Unit,
) {
    val metric = key.def
    val current = metric.ofTotals(stats.current)
    val previous = metric.ofTotals(stats.previous)
    val (value, unit) = metric.parts(current)
    val selected = key == selectedKey
    Column(
        modifier
            .clip(RoundedCornerShape(16.dp))
            .background(if (selected) Info.copy(alpha = 0.07f) else Color.White.copy(alpha = 0.03f))
            .border(
                1.dp,
                if (selected) Info.copy(alpha = 0.6f) else Color.White.copy(alpha = 0.08f),
                RoundedCornerShape(16.dp),
            )
            .clickable(onClick = onSelect)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Text(metric.label, fontSize = 11.5.sp, color = Color.White.copy(alpha = 0.55f), maxLines = 1)
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Color.White, maxLines = 1)
            Spacer(Modifier.width(4.dp))
            Text(unit, fontSize = 12.sp, color = Color.White.copy(alpha = 0.45f))
        }
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            DeltaChip(
                current = current,
                previous = previous,
                available = stats.previousAvailable,
                inPoints = metric.deltaInPoints,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                if (stats.previousAvailable) "上期 ${metric.format(previous)}" else "暂无上一周期数据",
                fontSize = 10.5.sp,
                color = Color.White.copy(alpha = 0.35f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** 较上一周期的变化：涨绿、跌红、持平灰；没有上期就不出 */
@Composable
private fun DeltaChip(current: Float, previous: Float, available: Boolean, inPoints: Boolean) {
    if (!available) return
    var text: String
    var direction: Int
    if (inPoints) {
        val points = ((current - previous) * 100).roundToInt()
        direction = points.compareTo(0)
        text = "${abs(points)} 个百分点"
    } else if (previous <= 0f) {
        if (current <= 0f) return
        direction = 1
        text = "新增"
    } else {
        val ratio = (current - previous) / previous
        direction = when {
            ratio > 0 -> 1
            ratio < 0 -> -1
            else -> 0
        }
        text = if (direction == 0) "持平" else "${(abs(ratio) * 100).roundToInt()}%"
    }
    val tone = when {
        direction > 0 -> Ok
        direction < 0 -> Danger
        else -> Color.White.copy(alpha = 0.55f)
    }
    val arrow = if (direction > 0) "▲" else if (direction < 0) "▼" else ""
    Row(
        Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(tone.copy(alpha = 0.15f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (arrow.isNotEmpty()) Text(arrow, fontSize = 8.sp, fontWeight = FontWeight.Bold, color = tone)
        if (arrow.isNotEmpty()) Spacer(Modifier.width(2.dp))
        Text(text, fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, color = tone, maxLines = 1)
    }
}

/* ------------------------------------------------------------ 走势图 */

private const val CHART_HEIGHT_DP = 200f
private const val PAD_LEFT = 46f
private const val PAD_RIGHT = 12f
private const val PAD_TOP = 14f
private const val PAD_BOTTOM = 26f

/** 一根柱子（含间隙）至少占这么宽，摆不下就按周折桶 */
private const val MIN_SLOT = 6f

@Composable
private fun TrendChart(stats: PlaybackWatchStatsView, metric: MetricDef) {
    val measurer = rememberTextMeasurer()
    val labelStyle = TextStyle(fontSize = 9.sp, color = Color.White.copy(alpha = 0.4f))
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    BoxWithConstraints(Modifier.padding(horizontal = McMetrics.pagePadding)) {
        // constraints 给的是像素，而下面的几何量全按 dp 算，先换算回来——混着用会让
        // 每根柱子按密度的倍数往外跑（第一版就栽在这：整张图只剩坐标轴）
        val width = constraints.maxWidth / density
        val innerWidth = max(0f, width - PAD_LEFT - PAD_RIGHT)
        val weekly = stats.byDay.isNotEmpty() && innerWidth / stats.byDay.size < MIN_SLOT
        val buckets = bucketize(stats.byDay, if (weekly) 7 else 1)
        val prevBuckets = bucketize(stats.previousByDay, if (weekly) 7 else 1)
        val current = buckets.map { metric.ofDays(it) }
        val previous = prevBuckets.map { metric.ofDays(it) }
        val showPrevious = stats.previousAvailable && previous.size == current.size
        val count = current.size
        val yMax = niceMax(max(current.maxOrNull() ?: 0f, if (showPrevious) previous.maxOrNull() ?: 0f else 0f))
        val innerHeight = CHART_HEIGHT_DP - PAD_TOP - PAD_BOTTOM
        val slot = if (count > 0) innerWidth / count else 0f
        val gap = min(6f, max(1f, slot * 0.3f))
        val barWidth = max(1f, slot - gap)
        val baseline = PAD_TOP + innerHeight
        val tickTarget = max(2, min(6, (innerWidth / 70).toInt()))
        val tickEvery = max(1, (count.toFloat() / tickTarget).roundToInt())

        Column {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(metric.label, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.55f))
                Spacer(Modifier.width(6.dp))
                Text(if (weekly) "按周" else "按天", fontSize = 10.5.sp, color = Color.White.copy(alpha = 0.35f))
            }
            Spacer(Modifier.height(4.dp))
            Canvas(
                Modifier
                    .fillMaxWidth()
                    .height(CHART_HEIGHT_DP.dp),
            ) {
                val pixelsPerDp = size.height / CHART_HEIGHT_DP
                fun x(i: Int) = PAD_LEFT * pixelsPerDp + slot * pixelsPerDp * i + slot * pixelsPerDp / 2
                fun y(v: Float) = (PAD_TOP + innerHeight - (if (yMax > 0) v / yMax * innerHeight else 0f)) * pixelsPerDp

                // 网格与 y 轴刻度
                for (i in 0..4) {
                    val v = yMax / 4 * i
                    val yy = y(v)
                    drawLine(
                        color = if (i == 0) Color.White.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.07f),
                        start = Offset(PAD_LEFT * pixelsPerDp, yy),
                        end = Offset(size.width - PAD_RIGHT * pixelsPerDp, yy),
                        strokeWidth = 1f,
                    )
                    val text = measurer.measure(metric.axis(v), labelStyle)
                    drawText(
                        textLayoutResult = text,
                        topLeft = Offset(
                            PAD_LEFT * pixelsPerDp - 8f - text.size.width,
                            yy - text.size.height / 2f,
                        ),
                    )
                }

                // 本期柱子（顶部圆角、底边贴基线）
                current.forEachIndexed { i, v ->
                    if (v <= 0f) return@forEachIndexed
                    val left = x(i) - barWidth * pixelsPerDp / 2
                    val top = y(v)
                    drawRoundRect(
                        color = Info.copy(alpha = 0.95f),
                        topLeft = Offset(left, top),
                        size = Size(barWidth * pixelsPerDp, baseline * pixelsPerDp - top),
                        cornerRadius = CornerRadius(3f * pixelsPerDp, 3f * pixelsPerDp),
                    )
                }

                // 上一周期：同一坐标系里的虚线
                if (showPrevious && previous.isNotEmpty()) {
                    val path = Path()
                    previous.forEachIndexed { i, v ->
                        if (i == 0) path.moveTo(x(i), y(v)) else path.lineTo(x(i), y(v))
                    }
                    drawPath(
                        path = path,
                        color = Color.White.copy(alpha = 0.32f),
                        style = Stroke(width = 1.5f * pixelsPerDp, pathEffect = PathEffect.dashPathEffect(floatArrayOf(4f, 4f))),
                    )
                }

                // x 轴日期刻度
                buckets.forEachIndexed { i, bucket ->
                    if (i % tickEvery != 0 && i != count - 1) return@forEachIndexed
                    val label = bucket.firstOrNull()?.let { dayLabel(it.date) } ?: ""
                    if (label.isEmpty()) return@forEachIndexed
                    val text = measurer.measure(label, labelStyle)
                    val left = when {
                        i == 0 -> PAD_LEFT * pixelsPerDp
                        i == count - 1 -> size.width - PAD_RIGHT * pixelsPerDp - text.size.width
                        else -> x(i) - text.size.width / 2f
                    }
                    drawText(
                        textLayoutResult = text,
                        topLeft = Offset(left, (CHART_HEIGHT_DP - 16f) * pixelsPerDp),
                    )
                }
            }
        }
    }
}

/** 从末尾往前每 size 天一桶，最新的桶一定是满的，首桶可能不满 */
private fun bucketize(rows: List<PlaybackStatsDayRow>, size: Int): List<List<PlaybackStatsDayRow>> {
    if (size <= 1) return rows.map { listOf(it) }
    val out = mutableListOf<List<PlaybackStatsDayRow>>()
    var end = rows.size
    while (end > 0) {
        out.add(0, rows.subList(max(0, end - size), end))
        end -= size
    }
    return out
}

/** "2026-09-26" → "9月26日" */
internal fun dayLabel(date: String): String {
    val parts = date.split("-")
    if (parts.size < 3) return date
    val month = parts[1].toIntOrNull() ?: return date
    val day = parts[2].toIntOrNull() ?: return date
    return "${month}月${day}日"
}

/** 坐标轴的整齐上限：1 / 2 / 5 × 10^n 里第一个不小于最大值的 */
private fun niceMax(max: Float): Float {
    if (max <= 0f) return 1f
    val exponent = kotlin.math.floor(log10(max.toDouble())).toInt()
    val base = 10.0.pow(exponent).toFloat()
    for (step in listOf(1, 2, 5, 10)) {
        if (max <= step * base) return step * base
    }
    return 10 * base
}

/* ------------------------------------------------------------ 分解面板 */

private data class BreakdownRow(
    val key: String,
    val label: String,
    /** 观看时长（毫秒）或场次，按面板而定 */
    val value: Long,
    val valueLabel: String,
    val secondary: String? = null,
    val poster: String? = null,
    val origin: String? = null,
    val muted: Boolean = false,
    val selected: Boolean = false,
    val onSelect: (() -> Unit)? = null,
)

/**
 * 分解面板：同一个模板（名称 · 值 · 占比条）。行数封顶——成员三五个、客户端两三个、
 * 作品榜十个、播放方式最多五档，不封顶四块面板高矮参差。默认五行，多出来的：
 * `foldExpand` 留一个「展开全部」，否则合成一行「其他 N 个」（占比仍合计 100%）。
 */
@Composable
private fun BreakdownPanel(
    title: String,
    total: Long,
    unit: String,
    rows: List<BreakdownRow>,
    note: String? = null,
    foldExpand: Boolean = false,
    emptyText: String? = "本周期没有数据",
    /** 「其他 N 部」之外还要说一句去向时用（如范围外折叠了几部作品） */
    footer: String? = null,
    onShowAll: (() -> Unit)? = null,
    limit: Int = 5,
) {
    var expanded by remember { mutableStateOf(false) }
    val visible = when {
        rows.size <= limit -> rows
        foldExpand && !expanded -> rows.take(limit)
        foldExpand -> rows
        else -> rows.take(limit) + BreakdownRow(
            key = "__other",
            label = "其他 ${rows.size - limit} $unit",
            value = rows.drop(limit).sumOf { it.value },
            valueLabel = formatWatched(rows.drop(limit).sumOf { it.value }),
            muted = true,
        )
    }
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(title, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.55f))
            note?.let {
                Spacer(Modifier.width(8.dp))
                Text(it, fontSize = 10.5.sp, color = Color.White.copy(alpha = 0.3f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Spacer(Modifier.height(6.dp))
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                .background(Color.White.copy(alpha = 0.02f)),
        ) {
            if (rows.isEmpty() && emptyText != null) {
                Text(emptyText, fontSize = 11.5.sp, color = Color.White.copy(alpha = 0.4f), modifier = Modifier.padding(14.dp))
            }
            visible.forEach { row ->
                BreakdownRowView(row, total)
            }
            if (foldExpand && rows.size > limit) {
                Text(
                    if (expanded) "收起" else "展开全部 ${rows.size} $unit",
                    fontSize = 11.5.sp,
                    fontWeight = FontWeight.Medium,
                    color = Info,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { expanded = !expanded }
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
            footer?.let { text ->
                if (text.startsWith("hidden:")) {
                    val count = text.removePrefix("hidden:").toIntOrNull() ?: 0
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("$count 部作品在你的浏览范围外", fontSize = 11.5.sp, color = Color.White.copy(alpha = 0.4f))
                        Spacer(Modifier.weight(1f))
                        onShowAll?.let {
                            Text("显示全部", fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = Info, modifier = Modifier.clickable(onClick = it))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun BreakdownRowView(row: BreakdownRow, total: Long) {
    val share = if (total > 0) ((row.value.toDouble() / total) * 100).roundToInt() else 0
    Row(
        Modifier
            .fillMaxWidth()
            .then(if (row.onSelect != null) Modifier.clickable(onClick = row.onSelect) else Modifier)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        row.poster?.let { poster ->
            Box(Modifier.width(24.dp).height(36.dp).clip(RoundedCornerShape(6.dp))) {
                RemoteImage(poster, row.origin, contentDescription = row.label, modifier = Modifier.fillMaxWidth())
            }
            Spacer(Modifier.width(10.dp))
        }
        Column(Modifier.weight(1f)) {
            // 名称吃掉剩余宽度、值靠右（网页里名称组是 flex-1、值是 shrink-0）：
            // 名称与附注先抢，抢不完再截断，右边的值不会被挤走
            Row(verticalAlignment = Alignment.Bottom) {
                Row(Modifier.weight(1f), verticalAlignment = Alignment.Bottom) {
                    Text(
                        row.label,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = if (row.muted) Color.White.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.85f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    row.secondary?.let {
                        Spacer(Modifier.width(8.dp))
                        Text(it, fontSize = 10.5.sp, color = Color.White.copy(alpha = 0.35f), maxLines = 1)
                    }
                }
                Spacer(Modifier.width(10.dp))
                Text(row.valueLabel, fontSize = 11.5.sp, color = Color.White.copy(alpha = 0.7f), maxLines = 1)
                Spacer(Modifier.width(6.dp))
                Text("$share%", fontSize = 11.5.sp, color = Color.White.copy(alpha = 0.35f))
            }
            Spacer(Modifier.height(6.dp))
            // 条的长度就是份额：与右边的百分比、与总量三者自洽
            Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = 0.06f))) {
                Box(
                    Modifier
                        .fillMaxWidth(max(1, share) / 100f)
                        .height(3.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(
                            when {
                                row.selected -> Ok
                                row.muted -> Color.White.copy(alpha = 0.22f)
                                else -> Info.copy(alpha = 0.9f)
                            },
                        ),
                )
            }
        }
    }
}

/* ------------------------------------------------------- TOP 3 最受欢迎 */

private const val TOP_BADGE = "TOP 3"

@Composable
private fun FavoritePodium(
    favorites: List<PlaybackStatsTitleRow>,
    previous: List<PlaybackStatsTitleRow>,
    memberId: Int?,
    hiddenCount: Int,
    origin: String?,
    onShowAll: (() -> Unit)? = null,
) {
    if (favorites.isEmpty()) {
        // 有播放却没有上榜作品：要么都在范围外，要么条目已被删除；说清去向，不留空白
        EmptyNote(
            title = if (hiddenCount > 0) "本期最受欢迎的作品都在你的浏览范围外" else "本期还没有可以上榜的作品",
            note = if (hiddenCount > 0) "$hiddenCount 部作品来自你设为不可见的库" else "播放过的条目已被删除，不再进榜",
        )
        return
    }
    val drilled = memberId != null
    val first = favorites.first()
    Column(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.02f)),
    ) {
        // 环境底：第一名海报放大糊在卡背上（网页的 blur-3xl + 深色渐变）
        Box {
            first.media.posterUrl?.let { poster ->
                Box(Modifier.matchParentSize()) {
                    RemoteImage(
                        poster,
                        origin,
                        contentDescription = null,
                        modifier = Modifier.matchParentSize().blur(48.dp),
                    )
                    Box(
                        Modifier
                            .matchParentSize()
                            .background(Color(0xF20B0D13)),
                    )
                }
            }
            Column(Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        TOP_BADGE,
                        fontSize = 9.5.sp,
                        fontWeight = FontWeight.Black,
                        color = Color(0xFF0B0D13),
                        modifier = Modifier
                            .clip(RoundedCornerShape(3.dp))
                            .background(Info)
                            .padding(horizontal = 6.dp, vertical = 3.dp),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        if (drilled) "本期看得最多" else "本期最受欢迎",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White.copy(alpha = 0.9f),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        if (drilled) "按观看时长" else "按看过的人数，并列看时长",
                        fontSize = 10.5.sp,
                        color = Color.White.copy(alpha = 0.35f),
                    )
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Bottom) {
                    TopEntry(first, 0, hero = true, previous = previous, origin = origin, modifier = Modifier.weight(1.5f))
                    favorites.drop(1).forEachIndexed { index, row ->
                        TopEntry(row, index + 1, hero = false, previous = previous, origin = origin, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

/** 一个名次：巨大的描边数字压在海报左后方，海报盖住数字的右侧（Netflix 的 TOP 10 式） */
@Composable
private fun TopEntry(
    row: PlaybackStatsTitleRow,
    rank: Int,
    hero: Boolean,
    previous: List<PlaybackStatsTitleRow>,
    origin: String?,
    modifier: Modifier = Modifier,
) {
    val change = rankChange(row, rank, previous)
    Column(modifier) {
        Box {
            Text(
                "${rank + 1}",
                fontSize = if (hero) 68.sp else 46.sp,
                fontWeight = FontWeight.Black,
                color = Color(0xFF0B0D13),
                modifier = Modifier.align(Alignment.BottomStart),
            )
            Box(
                Modifier
                    .padding(start = if (hero) 26.dp else 18.dp)
                    .width(if (hero) 84.dp else 64.dp)
                    .height(if (hero) 120.dp else 92.dp)
                    .clip(RoundedCornerShape(10.dp)),
            ) {
                RemoteImage(row.media.posterUrl, origin, contentDescription = row.media.title)
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            row.media.title,
            fontSize = if (hero) 13.5.sp else 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(2.dp))
        Text(
            listOfNotNull(
                if (row.media.kind == "tv") "剧集" else "电影",
                row.media.year?.toString(),
            ).joinToString(" · "),
            fontSize = 10.5.sp,
            color = TextFaint,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            "${row.members} 人看过 · ${row.plays} 场",
            fontSize = 10.5.sp,
            color = TextMuted,
            maxLines = 1,
        )
        change?.let { (text, tone) ->
            Spacer(Modifier.height(6.dp))
            Text(
                text,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                color = tone,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .background(tone.copy(alpha = 0.15f))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
    }
}

/** 与上一周期前三的对照：同名次「蝉联」，换了名次「上期第 n」，上期不在榜「新上榜」 */
private fun rankChange(row: PlaybackStatsTitleRow, rank: Int, previous: List<PlaybackStatsTitleRow>): Pair<String, Color>? {
    if (previous.isEmpty()) return null
    val was = previous.indexOfFirst { it.media.mediaItemId == row.media.mediaItemId }
    if (was == rank) return "蝉联" to Ok
    if (was == -1) return "新上榜" to Info
    return "${if (was > rank) "▲" else "▼"} 上期第 ${was + 1}" to if (was > rank) Ok else Color.White.copy(alpha = 0.55f)
}

/* ------------------------------------------------------------ 时段热力图 */

private val WEEKDAYS = listOf("一", "二", "三", "四", "五", "六", "日")

/** 星期 × 小时的观看时长，越深越多；没数据也把 7×24 的格子画出来 */
@Composable
private fun HourHeatmap(matrix: List<List<Long>>) {
    val total = matrix.sumOf { row -> row.sumOf { it } }
    val maxValue = max(1L, matrix.maxOfOrNull { row -> row.maxOrNull() ?: 0L } ?: 1L)
    Column(Modifier.padding(horizontal = McMetrics.pagePadding)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text("观看时段", fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.55f))
            Spacer(Modifier.width(8.dp))
            Text("星期 × 小时的观看时长，越深越多", fontSize = 10.5.sp, color = Color.White.copy(alpha = 0.3f))
        }
        Spacer(Modifier.height(6.dp))
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                .background(Color.White.copy(alpha = 0.02f))
                .padding(14.dp),
        ) {
            if (total == 0L) {
                Text(
                    "本周期还没有累计到观看时长；有人看过之后这里会显示星期 × 小时的分布",
                    fontSize = 11.5.sp,
                    color = Color.White.copy(alpha = 0.4f),
                )
                Spacer(Modifier.height(10.dp))
            }
            // 24 格的列头（每 6 小时标一个）
            Row(Modifier.fillMaxWidth().padding(start = 26.dp)) {
                (0 until 24).forEach { hour ->
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        Text(if (hour % 6 == 0) "$hour" else "", fontSize = 8.sp, color = Color.White.copy(alpha = 0.35f))
                    }
                }
            }
            Spacer(Modifier.height(3.dp))
            matrix.forEachIndexed { day, row ->
                Row(Modifier.fillMaxWidth().padding(vertical = 1.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(24.dp)) {
                        Text(WEEKDAYS.getOrElse(day) { "" }, fontSize = 8.sp, color = Color.White.copy(alpha = 0.4f))
                    }
                    (0 until 24).forEach { hour ->
                        val value = row.getOrElse(hour) { 0L }
                        val alpha = if (value > 0) (0.18f + (value.toFloat() / maxValue) * 0.82f).coerceAtMost(1f) else 0f
                        Box(
                            Modifier
                                .weight(1f)
                                .padding(horizontal = 1.dp)
                                .height(16.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(if (value > 0) Info.copy(alpha = alpha) else Color.White.copy(alpha = 0.04f)),
                        )
                    }
                }
            }
        }
    }
}

/* ------------------------------------------------------------------ 公共 */

/** 作品名（剧集带 S01E02，与播放流水里的写法一致；网页 `TitleText` 同款） */
internal fun statsTitle(media: io.movieclaw.android.core.model.MediaActivityTarget): String {
    if (media.title.isBlank()) return "未识别条目"
    return if (media.seasonNumber > 0 && media.episodeNumber > 0) {
        "%s S%02dE%02d".format(media.title, media.seasonNumber, media.episodeNumber)
    } else {
        media.title
    }
}
