package io.movieclaw.android.feature.offline

import androidx.compose.foundation.Canvas
import androidx.compose.material.icons.rounded.Check
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.offline.OfflineDownloader
import io.movieclaw.android.core.offline.OfflineStore

/**
 * 详情页的下载状态条（iOS `OfflineDownloadStatusBar` 的对应物）：
 * 左边进度环、中间「下载中 47%」、右边实时速度；暂停 / 失败换图标与颜色。
 * 只在没下完时出现（下载中 / 暂停 / 失败）；下完的副本在「文件」区里（本机那一行）。
 * 点它出操作菜单：暂停 / 继续 / 重试 / 删除 / 改下其他画质。
 */
@Composable
fun OfflineDownloadStatusBar(
    pack: OfflineStore.Pack,
    task: OfflineDownloader.TaskState?,
    onOpenMenu: () -> Unit,
) {
    val paused = task is OfflineDownloader.TaskState.Paused
    val failed = task is OfflineDownloader.TaskState.Failed
    val waitingWifi = task is OfflineDownloader.TaskState.WaitingForWifi
    val tint = when {
        failed -> Danger
        paused || waitingWifi -> Warning
        else -> Info
    }
    val fraction = (task as? OfflineDownloader.TaskState.Downloading)?.let {
        if (it.totalBytes > 0) (it.downloadedBytes.toFloat() / it.totalBytes).coerceIn(0f, 1f) else null
    }
    val speed = (task as? OfflineDownloader.TaskState.Downloading)?.speedBps?.takeIf { it > 0 }
    val text = when (task) {
        is OfflineDownloader.TaskState.Downloading ->
            "下载中 ${(fraction?.times(100) ?: 0f).toInt()}%"
        OfflineDownloader.TaskState.Queued -> if (pack.profile == "original") "准备下载" else "等待转码"
        OfflineDownloader.TaskState.Paused -> "已暂停"
        OfflineDownloader.TaskState.WaitingForWifi -> "等待 Wi-Fi"
        is OfflineDownloader.TaskState.Failed -> "${task.message}，点按重试"
        null -> "准备下载"
    }
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(Color.White.copy(alpha = 0.09f))
            .clickable(onClick = onOpenMenu)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        when {
            failed -> Text("!", color = tint, style = McType.subheadlineSemibold)
            paused -> Text("❚❚", color = tint, fontSize = 10.sp)
            else -> ProgressRing(fraction = fraction, color = tint)
        }
        Text(text, style = McType.subheadlineSemibold, color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
        if (speed != null) {
            Text(
                "${McFormat.bytes(speed)}/s",
                style = McType.caption,
                color = tint.copy(alpha = 0.75f),
            )
        }
        Spacer(Modifier.weight(1f))
        Text("⋯", style = McType.sub, color = tint)
    }
}

/** 进度环：知道总量画弧，不知道就只画底环（准备中） */
@Composable
private fun ProgressRing(fraction: Float?, color: Color) {
    Canvas(Modifier.size(18.dp)) {
        val stroke = 2.5.dp.toPx()
        val inset = stroke / 2
        val arcSize = Size(size.width - stroke, size.height - stroke)
        drawArc(
            color = color.copy(alpha = 0.25f),
            startAngle = 0f,
            sweepAngle = 360f,
            useCenter = false,
            topLeft = Offset(inset, inset),
            size = arcSize,
            style = Stroke(width = stroke),
        )
        if (fraction != null) {
            drawArc(
                color = color,
                startAngle = -90f,
                sweepAngle = 360f * fraction.coerceAtLeast(0.02f),
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }
    }
}

/** 状态条点开的操作菜单（iOS 的 Menu）：暂停 / 继续 / 重试 / 删除 / 改下其他画质 */
@Composable
fun OfflineDownloadActionsMenu(
    expanded: Boolean,
    pack: OfflineStore.Pack,
    task: OfflineDownloader.TaskState?,
    canChangeQuality: Boolean,
    onDismiss: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onChangeQuality: () -> Unit,
    onDelete: () -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        when (task) {
            is OfflineDownloader.TaskState.Downloading, OfflineDownloader.TaskState.Queued -> {
                if (task != OfflineDownloader.TaskState.Queued) {
                    DropdownMenuItem(text = { Text("暂停") }, onClick = { onDismiss(); onPause() })
                }
            }
            OfflineDownloader.TaskState.Paused ->
                DropdownMenuItem(text = { Text("继续下载") }, onClick = { onDismiss(); onResume() })
            is OfflineDownloader.TaskState.Failed ->
                DropdownMenuItem(text = { Text("重试") }, onClick = { onDismiss(); onResume() })
            OfflineDownloader.TaskState.WaitingForWifi ->
                DropdownMenuItem(text = { Text("等待 Wi-Fi（连接后自动继续）") }, onClick = { onDismiss() })
            null -> Unit
        }
        if (canChangeQuality) {
            DropdownMenuItem(text = { Text("改下其他画质") }, onClick = { onDismiss(); onChangeQuality() })
        }
        DropdownMenuItem(
            text = { Text("取消下载", color = Danger) },
            onClick = { onDismiss(); onDelete() },
        )
    }
}

/**
 * 删除 / 取消下载的二次确认（iOS 同款文案）：写明释放多少空间、「观看进度会保留」。
 * 离线时也能删——只动手机上这份。
 */
@Composable
fun OfflineDeleteDialog(
    pack: OfflineStore.Pack,
    isDone: Boolean,
    deviceName: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        titleContentColor = TextPrimary,
        textContentColor = TextMuted,
        title = { Text(if (isDone) "删除这份下载？" else "取消下载？", style = McType.title3) },
        text = {
            Column {
                Text(
                    "只删 $deviceName 上的副本，观看进度会保留。",
                    style = McType.footnote,
                    color = TextMuted,
                    lineHeight = 20.sp,
                )
                if (isDone) {
                    Spacer(Modifier.height(6.dp))
                    Text("释放 ${McFormat.bytes(pack.sizeBytes)}", style = McType.caption, color = TextMuted)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }) {
                Text(
                    if (isDone) "删除下载（${McFormat.bytes(pack.sizeBytes)}）" else "取消下载",
                    color = Danger,
                    style = McType.subheadlineSemibold,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("保留", color = TextPrimary) }
        },
    )
}

/** 本机副本徽标（分集卡右下角「已下载」用） */
@Composable
fun OfflineDownloadedBadge(modifier: Modifier = Modifier) {
    Row(
        modifier
            .clip(RoundedCornerShape(999.dp))
            .background(Color(0xCC0B3A22))
            .padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            androidx.compose.material.icons.Icons.Rounded.Check,
            contentDescription = "已下载",
            tint = Color(0xFF57D98A),
            modifier = Modifier.size(10.dp),
        )
        Spacer(Modifier.width(2.dp))
        Text("已下载", fontSize = 9.sp, color = Color(0xFF57D98A))
    }
}

/** 分集卡底部的小下载条（下载中 / 暂停 / 失败） */
@Composable
fun OfflineEpisodeStrip(
    task: OfflineDownloader.TaskState?,
    modifier: Modifier = Modifier,
) {
    val tint = when (task) {
        is OfflineDownloader.TaskState.Failed -> Danger
        OfflineDownloader.TaskState.Paused, OfflineDownloader.TaskState.WaitingForWifi -> Warning
        else -> Info
    }
    val fraction = (task as? OfflineDownloader.TaskState.Downloading)?.let {
        if (it.totalBytes > 0) (it.downloadedBytes.toFloat() / it.totalBytes).coerceIn(0f, 1f) else null
    }
    Row(
        modifier
            .clip(RoundedCornerShape(999.dp))
            .background(Color.Black.copy(alpha = 0.62f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        ProgressRing(fraction = fraction, color = tint)
        Text(
            when (task) {
                is OfflineDownloader.TaskState.Failed -> "失败"
                OfflineDownloader.TaskState.Paused -> "已暂停"
                OfflineDownloader.TaskState.WaitingForWifi -> "等 Wi-Fi"
                is OfflineDownloader.TaskState.Downloading -> "${((fraction ?: 0f) * 100).toInt()}%"
                else -> "准备中"
            },
            fontSize = 9.sp,
            color = tint,
        )
    }
}

/** 文件区里的本机副本行（iOS `OfflineLocalFileRow`）：标「本机」，可播放 / 改下其他画质 / 删除 */
@Composable
fun OfflineLocalFileRow(
    pack: OfflineStore.Pack,
    onPlay: () -> Unit,
    onChangeQuality: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "本机",
                fontSize = 10.sp,
                color = Color(0xFF57D98A),
                modifier = Modifier
                    .clip(RoundedCornerShape(4.dp))
                    .background(Color(0x3322A06B))
                    .padding(horizontal = 5.dp, vertical = 1.dp),
            )
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    "下载到本机的副本",
                    style = McType.footnote,
                    color = TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    buildString {
                        append(McFormat.bytes(pack.sizeBytes))
                        if (pack.profile != "original") append(" · ${pack.profile}")
                        append(" · 可离线播放")
                    },
                    style = McType.caption2,
                    color = TextMuted,
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SmallPill("播放") { onPlay() }
            SmallPill("改下其他画质") { onChangeQuality() }
            SmallPill("删除", danger = true) { onDelete() }
        }
    }
}

@Composable
private fun SmallPill(label: String, danger: Boolean = false, onClick: () -> Unit) {
    Box(
        Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(if (danger) Danger.copy(alpha = 0.14f) else Color.White.copy(alpha = 0.08f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(label, style = McType.caption, color = if (danger) Danger else TextPrimary)
    }
}
