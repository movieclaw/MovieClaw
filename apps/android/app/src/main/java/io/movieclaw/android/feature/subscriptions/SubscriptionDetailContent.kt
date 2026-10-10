package io.movieclaw.android.feature.subscriptions

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.FillCard
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Ok
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warn
import io.movieclaw.android.core.model.SubActivityView
import io.movieclaw.android.core.model.SubscriptionDownloadView
import io.movieclaw.android.core.model.SubscriptionView
import io.movieclaw.android.core.model.WantedView

/*
 * 订阅详情的版面（数据与动作仍由 SubscriptionDetailScreen / ViewModel 提供）。
 * 视觉语言对齐影片详情与订阅首页：通栏剧照 + 渐隐、大标题、状态胶囊、圆角卡片分组；
 * 以前是一整页散排的小字（标签/值、图例、排查记录全是同一级灰字），看不出主次。
 */

private val Upgrading = Color(0xFF2DD4BF)
private val Downloading = Color(0xFF7FB0FF)
private val CardShape = RoundedCornerShape(20.dp)

/** 一部订阅的四段进度（已入库 / 洗版中 / 下载中 / 缺失），图例与进度条同源 */
internal data class SubProgressParts(val imported: Int, val upgrading: Int, val downloading: Int, val missing: Int, val total: Int)

internal fun progressParts(sub: SubscriptionView): SubProgressParts {
    val p = sub.progress
    val dl = (p.grabbed - p.downloaded).coerceAtLeast(0)
    val missing = (p.total - p.imported - p.upgrading - dl).coerceAtLeast(0)
    return SubProgressParts(p.imported, p.upgrading, dl, missing, p.total)
}

internal fun statusLabel(s: SubscriptionView): String {
    val base = when (s.status) {
        "paused" -> "已暂停"
        "completed" -> if (s.media.kind == "tv") "已收齐" else "已入库"
        else -> "追踪中"
    }
    return if (s.progress.upgrading > 0) "$base · 洗版中 ${s.progress.upgrading}" else base
}

internal fun statusColor(s: SubscriptionView): Color = when {
    s.status == "paused" -> TextMuted
    s.status == "completed" -> Ok
    s.progress.upgrading > 0 -> Upgrading
    s.progress.grabbed > 0 -> Downloading
    else -> Warn
}

/** 收录范围：「第 1、2 季」/「仅追新集」/「正片」（电影） */
internal fun scopeLabel(s: SubscriptionView): String = when {
    s.media.kind == "movie" -> "正片"
    s.selectedSeasons.isEmpty() -> if (s.followFuture) "仅追新集" else "未选季"
    else -> "第 " + s.selectedSeasons.sorted().joinToString("、") + " 季"
}

/** 服务端 ISO 时间 → 「10-06 15:50」（同一年不写年份） */
internal fun shortTime(iso: String?): String? {
    if (iso.isNullOrBlank() || iso.length < 16) return null
    return iso.substring(5, 16).replace('T', ' ')
}

@Composable
internal fun SubscriptionDetailContent(
    sub: SubscriptionView,
    wanted: List<WantedView>,
    activities: List<SubActivityView>,
    downloads: Map<String, SubscriptionDownloadView>,
    origin: String?,
    busy: Boolean,
    showSearchNow: Boolean,
    showManual: Boolean,
    showMore: Boolean,
    onBack: () -> Unit,
    onSearchNow: () -> Unit,
    onManual: () -> Unit,
    onMore: () -> Unit,
) {
    val scroll = rememberScrollState()
    Box(Modifier.fillMaxSize().background(Bg)) {
        Column(Modifier.fillMaxSize().verticalScroll(scroll).padding(bottom = 40.dp)) {
            SubHero(sub, origin)
            Column(Modifier.padding(horizontal = McMetrics.pagePadding)) {
                if (showSearchNow || showManual || showMore) {
                    Spacer(Modifier.height(18.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (showSearchNow) {
                            Pill("立即搜索", Icons.Rounded.Search, primary = true, modifier = Modifier.weight(1f), onClick = onSearchNow)
                        }
                        if (showManual) {
                            Pill("手动选种", null, modifier = Modifier.weight(1f), onClick = onManual)
                        }
                        if (showMore) {
                            // 只有「更多」时也给整宽（成员只剩取消关注时，一颗孤零零的圆钮不好找）
                            if (showSearchNow || showManual) {
                                RoundGlassButton(Icons.Rounded.MoreHoriz, "更多", onMore)
                            } else {
                                Pill("管理订阅", Icons.Rounded.MoreHoriz, modifier = Modifier.weight(1f), onClick = onMore)
                            }
                        }
                    }
                }
                Spacer(Modifier.height(18.dp))
                ProgressCard(sub, activities)
                Spacer(Modifier.height(12.dp))
                FactsCard(sub)
                if (wanted.isNotEmpty() && sub.media.kind == "tv") {
                    SectionTitle("追踪明细")
                    wanted.groupBy { it.seasonNumber }.toSortedMap().forEach { (season, items) ->
                        SeasonCard(season, items, downloads, upgrading = sub.progress.upgrading)
                        Spacer(Modifier.height(10.dp))
                    }
                } else if (wanted.isNotEmpty()) {
                    // 电影只有一个单元：在途时把实时进度放进一张卡里
                    val live = wanted.mapNotNull { u -> u.infoHash?.let { downloads[it] }?.let { u to it } }
                    if (live.isNotEmpty()) {
                        SectionTitle("下载进度")
                        Card { live.forEach { (u, d) -> DownloadRow(u, d) } }
                    }
                }
                if (activities.isNotEmpty()) {
                    SectionTitle("排查记录")
                    ActivityCard(activities)
                }
            }
        }
        // 滚动后顶部起雾：内容从状态栏和返回键下面穿过时不糊在一起（随滚动淡入）。
        // 背景排在 statusBarsPadding 之前，状态栏那一截也一起盖住
        Box(
            Modifier.fillMaxWidth()
                .graphicsLayer { alpha = (scroll.value / 240f).coerceIn(0f, 1f) }
                .background(Brush.verticalGradient(0f to Bg, 0.6f to Bg.copy(alpha = 0.9f), 1f to Color.Transparent))
                .statusBarsPadding().height(72.dp),
        )
        // 悬浮返回键（与影片详情同位置）；忙碌时右上角转圈
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            McNavButton(icon = Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回", onClick = onBack)
            Spacer(Modifier.weight(1f))
            if (busy) CircularProgressIndicator(color = TextMuted, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
        }
    }
}

/** 通栏剧照 + 渐隐到底色；左下角海报 + 标题 + 一行要点 + 状态胶囊 */
@Composable
private fun SubHero(sub: SubscriptionView, origin: String?) {
    Box(Modifier.fillMaxWidth().height(340.dp)) {
        RemoteImage(
            url = sub.media.backdropUrl ?: sub.media.posterUrl,
            origin = origin,
            contentDescription = null,
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to Bg.copy(alpha = 0.35f),
                    0.45f to Bg.copy(alpha = 0.25f),
                    0.85f to Bg.copy(alpha = 0.92f),
                    1f to Bg,
                ),
            ),
        )
        Row(
            Modifier.align(Alignment.BottomStart).padding(horizontal = McMetrics.pagePadding),
            verticalAlignment = Alignment.Bottom,
        ) {
            RemoteImage(
                url = sub.media.posterUrl,
                origin = origin,
                contentDescription = sub.media.title,
                modifier = Modifier.width(92.dp).height(138.dp).clip(RoundedCornerShape(12.dp))
                    .border(1.dp, Color.White.copy(alpha = 0.10f), RoundedCornerShape(12.dp)),
            )
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    if (sub.media.kind == "tv") "剧集订阅" else "电影订阅",
                    style = McType.microSemibold, letterSpacing = 2.sp, color = Color(0xFF9FB0C9),
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    sub.media.title, fontSize = 26.sp, lineHeight = 31.sp, fontWeight = FontWeight.Bold,
                    color = TextPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    listOfNotNull(sub.media.year?.toString(), scopeLabel(sub).takeIf { sub.media.kind == "tv" })
                        .joinToString(" · "),
                    style = McType.sub, color = TextMuted,
                )
                Spacer(Modifier.height(10.dp))
                StatusChip(statusLabel(sub), statusColor(sub))
            }
        }
    }
}

@Composable
private fun StatusChip(text: String, color: Color) {
    Row(
        Modifier.clip(RoundedCornerShape(999.dp)).background(Color.Black.copy(alpha = 0.45f))
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(6.dp))
        Text(text, fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, color = color.takeIf { it != TextMuted } ?: TextPrimary)
    }
}

@Composable
private fun Card(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth().clip(CardShape).background(FillCard).border(1.dp, LineSoft, CardShape).padding(16.dp),
        content = content,
    )
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, fontSize = 19.sp, fontWeight = FontWeight.Bold, color = TextPrimary, modifier = Modifier.padding(top = 28.dp, bottom = 12.dp))
}

/** 收录进度卡：大号数字 + 四段进度条 + 只列非零的图例；最近一轮搜索作为脚注 */
@Composable
private fun ProgressCard(sub: SubscriptionView, activities: List<SubActivityView>) {
    val parts = progressParts(sub)
    Card {
        Row(verticalAlignment = Alignment.Bottom) {
            Text("${parts.imported}", fontSize = 34.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
            Text(
                if (sub.media.kind == "tv") " / ${parts.total} 集已入库" else if (parts.imported > 0) " 已入库" else " 未入库",
                style = McType.sub, color = TextMuted, modifier = Modifier.padding(bottom = 6.dp),
            )
            Spacer(Modifier.weight(1f))
            if (parts.total > 0) {
                Text("${parts.imported * 100 / parts.total}%", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = TextMuted, modifier = Modifier.padding(bottom = 6.dp))
            }
        }
        if (parts.total > 0) {
            Spacer(Modifier.height(10.dp))
            SegmentBar(
                listOf(Ok to parts.imported, Upgrading to parts.upgrading, Downloading to parts.downloading, Color.White.copy(alpha = 0.12f) to parts.missing),
                height = 8.dp,
            )
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                listOf(
                    Triple(Ok, "已入库", parts.imported),
                    Triple(Upgrading, "洗版中", parts.upgrading),
                    Triple(Downloading, "下载中", parts.downloading),
                    Triple(Color.White.copy(alpha = 0.35f), "缺失", parts.missing),
                ).filter { it.third > 0 }.forEach { (c, label, n) -> Legend(c, "$label $n") }
            }
        }
        // 最近一轮搜索（排查记录里最新一条搜索类活动）：默认两行，点开看全文
        activities.firstOrNull { it.type.contains("search", true) }?.let { act ->
            var expanded by remember(act.id) { mutableStateOf(false) }
            Spacer(Modifier.height(14.dp))
            Box(Modifier.fillMaxWidth().height(1.dp).background(LineSoft))
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("最近一次搜索", style = McType.microSemibold, color = TextFaint)
                shortTime(act.createdAt)?.let { Text("  ·  $it", style = McType.micro, color = TextFaint) }
            }
            Spacer(Modifier.height(4.dp))
            Text(
                act.message, fontSize = 13.sp, lineHeight = 19.sp, color = TextMuted,
                maxLines = if (expanded) Int.MAX_VALUE else 2, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clickable { expanded = !expanded },
            )
        }
    }
}

@Composable
private fun Legend(color: Color, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(5.dp))
        Text(text, fontSize = 12.5.sp, color = TextMuted)
    }
}

@Composable
private fun SegmentBar(segments: List<Pair<Color, Int>>, height: androidx.compose.ui.unit.Dp) {
    Row(Modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.08f))) {
        segments.forEach { (c, n) -> if (n > 0) Box(Modifier.weight(n.toFloat()).height(height).background(c)) }
    }
}

/** 订阅设置：分组卡（同「我的」页），左标签右值 */
@Composable
private fun FactsCard(sub: SubscriptionView) {
    val rows = buildList {
        add("收录范围" to scopeLabel(sub))
        if (sub.media.kind == "tv") add("自动续订" to if (sub.followFuture) "已开启" else "已关闭")
        sub.ruleSetId?.let { add("规则组" to "#$it") }
        shortTime(sub.createdAt)?.let { add("订阅于" to (sub.createdAt!!.take(4) + "-" + it)) }
    }
    Column(Modifier.fillMaxWidth().clip(CardShape).background(FillCard).border(1.dp, LineSoft, CardShape)) {
        rows.forEachIndexed { i, (k, v) ->
            if (i > 0) Box(Modifier.padding(start = 16.dp).fillMaxWidth().height(1.dp).background(LineSoft))
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(k, style = McType.sub, color = TextMuted)
                Spacer(Modifier.weight(1f))
                Text(v, style = McType.sub, fontWeight = FontWeight.Medium, color = TextPrimary)
            }
        }
    }
}

/** 一季一张卡：季名 + 入库数 + 细进度条 + 状态胶囊 + 在途集的实时进度 */
@Composable
private fun SeasonCard(season: Int, items: List<WantedView>, downloads: Map<String, SubscriptionDownloadView>, upgrading: Int) {
    val imported = items.count { it.importedAt != null }
    val downloading = items.count { it.grabbedAt != null && it.importedAt == null }
    val missing = items.count { it.status == "wanted" && it.grabbedAt == null }
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (season == 0) "特别篇" else "第 $season 季", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
            Spacer(Modifier.weight(1f))
            Text("$imported / ${items.size} 集", fontSize = 14.sp, color = TextMuted)
        }
        Spacer(Modifier.height(10.dp))
        SegmentBar(
            listOf(Ok to imported, Downloading to downloading, Color.White.copy(alpha = 0.12f) to (items.size - imported - downloading).coerceAtLeast(0)),
            height = 5.dp,
        )
        val chips = listOfNotNull(
            if (missing > 0) Triple("缺 $missing 集", Warn, Warn.copy(alpha = 0.12f)) else null,
            if (downloading > 0) Triple("$downloading 集下载中", Downloading, Downloading.copy(alpha = 0.12f)) else null,
            if (upgrading > 0) Triple("洗版 $upgrading", Upgrading, Upgrading.copy(alpha = 0.12f)) else null,
        )
        Spacer(Modifier.height(12.dp))
        if (chips.isEmpty()) {
            Text(if (imported == items.size) "本季已收齐" else "等待新集播出", fontSize = 12.5.sp, color = TextMuted)
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                chips.forEach { (t, fg, bg) ->
                    Text(
                        t, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = fg,
                        modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(bg).padding(horizontal = 9.dp, vertical = 4.dp),
                    )
                }
            }
        }
        // 在途投递的实时进度（5 秒轮询）：按单元锚定的种子 hash 对上
        val live = items.mapNotNull { u -> u.infoHash?.let { downloads[it] }?.let { u to it } }
        if (live.isNotEmpty()) {
            Spacer(Modifier.height(12.dp))
            live.forEach { (u, d) -> DownloadRow(u, d) }
        }
    }
}

/** 一集的下载：集号徽标 + 细进度条 + 速度/剩余 */
@Composable
private fun DownloadRow(unit: WantedView, d: SubscriptionDownloadView) {
    Row(Modifier.fillMaxWidth().padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(
            if (unit.episodeNumber > 0) "E${unit.episodeNumber}" else unitLabel(unit),
            fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary,
            modifier = Modifier.width(52.dp).clip(RoundedCornerShape(6.dp)).background(Color.White.copy(alpha = 0.08f))
                .padding(vertical = 3.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            val frac = (d.progress ?: 0.0).toFloat().coerceIn(0f, 1f)
            Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.08f))) {
                Box(Modifier.fillMaxWidth(frac).height(4.dp).background(if (d.state == "error") io.movieclaw.android.core.designsystem.Danger else Downloading))
            }
            Spacer(Modifier.height(4.dp))
            Text(downloadNote(d), fontSize = 11.5.sp, color = TextMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** 排查记录：时间线，默认最近 4 条，可展开 */
@Composable
private fun ActivityCard(activities: List<SubActivityView>) {
    var expanded by remember { mutableStateOf(false) }
    val shown = if (expanded) activities.take(50) else activities.take(4)
    Card {
        shown.forEachIndexed { i, act ->
            Row {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(14.dp)) {
                    Spacer(Modifier.height(6.dp))
                    Box(Modifier.size(7.dp).clip(CircleShape).background(if (i == 0) Color(0xFF9FB0C9) else Color.White.copy(alpha = 0.22f)))
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f).padding(bottom = if (i == shown.lastIndex) 0.dp else 14.dp)) {
                    shortTime(act.createdAt)?.let { Text(it, style = McType.micro, color = TextFaint) }
                    Text(act.message, fontSize = 13.sp, lineHeight = 19.sp, color = if (i == 0) TextPrimary else TextMuted)
                }
            }
        }
        if (activities.size > 4) {
            Spacer(Modifier.height(12.dp))
            Text(
                if (expanded) "收起" else "查看全部 ${minOf(activities.size, 50)} 条",
                fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF9FB0C9),
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { expanded = !expanded }.padding(vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun Pill(label: String, icon: ImageVector?, modifier: Modifier = Modifier, primary: Boolean = false, onClick: () -> Unit) {
    Row(
        modifier.height(46.dp).clip(RoundedCornerShape(999.dp))
            .background(
                if (primary) Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6)))
                else androidx.compose.ui.graphics.SolidColor(Color.White.copy(alpha = 0.10f)),
            )
            .border(1.dp, if (primary) Color.Transparent else LineSoft, RoundedCornerShape(999.dp))
            .clickable(onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val fg = if (primary) Color(0xFF141821) else TextPrimary
        icon?.let {
            Icon(it, contentDescription = null, tint = fg, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = fg)
    }
}

@Composable
private fun RoundGlassButton(icon: ImageVector, description: String, onClick: () -> Unit) {
    Box(
        Modifier.size(46.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.10f))
            .border(1.dp, LineSoft, CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = description, tint = TextPrimary, modifier = Modifier.size(22.dp))
    }
}
