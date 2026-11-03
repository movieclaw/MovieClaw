package io.movieclaw.android.feature.offline

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.HourglassEmpty
import androidx.compose.material.icons.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.PauseCircle
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.LibraryFileView
import io.movieclaw.android.core.offline.OfflineEntry
import io.movieclaw.android.core.offline.OfflineFormat
import io.movieclaw.android.core.offline.OfflineQueue
import io.movieclaw.android.core.offline.OfflineUnit
import io.movieclaw.android.core.offline.OfflineUnitStatus

// 下载入口与删除入口的共用部件（docs/design/offline-download.md §5、§8；iOS `OfflineDownloadViews` / `OfflineLocalFileRow`）。
// 删除一律二次确认，写明释放多少空间、「观看进度会保留」；离线时也能删（只动手机）。

/** 离线下载的单例（存储、下载器、可达性）：界面经它取，不进各页的 ViewModel */
@Composable
fun rememberOffline(): OfflineEntry {
    val context = LocalContext.current.applicationContext
    return remember { dagger.hilt.android.EntryPointAccessors.fromApplication(context, OfflineEntry::class.java) }
}

/** 「手机」/「平板」：iOS 文案里的「iPhone」 */
@Composable
fun deviceName(): String {
    val context = LocalContext.current
    return remember { OfflineFormat.deviceName(context) }
}

/** 下载进度环（同 App Store 的下载环）：知道总量画进度，不知道（准备中）转圈 */
@Composable
fun ProgressRing(fraction: Double?, color: Color, size: Dp = 18.dp) {
    if (fraction == null) {
        CircularProgressIndicator(color = color, strokeWidth = 2.dp, modifier = Modifier.size(size - 2.dp))
        return
    }
    Canvas(Modifier.size(size)) {
        val stroke = 2.5.dp.toPx()
        val inset = stroke / 2
        val arc = Size(this.size.width - stroke, this.size.height - stroke)
        drawArc(color.copy(alpha = 0.25f), 0f, 360f, false, topLeft = Offset(inset, inset), size = arc, style = Stroke(stroke))
        drawArc(
            color, -90f, 360f * fraction.toFloat().coerceIn(0.02f, 1f), false,
            topLeft = Offset(inset, inset), size = arc, style = Stroke(stroke, cap = StrokeCap.Round),
        )
    }
}

/** 状态图标：暂停 / 失败（排队转码是沙漏）/ 损坏；其余是进度环 */
@Composable
private fun UnitIcon(unit: OfflineUnit, tint: Color, size: Dp = 18.dp) {
    when {
        unit.state == OfflineUnit.State.paused -> Icon(Icons.Rounded.PauseCircle, null, tint = tint, modifier = Modifier.size(size))
        unit.state == OfflineUnit.State.failed ->
            Icon(if (unit.waitingForTranscode) Icons.Rounded.HourglassEmpty else Icons.Rounded.ErrorOutline, null, tint = tint, modifier = Modifier.size(size))
        unit.damaged -> Icon(Icons.Rounded.ErrorOutline, null, tint = tint, modifier = Modifier.size(size))
        else -> ProgressRing(
            if (unit.state == OfflineUnit.State.downloading || unit.state == OfflineUnit.State.queued) unit.progressFraction else null,
            tint, size,
        )
    }
}

/**
 * 电影详情页播放键上方的下载状态条（与「收藏」「标为已看」同一种玻璃胶囊，点它出操作菜单）：
 * 左边进度环、中间「下载中 47%」、右边实时速度；暂停 / 失败 / 损坏换图标与颜色
 */
@Composable
fun OfflineDownloadStatusBar(
    unit: OfflineUnit,
    speed: Double?,
    modifier: Modifier = Modifier,
    /** 下载队列里排在它前面的个数；只许 Wi-Fi 下、眼下是计费网络（§5.5） */
    ahead: Int = 0,
    waitingForWiFi: Boolean = false,
    onClick: () -> Unit,
) {
    val tint = if (unit.needsAttention) Warning else Info
    // 排队时这条够宽，写全「等待下载，前面还有 N 个」
    val status = if (unit.state == OfflineUnit.State.queued || (waitingForWiFi && unit.runnable)) {
        OfflineUnitStatus.text(unit, ahead, waitingForWiFi)
    } else {
        OfflineUnitStatus.short(unit)
    }
    val text = if (unit.state == OfflineUnit.State.failed && !unit.waitingForTranscode) "$status，点按重试" else status
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(Color.White.copy(alpha = 0.09f))
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp)
            .testTag("item-download"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        UnitIcon(unit, tint)
        Text(text, style = McType.subheadlineSemibold, color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (speed != null && speed > 0 && unit.state == OfflineUnit.State.downloading && !waitingForWiFi) {
            Text("${McFormat.bytes(speed.toLong())}/s", style = McType.sub, color = tint.copy(alpha = 0.75f))
        }
    }
}

/**
 * 详情页的下载控件（iOS `OfflineDownloadControl`）：只在下载没完成时出现（下载中 / 暂停 / 失败 / 文件损坏）；
 * 下完的副本在「文件」区里（本机那一行），开始下载在右上角「⋯」。点状态条出菜单：暂停 / 继续 / 重试 / 取消。
 */
@Composable
fun OfflineDownloadControl(
    mediaItemId: Long,
    season: Int,
    episode: Int,
    modifier: Modifier = Modifier,
    /** 下完却打不开（损坏）时「改下其他画质」：在线、有下载权限才给 */
    onChangeQuality: ((fileId: Long) -> Unit)? = null,
) {
    val offline = rememberOffline()
    val state by offline.store().state.collectAsStateWithLifecycle()
    val speeds by offline.store().speeds.collectAsStateWithLifecycle()
    val unit = offline.store().unit(mediaItemId, season, episode, state)?.takeIf { !it.playable } ?: return
    val queue by offline.store().queue.collectAsStateWithLifecycle()
    val waitingForWiFi by offline.downloader().waitingForWiFi.collectAsStateWithLifecycle()
    var menu by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    val downloader = offline.downloader()
    Box(modifier) {
        OfflineDownloadStatusBar(unit, speeds[unit.fileId], ahead = OfflineQueue.ahead(unit.fileId, queue), waitingForWiFi = waitingForWiFi) { menu = true }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (unit.state != OfflineUnit.State.done && OfflineQueue.canPrioritize(unit.fileId, queue)) {
                DropdownMenuItem(text = { Text("优先下载") }, onClick = { menu = false; downloader.prioritize(listOf(unit.fileId)) })
            }
            when (unit.state) {
                OfflineUnit.State.queued, OfflineUnit.State.downloading ->
                    DropdownMenuItem(text = { Text("暂停") }, onClick = { menu = false; downloader.pause(unit.fileId) })
                OfflineUnit.State.paused ->
                    DropdownMenuItem(text = { Text("继续下载") }, onClick = { menu = false; downloader.resume(unit.fileId) })
                OfflineUnit.State.failed -> if (!unit.waitingForTranscode) {
                    DropdownMenuItem(text = { Text("重试") }, onClick = { menu = false; downloader.resume(unit.fileId) })
                }
                OfflineUnit.State.done -> onChangeQuality?.let { change ->
                    DropdownMenuItem(text = { Text("改下其他画质") }, onClick = { menu = false; change(unit.fileId) })
                }
                else -> Unit
            }
            DropdownMenuItem(
                text = { Text(if (unit.state == OfflineUnit.State.done) "删除下载" else "取消下载", color = Danger) },
                onClick = { menu = false; confirm = true },
            )
        }
    }
    if (confirm) {
        val device = deviceName()
        OfflineConfirmDialog(
            title = if (unit.state == OfflineUnit.State.done) "删除这份下载？" else "取消下载？",
            message = "只删${device}上的副本，观看进度会保留。",
            action = if (unit.state == OfflineUnit.State.done) "删除下载（${McFormat.bytes(unit.receivedBytes)}）" else "取消下载",
            onDismiss = { confirm = false },
            onConfirm = { downloader.delete(unit.fileId) },
        )
    }
}

/** 删除 / 取消的二次确认（红字动作 + 「保留」） */
@Composable
fun OfflineConfirmDialog(title: String, message: String, action: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        titleContentColor = TextPrimary,
        textContentColor = TextMuted,
        title = { Text(title, style = McType.title3) },
        text = { Text(message, style = McType.footnote, color = TextMuted, lineHeight = 20.sp) },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }, modifier = Modifier.testTag("offline-confirm")) {
                Text(action, color = Danger, style = McType.subheadlineSemibold)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("保留", color = TextPrimary) } },
    )
}

/**
 * 剧照上的下载状态（详情页分集卡；iOS `OfflineDownloadStrip`）：蓝描边 + 底部一条——
 * 左边状态图标、中间「下载中 47%」、右边实时速度，最底下一道进度
 */
@Composable
fun BoxScope.OfflineDownloadStrip(
    unit: OfflineUnit,
    speed: Double?,
    cornerRadius: Dp = 12.dp,
    /** 下载队列里排在它前面的个数；只许 Wi-Fi 下、眼下是计费网络（§5.5） */
    ahead: Int = 0,
    waitingForWiFi: Boolean = false,
) {
    val tint = if (unit.needsAttention) Warning else Info
    Box(Modifier.matchParentSize().border(2.dp, tint, RoundedCornerShape(cornerRadius)))
    Column(
        Modifier
            .align(Alignment.BottomCenter)
            .fillMaxWidth()
            .clip(RoundedCornerShape(bottomStart = cornerRadius, bottomEnd = cornerRadius))
            .background(Color(7, 12, 20).copy(alpha = 0.92f)),
    ) {
        Row(
            Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            UnitIcon(unit, tint, 12.dp)
            Text(OfflineUnitStatus.short(unit, ahead, waitingForWiFi), fontSize = 11.sp, fontWeight = FontWeight.Medium, color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (speed != null && speed > 0 && unit.state == OfflineUnit.State.downloading && !waitingForWiFi) {
                Text("${McFormat.bytes(speed.toLong())}/s", fontSize = 11.sp, color = tint.copy(alpha = 0.8f), maxLines = 1)
            }
        }
        Box(Modifier.fillMaxWidth(unit.progressFraction.toFloat().coerceIn(0f, 1f)).height(2.dp).background(tint))
    }
}

/** 分集卡右上角的「已下载」（绿箭头） */
@Composable
fun OfflineDownloadedBadge(modifier: Modifier = Modifier) {
    Row(
        modifier
            .height(18.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(Color.Black.copy(alpha = 0.6f))
            .padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(Icons.Rounded.ArrowDownward, contentDescription = "已下载", tint = Success, modifier = Modifier.size(10.dp))
        Text("已下载", fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
    }
}

/** 刚下完时分集卡底部短暂提示「下载完成」（2.5 秒） */
@Composable
fun BoxScope.OfflineJustFinished(playable: Boolean) {
    var was by remember { mutableStateOf(playable) }
    var show by remember { mutableStateOf(false) }
    LaunchedEffect(playable) {
        if (!was && playable) {
            show = true
            kotlinx.coroutines.delay(2_500)
            show = false
        }
        was = playable
    }
    AnimatedVisibility(show, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.align(Alignment.BottomStart).padding(6.dp)) {
        Text(
            "下载完成", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
            modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(Success.copy(alpha = 0.9f)).padding(horizontal = 6.dp, vertical = 1.dp),
        )
    }
}

/**
 * 详情页「文件」区里本机副本那一行（iOS `OfflineLocalFileRow`）：与服务器上的文件行同一个样子，文件名后标「本机」；
 * 展开的信息与源文件一致，只是保存位置写本机、时间写下载时间、尺寸写本机这份的大小。
 * 转码档是另一份文件：只列确定知道的（档位、大小），不把源文件的码率、编码冒充成本机的。
 * 右边垃圾桶立即删除，确认里说明删除后没网就不能播了；长按可改下其他画质。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun OfflineLocalFileRow(
    unit: OfflineUnit,
    source: LibraryFileView?,
    title: String,
    canChangeQuality: Boolean,
    onChangeQuality: () -> Unit,
    specRows: (LibraryFileView) -> List<Pair<String, String>> = { emptyList() },
) {
    val offline = rememberOffline()
    val device = deviceName()
    var expanded by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().testTag("local-file-row-${unit.fileId}")) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                Row(
                    Modifier.combinedClickable(onClick = { expanded = !expanded }, onLongClick = { menu = true }),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Rounded.KeyboardArrowRight, null, tint = TextFaint,
                        modifier = Modifier.size(16.dp).rotate(if (expanded) 90f else 0f),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        source?.fileName ?: title, style = McType.footnote, color = TextMuted,
                        maxLines = if (expanded) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
                    )
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    if (canChangeQuality) {
                        DropdownMenuItem(text = { Text("改下其他画质") }, onClick = { menu = false; onChangeQuality() })
                    }
                    DropdownMenuItem(text = { Text("从${device}删除", color = Danger) }, onClick = { menu = false; confirm = true })
                }
            }
            Spacer(Modifier.width(8.dp))
            Row(
                Modifier.clip(RoundedCornerShape(999.dp)).background(Success.copy(alpha = 0.12f)).padding(horizontal = 6.dp, vertical = 2.dp).testTag("local-file-tag"),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Icon(Icons.Rounded.PhoneAndroid, null, tint = Success, modifier = Modifier.size(11.dp))
                Text("本机", fontSize = 11.sp, fontWeight = FontWeight.Medium, color = Success)
            }
            Spacer(Modifier.width(4.dp))
            androidx.compose.material3.IconButton(onClick = { confirm = true }, modifier = Modifier.size(36.dp).testTag("local-file-delete-${unit.fileId}")) {
                Icon(Icons.Rounded.Delete, contentDescription = "从${device}删除", tint = TextFaint, modifier = Modifier.size(18.dp))
            }
        }
        if (expanded) {
            val original = unit.profile == "original"
            val downloaded = unit.completedAt?.let { java.time.Instant.ofEpochMilli(it).toString() }
                ?.let { "${McFormat.dateTime(it)} · ${McFormat.relative(it)}" } ?: "—"
            val rows = buildList {
                add("保存位置" to "本机（$device · MovieClaw 下载）")
                add("下载时间" to downloaded)
                add("来源" to if (original) "从服务器下载 · 原画" else "服务器转码 · ${unit.profileLabel}")
                add("文件尺寸" to McFormat.bytes(unit.receivedBytes))
                if (original && source != null) addAll(specRows(source)) else if (!original) add("画面规格" to unit.profileLabel)
            }
            Column(Modifier.padding(start = 14.dp, end = 14.dp, bottom = 14.dp, top = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                rows.forEach { (label, value) ->
                    Row {
                        Text(label, style = McType.footnote, color = TextFaint, modifier = Modifier.width(76.dp))
                        Spacer(Modifier.width(16.dp))
                        Text(value, style = McType.footnote, color = TextMuted)
                    }
                }
            }
        }
    }
    if (confirm) {
        OfflineConfirmDialog(
            title = "删除${device}上的这份副本？",
            message = "立即删除，不进回收站。删除后没网时就不能播放了，要离线看得重新下载；观看进度会保留。",
            action = "删除（释放 ${McFormat.bytes(unit.receivedBytes)}）",
            onDismiss = { confirm = false },
            onConfirm = { offline.downloader().delete(unit.fileId) },
        )
    }
}

/**
 * 退出登录时问一句要不要连本机下载一起删（docs/design/offline-download.md §8、§9；iOS `OfflineDownloadCleanup`）：
 * 不删就留着——同一账号重新登录就回来；令牌被吊销（别处改了密码）时不自动删。
 * [everywhere]：退出全部账号（共用设备交还前），问的是这台设备上全部账号的下载。
 * 没有下载时直接 [onProceed]；无论删不删，最后都 [onProceed]
 */
@Composable
fun OfflineLogoutPrompt(everywhere: Boolean, onProceed: () -> Unit) {
    val offline = rememberOffline()
    val store = offline.store()
    val device = deviceName()
    val owners = remember { if (everywhere) io.movieclaw.android.core.offline.OfflineOwners.scan() else emptyList() }
    val items = store.state.collectAsStateWithLifecycle().value.items
    val has = if (everywhere) owners.isNotEmpty() || items.isNotEmpty() else store.owner != null && items.isNotEmpty()
    LaunchedEffect(has) { if (!has) onProceed() }
    if (!has) return
    AlertDialog(
        onDismissRequest = onProceed,
        containerColor = Color(0xFF15161A),
        titleContentColor = TextPrimary,
        textContentColor = TextMuted,
        title = {
            Text(
                if (everywhere) "同时删除这台${device}上的全部下载？" else "同时删除本机下载的 ${items.size} 部（${McFormat.bytes(store.totalBytes)}）？",
                style = McType.title3,
            )
        },
        text = {
            Text(
                if (everywhere) "共用设备交还前建议删除。不删的话，重新登录对应账号还能接着看。" else "不删的话，下次登录这个账号还能接着看。",
                style = McType.footnote, color = TextMuted, lineHeight = 20.sp,
            )
        },
        confirmButton = {
            TextButton(onClick = {
                items.keys.forEach { offline.downloader().deleteItem(it) }
                if (everywhere) owners.forEach { io.movieclaw.android.core.offline.OfflineOwners.remove(it) }
                else store.owner?.let { io.movieclaw.android.core.offline.OfflineOwners.remove(it) }
                onProceed()
            }) { Text(if (everywhere) "全部删除" else "删除下载", color = Danger, style = McType.subheadlineSemibold) }
        },
        dismissButton = { TextButton(onClick = onProceed) { Text("保留", color = TextPrimary) } },
    )
}
