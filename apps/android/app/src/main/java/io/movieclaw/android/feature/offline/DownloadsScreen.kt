package io.movieclaw.android.feature.offline

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
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
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.offline.OfflineDownloader
import io.movieclaw.android.core.offline.OfflineStore
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * 我的 → 下载（iOS `OfflineStorageView` 的对应物，docs/design/offline-download.md §8）：
 * 下载中（每一集一行：海报、片名、第 N 季第 M 集 · 档位、状态与速度、进度；下完移到「已下载」）
 * → 建议（有已看完的才出现：删除已看完的）
 * → 已下载（**按条目**一行：海报、标题、已下载 N 集/档位、占用；点进详情，删除二次确认）
 * → 容量条放最后（本机储存空间：下载 / 其他已用 / 剩余）。
 *
 * 与 iOS 的已知差异：iOS 会列「其他账号」在这台设备上的下载（各账号独立目录），
 * 安卓的本机副本目前只按当前安装存一份，没有多账号分区，故这一组不出现。
 */
@HiltViewModel
class DownloadsViewModel @Inject constructor(
    private val store: OfflineStore,
    private val downloader: OfflineDownloader,
    private val repository: SessionRepository,
    private val apiFactory: io.movieclaw.android.core.network.ApiFactory,
    private val prefs: io.movieclaw.android.core.offline.OfflinePrefs,
) : ViewModel() {
    data class Ui(
        val packs: List<OfflineStore.Pack> = emptyList(),
        val known: Map<Long, OfflineStore.Pack> = emptyMap(),
        val tasks: Map<Long, OfflineDownloader.TaskState> = emptyMap(),
        val totalBytes: Long = 0,
        val otherOwners: List<OfflineStore.OtherOwner> = emptyList(),
        val allowCellular: Boolean = false,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui.asStateFlow()

    /** 容量条的读数：打开页面 / 下完一集 / 删除时取一次（同 iOS，不跟着进度每秒跳） */
    private val _capacity = MutableStateFlow<Pair<Long, Long?>?>(null) // (free, total)
    val capacity: StateFlow<Pair<Long, Long?>?> = _capacity.asStateFlow()

    val origin: String? get() = repository.ui.value.origin
    val deviceName: String = android.os.Build.MODEL ?: "本机"

    init {
        viewModelScope.launch {
            combine(
                store.packs,
                downloader.known,
                downloader.tasks,
                store.otherOwners,
                prefs.allowCellular,
            ) { packs, known, tasks, others, allowCellular ->
                Ui(packs, known, tasks, packs.sumOf { it.sizeBytes }, others, allowCellular)
            }.collect { _ui.value = it }
        }
        viewModelScope.launch {
            store.packs.collect { readCapacity() }
        }
    }

    fun readCapacity() {
        _capacity.value = store.freeBytes() to store.totalCapacityBytes()
    }

    fun setAllowCellular(on: Boolean) {
        viewModelScope.launch { prefs.setAllowCellular(on) }
    }

    fun deleteOtherOwner(owner: OfflineStore.OtherOwner) {
        store.deleteOwner(owner.owner)
        readCapacity()
    }

    fun pause(fileId: Long) = downloader.pause(fileId)

    fun resume(pack: OfflineStore.Pack) {
        origin?.let { downloader.resumePack(it, pack) }
    }

    fun cancel(pack: OfflineStore.Pack) {
        origin?.let { downloader.deleteLocal(it, pack) }
    }

    fun deleteItem(mediaItemId: Long) {
        store.deleteItem(mediaItemId)
        readCapacity()
    }

    fun deleteWatched(packs: List<OfflineStore.Pack>) {
        val o = origin
        packs.forEach { pack ->
            if (o != null) downloader.deleteLocal(o, pack) else store.delete(pack.mediaItemId, pack.fileId)
        }
        readCapacity()
    }

    fun syncViewings() {
        val o = origin ?: return
        viewModelScope.launch { runCatching { store.syncViewings(o, apiFactory.forOrigin(o)) } }
    }
}

/** 已下载的一个条目（把同一 mediaItemId 的副本聚成一行，iOS `OfflineItemSummary`） */
private data class ItemSummary(
    val mediaItemId: Long,
    val libraryId: Long,
    val title: String,
    val posterUrl: String?,
    val kind: String,
    val doneCount: Int,
    val activeCount: Int,
    val bytes: Long,
    val packs: List<OfflineStore.Pack>,
)

@Composable
fun DownloadsScreen(
    onBack: () -> Unit,
    onPlayLocal: (mediaItemId: Long, fileId: Long) -> Unit,
    /** 点条目 → 该条目的库内详情（iOS 的 NavigationLink） */
    onOpenItem: (libraryId: Long, mediaItemId: Long) -> Unit = { _, _ -> },
    vm: DownloadsViewModel = hiltViewModel(),
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val capacity by vm.capacity.collectAsStateWithLifecycle()
    var menuFor by remember { mutableStateOf<OfflineStore.Pack?>(null) }
    var confirmDelete by remember { mutableStateOf<DeleteTarget?>(null) }
    var settingsOpen by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { vm.syncViewings(); vm.readCapacity() }

    // 下载中：本机还没有副本、但在下（排队/下载中/暂停/失败）的单元
    val activePacks = ui.known.values
        .filter { pack -> ui.packs.none { it.fileId == pack.fileId } }
        .sortedBy { it.title }
    val doneItems = ui.packs
        .groupBy { it.mediaItemId }
        .map { (mediaItemId, packs) ->
            val first = packs.first()
            ItemSummary(
                mediaItemId = mediaItemId,
                libraryId = packs.firstOrNull { it.libraryId > 0 }?.libraryId ?: 0L,
                title = first.title,
                posterUrl = packs.firstNotNullOfOrNull { it.posterUrl },
                kind = if (packs.any { it.seasonNumber > 0 }) "tv" else "movie",
                doneCount = packs.size,
                activeCount = activePacks.count { it.mediaItemId == mediaItemId },
                bytes = packs.sumOf { it.sizeBytes },
                packs = packs,
            )
        }
        .sortedBy { it.title }
    val watched = ui.packs.filter { it.played }

    Column(Modifier.fillMaxSize().background(Bg)) {
        McTopBar(
            variant = McTopBarVariant.Sub,
            title = "下载",
            onBack = onBack,
            actions = {
                Box {
                    androidx.compose.material3.IconButton(onClick = { settingsOpen = true }) {
                        Icon(Icons.Rounded.Settings, contentDescription = "下载设置", tint = TextPrimary, modifier = Modifier.size(20.dp))
                    }
                    DropdownMenu(expanded = settingsOpen, onDismissRequest = { settingsOpen = false }) {
                        DropdownMenuItem(
                            text = {
                                Column {
                                    Text("使用蜂窝网络下载", style = McType.sub, color = TextPrimary)
                                    Text("关闭时只在 Wi-Fi 下下载", style = McType.caption2, color = TextMuted)
                                }
                            },
                            trailingIcon = {
                                if (ui.allowCellular) Icon(Icons.Rounded.Check, contentDescription = null, tint = Accent)
                            },
                            onClick = {
                                vm.setAllowCellular(!ui.allowCellular)
                                settingsOpen = false
                            },
                        )
                    }
                }
            },
        )
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
            if (activePacks.isNotEmpty()) {
                item {
                    SectionTitle("下载中")
                }
                items(activePacks, key = { "active-${it.fileId}" }) { pack ->
                    DownloadingRow(
                        pack = pack,
                        task = ui.tasks[pack.fileId],
                        origin = vm.origin,
                        onClick = { if (pack.libraryId > 0) onOpenItem(pack.libraryId, pack.mediaItemId) },
                        onLongClick = { menuFor = pack },
                    )
                }
            }

            if (watched.isNotEmpty()) {
                item {
                    Spacer(Modifier.height(14.dp))
                    GlassCard(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Success, modifier = Modifier.size(22.dp))
                            Spacer(Modifier.width(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text("删除已看完的", style = McType.sub, color = TextPrimary)
                                Text(
                                    "${watched.size} 个已看完，占用 ${McFormat.bytes(watched.sumOf { it.sizeBytes })}",
                                    style = McType.caption2, color = TextMuted,
                                )
                            }
                            Text(
                                "删除",
                                style = McType.caption,
                                color = Danger,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(999.dp))
                                    .background(Danger.copy(alpha = 0.12f))
                                    .clickable { confirmDelete = DeleteTarget.Watched(watched) }
                                    .padding(horizontal = 12.dp, vertical = 6.dp),
                            )
                        }
                    }
                }
            }

            item {
                SectionTitle(
                    if (doneItems.isEmpty()) "已下载" else "已下载 · ${doneItems.size} 部",
                )
            }
            if (doneItems.isEmpty() && activePacks.isEmpty()) {
                item {
                    Text(
                        "还没有下载。在影片详情页点「⋯ → 下载」，没网的时候也能看。",
                        style = McType.footnote, color = TextFaint,
                        modifier = Modifier.padding(vertical = 20.dp),
                    )
                }
            } else if (doneItems.isEmpty()) {
                item {
                    Text("下完的会出现在这里。", style = McType.footnote, color = TextFaint)
                }
            }
            items(doneItems, key = { "item-${it.mediaItemId}" }) { item ->
                DownloadedItemRow(
                    item = item,
                    origin = vm.origin,
                    onClick = { if (item.libraryId > 0) onOpenItem(item.libraryId, item.mediaItemId) },
                    onPlay = {
                        val single = item.packs.minByOrNull { it.episodeNumber }
                        if (single != null) onPlayLocal(single.mediaItemId, single.fileId)
                    },
                    onDelete = { confirmDelete = DeleteTarget.Item(item) },
                )
                Spacer(Modifier.height(8.dp))
            }

            if (ui.otherOwners.isNotEmpty()) {
                item {
                    Spacer(Modifier.height(14.dp))
                    SectionTitle("其他账号")
                }
                items(ui.otherOwners, key = { "owner-${it.owner.key}" }) { other ->
                    OtherOwnerRow(other = other, onDelete = { confirmDelete = DeleteTarget.OtherOwner(other) })
                }
                item {
                    Text(
                        "这台 ${vm.deviceName} 上其他账号的下载，重新登录那个账号就能看。",
                        style = McType.caption2, color = TextFaint,
                        modifier = Modifier.padding(top = 4.dp, bottom = 4.dp),
                    )
                }
            }

            item {
                Spacer(Modifier.height(16.dp))
                StorageCard(used = ui.totalBytes, free = capacity?.first, total = capacity?.second)
                Spacer(Modifier.height(30.dp))
            }
        }
    }

    // 下载中那一行的操作（iOS 的左滑 / 长按菜单）
    menuFor?.let { pack ->
        Box(Modifier.fillMaxSize()) {
            DropdownMenu(expanded = true, onDismissRequest = { menuFor = null }) {
                when (val task = ui.tasks[pack.fileId]) {
                    is OfflineDownloader.TaskState.Paused,
                    is OfflineDownloader.TaskState.Failed ->
                        DropdownMenuItem(text = { Text("继续下载") }, onClick = { menuFor = null; vm.resume(pack) })
                    OfflineDownloader.TaskState.Queued,
                    OfflineDownloader.TaskState.WaitingForWifi -> Unit
                    else -> DropdownMenuItem(text = { Text("暂停") }, onClick = { menuFor = null; vm.pause(pack.fileId) })
                }
                DropdownMenuItem(
                    text = { Text("取消下载", color = Danger) },
                    onClick = { menuFor = null; confirmDelete = DeleteTarget.Pack(pack) },
                )
            }
        }
    }

    when (val target = confirmDelete) {
        is DeleteTarget.Item -> ConfirmDeleteDialog(
            title = "删除「${target.item.title}」的下载？",
            bytes = target.item.bytes,
            actionLabel = "删除（释放 ${McFormat.bytes(target.item.bytes)}）",
            deviceName = vm.deviceName,
            onDismiss = { confirmDelete = null },
            onConfirm = { vm.deleteItem(target.item.mediaItemId) },
        )
        is DeleteTarget.Watched -> ConfirmDeleteDialog(
            title = "删除 ${target.packs.size} 个已看完的下载？",
            bytes = target.packs.sumOf { it.sizeBytes },
            actionLabel = "删除（释放 ${McFormat.bytes(target.packs.sumOf { it.sizeBytes })}）",
            deviceName = vm.deviceName,
            onDismiss = { confirmDelete = null },
            onConfirm = { vm.deleteWatched(target.packs) },
        )
        is DeleteTarget.Pack -> ConfirmDeleteDialog(
            title = "取消下载？",
            bytes = 0,
            actionLabel = "取消下载",
            deviceName = vm.deviceName,
            onDismiss = { confirmDelete = null },
            onConfirm = { vm.cancel(target.pack) },
        )
        is DeleteTarget.OtherOwner -> ConfirmDeleteDialog(
            title = "删除「${target.owner.owner.username}」在这台设备上的下载？",
            bytes = target.owner.bytes,
            actionLabel = "删除（释放 ${McFormat.bytes(target.owner.bytes)}）",
            deviceName = vm.deviceName,
            onDismiss = { confirmDelete = null },
            onConfirm = { vm.deleteOtherOwner(target.owner) },
        )
        null -> Unit
    }
}

private sealed interface DeleteTarget {
    data class Item(val item: ItemSummary) : DeleteTarget
    data class Watched(val packs: List<OfflineStore.Pack>) : DeleteTarget
    data class Pack(val pack: OfflineStore.Pack) : DeleteTarget
    data class OtherOwner(val owner: OfflineStore.OtherOwner) : DeleteTarget
}

@Composable
private fun OtherOwnerRow(other: OfflineStore.OtherOwner, onDelete: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(other.owner.username, style = McType.sub, color = TextPrimary)
            Text(
                "${other.owner.host} · ${other.items} 部",
                style = McType.caption2, color = TextMuted,
            )
        }
        Text(McFormat.bytes(other.bytes), style = McType.caption2, color = TextMuted)
        androidx.compose.material3.IconButton(onClick = onDelete) {
            Icon(Icons.Rounded.Delete, contentDescription = "删除其他账号的下载", tint = Danger, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Spacer(Modifier.height(12.dp))
    Text(text, style = McType.subheadlineSemibold, color = TextPrimary)
    Spacer(Modifier.height(8.dp))
}

/** 下载中的一行：海报 + 片名 + 集/档位 + 状态与速度 + 进度（下完就从这组消失） */
@Composable
private fun DownloadingRow(
    pack: OfflineStore.Pack,
    task: OfflineDownloader.TaskState?,
    origin: String?,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    val tint = when (task) {
        is OfflineDownloader.TaskState.Failed -> Danger
        OfflineDownloader.TaskState.Paused, OfflineDownloader.TaskState.WaitingForWifi -> Warning
        else -> Info
    }
    val fraction = (task as? OfflineDownloader.TaskState.Downloading)?.let {
        if (it.totalBytes > 0) (it.downloadedBytes.toFloat() / it.totalBytes).coerceIn(0f, 1f) else 0f
    }
    val speed = (task as? OfflineDownloader.TaskState.Downloading)?.speedBps?.takeIf { it > 0 }
    Row(
        Modifier
            .fillMaxWidth()
            .combinedClickableCompat(onClick = onClick, onLongClick = onLongClick)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Poster(pack.posterUrl, origin)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(pack.title, style = McType.subheadlineSemibold, color = TextPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(3.dp))
            Text(
                buildString {
                    if (pack.seasonNumber > 0) append("第 ${pack.seasonNumber} 季第 ${pack.episodeNumber} 集 · ")
                    append(if (pack.profile == "original") "原画" else pack.profile)
                },
                style = McType.caption2, color = TextMuted,
            )
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    when (task) {
                        is OfflineDownloader.TaskState.Failed -> "下载失败"
                        OfflineDownloader.TaskState.Paused -> "已暂停"
                        OfflineDownloader.TaskState.WaitingForWifi -> "等待 Wi-Fi"
                        OfflineDownloader.TaskState.Queued -> if (pack.profile == "original") "准备下载" else "等待转码"
                        is OfflineDownloader.TaskState.Downloading -> "下载中 ${((fraction ?: 0f) * 100).toInt()}%"
                        null -> "准备下载"
                    },
                    style = McType.caption2, color = tint,
                )
                if (speed != null) {
                    Spacer(Modifier.width(6.dp))
                    Text("${McFormat.bytes(speed)}/s", style = McType.caption2, color = TextMuted)
                }
            }
            Spacer(Modifier.height(6.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(3.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(Color.White.copy(alpha = 0.12f)),
            ) {
                Box(
                    Modifier
                        .fillMaxWidth(fraction ?: 0f)
                        .height(3.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(tint),
                )
            }
        }
    }
}

/** 已下载的一个条目（按条目聚成一行）：海报 + 标题 + 「已下载 N 集」/档位 + 占用 */
@Composable
private fun DownloadedItemRow(
    item: ItemSummary,
    origin: String?,
    onClick: () -> Unit,
    onPlay: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Poster(item.posterUrl, origin)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(item.title, style = McType.subheadlineSemibold, color = TextPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(3.dp))
            Text(
                buildString {
                    if (item.kind == "tv") append("已下载 ${item.doneCount} 集")
                    else append(item.packs.firstOrNull()?.profile?.takeIf { it != "original" } ?: "原画")
                    if (item.activeCount > 0) append(" · 还有 ${item.activeCount} 个在下载")
                },
                style = McType.caption2, color = TextMuted,
            )
            Spacer(Modifier.height(3.dp))
            Text(McFormat.bytes(item.bytes), style = McType.caption2, color = TextMuted)
        }
        androidx.compose.material3.IconButton(onClick = onPlay) {
            Icon(Icons.Rounded.PlayArrow, contentDescription = "播放本机副本", tint = Success)
        }
        androidx.compose.material3.IconButton(onClick = onDelete) {
            Icon(Icons.Rounded.Delete, contentDescription = "删除下载", tint = Danger)
        }
    }
}

@Composable
private fun Poster(url: String?, origin: String?) {
    Box(
        Modifier
            .width(60.dp)
            .aspectRatio(2f / 3f)
            .clip(RoundedCornerShape(8.dp))
            .background(Color.White.copy(alpha = 0.06f)),
    ) {
        RemoteImage(
            url = url,
            origin = origin,
            contentDescription = null,
            modifier = Modifier.fillMaxSize(),
        )
    }
}

/** 容量条（iOS `StorageUsageBar`）：下载 / 其他已用 / 剩余 */
@Composable
private fun StorageCard(used: Long, free: Long?, total: Long?) {
    GlassCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("本机储存空间", style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f))
            free?.let { Text("可用 ${McFormat.bytes(it)}", style = McType.caption2, color = TextMuted) }
        }
        Spacer(Modifier.height(10.dp))
        if (total != null && total > 0 && free != null) {
            val other = (total - free - used).coerceAtLeast(0)
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(RoundedCornerShape(999.dp)),
            ) {
                if (used > 0) Box(Modifier.weight(used.toFloat().coerceAtLeast(1f)).height(6.dp).background(Info))
                if (other > 0) Box(Modifier.weight(other.toFloat()).height(6.dp).background(Color.White.copy(alpha = 0.25f)))
                Box(Modifier.weight(free.toFloat().coerceAtLeast(1f)).height(6.dp).background(Color.White.copy(alpha = 0.06f)))
            }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Legend(Info, "下载 ${McFormat.bytes(used)}")
                Legend(Color.White.copy(alpha = 0.25f), "其他已用")
            }
        } else {
            Text("MovieClaw 下载 ${McFormat.bytes(used)}", style = McType.caption, color = TextMuted)
        }
    }
}

@Composable
private fun Legend(color: Color, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(5.dp))
        Text(text, style = McType.caption2, color = TextMuted)
    }
}

/** 删除确认（iOS `ConfirmDelete`）：写明释放多少、「观看进度会保留」 */
@Composable
private fun ConfirmDeleteDialog(
    title: String,
    bytes: Long,
    actionLabel: String,
    deviceName: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        titleContentColor = TextPrimary,
        textContentColor = TextMuted,
        title = { Text(title, style = McType.title3) },
        text = {
            Text(
                "只删 $deviceName 上的副本，观看进度会保留。",
                style = McType.footnote, color = TextMuted, lineHeight = 20.sp,
            )
        },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }) {
                Text(actionLabel, color = Danger, style = McType.subheadlineSemibold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("保留", color = TextPrimary) }
        },
    )
}

/** 长按 + 点按同一行（iOS 左滑 / 长按菜单的等价入口） */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun Modifier.combinedClickableCompat(onClick: () -> Unit, onLongClick: () -> Unit): Modifier =
    this.then(
        Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick),
    )
