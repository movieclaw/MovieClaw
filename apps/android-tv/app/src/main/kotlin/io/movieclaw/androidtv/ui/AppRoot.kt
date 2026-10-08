package io.movieclaw.androidtv.ui

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.AccountSession
import io.movieclaw.androidtv.AppGraph
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.core.session.AppModel
import io.movieclaw.androidtv.ui.components.LocalServer
import io.movieclaw.androidtv.ui.shell.MainShell
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McTheme
import io.movieclaw.androidtv.ui.welcome.WelcomeRoot

/**
 * 根（TVRootView）：按登录阶段切换。`Ready` 时主界面按「服务器#用户名」做 key——换账号（含换服务器）整棵重建。
 * 阶段之间交叉淡入。
 */
@Composable
fun AppRoot(graph: AppGraph, args: LaunchArgs) {
    val model = graph.model
    val phase by model.phase.collectAsState()
    LaunchedEffect(Unit) {
        model.restore(args.server, args.username, args.password)
        model.revalidate()
        model.retryRevocations()
    }
    McTheme {
        CompositionLocalProvider(LocalGraph provides graph) {
            Box(Modifier.fillMaxSize().background(McColors.Background)) {
                Crossfade(phase is AppModel.Phase.Ready, label = "phase") { ready ->
                    val current = phase
                    when {
                        ready && current is AppModel.Phase.Ready -> {
                            val server = model.server ?: return@Crossfade
                            val token = model.token ?: return@Crossfade
                            key("$server#${current.session.username}") {
                                val session = remember(current.session) { AccountSession(server, token, current.session, model.api(server, token)) }
                                CompositionLocalProvider(LocalSession provides session, LocalServer provides server) {
                                    MainShell(args)
                                }
                            }
                        }
                        current is AppModel.Phase.Launching ->
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Spinner() }
                        else -> WelcomeRoot(current)
                    }
                }
            }
        }
    }
}
