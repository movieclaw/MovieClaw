package io.movieclaw.android.feature.offline

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.offline.OfflineDisk
import io.movieclaw.android.core.offline.OfflineFormat
import io.movieclaw.android.core.offline.OfflineItemSummary
import io.movieclaw.android.core.offline.OfflineOwner
import io.movieclaw.android.core.offline.OfflineOwners
import io.movieclaw.android.core.offline.OfflineUnit
import io.movieclaw.android.core.offline.OfflineUnitStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 我的 → 下载（docs/design/offline-download.md §8；iOS `OfflineStorageView`）：
 * 下载中（有才出现，每一集一行，下完就移到已下载）→ 清理建议（有已看完的才出现）
 * → 已下载（点进条目、长按删除）→ 其他账号 → 容量条（放最后）；下载设置在右上角菜单。首页的「正在下载」提示条点进这里
 */
@Composable
fun DownloadsScreen(
    onBack: () -> Unit,
    /** 点条目 → 该条目的库内详情 */
    onOpenItem: (libraryId: Long, mediaItemId: Long) -> Unit,
    origin: String?,
) {
    val offline = rememberOffline()
    val store = offline.store()
    val state by store.state.collectAsStateWithLifecycle()
    val speeds by store.speeds.collectAsStateWithLifecycle()
    val doneBytes by store.doneBytes.collectAsStateWithLifecycle()
    val doneBytesByItem by store.doneBytesByItem.collectAsStateWithLifecycle()
    val allowCellular by offline.prefs().allowCellular.collectAsStateWithLifecycle()
    val device = deviceName()
    val scope = rememberCoroutineScope()
    var confirm by remember { mutableStateOf<Confirm?>(null) }
    var settings by remember { mutableStateOf(false) }
    var otherOwners by remember { mutableStateOf<List<Triple<OfflineOwner, Long, Int>>>(emptyList()) }
    /** 容量条的读数：打开页面、下完一集、删除时才取一次（下载中也不该每秒跳） */
    var capacity by remember { mutableStateOf<Pair<Long?, Long?>?>(null) }

    LaunchedEffect(state.owner?.key) {
        val current = state.owner?.key
        otherOwners = withContext(Dispatchers.IO) {
            OfflineOwners.scan().filter { it.key != current }.map { owner ->
                val (bytes, items) = OfflineOwners.usage(owner)
                Triple(owner, bytes, items)
            }.filter { it.second > 0 }
        }
    }
    LaunchedEffect(doneBytes) {
        capacity = withContext(Dispatchers.IO) { OfflineDisk.availableBytes() to OfflineDisk.totalCapacity() }
    }

    val items = store.downloadedItems(state)
    val active = store.activeUnits(state)
    val watched = state.units.values.filter { unit ->
        unit.playable && store.localProgress(unit.mediaItemId, unit.season, unit.episode, state)?.played == true
    }

    Column(Modifier.fillMaxSize().background(Bg).testTag("offline-storage")) {
        McTopBar(
            variant = McTopBarVariant.Sub,
            title = "下载",
            onBack = onBack,
            actions = {
                Box {
                    IconButton(onClick = { settings = true }, modifier = Modifier.testTag("offline-settings")) {
                        Icon(Icons.Rounded.Settings, contentDescription = "下载设置", tint = TextPrimary, modifier = Modifier.size(20.dp))
                    }
                    DropdownMenu(expanded = settings, onDismissRequest = { settings = false }) {
                        Text("关闭时只在 Wi-Fi 下下载", style = McType.caption2, color = TextMuted, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                        DropdownMenuItem(
                            text = { Text("使用蜂窝网络下载", style = McType.sub, color = TextPrimary) },
                            trailingIcon = { if (allowCellular) Icon(Icons.Rounded.Check, contentDescription = null, tint = Info) },
                            onClick = {
                                settings = false
                                scope.launch { offline.prefs().setAllowCellular(!allowCellular) }
                            },
                        )
                    }
                }
            },
        )
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 20.dp)) {
            if (active.isNotEmpty()) {
                item { SectionTitle("下载中", Modifier.testTag("offline-storage-downloading")) }
                items(active, key = { "active-${it.fileId}" }) { unit ->
                    val item = state.items[unit.mediaItemId] ?: return@items
                    DownloadingRow(unit, item, speeds[unit.fileId], origin, onOpen = { onOpenItem(item.libraryId, item.mediaItemId) })
                }
            }
            if (watched.isNotEmpty()) {
                item {
                    SectionTitle("建议")
                    GlassCard(Modifier.fillMaxWidth()) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Success, modifier = Modifier.size(26.dp))
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text("删除已看完的", style = McType.bodyMedium, color = TextPrimary)
                                Text("${watched.size} 个已看完，占用 ${McFormat.bytes(watched.sumOf { it.receivedBytes })}", style = McType.footnote, color = TextMuted)
                            }
                            Text(
                                "删除", style = McType.caption, color = Danger,
                                modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Danger.copy(alpha = 0.12f))
                                    .clickable { confirm = Confirm.Watched(watched) }.padding(horizontal = 12.dp, vertical = 6.dp).testTag("offline-delete-watched"),
                            )
                        }
                    }
                }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SectionTitle("已下载")
                    if (items.isNotEmpty()) {
                        Spacer(Modifier.width(8.dp))
                        Text("${items.size} 部", style = McType.sub, color = TextMuted)
                    }
                }
                if (items.isEmpty()) {
                    Text(
                        if (active.isEmpty()) "还没有下载。在影片详情页点「下载」，没网的时候也能看。" else "下完的会出现在这里。",
                        style = McType.sub, color = TextMuted, modifier = Modifier.padding(vertical = 8.dp),
                    )
                }
            }
            items(items, key = { "item-${it.mediaItemId}" }) { item ->
                DownloadedItemRow(
                    item = item,
                    units = store.unitsOfItem(item.mediaItemId, state),
                    bytes = doneBytesByItem[item.mediaItemId] ?: 0,
                    origin = origin,
                    onOpen = { onOpenItem(item.libraryId, item.mediaItemId) },
                    onDelete = { confirm = Confirm.Item(item) },
                )
            }
            if (otherOwners.isNotEmpty()) {
                item { SectionTitle("其他账号") }
                items(otherOwners, key = { "owner-${it.first.key}" }) { (owner, bytes, count) ->
                    OwnerRow(owner, bytes, count) { confirm = Confirm.Owner(owner, bytes) }
                }
                item {
                    Text("这台${device}上其他账号的下载，重新登录那个账号就能看。", style = McType.caption2, color = TextFaint, modifier = Modifier.padding(vertical = 4.dp))
                }
            }
            // 容量放最后：这一页先管下载，剩余空间是参考（空间不够时选档面板会直接提示）
            item {
                Spacer(Modifier.height(20.dp))
                StorageCard(doneBytes, capacity?.first, capacity?.second)
                Spacer(Modifier.height(32.dp))
            }
        }
    }

    when (val target = confirm) {
        is Confirm.Item -> OfflineConfirmDialog(
            title = "删除「${target.item.title}」的下载？",
            message = "只删${device}上的副本，观看进度会保留。",
            action = "删除（释放 ${McFormat.bytes(store.bytesOfItem(target.item.mediaItemId))}）",
            onDismiss = { confirm = null },
            onConfirm = { offline.downloader().deleteItem(target.item.mediaItemId) },
        )
        is Confirm.Watched -> OfflineConfirmDialog(
            title = "删除 ${target.units.size} 个已看完的下载？",
            message = "只删${device}上的副本，观看进度会保留。",
            action = "删除（释放 ${McFormat.bytes(target.units.sumOf { it.receivedBytes })}）",
            onDismiss = { confirm = null },
            onConfirm = { target.units.forEach { offline.downloader().delete(it.fileId) } },
        )
        is Confirm.Owner -> OfflineConfirmDialog(
            title = "删除「${target.owner.username}」在这台${device}上的全部下载？",
            message = "只删${device}上的副本，观看进度会保留。",
            action = "删除（释放 ${McFormat.bytes(target.bytes)}）",
            onDismiss = { confirm = null },
            onConfirm = {
                OfflineOwners.remove(target.owner)
                otherOwners = otherOwners.filter { it.first.key != target.owner.key }
                // 别的账号的下载不在本账号的目录里，删了容量条读数不会自己变
                scope.launch { capacity = withContext(Dispatchers.IO) { OfflineDisk.availableBytes() to OfflineDisk.totalCapacity() } }
            },
        )
        null -> Unit
    }
}

private sealed interface Confirm {
    data class Item(val item: OfflineItemSummary) : Confirm
    data class Watched(val units: List<OfflineUnit>) : Confirm
    data class Owner(val owner: OfflineOwner, val bytes: Long) : Confirm
}

@Composable
private fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = McType.headline, color = TextPrimary, modifier = modifier.padding(top = 18.dp, bottom = 8.dp))
}

@Composable
private fun Poster(url: String?, origin: String?) {
    Box(Modifier.width(60.dp).height(90.dp).clip(RoundedCornerShape(8.dp)).background(Color.White.copy(alpha = 0.06f))) {
        RemoteImage(url = url, origin = origin, contentDescription = null, modifier = Modifier.fillMaxSize())
    }
}

/**
 * 「下载中」的一行：海报 + 片名 + 哪一集 · 档位 + 状态与速度 + 进度。
 * 点进条目；长按暂停、继续、取消（iOS 左滑 / 长按）。下完就从这一组消失
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DownloadingRow(unit: OfflineUnit, item: OfflineItemSummary, speed: Double?, origin: String?, onOpen: () -> Unit) {
    val offline = rememberOffline()
    var menu by remember { mutableStateOf(false) }
    val tint = if (unit.needsAttention) Warning else Info
    Box {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = onOpen, onLongClick = { menu = true }).padding(vertical = 8.dp).testTag("offline-downloading-${unit.fileId}"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Poster(item.posterUrl, origin)
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(item.title, style = McType.bodySemibold, color = TextPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(4.dp))
                Text(
                    listOfNotNull(if (unit.isMovie) null else OfflineFormat.seasonEpisode(unit.season, unit.episode), unit.profileLabel).joinToString(" · "),
                    style = McType.footnote, color = TextMuted,
                )
                Spacer(Modifier.height(4.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(OfflineUnitStatus.text(unit), style = McType.footnote, color = tint)
                    if (speed != null && speed > 0 && unit.state == OfflineUnit.State.downloading) {
                        Text("${McFormat.bytes(speed.toLong())}/s", style = McType.footnote, color = TextMuted)
                    }
                }
                Spacer(Modifier.height(6.dp))
                Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.12f))) {
                    Box(Modifier.fillMaxWidth(unit.progressFraction.toFloat().coerceIn(0f, 1f)).height(4.dp).clip(RoundedCornerShape(999.dp)).background(tint))
                }
            }
            Icon(androidx.compose.material.icons.Icons.Rounded.KeyboardArrowRight, null, tint = TextFaint, modifier = Modifier.size(22.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            val downloader = offline.downloader()
            if (unit.waitingForTranscode) {
                // 排队等服务器转码：到点自己会再去问，只给取消
            } else if (unit.state == OfflineUnit.State.paused || unit.state == OfflineUnit.State.failed) {
                DropdownMenuItem(text = { Text("继续下载") }, onClick = { menu = false; downloader.resume(unit.fileId) })
            } else {
                DropdownMenuItem(text = { Text("暂停") }, onClick = { menu = false; downloader.pause(unit.fileId) })
            }
            DropdownMenuItem(text = { Text("取消下载", color = Danger) }, onClick = { menu = false; downloader.delete(unit.fileId) })
        }
    }
}

/** 已下载的一个条目：海报 + 标题 + 「已下载 N 集」/档位（+ 还有 N 个在下载）+ 占用；点进详情，长按删除 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DownloadedItemRow(item: OfflineItemSummary, units: List<OfflineUnit>, bytes: Long, origin: String?, onOpen: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val done = units.filter { it.playable }
    val active = units.filter { it.isActive }
    val detail = buildList {
        if (item.kind == "tv") add("已下载 ${done.size} 集") else done.firstOrNull()?.let { add(it.profileLabel) }
        if (active.isNotEmpty()) add("还有 ${active.size} 个在下载")
    }.joinToString(" · ")
    Box {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = onOpen, onLongClick = { menu = true }).padding(vertical = 8.dp).testTag("offline-storage-item-${item.mediaItemId}"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Poster(item.posterUrl, origin)
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(item.title, style = McType.bodySemibold, color = TextPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(6.dp))
                Text(detail, style = McType.footnote, color = TextMuted)
                Spacer(Modifier.height(6.dp))
                Text(McFormat.bytes(bytes), style = McType.footnote, color = TextMuted)
            }
            Icon(androidx.compose.material.icons.Icons.Rounded.KeyboardArrowRight, null, tint = TextFaint, modifier = Modifier.size(22.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("删除下载", color = Danger) }, onClick = { menu = false; onDelete() })
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun OwnerRow(owner: OfflineOwner, bytes: Long, count: Int, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = {}, onLongClick = { menu = true }).padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(owner.username, style = McType.body, color = TextPrimary)
                Text("${owner.host} · $count 部", style = McType.caption, color = TextMuted)
            }
            Text(McFormat.bytes(bytes), style = McType.sub, color = TextMuted)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("删除", color = Danger) }, onClick = { menu = false; onDelete() })
        }
    }
}

/** 容量条（同系统「储存空间」）：MovieClaw 下载 / 其他已用 / 剩余。读数是快照，不跟下载进度变 */
@Composable
private fun StorageCard(downloads: Long, free: Long?, total: Long?) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.04f)).padding(16.dp).testTag("offline-storage-summary"),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("本机储存空间", style = McType.subheadline, color = TextPrimary, modifier = Modifier.weight(1f))
            free?.let { Text("可用 ${McFormat.bytes(it)}", style = McType.footnote, color = TextMuted) }
        }
        Spacer(Modifier.height(12.dp))
        if (total != null && total > 0 && free != null) {
            val other = (total - free - downloads).coerceAtLeast(0)
            Row(Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(999.dp))) {
                // 最小可见下载段仍计入总宽
                if (downloads > 0) Box(Modifier.weight(maxOf(downloads.toFloat(), total * 0.01f)).height(6.dp).background(Info))
                if (other > 0) Box(Modifier.weight(other.toFloat()).height(6.dp).background(Color.White.copy(alpha = 0.25f)))
                Box(Modifier.weight(maxOf(free.toFloat(), 1f)).height(6.dp).background(Color.White.copy(alpha = 0.06f)))
            }
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Legend(Info, "下载 ${McFormat.bytes(downloads)}")
                Spacer(Modifier.weight(1f))
                Legend(Color.White.copy(alpha = 0.25f), "其他已用")
            }
        } else {
            Text("MovieClaw 下载 ${McFormat.bytes(downloads)}", style = McType.subheadline, color = TextPrimary)
        }
    }
}

@Composable
private fun Legend(color: Color, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(5.dp))
        Text(text, style = McType.footnote, color = TextMuted)
    }
}
