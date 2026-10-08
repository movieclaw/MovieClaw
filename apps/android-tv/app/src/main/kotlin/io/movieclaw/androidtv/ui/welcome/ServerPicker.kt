package io.movieclaw.androidtv.ui.welcome

import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.tv.material3.Text
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.session.ServerDiscovery
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt

/**
 * 找服务器（TVServerPicker）：局域网自动发现 + 本机登录过的 + 手动输入。选了不测连接，直接进登录这一步。
 * 与 Apple 端的差别：局域网里找到几台就列几台（Apple 只显示第一台）。
 */
@Composable
fun ServerPicker(onPick: (ServerAddress) -> Unit) {
    val graph = LocalGraph.current
    val context = LocalContext.current.applicationContext
    val saved by graph.model.savedServers.collectAsState()
    var discovering by remember { mutableStateOf(true) }
    var found by remember { mutableStateOf<List<ServerDiscovery.Found>>(emptyList()) }
    // 加一就重新找一遍（「重新查找」）
    var round by remember { mutableIntStateOf(0) }
    var manual by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val firstSaved = remember { FocusRequester() }
    val field = remember { FocusRequester() }

    LaunchedEffect(round) {
        discovering = true
        found = emptyList()
        found = ServerDiscovery.discover(graph.http, context) { found = it }
        discovering = false
    }

    fun submitManual() {
        val address = ServerAddress.parse(manual.trim())
        if (address == null) {
            error = "地址格式不对：请填写完整地址，例如 http://192.168.0.100:3000"
        } else {
            error = null
            onPick(address)
        }
    }

    val recent = saved.filter { s -> found.none { it.address.toString() == s.origin } }
    // 系统默认的焦点是最上面那个可聚焦的：找服务器还在转圈时，是登录过的第一台服务器，否则是输入框
    InitialFocus(if (recent.isNotEmpty()) firstSaved else field)

    WelcomeCard(1400, 34) {
        Text("连接服务器", style = welcomeSerif(52))
        Text("服务器地址就是在浏览器里打开 MovieClaw 时地址栏里的那一串。", style = McType.Callout, color = McColors.Secondary)
        if (discovering) StatusLine("正在局域网里寻找 MovieClaw…", spacing = 18.pt)
        if (found.isNotEmpty()) {
            Column(Modifier.focusGroup(), verticalArrangement = Arrangement.spacedBy(16.pt)) {
                for (server in found) {
                    WelcomeButton(
                        "连接局域网里的「${server.name}」· ${server.address.fullDisplay}",
                        onClick = { onPick(server.address) },
                        icon = McIcons.Wifi,
                    )
                }
            }
        } else if (!discovering) {
            Row(horizontalArrangement = Arrangement.spacedBy(20.pt), verticalAlignment = Alignment.CenterVertically) {
                Text("没在局域网里找到服务器", style = McType.Body, color = McColors.Secondary)
                WelcomeButton("重新查找", onClick = { round++ })
            }
        }
        if (recent.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(16.pt)) {
                Text("登录过的服务器", style = McType.Headline)
                LazyRow(Modifier.focusGroup(), horizontalArrangement = Arrangement.spacedBy(24.pt)) {
                    items(recent, key = { it.origin }) { server ->
                        WelcomeButton(
                            server.origin,
                            onClick = { onPick(server.address) },
                            modifier = if (server == recent.first()) Modifier.focusRequester(firstSaved) else Modifier,
                        )
                    }
                }
            }
        }
        Row(Modifier.focusGroup(), horizontalArrangement = Arrangement.spacedBy(24.pt), verticalAlignment = Alignment.CenterVertically) {
            TvTextField(
                manual,
                { manual = it },
                "手动输入地址，例如 http://192.168.0.100:3000",
                Modifier.width(900.pt),
                focusRequester = field,
                keyboardType = KeyboardType.Uri,
                imeAction = ImeAction.Go,
                onSubmit = ::submitManual,
            )
            WelcomeButton("连接", onClick = ::submitManual, enabled = manual.isNotBlank())
        }
        error?.let { ErrorLabel(it) }
    }
}
