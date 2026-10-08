package io.movieclaw.android.feature.account

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Accent2
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.FeedbackBus
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.SurfaceRaised
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.session.SavedServer
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

@HiltViewModel
class AccountSwitcherViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val feedback: FeedbackBus,
) : ViewModel() {

    val servers = repository.servers
    val current = repository.ui

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    fun switchTo(origin: String, username: String) {
        if (_busy.value) return
        _busy.value = true
        viewModelScope.launch {
            repository.switchAccount(origin, username)
            _busy.value = false
        }
    }

    fun remove(origin: String, username: String) {
        viewModelScope.launch {
            repository.removeAccount(origin, username)
            feedback.success("已从本机移除「$username」")
        }
    }

    fun logoutAll() {
        viewModelScope.launch {
            repository.logoutAll()
            feedback.success("已退出全部账号")
        }
    }
}

/** 账号切换:按服务器分组,点一下即切换(不用重新输密码) */
@Composable
fun AccountSwitcherScreen(
    onBack: () -> Unit,
    onAddAccount: () -> Unit,
    vm: AccountSwitcherViewModel = hiltViewModel(),
) {
    val servers by vm.servers.collectAsStateWithLifecycle()
    val current by vm.current.collectAsStateWithLifecycle()
    val busy by vm.busy.collectAsStateWithLifecycle()
    var confirmLogoutAll by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp, vertical = 4.dp),
        ) {
            McNavButton(
                icon = Icons.AutoMirrored.Rounded.ArrowBack,
                contentDescription = "返回",
                onClick = onBack,
            )
            Text("切换账号", style = McType.headline)
        }

        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            Text(
                "本机已登录的账号,点击即可切换,不用再输密码。",
                style = McType.caption,
                color = TextFaint,
                modifier = Modifier.padding(bottom = 12.dp),
            )

            val onlyOneServer = servers.size <= 1
            servers.forEach { server ->
                if (!onlyOneServer) {
                    Text(
                        server.origin.removePrefix("https://").removePrefix("http://"),
                        style = McType.caption,
                        color = TextFaint,
                        modifier = Modifier.padding(top = 6.dp, bottom = 6.dp),
                    )
                }
                server.accounts.forEach { account ->
                    AccountRow(
                        server = server,
                        account = account,
                        isCurrent = server.origin == current.origin &&
                            account.username == current.session?.username,
                        busy = busy,
                        onSwitch = { vm.switchTo(server.origin, account.username) },
                        onRemove = { vm.remove(server.origin, account.username) },
                    )
                    Spacer(Modifier.height(8.dp))
                }
            }

            Spacer(Modifier.height(8.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(SurfaceRaised)
                    .border(1.dp, LineColor, RoundedCornerShape(12.dp))
                    .clickable(onClick = onAddAccount)
                    .padding(14.dp),
            ) {
                Icon(Icons.Rounded.PersonAdd, contentDescription = null, tint = AccentStrong, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(12.dp))
                Text("添加账号", style = McType.subheadline)
            }
            Spacer(Modifier.height(8.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .clickable { confirmLogoutAll = true }
                    .padding(14.dp),
            ) {
                Icon(Icons.AutoMirrored.Rounded.Logout, contentDescription = null, tint = Danger, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(12.dp))
                Text("退出全部账号", style = McType.subheadline, color = Danger)
            }
            Spacer(Modifier.height(10.dp))
            Text(
                "添加账号时改一下服务器地址,就能登录到另一台 MovieClaw;" +
                    "要撤销某台设备上的登录凭证,请到「设置 → 设备管理」。",
                style = McType.caption2,
                color = TextFaint,
                lineHeight = 17.sp,
            )
            Spacer(Modifier.height(30.dp))
        }
    }

    if (confirmLogoutAll) {
        AlertDialog(
            onDismissRequest = { confirmLogoutAll = false },
            title = { Text("退出全部账号?") },
            text = {
                Text(
                    "本机将不再保留任何登录状态,账号本身不受影响;下次使用需要重新输入密码。",
                    style = McType.footnote,
                    lineHeight = 20.sp,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmLogoutAll = false
                    vm.logoutAll()
                }) { Text("退出", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { confirmLogoutAll = false }) { Text("取消") } },
        )
    }
}

@Composable
private fun AccountRow(
    server: SavedServer,
    account: io.movieclaw.android.core.session.SavedAccount,
    isCurrent: Boolean,
    busy: Boolean,
    onSwitch: () -> Unit,
    onRemove: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (isCurrent) AccentSoft else SurfaceRaised)
            .border(1.dp, if (isCurrent) Accent.copy(alpha = 0.35f) else LineColor, RoundedCornerShape(12.dp))
            .clickable(enabled = !isCurrent && !busy && !account.expired, onClick = onSwitch)
            .padding(14.dp),
    ) {
        Box(
            Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(Brush.verticalGradient(listOf(AccentStrong, Accent2))),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                (account.nickname ?: account.username).take(1).uppercase(),
                style = McType.subheadlineSemibold,
                color = Color(0xFF0A0E12),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    account.nickname ?: account.username,
                    style = McType.subheadlineSemibold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (isCurrent) {
                    Spacer(Modifier.width(6.dp))
                    Icon(Icons.Rounded.Check, contentDescription = null, tint = Accent, modifier = Modifier.size(14.dp))
                    Text("当前", style = McType.caption, color = Accent)
                }
            }
            Text(
                "@${account.username} · ${if (account.role == "admin") "超级管理员" else "成员"}",
                style = McType.caption,
                color = TextMuted,
            )
            if (account.expired) {
                Text("登录已失效,点「添加账号」重新输入密码", style = McType.caption2, color = Warning)
            }
        }
        if (!isCurrent) {
            IconButton(onClick = onRemove) {
                Icon(Icons.Rounded.Close, contentDescription = "从本机移除", tint = TextFaint, modifier = Modifier.size(16.dp))
            }
        }
    }
}
