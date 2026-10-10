package io.movieclaw.android.feature.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.playback.PlayTarget
import kotlinx.coroutines.CancellationException

@Composable
internal fun PlayerEpisodePicker(
    target: PlayTarget,
    loadSeasons: suspend (PlayTarget) -> List<Int>,
    loadEpisodes: suspend (PlayTarget, Int) -> List<EpisodeView>,
    onDismiss: () -> Unit,
    onSelect: (Int, EpisodeView) -> Unit,
) {
    var seasons by remember(target) { mutableStateOf<List<Int>?>(null) }
    var season by remember(target) { mutableIntStateOf(target.seasonNumber) }
    var episodes by remember(target, season) { mutableStateOf<List<EpisodeView>?>(null) }
    var failed by remember(target, season) { mutableStateOf(false) }
    var retry by remember { mutableIntStateOf(0) }
    LaunchedEffect(target, season, retry) {
        failed = false
        episodes = null
        try {
            if (seasons == null) seasons = loadSeasons(target)
            episodes = loadEpisodes(target, season)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            failed = true
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF17191F),
        title = { Text("选集", color = Color.White, style = McType.headline) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                LazyRow(
                    state = rememberLazyListState(initialFirstVisibleItemIndex = seasons.orEmpty().indexOf(target.seasonNumber).coerceAtLeast(0)),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(seasons.orEmpty(), key = { it }) { number ->
                        Text(
                            "第 $number 季",
                            color = if (number == season) Accent else Color.White,
                            style = McType.footnote,
                            modifier = Modifier.clip(RoundedCornerShape(12.dp))
                                .background(Color.White.copy(alpha = 0.08f))
                                .clickable { season = number }
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                        )
                    }
                }
                when {
                    failed -> TextButton(onClick = { retry++ }) { Text("加载失败，点击重试", color = Accent) }
                    episodes == null -> Box(Modifier.fillMaxWidth().heightIn(min = 96.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = Accent)
                    }
                    episodes.orEmpty().isEmpty() -> Text("本季暂无剧集", color = Color.White)
                    else -> LazyVerticalGrid(
                        columns = GridCells.Adaptive(64.dp),
                        state = rememberLazyGridState(initialFirstVisibleItemIndex = if (season == target.seasonNumber)
                            episodes.orEmpty().indexOfFirst { it.episodeNumber == target.episodeNumber }.coerceAtLeast(0) else 0),
                        modifier = Modifier.fillMaxWidth().heightIn(max = 180.dp),
                        contentPadding = PaddingValues(2.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        items(episodes.orEmpty(), key = { it.episodeNumber }) { episode ->
                            val current = season == target.seasonNumber && episode.episodeNumber == target.episodeNumber
                            Box(
                                modifier = Modifier.clip(RoundedCornerShape(10.dp))
                                    .background(if (current) Accent.copy(alpha = 0.22f) else Color.White.copy(alpha = 0.08f))
                                    .clickable(enabled = episode.owned && !current) { onSelect(season, episode) }
                                    .padding(vertical = 14.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    "${episode.episodeNumber}", style = McType.footnote,
                                    color = when { current -> Accent; episode.owned -> Color.White; else -> Color.White.copy(alpha = 0.3f) },
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("关闭", color = Color.White) } },
    )
}
