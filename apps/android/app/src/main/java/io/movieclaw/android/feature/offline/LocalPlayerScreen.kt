package io.movieclaw.android.feature.offline

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import androidx.activity.compose.BackHandler
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.offline.OfflineStore
import java.time.Instant
import java.util.UUID

/**
 * 本机副本播放（iOS `OfflineLocalFile` 播放的对应物）：
 * ExoPlayer 直接播 filesDir 里的正片，不走服务器会话；退出/暂停时把这次观看
 * 写进本机的 viewings.json，联网后由 [OfflineStore.syncViewings] 按编号幂等补传
 * （服务端据此写入观看记录与续播点，docs/design/offline-download.md §7）。
 */
@Composable
fun LocalPlayerScreen(
    mediaItemId: Long,
    fileId: Long,
    onBack: () -> Unit,
    store: OfflineStore,
) {
    val pack = remember(fileId) { store.packFor(fileId) }
    val context = LocalContext.current
    val video = remember(fileId) {
        pack?.let { store.videoFile(it.mediaItemId, it.fileId, it.container) }
    }

    var startedAtMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var startPositionMs by remember { mutableLongStateOf(pack?.let { 0L } ?: 0L) }

    val player = remember(fileId) {
        ExoPlayer.Builder(context).build().apply {
            video?.let { setMediaItem(MediaItem.fromUri(android.net.Uri.fromFile(it))) }
            playWhenReady = true
            prepare()
        }
    }

    fun recordViewing(ended: Boolean) {
        val p = pack ?: return
        val position = player.currentPosition.coerceAtLeast(0)
        val now = Instant.now()
        store.appendViewing(
            p,
            io.movieclaw.android.core.model.OfflineViewingRecord(
                viewingId = UUID.randomUUID().toString(),
                mediaItemId = p.mediaItemId,
                seasonNumber = p.seasonNumber,
                episodeNumber = p.episodeNumber,
                fileId = p.fileId,
                startedAt = Instant.ofEpochMilli(startedAtMs).toString(),
                updatedAt = now.toString(),
                startPositionMs = startPositionMs,
                positionMs = position,
                watchedMs = (System.currentTimeMillis() - startedAtMs).coerceAtLeast(0),
                completed = ended || (p.durationMs?.let { position >= it - 2_000 } ?: false),
                ended = ended,
                durationMs = p.durationMs,
            ),
        )
        startPositionMs = position
    }

    DisposableEffect(fileId) {
        onDispose {
            val finished = pack?.durationMs?.let { player.currentPosition >= it - 2_000 } ?: false
            recordViewing(ended = false)
            // 看完了：本机副本标 played，「我的 → 下载」的「建议删除已看完的」据此出现（iOS 同义）
            pack?.let { p -> store.markPlayed(p.mediaItemId, p.fileId, finished) }
            player.release()
        }
    }
    BackHandler { recordViewing(ended = false); onBack() }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    this.player = player
                    useController = true
                }
            },
            modifier = Modifier.fillMaxSize(),
        )
        Row(
            Modifier
                .fillMaxWidth()
                // 状态栏下移：本机播放页是满屏的，不垫内边距时返回键会压在状态栏/刘海上
                .statusBarsPadding()
                .padding(horizontal = 8.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { recordViewing(ended = false); onBack() }) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回", tint = Color.White)
            }
            Text(
                pack?.title ?: "本机副本",
                style = McType.subheadlineSemibold,
                color = TextPrimary,
                maxLines = 1,
            )
            Spacer(Modifier.weight(1f))
        }
        Column(Modifier.align(Alignment.BottomStart).padding(16.dp)) {
            Text("本机副本 · ${McFormat.bytes(pack?.sizeBytes ?: 0)}", style = McType.caption2, color = Color.White.copy(alpha = 0.6f))
            Spacer(Modifier.height(2.dp))
        }
    }
}
