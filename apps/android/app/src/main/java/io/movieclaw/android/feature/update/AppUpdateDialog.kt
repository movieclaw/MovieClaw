package io.movieclaw.android.feature.update

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.network.BuildInfo

/** 更新弹窗：发现新版 / 下载进度 / 安装失败 / 已是最新（手动检查时） */
@Composable
fun AppUpdateDialog(controller: AppUpdateController) {
    val state by controller.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    when (val s = state) {
        AppUpdateController.State.Idle -> Unit
        AppUpdateController.State.Checking -> AlertDialog(
            onDismissRequest = controller::dismiss,
            title = { Text("检查更新") },
            text = { Text("正在问服务器有没有新版本…", style = McType.subheadline, color = TextMuted) },
            confirmButton = { TextButton(onClick = controller::dismiss) { Text("取消") } },
        )
        is AppUpdateController.State.UpToDate -> AlertDialog(
            onDismissRequest = controller::dismiss,
            title = { Text("已是最新版本") },
            text = { Text("当前 ${BuildInfo.DISPLAY_VERSION}，最新发布 ${s.latest.version}。", style = McType.subheadline, color = TextMuted) },
            confirmButton = { TextButton(onClick = controller::dismiss) { Text("好", color = Accent) } },
        )
        is AppUpdateController.State.Available -> AlertDialog(
            onDismissRequest = controller::dismiss,
            title = { Text("发现新版本 ${s.release.version}") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text("当前 ${BuildInfo.DISPLAY_VERSION} · 安装包 ${"%.1f".format(s.release.size / 1_048_576.0)} MB", style = McType.caption, color = TextMuted)
                    if (s.signatureMatches == false) {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            "新版的签名和本机这份不同（本机装的可能是自己编的测试包），系统不允许直接覆盖，需要先卸载再装，会清掉登录和设置。",
                            style = McType.caption,
                            color = io.movieclaw.android.core.designsystem.Warning,
                        )
                    }
                    Spacer(Modifier.height(10.dp))
                    Text(controller.summary(s.release), style = McType.subheadline)
                }
            },
            confirmButton = {
                if (s.signatureMatches == false) {
                    TextButton(onClick = {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(s.release.releaseUrl)))
                        controller.dismiss()
                    }) { Text("打开发布页", color = Accent) }
                } else if (!controller.canInstall) {
                    TextButton(onClick = { context.startActivity(controller.installPermissionIntent()) }) {
                        Text("允许安装应用", color = Accent)
                    }
                    TextButton(onClick = { controller.startUpdate(s.offer) }) { Text("立即更新", color = Accent) }
                } else {
                    TextButton(onClick = { controller.startUpdate(s.offer) }) { Text("立即更新", color = Accent) }
                }
            },
            dismissButton = {
                TextButton(onClick = { controller.skip(s.release) }) { Text("跳过这一版", color = TextMuted) }
                TextButton(onClick = controller::dismiss) { Text("以后再说", color = TextMuted) }
            },
        )
        is AppUpdateController.State.Downloading -> AlertDialog(
            onDismissRequest = {},
            title = { Text("正在下载 ${s.release.version}") },
            text = {
                Column {
                    LinearProgressIndicator(progress = { s.progress }, modifier = Modifier.fillMaxWidth(), color = Accent)
                    Spacer(Modifier.height(8.dp))
                    Text("${(s.progress * 100).toInt()}% · " + if (s.fromServer) "官网连不上，改经你的服务器下载" else "从官网下载", style = McType.caption, color = TextMuted)
                }
            },
            confirmButton = { TextButton(onClick = controller::dismiss) { Text("取消") } },
        )
        is AppUpdateController.State.Installing -> AlertDialog(
            onDismissRequest = controller::dismiss,
            title = { Text("正在安装 ${s.release.version}") },
            text = { Text("请在系统弹窗里确认安装。装好后 App 会自动关闭，再打开就是新版。", style = McType.subheadline, color = TextMuted) },
            confirmButton = { TextButton(onClick = controller::dismiss) { Text("好", color = Accent) } },
        )
        is AppUpdateController.State.Failed -> AlertDialog(
            onDismissRequest = controller::dismiss,
            title = { Text(if (s.offer == null) "检查更新失败" else "更新没有完成") },
            text = { Text(s.message, style = McType.subheadline, color = TextMuted) },
            confirmButton = {
                s.offer?.let { offer -> TextButton(onClick = { controller.startUpdate(offer) }) { Text("重试", color = Accent) } }
                TextButton(onClick = controller::dismiss) { Text("关闭") }
            },
        )
    }
}
