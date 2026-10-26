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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
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
import io.movieclaw.android.core.model.WebhookConfigPayload
import io.movieclaw.android.core.model.WebhookConfigView
import io.movieclaw.android.core.model.WebhookDeliveryView
import io.movieclaw.android.core.model.WebhookEndpointPayload
import io.movieclaw.android.core.model.WebhookEndpointView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Webhook（iOS `WebhookSettingsView` 的对应物）：端点清单 + 每个端点的最近投递 + 测试发送。
 *
 * 接口同 iOS：`GET /webhook`、`POST /webhook/endpoints/{id}/test`、
 * `GET /webhook/endpoints/{id}/deliveries`。
 * 端点的增删改（`PUT /webhook` 整份保存、轮换 secret）仍是复杂表单，未做，页面上标注去网页端。
 */
@HiltViewModel
class WebhookSettingsViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val testing: String? = null,
        val saving: Boolean = false,
        val error: String? = null,
        val config: WebhookConfigView = WebhookConfigView(),
        val deliveries: Map<String, List<WebhookDeliveryView>> = emptyMap(),
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
            runCatching { api.webhookShow().dataOrThrow() }
                .onSuccess { c -> _ui.value = _ui.value.copy(loading = false, config = c) }
                .onFailure { e -> _ui.value = _ui.value.copy(loading = false, error = e.message ?: "读取失败") }
        }
    }

    /** 保存整体配置（总开关/端点启停都走这里，服务端按 id 保留 secret） */
    private fun save(next: WebhookConfigView) {
        viewModelScope.launch {
            val api = api() ?: return@launch
            _ui.value = _ui.value.copy(saving = true, error = null)
            runCatching { api.webhookSet(next.toPayload()).dataOrThrow() }
                .onSuccess { c -> _ui.value = _ui.value.copy(saving = false, config = c) }
                .onFailure { e -> _ui.value = _ui.value.copy(saving = false, error = e.message ?: "保存失败") }
        }
    }

    fun setEnabled(on: Boolean) = save(_ui.value.config.copy(enabled = on))

    fun setEndpointEnabled(id: String, on: Boolean) = save(
        _ui.value.config.copy(
            endpoints = _ui.value.config.endpoints.map { if (it.id == id) it.copy(enabled = on) else it },
        ),
    )

    /** 测试发送；成功后刷新该端点的投递记录 */
    fun test(endpointId: String) {
        viewModelScope.launch {
            val api = api() ?: return@launch
            _ui.value = _ui.value.copy(testing = endpointId, error = null)
            runCatching { api.webhookTest(endpointId).dataOrThrow() }
                .onSuccess { d ->
                    _ui.value = _ui.value.copy(
                        testing = null,
                        deliveries = _ui.value.deliveries + (endpointId to listOf(d) + _ui.value.deliveries[endpointId].orEmpty()),
                    )
                }
                .onFailure { e -> _ui.value = _ui.value.copy(testing = null, error = e.message ?: "测试失败") }
        }
    }

    /** 读取某端点的投递记录 */
    fun loadDeliveries(endpointId: String) {
        viewModelScope.launch {
            val api = api() ?: return@launch
            runCatching { api.webhookDeliveries(endpointId).dataOrThrow() }
                .onSuccess { list -> _ui.value = _ui.value.copy(deliveries = _ui.value.deliveries + (endpointId to list)) }
                .onFailure { e -> _ui.value = _ui.value.copy(error = e.message ?: "读取投递记录失败") }
        }
    }
}

@Composable
fun WebhookSettingsScreen(onBack: () -> Unit, vm: WebhookSettingsViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.load() }

    Column(Modifier.fillMaxSize().background(Bg)) {
        SettingsTopBar(title = "Webhook", onBack = onBack)
        when {
            ui.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            else -> Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (ui.error != null) Text(ui.error!!, style = McType.footnote, color = TextMuted)

                GlassCard(Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Webhook 总开关", style = McType.subheadlineSemibold)
                            Spacer(Modifier.height(3.dp))
                            Text(
                                if (ui.config.enabled) "已启用，事件会推送到下列端点" else "已停用，不会发出任何投递",
                                style = McType.caption,
                                color = TextFaint,
                            )
                        }
                        Text(
                            if (ui.config.enabled) "已启用" else "已停用",
                            style = McType.caption,
                            color = if (ui.config.enabled) Accent else TextFaint,
                        )
                        Spacer(Modifier.width(8.dp))
                        Switch(
                            checked = ui.config.enabled,
                            enabled = !ui.saving,
                            onCheckedChange = { vm.setEnabled(it) },
                            colors = SwitchDefaults.colors(checkedTrackColor = Accent),
                        )
                    }
                }

                if (ui.config.endpoints.isEmpty()) {
                    Text("还没有配置 Webhook 端点", style = McType.caption, color = TextFaint)
                } else {
                    ui.config.endpoints.forEach { ep ->
                        EndpointCard(
                            ep = ep,
                            testing = ui.testing == ep.id,
                            saving = ui.saving,
                            deliveries = ui.deliveries[ep.id].orEmpty(),
                            onTest = { vm.test(ep.id) },
                            onToggleEnabled = { vm.setEndpointEnabled(ep.id, it) },
                            onShowDeliveries = { vm.loadDeliveries(ep.id) },
                        )
                    }
                }

                Text(
                    "端点的新增、编辑、轮换 secret 仍然在网页端「设置 → Webhook」里完成。",
                    style = McType.caption,
                    color = TextFaint,
                    lineHeight = 16.sp,
                )
            }
        }
    }
}

@Composable
private fun EndpointCard(
    ep: WebhookEndpointView,
    testing: Boolean,
    saving: Boolean,
    deliveries: List<WebhookDeliveryView>,
    onTest: () -> Unit,
    onToggleEnabled: (Boolean) -> Unit,
    onShowDeliveries: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    GlassCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(ep.name.ifBlank { ep.id }, style = McType.subheadlineSemibold)
                    Spacer(Modifier.height(2.dp))
                    Text(ep.url, style = McType.caption, color = TextMuted)
                }
                Text(
                    if (ep.enabled) "已启用" else "未启用",
                    style = McType.caption,
                    color = if (ep.enabled) Accent else TextFaint,
                )
                Spacer(Modifier.width(8.dp))
                Switch(
                    checked = ep.enabled,
                    enabled = !saving,
                    onCheckedChange = onToggleEnabled,
                    colors = SwitchDefaults.colors(checkedTrackColor = Accent),
                )
            }
            if (ep.secretMasked.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text("secret ${ep.secretMasked}", style = McType.caption, color = TextFaint)
            }
            if (ep.events.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                Text(ep.events.joinToString(" · "), style = McType.caption, color = TextFaint, lineHeight = 15.sp)
            }
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton(if (testing) "测试中…" else "测试发送", enabled = !testing, onClick = onTest)
                PillButton(
                    if (expanded) "收起投递记录" else "投递记录",
                    enabled = true,
                    onClick = { expanded = !expanded; if (expanded) onShowDeliveries() },
                )
            }
            if (expanded) {
                Spacer(Modifier.height(8.dp))
                if (deliveries.isEmpty()) {
                    Text("还没有投递记录", style = McType.caption, color = TextFaint)
                } else {
                    deliveries.take(8).forEach { d ->
                        Row(Modifier.padding(vertical = 3.dp)) {
                            Text(
                                "${if (d.ok) "✓" else "✗"} ${d.event}",
                                style = McType.caption,
                                color = if (d.ok) Accent else Color(0xFFFF8A80),
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                "${d.statusCode ?: "-"} · ${d.durationMs}ms",
                                style = McType.caption,
                                color = TextFaint,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PillButton(text: String, enabled: Boolean, onClick: () -> Unit) {
    Text(
        text,
        style = McType.caption,
        color = if (enabled) TextPrimary else TextFaint,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(Color.White.copy(alpha = if (enabled) 0.10f else 0.04f))
            .clickable(enabled = enabled) { onClick() }
            .padding(horizontal = 12.dp, vertical = 7.dp),
    )
}

private fun WebhookConfigView.toPayload(): WebhookConfigPayload = WebhookConfigPayload(
    enabled = enabled,
    endpoints = endpoints.map { ep ->
        WebhookEndpointPayload(
            id = ep.id,
            name = ep.name,
            url = ep.url,
            format = ep.format.ifBlank { "movieclaw" },
            enabled = ep.enabled,
            events = ep.events,
            template = ep.template,
            headers = ep.headers,
            egressScope = ep.egressScope.ifBlank { "lan" },
        )
    },
)
