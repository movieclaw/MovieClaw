package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.draw.clip
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
import io.movieclaw.android.core.model.CloudSettingsRequest
import io.movieclaw.android.core.model.CloudStatusView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * MovieClaw Cloud（iOS `CloudSettingsView` 的对应物）。
 *
 * 接口同 iOS：`GET /cloud`、`POST /cloud/renew`、`PUT /cloud/settings`（统计上报开关）。
 * 配对（`/cloud/pairing`）与断开（`/cloud/disconnect`）涉及一次性配对码与二次确认，
 * 本版不做，页面明确提示去网页端完成。
 */
@HiltViewModel
class CloudSettingsViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val busy: Boolean = false,
        val error: String? = null,
        val status: CloudStatusView = CloudStatusView(),
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui.asStateFlow()

    private fun api() = repository.ui.value.origin?.let { apiFactory.forOrigin(it) }

    fun load() {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, error = null)
            val api = api()
            if (api == null) {
                _ui.value = _ui.value.copy(loading = false, error = "还没有连上服务器")
                return@launch
            }
            runCatching { api.cloudStatus().dataOrThrow() }
                .onSuccess { s -> _ui.value = _ui.value.copy(loading = false, status = s) }
                .onFailure { e -> _ui.value = _ui.value.copy(loading = false, error = e.message ?: "读取失败") }
        }
    }

    fun renew() {
        viewModelScope.launch {
            val api = api() ?: return@launch
            _ui.value = _ui.value.copy(busy = true, error = null)
            runCatching { api.cloudRenew().dataOrThrow() }
                .onSuccess { s -> _ui.value = _ui.value.copy(busy = false, status = s) }
                .onFailure { e -> _ui.value = _ui.value.copy(busy = false, error = e.message ?: "续期失败") }
        }
    }

    fun setReportStats(on: Boolean) {
        viewModelScope.launch {
            val api = api() ?: return@launch
            _ui.value = _ui.value.copy(busy = true, error = null)
            runCatching { api.cloudSettingsSet(CloudSettingsRequest(on)).dataOrThrow() }
                .onSuccess { s -> _ui.value = _ui.value.copy(busy = false, status = s) }
                .onFailure { e -> _ui.value = _ui.value.copy(busy = false, error = e.message ?: "保存失败") }
        }
    }
}

@Composable
fun CloudSettingsScreen(onBack: () -> Unit, vm: CloudSettingsViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.load() }

    Column(Modifier.fillMaxSize().background(Bg)) {
        SettingsTopBar(title = "MovieClaw Cloud", onBack = onBack)
        when {
            ui.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            else -> Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (ui.error != null) Text(ui.error!!, style = McType.footnote, color = TextMuted)

                val s = ui.status
                GlassCard(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp)) {
                        Text(stateLabel(s.state), style = McType.subheadlineSemibold, color = TextPrimary)
                        if (!s.healthMessage.isNullOrBlank()) {
                            Spacer(Modifier.height(4.dp))
                            Text(s.healthMessage, style = McType.caption, color = TextFaint, lineHeight = 16.sp)
                        }
                        if (s.cloudUrl.isNotBlank()) {
                            Spacer(Modifier.height(6.dp))
                            Text(s.cloudUrl, style = McType.caption, color = TextMuted)
                        }
                    }
                }

                GlassCard(Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("上报使用统计", style = McType.subheadlineSemibold)
                            Spacer(Modifier.height(3.dp))
                            Text(
                                s.lastReportAt?.let { "上次上报：$it" } ?: "尚未上报",
                                style = McType.caption,
                                color = TextFaint,
                            )
                        }
                        Switch(
                            checked = s.reportStats,
                            enabled = !ui.busy,
                            onCheckedChange = { vm.setReportStats(it) },
                            colors = SwitchDefaults.colors(checkedTrackColor = Accent),
                        )
                    }
                }

                if (s.state == "connected") {
                    Text(
                        if (ui.busy) "续期中…" else "续期连接",
                        style = McType.caption,
                        color = if (ui.busy) TextFaint else Accent,
                        modifier = Modifier
                            .clip(androidx.compose.foundation.shape.RoundedCornerShape(999.dp))
                            .background(androidx.compose.ui.graphics.Color.White.copy(alpha = 0.06f))
                            .clickable(enabled = !ui.busy) { vm.renew() }
                            .padding(horizontal = 12.dp, vertical = 7.dp),
                    )
                }

                Text(
                    "配对、断开连接与通知开关仍然在网页端「设置 → MovieClaw Cloud」里完成。",
                    style = McType.caption,
                    color = TextFaint,
                    lineHeight = 16.sp,
                )
            }
        }
    }
}

private fun stateLabel(state: String): String = when (state) {
    "connected" -> "已连接 MovieClaw Cloud"
    "pairing" -> "正在配对…"
    else -> "未连接"
}
