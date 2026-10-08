package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.LlmModelInfo
import io.movieclaw.android.core.model.LlmPresetView
import io.movieclaw.android.core.model.LlmProviderPayload
import io.movieclaw.android.core.model.LlmProviderView

/**
 * 接入 / 编辑模型供应商（iOS `SettingsBLLMProviderForm` / Web `llm-config-section` 同构）。
 * 文案逐字照上游；保存成功即关弹层（**不弹 Toast**），失败原因显示在表单顶部且弹层保持打开。
 *
 * 与 iOS 的差异（如实记）：自定义端点（`openai_compat`）下的「自定义模型参数」只做了必填项
 * （模型 id / 上下文长度 / 最大输出 / 思考预算上限 + 4 个开关），没有做「思考强度控制」的
 * 方言选择与档位勾选——那一段只影响自建网关的进阶参数，先留空 = iOS 的第一档「不可控」。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun LlmProviderFormSheet(
    presets: List<LlmPresetView>,
    existing: LlmProviderView?,
    saving: Boolean,
    formError: String?,
    onDismiss: () -> Unit,
    onSave: (Int?, LlmProviderPayload) -> Unit,
) {
    var presetId by remember { mutableStateOf(existing?.providerType ?: presets.firstOrNull()?.id.orEmpty()) }
    val preset = presets.firstOrNull { it.id == presetId }
    var name by remember { mutableStateOf(existing?.name.orEmpty()) }
    var baseUrl by remember { mutableStateOf(existing?.baseUrl.orEmpty()) }
    var apiKey by remember { mutableStateOf("") }
    var showKey by remember { mutableStateOf(false) }
    var userAgent by remember { mutableStateOf(existing?.userAgent.orEmpty()) }
    var advancedOpen by remember { mutableStateOf(false) }
    var customModels by remember { mutableStateOf(existing?.extraModels.orEmpty()) }
    var addModelOpen by remember { mutableStateOf(false) }
    var localError by remember { mutableStateOf<String?>(null) }
    val customEndpoint = preset != null && preset.baseUrl == null

    fun validate(): String? = when {
        name.contains("/") -> "实例名不能包含斜杠 /。"
        apiKey.isBlank() -> "请填写 API Key。"
        customEndpoint && !(baseUrl.startsWith("http://") || baseUrl.startsWith("https://")) ->
            "请填写以 http:// 或 https:// 开头的完整 API 端点。"
        customEndpoint && customModels.isEmpty() -> "请至少添加一个模型（接入后才有模型可用）。"
        userAgent.any { it.code < 32 || it.code > 126 } -> "User-Agent 包含不支持的字符，请检查高级设置。"
        else -> null
    }

    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(bottom = 20.dp)) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(36.dp).clip(RoundedCornerShape(18.dp)).clickable(onClick = onDismiss),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Rounded.Close, contentDescription = "取消", tint = TextMuted, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(8.dp))
                Text(
                    existing?.let { "编辑「${it.name}」" } ?: "接入模型供应商",
                    style = McType.bodySemibold, color = TextPrimary,
                )
            }
            Column(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 560.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                (localError ?: formError)?.let {
                    Text(it, style = McType.sub, color = Color(0xFFFF9F9F))
                }

                // ── 供应商 ──
                FieldLabel("供应商")
                var presetOpen by remember { mutableStateOf(false) }
                PickerValue(preset?.displayName ?: "请选择") { presetOpen = true }
                if (presetOpen) {
                    OptionDialog("供应商", presets.map { it.id to it.displayName }) { picked ->
                        presetId = picked
                        // 换供应商：端点 / UA / 高级设置 / 自定义模型全清空（iOS 同款）
                        baseUrl = ""
                        userAgent = ""
                        advancedOpen = false
                        customModels = emptyList()
                        presetOpen = false
                    }
                }
                preset?.let { p ->
                    Text(providerHint(p), style = McType.caption, color = TextFaint)
                }
                Text("保存后系统会自动测试连接。", style = McType.caption, color = TextFaint)

                // ── 实例名 ──
                FormField(
                    label = "实例名（可选）",
                    value = name,
                    placeholder = preset?.displayName ?: "如：官方 OpenAI / 家里的 vLLM",
                    onChange = { name = it },
                )
                Text(
                    "接入多家时用来区分：同一模型在多家都有时，对话框会以「模型（实例名）」标注。留空按供应商名保存。",
                    style = McType.caption, color = TextFaint,
                )

                // ── API 端点（自定义端点才要）──
                if (customEndpoint) {
                    FormField(
                        label = "API 端点 *",
                        value = baseUrl,
                        placeholder = "http://192.168.1.5:8000/v1",
                        onChange = { baseUrl = it },
                    )
                } else {
                    Text("API 端点（可选）：留空使用官方端点；使用代理或镜像时填写完整地址。", style = McType.caption, color = TextFaint)
                    FormField(label = "API 端点（代理 / 镜像）", value = baseUrl, placeholder = "官方默认端点", onChange = { baseUrl = it })
                }

                // ── API Key ──
                FormField(
                    label = "API Key *",
                    value = apiKey,
                    placeholder = if (existing == null) "sk-…" else "出于安全，请重新填写",
                    onChange = { apiKey = it },
                    trailing = {
                        Text(
                            if (showKey) "显示" else "隐藏",
                            style = McType.caption, color = Accent,
                            modifier = Modifier.clickable { showKey = !showKey },
                        )
                    },
                )
                if (existing != null) {
                    Text("已保存的密钥不会回显，修改其他配置时也需要重新填写。", style = McType.caption, color = TextFaint)
                }

                // ── 高级设置：User-Agent ──
                if (customEndpoint) {
                    Text(
                        if (advancedOpen) "▾ 高级设置" else "▸ 高级设置",
                        style = McType.subSemibold, color = TextMuted,
                        modifier = Modifier.clickable { advancedOpen = !advancedOpen },
                    )
                    if (advancedOpen) {
                        FormField(
                            label = "User-Agent（可选）",
                            value = userAgent,
                            placeholder = preset?.defaultUserAgent.orEmpty(),
                            onChange = { userAgent = it },
                        )
                        Text(
                            "仅当网关或 WAF 对请求标识有要求时填写，留空使用上方显示的 SDK 默认值。",
                            style = McType.caption, color = TextFaint,
                        )
                    }
                }

                // ── 模型目录 ──
                FieldLabel("模型目录")
                if (customEndpoint) {
                    customModels.forEach { model ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(model.id, style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f))
                            Text(
                                "移除", style = McType.caption, color = Color(0xFFFF9F9F),
                                modifier = Modifier.clickable { customModels = customModels - model },
                            )
                        }
                    }
                    Text(
                        "添加模型…", style = McType.subSemibold, color = Accent,
                        modifier = Modifier.clickable { addModelOpen = true },
                    )
                    Text(
                        "兼容端点没有内置目录，请把端点上部署的模型添加进来（含参数）。接入后这些模型可在 AI 设定与对话框里选用；连接测试用第一个。",
                        style = McType.caption, color = TextFaint,
                    )
                } else {
                    Text(
                        "模型目录以「${preset?.displayName ?: ""}」预设为准，共 ${preset?.models?.size ?: 0} 个模型，接入后可在 AI 设定与对话框里选用；连接测试用目录里第一个。",
                        style = McType.caption, color = TextFaint,
                    )
                }

                // ── 保存 ──
                Text(
                    if (saving) "保存中…" else "保存并测试连接",
                    style = McType.subSemibold,
                    color = if (saving) TextFaint else Color(0xFF0A0E12),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(if (saving) Color.White.copy(alpha = 0.2f) else Accent)
                        .clickable(enabled = !saving) {
                            val error = validate()
                            localError = error
                            if (error == null) {
                                onSave(
                                    existing?.id,
                                    LlmProviderPayload(
                                        name = name.ifBlank { preset?.displayName.orEmpty() },
                                        providerType = presetId,
                                        baseUrl = baseUrl.takeIf { it.isNotBlank() },
                                        userAgent = userAgent.takeIf { it.isNotBlank() },
                                        apiKey = apiKey,
                                        defaultModel = customModels.firstOrNull()?.id,
                                        extraModels = if (customEndpoint) customModels else emptyList(),
                                    ),
                                )
                            }
                        }
                        .padding(vertical = 13.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
    }

    if (addModelOpen) {
        CustomModelDialog(
            onDismiss = { addModelOpen = false },
            onAdd = { model ->
                customModels = customModels + model
                addModelOpen = false
            },
        )
    }
}

/** 预设提示卡（iOS `providerHint` 逐字） */
private fun providerHint(preset: LlmPresetView): String = when (preset.id) {
    "bailian" -> "聚合 Qwen / DeepSeek / Kimi / GLM"
    "openai" -> "官方端点，可配代理"
    else -> if (preset.baseUrl == null) "自建 vLLM / Ollama / 任意网关" else preset.baseUrl
}

/** 自定义模型：必填项 + 4 个开关（iOS 子表单的必填部分） */
@Composable
private fun CustomModelDialog(onDismiss: () -> Unit, onAdd: (LlmModelInfo) -> Unit) {
    var id by remember { mutableStateOf("") }
    var context by remember { mutableStateOf("") }
    var maxOutput by remember { mutableStateOf("") }
    var budget by remember { mutableStateOf("") }
    var tools by remember { mutableStateOf(true) }
    var parallelTools by remember { mutableStateOf(false) }
    var thinking by remember { mutableStateOf(false) }
    var vision by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("自定义模型（填写参数）", style = McType.bodySemibold) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                error?.let { Text(it, style = McType.sub, color = Color(0xFFFF9F9F)); Spacer(Modifier.height(8.dp)) }
                FormField("模型 id *", id, "如：qwen3-max", { id = it })
                FormField("上下文长度 *", context, "如：131072", { context = it })
                FormField("最大输出 *", maxOutput, "如：8192", { maxOutput = it })
                FormField("思考预算上限 *", budget, "思维链可用的最大 token 数（thinking_budget 上限），超配供应商会直接报错。", { budget = it })
                SwitchLine("支持工具调用", tools) { tools = it }
                SwitchLine("支持并发工具调用", parallelTools) { parallelTools = it }
                SwitchLine("输出思考内容", thinking) { thinking = it }
                SwitchLine("支持图片输入", vision) { vision = it }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val ctx = context.toIntOrNull()
                val out = maxOutput.toIntOrNull()
                val b = budget.toIntOrNull()
                error = when {
                    id.isBlank() || ctx == null || out == null || b == null -> "请补全新模型参数中标有 * 的项目。"
                    else -> null
                }
                if (error == null) {
                    onAdd(
                        LlmModelInfo(
                            id = id,
                            contextWindow = ctx,
                            maxOutputTokens = out,
                            maxThinkingTokens = b,
                            supportsTools = tools,
                            supportsParallelToolCalls = parallelTools,
                            supportsThinking = thinking,
                            modalities = if (vision) listOf("text", "image") else listOf("text"),
                        ),
                    )
                }
            }) { Text("添加到目录", color = Accent) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) } },
    )
}

@Composable
private fun SwitchLine(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onChange(!checked) }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(if (checked) "☑" else "☐", style = McType.sub, color = if (checked) Accent else TextMuted)
        Spacer(Modifier.width(8.dp))
        Text(label, style = McType.sub, color = TextPrimary)
    }
}

@Composable
private fun FieldLabel(text: String) {
    Text(text, style = McType.caption, color = TextFaint)
}

@Composable
private fun PickerValue(value: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Color.White.copy(alpha = 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(value, style = McType.sub, color = TextPrimary, modifier = Modifier.weight(1f))
        Icon(Icons.Rounded.ArrowDropDown, contentDescription = null, tint = TextMuted, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun OptionDialog(title: String, options: List<Pair<String, String>>, onPick: (String) -> Unit) {
    AlertDialog(
        onDismissRequest = {},
        confirmButton = {},
        title = { Text(title, style = McType.bodySemibold) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                options.forEach { (key, label) ->
                    Text(
                        label, style = McType.sub, color = TextPrimary,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onPick(key) }
                            .padding(vertical = 10.dp),
                    )
                }
            }
        },
    )
}

@Composable
private fun FormField(
    label: String,
    value: String,
    placeholder: String,
    onChange: (String) -> Unit,
    trailing: (@Composable () -> Unit)? = null,
) {
    Column {
        FieldLabel(label)
        Spacer(Modifier.height(4.dp))
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            placeholder = { Text(placeholder, style = McType.sub, color = TextFaint) },
            singleLine = true,
            trailingIcon = trailing,
            textStyle = McType.sub,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = Accent,
                unfocusedBorderColor = Color.White.copy(alpha = 0.14f),
                focusedTextColor = TextPrimary,
                unfocusedTextColor = TextPrimary,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
