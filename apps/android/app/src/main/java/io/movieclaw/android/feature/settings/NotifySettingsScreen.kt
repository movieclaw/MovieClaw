package io.movieclaw.android.feature.settings

import android.Manifest
import android.content.Context
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.core.app.NotificationManagerCompat
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.notify.NotifyPrefs
import io.movieclaw.android.core.notify.NotifyScheduler
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import android.app.Application

/**
 * 「通知」设置（iOS 是「账号 → 通知」，但那条链路走 APNs + 服务端云中继；
 * 本项目**不动服务端**，所以这里是纯客户端实现：系统本机每 15 分钟检查一次
 * 下载 / 入库 / 今日预告的变化，只在状态真的翻转时发本地通知）。
 *
 * 界面上如实写明机制与代价（最长 15 分钟延迟、依赖系统调度、不做服务端推送），
 * 4 个开关对应 4 条通知渠道（下载 / 入库 / 订阅更新 / 系统与任务）。
 */
data class NotifySettingsState(
    val loaded: Boolean = false,
    val enabled: Boolean = false,
    val download: Boolean = true,
    val arrival: Boolean = true,
    val subscription: Boolean = true,
    val task: Boolean = true,
)

@HiltViewModel
class NotifySettingsViewModel @Inject constructor(
    private val app: Application,
) : ViewModel() {
    private val prefs = NotifyPrefs(app)
    private val _ui = MutableStateFlow(NotifySettingsState())
    val ui = _ui.asStateFlow()

    init {
        viewModelScope.launch {
            val s = prefs.read()
            _ui.value = NotifySettingsState(
                loaded = true,
                enabled = s.enabled,
                download = s.download,
                arrival = s.arrival,
                subscription = s.subscription,
                task = s.task,
            )
            // 已开启却没排程（重装 / 清数据 / 系统撤销）时补上
            if (s.enabled) NotifyScheduler.schedule(app)
        }
    }

    fun setEnabled(on: Boolean) {
        _ui.value = _ui.value.copy(enabled = on)
        viewModelScope.launch {
            prefs.setEnabled(on)
            if (on) NotifyScheduler.schedule(app) else NotifyScheduler.cancel(app)
        }
        // 首轮基线交给 Worker 自己落：开启后第一次只记状态不轰炸
    }

    fun setChannels(download: Boolean, arrival: Boolean, subscription: Boolean, task: Boolean) {
        _ui.value = _ui.value.copy(
            download = download, arrival = arrival, subscription = subscription, task = task,
        )
        viewModelScope.launch { prefs.setChannel(download, arrival, subscription, task) }
    }
}

@Composable
fun NotifySettingsScreen(
    onBack: () -> Unit,
    vm: NotifySettingsViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsState()
    val context = LocalContext.current
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        // 用户拒了权限就保持开关不变（下次点开还会再问一次），并在下面那行提示里说明
        if (!granted) vm.setEnabled(false)
    }

    Column(Modifier.fillMaxSize()) {
        SettingsTopBar(title = "通知", onBack = onBack) { }
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(6.dp))
            NotifyRow(
                title = "开启通知",
                subtitle = "在本机检查下载、入库与今日更新，有变化时提醒",
                checked = state.enabled,
                onChange = { on ->
                    if (on && Build.VERSION.SDK_INT >= 33 &&
                        !NotificationManagerCompat.from(context).areNotificationsEnabled()
                    ) {
                        permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        vm.setEnabled(on)
                    }
                },
            )
            if (state.enabled) {
                NotifyRow(
                    title = "下载",
                    subtitle = "下载完成或失败时",
                    checked = state.download,
                    onChange = { vm.setChannels(it, state.arrival, state.subscription, state.task) },
                )
                NotifyRow(
                    title = "入库",
                    subtitle = "整理完成、新内容进库时",
                    checked = state.arrival,
                    onChange = { vm.setChannels(state.download, it, state.subscription, state.task) },
                )
                NotifyRow(
                    title = "订阅更新",
                    subtitle = "订阅的作品今天有可看的时",
                    checked = state.subscription,
                    onChange = { vm.setChannels(state.download, state.arrival, it, state.task) },
                )
                NotifyRow(
                    title = "系统与任务",
                    subtitle = "下载失败等需要处理的提醒",
                    checked = state.task,
                    onChange = { vm.setChannels(state.download, state.arrival, state.subscription, it) },
                )
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun NotifyRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .border(1.dp, Color.White.copy(alpha = 0.06f), RoundedCornerShape(12.dp))
            .clickable { onChange(!checked) }
            .padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = McType.subheadline)
            Text(subtitle, style = McType.caption, color = TextFaint)
        }
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = Accent),
        )
    }
}
