package io.movieclaw.androidtv.ui.player

import androidx.compose.runtime.Composable
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.shell.PlayRequest

/** 播放器（TVPlayerScreen）——待实现 */
@Composable
fun PlayerScreen(request: PlayRequest, onClose: () -> Unit) = StateView(McIcons.Play, "播放 ${request.mediaItemId}", action = "返回", onAction = onClose)
