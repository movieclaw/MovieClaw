package io.movieclaw.androidtv.ui.update

import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import io.movieclaw.androidtv.AccountSession
import io.movieclaw.androidtv.BuildConfig
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.components.glass
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.welcome.InitialFocus
import io.movieclaw.androidtv.ui.welcome.WelcomeButton

/** 更新弹窗（电视）：发现新版 / 下载进度 / 安装失败 / 已是最新。焦点默认落在主按钮上，返回键关掉 */
@Composable
fun TvUpdateDialog(update: TvAppUpdate, session: AccountSession) {
    val state by update.state.collectAsState()
    val context = LocalContext.current
    val current = "${BuildConfig.VERSION_NAME}（${BuildConfig.VERSION_CODE}）"
    when (val s = state) {
        TvAppUpdate.State.Idle -> Unit
        TvAppUpdate.State.Checking -> Frame(update::dismiss, "检查更新", "正在问服务器有没有新版本…") {
            Primary("取消", update::dismiss)
        }
        is TvAppUpdate.State.UpToDate -> Frame(update::dismiss, "已是最新版本", "当前 $current，最新发布 ${s.latest.version}。") {
            Primary("好", update::dismiss)
        }
        is TvAppUpdate.State.Available -> {
            val body = buildString {
                append("当前 $current · 安装包 ${"%.1f".format(s.release.size / 1_048_576.0)} MB\n\n")
                if (s.signatureMatches == false) {
                    append("新版的签名和这台电视上装的不同（装的可能是自己编的测试包），系统不允许直接覆盖，需要先卸载再装，会清掉登录和设置。\n\n")
                }
                append(update.summary(s.release))
            }
            Frame(update::dismiss, "发现新版本 ${s.release.version}", body) {
                if (s.signatureMatches != false) {
                    if (update.canInstall) {
                        Primary("立即更新") { update.startUpdate(session, s.offer) }
                    } else {
                        Primary("允许安装应用") { context.startActivity(update.installPermissionIntent()) }
                        WelcomeButton("立即更新", onClick = { update.startUpdate(session, s.offer) }, style = McType.Callout)
                    }
                }
                WelcomeButton("跳过这一版", onClick = { update.skip(s.release) }, style = McType.Callout)
                WelcomeButton("以后再说", onClick = update::dismiss, style = McType.Callout)
            }
        }
        is TvAppUpdate.State.Downloading -> Frame(update::dismiss, "正在下载 ${s.release.version}", (if (s.fromServer) "官网连不上，改经你的服务器下载" else "从官网下载") + " · ${(s.progress * 100).toInt()}%", progress = s.progress) {
            Primary("取消", update::dismiss)
        }
        is TvAppUpdate.State.Installing -> Frame(update::dismiss, "正在安装 ${s.release.version}", "请在系统弹窗里确认安装。装好后 App 会自动关闭，再打开就是新版。") {
            Primary("好", update::dismiss)
        }
        is TvAppUpdate.State.Failed -> Frame(update::dismiss, if (s.offer == null) "检查更新失败" else "更新没有完成", s.message) {
            s.offer?.let { offer -> Primary("重试") { update.startUpdate(session, offer) } }
            if (s.offer == null) Primary("关闭", update::dismiss) else WelcomeButton("关闭", onClick = update::dismiss, style = McType.Callout)
        }
    }
}

@Composable
private fun Frame(
    onDismiss: () -> Unit,
    title: String,
    body: String,
    progress: Float? = null,
    buttons: @Composable () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(
                Modifier.widthIn(max = 1000.pt).glass().padding(60.pt).focusGroup(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(24.pt),
            ) {
                Text(title, style = McType.Title3.copy(fontWeight = FontWeight.SemiBold))
                Text(body, style = McType.Callout, color = McColors.Secondary, textAlign = TextAlign.Center)
                progress?.let { p ->
                    Box(Modifier.fillMaxWidth().height(10.pt).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.15f))) {
                        Box(Modifier.fillMaxWidth(p.coerceIn(0f, 1f)).height(10.pt).background(Color.White))
                    }
                }
                Row(Modifier.padding(top = 12.pt), horizontalArrangement = Arrangement.spacedBy(24.pt)) { buttons() }
            }
        }
    }
}

/** 主按钮：弹窗出现时焦点落在它上面 */
@Composable
private fun Primary(title: String, onClick: () -> Unit) {
    val focus = remember { FocusRequester() }
    InitialFocus(focus)
    WelcomeButton(title, onClick = onClick, style = McType.Callout, modifier = Modifier.focusRequester(focus))
}
