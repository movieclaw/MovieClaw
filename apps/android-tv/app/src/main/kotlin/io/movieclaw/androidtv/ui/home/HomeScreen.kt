package io.movieclaw.androidtv.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Button
import androidx.tv.material3.Text
import io.movieclaw.androidtv.AccountSession
import io.movieclaw.androidtv.core.model.generated.LibraryItemView
import io.movieclaw.androidtv.core.model.generated.UpNextItemView
import io.movieclaw.androidtv.core.playback.PlaybackTarget
import io.movieclaw.androidtv.ui.McColors
import io.movieclaw.androidtv.ui.McMetrics
import io.movieclaw.androidtv.ui.components.MediaCard

private data class LibraryRow(val name: String, val items: List<LibraryItemView>)

private data class HomeData(val upNext: List<UpNextItemView>, val rows: List<LibraryRow>)

/**
 * A0 的首页：「接下来继续」+ 各媒体库最近的条目，够选片起播。跟着焦点走的大图区、
 * 用户自定义的行、详情页在 A1（docs/design/androidtv-app.md §2）。
 */
@Composable
fun HomeScreen(session: AccountSession, onPlay: (PlaybackTarget) -> Unit, onSignOut: () -> Unit) {
    var data by remember { mutableStateOf<HomeData?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val firstCard = remember { FocusRequester() }

    LaunchedEffect(session) {
        try {
            val upNext = session.api.playbackUpNext(limit = 20).items
            val rows = session.api.libraryList(scope = "visible").filter { it.viewerAccess }.map { library ->
                LibraryRow(library.name, session.api.libraryItemsList(library.id, sort = "added_at", order = "desc", limit = 40))
            }
            data = HomeData(upNext, rows.filter { it.items.isNotEmpty() })
        } catch (e: Exception) {
            error = e.message ?: "加载失败"
        }
    }
    LaunchedEffect(data) { if (data != null) runCatching { firstCard.requestFocus() } }

    val loaded = data
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.padding(horizontal = McMetrics.SafeHorizontal, vertical = McMetrics.SafeVertical),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("${session.account.nickname} · ${session.server}", color = McColors.TextSecondary, fontSize = 16.sp)
            Spacer(Modifier.width(24.dp))
            Button(onClick = onSignOut) { Text("退出登录") }
        }
        when {
            error != null -> Text(error!!, color = McColors.Danger, modifier = Modifier.padding(McMetrics.SafeHorizontal))
            loaded == null -> Text("正在加载……", color = McColors.TextSecondary, modifier = Modifier.padding(McMetrics.SafeHorizontal))
            else -> {
                // 进来时焦点落在第一行的第一张卡上
                val firstKey = loaded.upNext.firstOrNull()?.let { "u${it.mediaItemId}" }
                    ?: loaded.rows.firstOrNull()?.items?.firstOrNull()?.let { "i${it.mediaItemId}" }
                fun focusFor(key: String) = if (key == firstKey) Modifier.focusRequester(firstCard) else Modifier
                LazyColumn(
                    contentPadding = PaddingValues(bottom = 48.dp),
                    verticalArrangement = Arrangement.spacedBy(28.dp),
                ) {
                    if (loaded.upNext.isNotEmpty()) {
                        item("up-next") {
                            Shelf("接下来继续") {
                                items(loaded.upNext, key = { "u${it.mediaItemId}" }) { item ->
                                    MediaCard(
                                        server = session.server,
                                        imageUrl = item.episodeStillUrl ?: item.backdropUrl ?: item.posterUrl,
                                        title = item.title,
                                        width = 300.dp,
                                        aspect = 16f / 9f,
                                        progress = item.progressPercent?.div(100f),
                                        onClick = {
                                            onPlay(PlaybackTarget(item.mediaItemId, item.seasonNumber, item.episodeNumber, title = item.title))
                                        },
                                        modifier = focusFor("u${item.mediaItemId}"),
                                    )
                                }
                            }
                        }
                    }
                    loaded.rows.forEach { row ->
                        item(row.name) {
                            Shelf(row.name) {
                                items(row.items, key = { "i${it.mediaItemId}" }) { item ->
                                    val landscape = item.primaryAspect >= 1.0
                                    MediaCard(
                                        server = session.server,
                                        imageUrl = if (landscape) item.backdropUrl ?: item.posterUrl else item.posterUrl,
                                        title = item.title,
                                        width = if (landscape) 300.dp else 150.dp,
                                        aspect = if (landscape) 16f / 9f else 2f / 3f,
                                        onClick = { onPlay(PlaybackTarget(item.mediaItemId, title = item.title)) },
                                        modifier = focusFor("i${item.mediaItemId}"),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Shelf(title: String, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column {
        Text(
            title,
            color = McColors.TextPrimary,
            fontSize = 22.sp,
            modifier = Modifier.padding(start = McMetrics.SafeHorizontal, bottom = 12.dp),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = McMetrics.SafeHorizontal),
            horizontalArrangement = Arrangement.spacedBy(20.dp),
            content = content,
        )
    }
}
