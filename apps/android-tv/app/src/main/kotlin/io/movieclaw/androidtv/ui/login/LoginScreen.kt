package io.movieclaw.androidtv.ui.login

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Button
import androidx.tv.material3.Text
import io.movieclaw.androidtv.AppGraph
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.UnreachableException
import io.movieclaw.androidtv.ui.LaunchArgs
import io.movieclaw.androidtv.ui.McColors
import io.movieclaw.androidtv.ui.components.McTextField
import kotlinx.coroutines.launch

/**
 * 账号密码登录（A0）。扫码登录与局域网发现在 A1 加上，并成为默认（docs/design/androidtv-app.md §2）。
 */
@Composable
fun LoginScreen(graph: AppGraph, args: LaunchArgs) {
    var server by remember { mutableStateOf(args.server ?: graph.accounts.accounts.value.lastOrNull()?.origin.orEmpty()) }
    var username by remember { mutableStateOf(args.username.orEmpty()) }
    var password by remember { mutableStateOf(args.password.orEmpty()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val first = remember { FocusRequester() }

    fun submit() {
        val address = ServerAddress.parse(server) ?: run { error = "服务器地址填得不对"; return }
        if (username.isBlank() || password.isEmpty()) { error = "请填写用户名和密码"; return }
        busy = true
        error = null
        scope.launch {
            try {
                graph.activate(graph.login.passwordLogin(address, username, password))
            } catch (e: UnreachableException) {
                error = "连不上 $address，检查一下地址和网络"
            } catch (e: Exception) {
                error = e.message ?: "登录失败"
            } finally {
                busy = false
            }
        }
    }

    LaunchedEffect(Unit) {
        if (args.server != null && args.username != null && args.password != null) submit() else first.requestFocus()
    }

    Column(
        Modifier.fillMaxSize().padding(horizontal = 96.dp, vertical = 64.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.Start,
    ) {
        Text("登录 MovieClaw", color = McColors.TextPrimary, fontSize = 34.sp)
        Spacer(Modifier.height(32.dp))
        McTextField("服务器地址", server, { server = it }, Modifier.focusRequester(first), keyboardType = KeyboardType.Uri)
        Spacer(Modifier.height(20.dp))
        McTextField("用户名", username, { username = it })
        Spacer(Modifier.height(20.dp))
        McTextField("密码", password, { password = it }, password = true, imeAction = ImeAction.Done)
        Spacer(Modifier.height(28.dp))
        Button(onClick = ::submit, enabled = !busy) { Text(if (busy) "正在登录……" else "登录") }
        error?.let {
            Spacer(Modifier.height(16.dp))
            Text(it, color = McColors.Danger, fontSize = 16.sp)
        }
    }
}
