package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.ChannelPushConfigView
import io.movieclaw.android.core.model.OfficialChannelRequest
import io.movieclaw.android.core.model.PushChannelView
import io.movieclaw.android.core.model.PushChannelsView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * App 推送 / IM 推送（iOS `PushSettingsView` + `SettingsBPushChannels` 的对应物）。
 *
 * 接口与 iOS 同口径：
 *  - `GET /push/channels`、`PUT /push/channels/official`（官方通道开关 + 通道清单）
 *  - `GET/PUT /channels/im/push-config`（IM 推送的内容开关）
 *
 * MCP 端点、Relay 增删这类复杂表单不在这一页（后续分区/迭代），这里只做可用的开关与状态。
 */
@HiltViewModel
class PushSettingsViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val saving: Boolean = false,
        val error: String? = null,
        val channels: PushChannelsView = PushChannelsView(),
        val imConfig: ChannelPushConfigView = ChannelPushConfigView(),
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            val origin = repository.ui.value.origin
            if (origin == null) {
                _ui.value = _ui.value.copy(loading = false, error = "还没有连上服务器")
                return@launch
            }
            val api = apiFactory.forOrigin(origin)
            val channelsResult = runCatching { api.pushChannelsList().dataOrThrow() }
            val imResult = runCatching { api.channelsImPushConfigGet().dataOrThrow() }
            _ui.value = _ui.value.copy(
                loading = false,
                channels = channelsResult.getOrDefault(PushChannelsView()),
                imConfig = imResult.getOrDefault(ChannelPushConfigView()),
                error = channelsResult.exceptionOrNull()?.message
                    ?: imResult.exceptionOrNull()?.message,
            )
        }
    }

    fun setOfficial(enabled: Boolean) {
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            _ui.value = _ui.value.copy(saving = true, error = null)
            runCatching {
                apiFactory.forOrigin(origin).pushChannelsOfficialSet(OfficialChannelRequest(enabled)).dataOrThrow()
            }
                .onSuccess { v -> _ui.value = _ui.value.copy(saving = false, channels = v) }
                .onFailure { e -> _ui.value = _ui.value.copy(saving = false, error = e.message ?: "保存失败") }
        }
    }

    fun setImConfig(next: ChannelPushConfigView) {
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            _ui.value = _ui.value.copy(saving = true, error = null, imConfig = next)
            runCatching {
                apiFactory.forOrigin(origin).channelsImPushConfigUpdate(next).dataOrThrow()
            }
                .onSuccess { v -> _ui.value = _ui.value.copy(saving = false, imConfig = v) }
                .onFailure { e -> _ui.value = _ui.value.copy(saving = false, error = e.message ?: "保存失败") }
        }
    }
}

@Composable
fun PushSettingsScreen(onBack: () -> Unit, vm: PushSettingsViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.load() }

    Column(Modifier.fillMaxSize().background(Bg)) {
        SettingsTopBar(title = "App 推送 / IM 推送", onBack = onBack)
        when {
            ui.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            else -> Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (ui.error != null) {
                    Text(ui.error!!, style = McType.footnote, color = TextMuted)
                }
                // 官方通道
                // 官方通道固定为 kind=official（通道列表里可能先排自建中继）
                val official = ui.channels.channels.firstOrNull { it.kind == "official" }
                GlassCard(Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("官方推送通道", style = McType.subheadlineSemibold)
                            Spacer(Modifier.height(3.dp))
                            Text(
                                official?.let { it.name.ifBlank { it.id } } ?: "未配置",
                                style = McType.caption,
                                color = TextFaint,
                            )
                        }
                        Switch(
                            checked = official?.enabled == true,
                            enabled = !ui.saving && official != null,
                            onCheckedChange = { vm.setOfficial(it) },
                            colors = SwitchDefaults.colors(checkedTrackColor = Accent),
                        )
                    }
                }
                // IM 推送内容开关
                GlassCard(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp)) {
                        Text("IM 推送内容", style = McType.subheadlineSemibold)
                        Spacer(Modifier.height(6.dp))
                        ToggleRow(
                            title = "订阅开始下载时推送",
                            checked = ui.imConfig.pushDispatch,
                            enabled = !ui.saving,
                        ) { vm.setImConfig(ui.imConfig.copy(pushDispatch = it)) }
                        ToggleRow(
                            title = "入库完成时推送",
                            checked = ui.imConfig.pushImported,
                            enabled = !ui.saving,
                        ) { vm.setImConfig(ui.imConfig.copy(pushImported = it)) }
                    }
                }
                // 通道清单
                if (ui.channels.channels.isNotEmpty()) {
                    GlassCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(14.dp)) {
                            Text("推送通道", style = McType.subheadlineSemibold)
                            Spacer(Modifier.height(8.dp))
                            ui.channels.channels.forEach { ch: PushChannelView ->
                                Row(Modifier.padding(vertical = 5.dp)) {
                                    Column(Modifier.weight(1f)) {
                                        Text(
                                            ch.name.ifBlank { ch.id },
                                            style = McType.sub,
                                            color = TextPrimary,
                                        )
                                        if (ch.statusText.isNotBlank()) {
                                            Text(ch.statusText, style = McType.caption, color = TextFaint, lineHeight = 15.sp)
                                        }
                                    }
                                    Text(
                                        if (ch.enabled) "已启用" else "未启用",
                                        style = McType.caption,
                                        color = if (ch.enabled) Accent else TextFaint,
                                    )
                                }
                            }
                        }
                    }
                }
                Text(
                    "Cloud 连接状态：${ui.channels.cloudState}",
                    style = McType.caption,
                    color = TextFaint,
                )
            }
        }
    }
}

@Composable
private fun ToggleRow(title: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            enabled = enabled,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = Accent),
        )
    }
}
