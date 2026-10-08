package io.movieclaw.androidtv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import io.movieclaw.androidtv.AppGraph
import io.movieclaw.androidtv.core.playback.PlaybackTarget
import io.movieclaw.androidtv.ui.home.HomeScreen
import io.movieclaw.androidtv.ui.login.LoginScreen
import io.movieclaw.androidtv.ui.player.PlayerScreen

/** 导航栈里的页面。一期只有这几个；导航抽屉（账号 / 搜索 / 首页）在 A1 套到首页外面。 */
sealed interface Screen {
    data object Home : Screen
    data class Player(val target: PlaybackTarget) : Screen
}

@Composable
fun AppRoot(graph: AppGraph, args: LaunchArgs) {
    McTheme {
        Box(Modifier.fillMaxSize().background(McColors.Background)) {
            val session by graph.session.collectAsState()
            val current = session
            if (current == null) {
                LoginScreen(graph, args)
            } else {
                // 换账号 = 整棵导航树重建（docs/design/androidtv-app.md §2「谁在看」）
                androidx.compose.runtime.key(current.account.id) {
                    val backStack = remember { mutableStateListOf<Screen>(Screen.Home) }
                    LaunchedEffect(Unit) {
                        args.playMediaItemId?.let { backStack += Screen.Player(PlaybackTarget(mediaItemId = it)) }
                    }
                    // 自己管的导航栈：Navigation3 要 minSdk 24，而这里的需求就是一个栈加返回键。
                    // 每个页面的可保存状态按栈位保留，压栈再返回时滚动位置不丢
                    val saveable = rememberSaveableStateHolder()
                    val top = backStack.last()
                    BackHandler(enabled = backStack.size > 1) { backStack.removeAt(backStack.lastIndex) }
                    saveable.SaveableStateProvider("${backStack.lastIndex}:$top") {
                        when (top) {
                            Screen.Home -> HomeScreen(
                                current,
                                onPlay = { backStack += Screen.Player(it) },
                                onSignOut = graph::signOut,
                            )
                            is Screen.Player -> PlayerScreen(graph, current, top.target, onExit = {
                                if (backStack.lastOrNull() == top) backStack.removeAt(backStack.lastIndex)
                            })
                        }
                    }
                }
            }
        }
    }
}
