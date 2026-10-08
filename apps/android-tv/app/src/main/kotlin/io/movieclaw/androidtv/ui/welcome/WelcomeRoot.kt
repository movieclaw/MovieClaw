package io.movieclaw.androidtv.ui.welcome

import androidx.compose.runtime.Composable
import io.movieclaw.androidtv.core.session.AppModel
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.StateView

/** 欢迎 / 登录（TVWelcomeView）——待实现 */
@Composable
fun WelcomeRoot(phase: AppModel.Phase) = StateView(McIcons.Server, "连接服务器", message = phase.toString())
