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
import io.movieclaw.android.core.model.McpStatusView
import io.movieclaw.android.core.model.McpToggleRequest
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * MCP 服务（iOS `MCPSettingsView` 的对应物）：总开关、端点地址前缀、端点清单。
 *
 * 接口同 iOS：`GET /mcp/status`、`PUT /mcp/status`（`{ enabled }`）。
 * 端点的增删改（`POST/PUT/DELETE /mcp/endpoints…`）与工具目录属于复杂表单，本页暂不做，
 * 页面上明确提示去网页端。
 */
@HiltViewModel
class McpSettingsViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Ui(
        val loading: Boolean = true,
        val saving: Boolean = false,
        val error: String? = null,
        val status: McpStatusView = McpStatusView(),
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
            runCatching { apiFactory.forOrigin(origin).mcpStatus().dataOrThrow() }
                .onSuccess { s -> _ui.value = _ui.value.copy(loading = false, status = s) }
                .onFailure { e -> _ui.value = _ui.value.copy(loading = false, error = e.message ?: "读取失败") }
        }
    }

    fun setEnabled(on: Boolean) {
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            _ui.value = _ui.value.copy(saving = true, error = null)
            runCatching {
                apiFactory.forOrigin(origin).mcpToggle(McpToggleRequest(on)).dataOrThrow()
            }
                .onSuccess { s -> _ui.value = _ui.value.copy(saving = false, status = s) }
                .onFailure { e -> _ui.value = _ui.value.copy(saving = false, error = e.message ?: "保存失败") }
        }
    }
}

@Composable
fun McpSettingsScreen(onBack: () -> Unit, vm: McpSettingsViewModel = hiltViewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.load() }

    Column(Modifier.fillMaxSize().background(Bg)) {
        SettingsTopBar(title = "MCP 服务", onBack = onBack)
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
                            Text("MCP 总开关", style = McType.subheadlineSemibold)
                            Spacer(Modifier.height(3.dp))
                            Text(
                                if (ui.status.externalUrlConfigured) "已配置外部访问地址，公网可用"
                                else "未配置外部访问地址，仅局域网可用",
                                style = McType.caption,
                                color = TextFaint,
                                lineHeight = 15.sp,
                            )
                        }
                        Switch(
                            checked = ui.status.enabled,
                            enabled = !ui.saving,
                            onCheckedChange = { vm.setEnabled(it) },
                            colors = SwitchDefaults.colors(checkedTrackColor = Accent),
                        )
                    }
                }

                if (ui.status.baseUrl.isNotBlank()) {
                    GlassCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(14.dp)) {
                            Text("接入地址前缀", style = McType.subheadlineSemibold)
                            Spacer(Modifier.height(4.dp))
                            Text(ui.status.baseUrl, style = McType.caption, color = TextMuted)
                        }
                    }
                }

                if (ui.status.endpoints.isNotEmpty()) {
                    GlassCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(14.dp)) {
                            Text("端点（${ui.status.endpoints.size}）", style = McType.subheadlineSemibold)
                            Spacer(Modifier.height(8.dp))
                            ui.status.endpoints.forEach { ep ->
                                Row(Modifier.padding(vertical = 6.dp)) {
                                    Column(Modifier.weight(1f)) {
                                        Text(
                                            ep.name.ifBlank { ep.slug },
                                            style = McType.sub,
                                            color = TextPrimary,
                                        )
                                        Text(
                                            listOfNotNull(
                                                ep.services.joinToString(" / ").takeIf { it.isNotBlank() },
                                                "${ep.toolCount} 个工具",
                                            ).joinToString(" · "),
                                            style = McType.caption,
                                            color = TextFaint,
                                        )
                                    }
                                    Text(
                                        if (ep.enabled) "已启用" else "未启用",
                                        style = McType.caption,
                                        color = if (ep.enabled) Accent else TextFaint,
                                    )
                                }
                            }
                        }
                    }
                } else {
                    Text("还没有配置 MCP 端点", style = McType.caption, color = TextFaint)
                }

                Text(
                    "端点的增删改与工具授权仍然在网页端「设置 → MCP 服务」里完成。",
                    style = McType.caption,
                    color = TextFaint,
                    lineHeight = 16.sp,
                )
            }
        }
    }
}
