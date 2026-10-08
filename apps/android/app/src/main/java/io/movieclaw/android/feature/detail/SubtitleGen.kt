package io.movieclaw.android.feature.detail

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
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material3.Icon
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.FlatCard
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.ProgressBar
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.JobView
import io.movieclaw.android.core.model.PgsLanguageOption
import io.movieclaw.android.core.model.SubtitleGenCandidateView
import io.movieclaw.android.core.model.SubtitleGenPreviewView
import io.movieclaw.android.feature.activity.LlmGate

/** AI 字幕的警告黄（iOS `Theme.warning` 同色系） */
private val Warning = Color(0xFFF5C451)
private val InfoBlue = Color(0xFF7FB0FF)
private val OkGreen = Color(0xFF7ED9A0)
private val DangerRed = Color(0xFFFF9F9F)

/** 弹层的两种模式：预检 / 任务状态 */
enum class SubtitleGenMode { PREVIEW, STATUS }

/**
 * 「AI 生成字幕」入口（iOS `TrackSubtitleGenButton` / Web `subtitle-gen-panel.tsx`）：
 * 字幕行尾部的一颗胶囊。**仅管理员 + 文件在盘**才出现；运行中 / 有终态问题时忽略门禁、
 * 永远显示状态徽章；空闲时未接 AI 显示「接入…去接入」引导（整条是按钮，点了进「模型接入」）。
 */
@Composable
internal fun SubtitleGenEntry(
    generated: Boolean,
    gate: LlmGate,
    job: JobView?,
    previewing: Boolean,
    targetLanguage: String,
    secondaryLanguage: String?,
    onClick: () -> Unit,
) {
    val running = job?.status in RUNNING_STATUSES
    val terminalIssue = job?.status in TERMINAL_ISSUE_STATUSES
    val succeeded = job?.status == "succeeded"

    if (!running && !terminalIssue && gate == LlmGate.MISSING) {
        // 未接 AI：整句是按钮，点了去「模型接入」
        Row(
            Modifier
                .clip(RoundedCornerShape(6.dp))
                .background(Warning.copy(alpha = 0.1f))
                .border(1.dp, Warning.copy(alpha = 0.3f), RoundedCornerShape(6.dp))
                .clickable(onClick = onClick)
                .padding(horizontal = 8.dp, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("接入 AI 模型后即可解锁生成字幕能力。", style = McType.caption, color = Warning)
            Text("去接入", style = McType.caption.copy(fontWeight = FontWeight.SemiBold), color = InfoBlue)
        }
        return
    }
    if (!running && !terminalIssue && gate == LlmGate.CHECKING) {
        // 检查中不闪出触发按钮（同 iOS：零尺寸占位）
        Box(Modifier.size(0.dp))
        return
    }

    val badge = when {
        previewing -> "正在检查"
        running -> runningText(job!!, targetLanguage, secondaryLanguage)
        generated || succeeded -> "AI 生成字幕"
        terminalIssue -> "AI 未完成"
        else -> "AI 生成字幕"
    }
    val tint = when {
        running -> InfoBlue
        terminalIssue -> DangerRed
        else -> Color.White.copy(alpha = 0.75f)
    }
    val edge = when {
        running -> InfoBlue.copy(alpha = 0.3f)
        terminalIssue -> DangerRed.copy(alpha = 0.3f)
        else -> Color.White.copy(alpha = 0.16f)
    }
    Row(
        Modifier
            .height(32.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(if (running) InfoBlue.copy(alpha = 0.12f) else Color.Transparent)
            .border(1.dp, edge, RoundedCornerShape(7.dp))
            .clickable(enabled = !previewing, onClick = onClick)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (running) {
            Box(Modifier.size(6.dp).clip(RoundedCornerShape(3.dp)).background(tint))
        } else {
            Icon(Icons.Rounded.AutoAwesome, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        }
        Text(badge, style = McType.caption, color = tint, maxLines = 1)
    }
}

internal val SUBTITLE_RUNNING_STATUSES = setOf("queued", "running", "retry_wait", "cancelling", "waiting")
internal val SUBTITLE_ISSUE_STATUSES = setOf("blocked", "failed", "cancelled")
private val RUNNING_STATUSES = SUBTITLE_RUNNING_STATUSES
private val TERMINAL_ISSUE_STATUSES = SUBTITLE_ISSUE_STATUSES

/** 运行中徽章：`{输出} · {阶段文案}`（阶段文案逐字照 iOS `runningBadgeText`） */
private fun runningText(job: JobView, target: String, secondary: String?): String {
    val details = job.progress.details
    fun bool(key: String) = details?.get(key)?.let { it.toString() == "true" } == true
    val phase = job.progress.phase
    val percent = job.progress.percent
    val text = SubtitleGenText.runningBadgeText(phase, percent, bool("extract_queued"))
    val output = SubtitleGenText.outputLabel(target, secondary)
    return "$output · $text"
}

/**
 * 预检 / 状态弹层：一次只开一种模式（iOS 同款）。
 * 预检里的每个动作都由调用方（ItemDetailViewModel）落到接口上。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun SubtitleGenSheet(
    mode: SubtitleGenMode,
    state: SubtitleGenUiState,
    onDismiss: () -> Unit,
    onTargetLanguage: (String) -> Unit,
    onSecondaryLanguage: (String) -> Unit,
    onBilingual: (Boolean) -> Unit,
    onSourceKey: (String) -> Unit,
    onPgsLanguage: (String) -> Unit,
    onConfirm: () -> Unit,
    onRetryPreview: () -> Unit,
    onCancelJob: () -> Unit,
    onHandOffToAgent: () -> Unit,
) {
    val preview = state.preview
    val job = state.job
    val running = job?.status in RUNNING_STATUSES
    val outputLabel = SubtitleGenText.outputLabel(state.targetLanguage, state.secondaryLanguage.takeIf { state.bilingual })
    val canPreparePgs = preview?.blocker?.code == "pgs_conversion_required" &&
        preview.pgsConversion?.available == true
    val canConvertPgs = canPreparePgs &&
        (preview?.pgsConversion?.languageConfirmationRequired != true || state.pgsOcrLanguage.isNotBlank())
    val blockedWithoutPgs = preview?.blocker != null && !canPreparePgs
    val ready = mode == SubtitleGenMode.STATUS || !state.previewing

    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(bottom = 20.dp)) {
            // ── 头：标题 + 副标题（左）／✕（左前）＋主动作（右后）──
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(36.dp).clip(RoundedCornerShape(18.dp)).clickable(onClick = onDismiss),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Rounded.Close,
                        contentDescription = if (blockedWithoutPgs || state.requestError != null) "关闭" else "取消",
                        tint = TextMuted,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        when {
                            mode == SubtitleGenMode.STATUS && running -> "正在生成$outputLabel"
                            mode == SubtitleGenMode.STATUS -> "AI 字幕任务"
                            else -> "生成 AI 字幕"
                        },
                        style = McType.bodySemibold,
                        color = TextPrimary,
                    )
                    Text(
                        when {
                            mode == SubtitleGenMode.STATUS && running -> "后台运行，离开页面不会中断。"
                            mode == SubtitleGenMode.STATUS -> "任务详情与处理建议。"
                            else -> "确认后才调用 AI，并在后台生成。"
                        },
                        style = McType.caption,
                        color = TextMuted,
                    )
                }
                if (mode == SubtitleGenMode.PREVIEW && ready) {
                    val confirmText = when {
                        canPreparePgs -> "开始生成$outputLabel"
                        preview?.blocker == null && preview?.chosenKey != null -> "确认生成$outputLabel"
                        else -> null
                    }
                    if (confirmText != null) {
                        Text(
                            if (state.starting) "正在启动…" else confirmText,
                            style = McType.subSemibold,
                            color = if (!state.starting && (canConvertPgs || !canPreparePgs)) OkGreen else TextFaint,
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable(
                                    enabled = !state.starting && !state.agentStarting &&
                                        (if (canPreparePgs) canConvertPgs else true),
                                    onClick = onConfirm,
                                )
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                }
            }

            Column(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 560.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (mode == SubtitleGenMode.STATUS) {
                    StatusBody(job, state, onCancelJob)
                } else {
                    PreviewBody(
                        state = state,
                        preview = preview,
                        outputLabel = outputLabel,
                        canPreparePgs = canPreparePgs,
                        onTargetLanguage = onTargetLanguage,
                        onSecondaryLanguage = onSecondaryLanguage,
                        onBilingual = onBilingual,
                        onSourceKey = onSourceKey,
                        onPgsLanguage = onPgsLanguage,
                    )
                }

                // ── 行按钮：重新检查 / 重新预检 + 交给 Agent ──
                Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                    val retryLabel = if (mode == SubtitleGenMode.STATUS) "重新预检" else "重新检查"
                    if (mode == SubtitleGenMode.STATUS || blockedWithoutPgs ||
                        (preview == null && state.requestError != null)
                    ) {
                        ActionLink(retryLabel, onClick = onRetryPreview)
                    }
                    if (mode == SubtitleGenMode.STATUS || blockedWithoutPgs || state.requestError != null) {
                        ActionLink(
                            if (state.agentStarting) "正在交给 Agent…" else "交给 Agent 处理",
                            onClick = onHandOffToAgent,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ActionLink(label: String, onClick: () -> Unit) {
    Text(
        label,
        style = McType.subSemibold,
        color = InfoBlue,
        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick)
            .padding(horizontal = 6.dp, vertical = 4.dp),
    )
}

/** 预检模式的内容（输出语言 → 参考字幕 → PGS → 阻断 → 结论 → 错误） */
@Composable
private fun PreviewBody(
    state: SubtitleGenUiState,
    preview: SubtitleGenPreviewView?,
    outputLabel: String,
    canPreparePgs: Boolean,
    onTargetLanguage: (String) -> Unit,
    onSecondaryLanguage: (String) -> Unit,
    onBilingual: (Boolean) -> Unit,
    onSourceKey: (String) -> Unit,
    onPgsLanguage: (String) -> Unit,
) {
    if (state.previewing && preview == null) {
        Text("正在检查参考字幕，不会调用 AI…", style = McType.sub, color = TextMuted)
        state.pendingMessage?.let {
            Text(
                "首次读取内封字幕需要通读整个视频文件，读好后会自动继续；这一步不会调用 AI，也不产生费用。",
                style = McType.caption, color = TextFaint,
            )
        }
        return
    }
    if (preview == null) {
        state.requestError?.let { Text(it, style = McType.sub, color = DangerRed) }
        return
    }

    // ── 输出语言 ──
    SectionLabel("输出语言")
    LanguagePicker(
        label = if (state.bilingual) "第一行语言" else "目标语言",
        value = state.targetLanguage,
        enabled = !state.starting,
        onPick = onTargetLanguage,
    )
    if (state.bilingual) {
        LanguagePicker(
            label = "第二行语言",
            value = state.secondaryLanguage,
            enabled = !state.starting,
            onPick = onSecondaryLanguage,
        )
    }
    CheckRow("生成双语字幕", checked = state.bilingual, enabled = !state.starting, onToggle = onBilingual)
    if (state.bilingual) {
        Text("每条字幕固定两行，上下顺序按这里的选择生成。", style = McType.caption, color = TextFaint)
    }

    // ── 参考字幕 ──
    SectionLabel("参考字幕")
    if (preview.candidates.isEmpty()) {
        Text("没有可用的参考字幕", style = McType.sub, color = TextMuted)
    } else {
        var expanded by remember { mutableStateOf(false) }
        val chosen = preview.candidates.firstOrNull { it.selectable && it.ref == (state.sourceKey ?: preview.selectedSourceKey) }
            ?: preview.candidates.firstOrNull { it.selectable }
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(Color.White.copy(alpha = 0.06f))
                .clickable(enabled = !state.starting) { expanded = true }
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                chosen?.let { SubtitleGenText.candidateLabel(it) } ?: "没有可用的参考字幕",
                style = McType.sub, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Icon(Icons.Rounded.ArrowDropDown, contentDescription = null, tint = TextMuted, modifier = Modifier.size(18.dp))
        }
        if (expanded) {
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { expanded = false },
                confirmButton = {},
                title = { Text("参考字幕", style = McType.bodySemibold) },
                text = {
                    Column(Modifier.verticalScroll(rememberScrollState())) {
                        preview.candidates.forEach { candidate ->
                            val enabled = candidate.selectable
                            val suffix = if (!enabled) "（不可用：${candidate.excluded ?: "不支持"}）" else ""
                            Text(
                                SubtitleGenText.candidateLabel(candidate) + suffix,
                                style = if (candidate.ref == chosen?.ref) McType.subSemibold else McType.sub,
                                color = if (enabled) TextPrimary else TextFaint,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(enabled = enabled) {
                                        expanded = false
                                        onSourceKey(candidate.ref)
                                    }
                                    .padding(vertical = 10.dp),
                            )
                        }
                    }
                },
            )
        }
        Text(
            "默认优先英语。也可以指定其他内封或外挂字幕；选择 PGS 时会先识别文字，再开始 AI 翻译。",
            style = McType.caption, color = TextFaint,
        )
        if (chosen?.requiresOcr == true) {
            Text("当前选择的是图片字幕，需要先完成文字识别。", style = McType.caption, color = Warning)
        }
    }

    // ── PGS 转换（先识别图片字幕）──
    val pgs = preview.pgsConversion
    if (canPreparePgs && pgs != null) {
        SectionLabel(if (pgs.languageConfirmationRequired) "请选择原字幕语言" else "先识别图片字幕")
        Text(
            "这份字幕是图片。MovieClaw 会先识别其中的文字，确认内容完整后再生成${outputLabel}字幕。",
            style = McType.sub, color = TextMuted,
        )
        if (pgs.languageConfirmationRequired) {
            LanguageOptionsPicker(
                label = "原字幕语言",
                value = state.pgsOcrLanguage,
                options = pgs.languageOptions,
                onPick = onPgsLanguage,
            )
            Text("请选择画面中实际显示的语言。", style = McType.caption, color = TextFaint)
        } else {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("原字幕语言", style = McType.sub, color = TextMuted, modifier = Modifier.weight(1f))
                Text(pgs.ocrLanguageLabel ?: "已自动识别", style = McType.sub, color = TextPrimary)
            }
        }
        Text(
            "原影片和字幕不会被修改。识别结果可能有少量错字，完成后建议抽查人名与特殊字体。",
            style = McType.caption, color = TextFaint,
        )
    }

    // ── 阻断 ──
    val blocker = preview.blocker
    if (blocker != null && !canPreparePgs) {
        FlatCard(Modifier.fillMaxWidth(), radius = 12.dp) {
            Column(Modifier.padding(14.dp)) {
                Text(blocker.title, style = McType.subSemibold, color = DangerRed)
                Spacer(Modifier.height(4.dp))
                Text(blocker.message, style = McType.sub, color = TextMuted)
                if (blocker.suggestions.isNotEmpty()) {
                    Spacer(Modifier.height(10.dp))
                    Text("可以这样处理", style = McType.caption, color = TextFaint)
                    blocker.suggestions.forEach {
                        Text("· $it", style = McType.sub, color = TextMuted, modifier = Modifier.padding(top = 4.dp))
                    }
                }
            }
        }
    }

    // ── 结论 ──
    val chosen = preview.candidates.firstOrNull { it.ref == (preview.chosenKey ?: preview.selectedSourceKey) }
    if (blocker == null && preview.chosenKey != null && chosen != null) {
        Text(
            "${SubtitleGenText.candidateLabel(chosen)}  →  $outputLabel",
            style = McType.subSemibold, color = TextPrimary,
        )
        val cost = if (preview.referenceNotice != null) {
            if (preview.estimatedTokens > 0) "按片长粗估${SubtitleGenText.tokenEstimate(preview.estimatedTokens)}"
            else "读取字幕后按实际对白估算"
        } else {
            "${SubtitleGenText.grouped(preview.eventCount.toLong())} 条对白 · ${SubtitleGenText.tokenEstimate(preview.estimatedTokens)}"
        }
        Text(cost, style = McType.sub, color = TextMuted)
        Text(
            "生成同目录 ${preview.outputFilename ?: "规范命名的 AI 字幕文件"}，原字幕不变；离开页面不影响生成。",
            style = McType.caption, color = TextFaint,
        )
        preview.referenceNotice?.let {
            Text(it, style = McType.caption, color = InfoBlue)
        }
        if (preview.alreadyGenerated) {
            Text("已有 AI 字幕，将被覆盖。", style = McType.caption, color = Warning)
        }
    }

    // ── 请求错误 ──
    state.requestError?.let {
        if (blocker != null || preview.chosenKey == null) {
            Text(it, style = McType.sub, color = DangerRed)
        }
    }
}

/** 状态模式的内容：进度卡 / 结束结果 / 停止 */
@Composable
private fun StatusBody(job: JobView?, state: SubtitleGenUiState, onCancelJob: () -> Unit) {
    if (job == null) {
        Text("任务已经结束。", style = McType.sub, color = TextMuted)
        return
    }
    val running = job.status in RUNNING_STATUSES
    val succeeded = job.status == "succeeded"
    if (running) {
        SubtitleGenProgressView(job)
        job.error?.message?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = McType.sub, color = DangerRed)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            ActionLink("关闭", onClick = {})
            ActionLink("停止生成", onClick = onCancelJob)
        }
    } else {
        val output = SubtitleGenText.outputLabel(state.targetLanguage, state.secondaryLanguage.takeIf { state.bilingual })
        val title = if (succeeded) "${output}字幕生成完成" else "${output}字幕生成未完成"
        FlatCard(Modifier.fillMaxWidth(), radius = 12.dp) {
            Column(Modifier.padding(14.dp)) {
                Text(title, style = McType.subSemibold, color = if (succeeded) OkGreen else DangerRed)
                Spacer(Modifier.height(4.dp))
                val detail = job.error?.message?.takeIf { it.isNotBlank() }
                    ?: job.result?.get("message")?.let { runCatching { it.toString().trim('"') }.getOrNull() }
                    ?: "任务已经结束。"
                Text(detail, style = McType.sub, color = TextMuted)
            }
        }
    }
}

/** 进度卡（iOS `TrackGenProgressView`）：消息 / 百分比 / 计数行 / 五阶段清单 */
@Composable
internal fun SubtitleGenProgressView(job: JobView) {
    val details = job.progress.details
    fun int(key: String): Int = details?.get(key)?.let { runCatching { it.toString().toInt() }.getOrNull() } ?: 0
    fun long(key: String): Long = details?.get(key)?.let { runCatching { it.toString().toLong() }.getOrNull() } ?: 0
    val phase = job.progress.phase
    val usesOcr = details?.get("uses_ocr")?.toString() == "true"

    FlatCard(Modifier.fillMaxWidth(), radius = 12.dp) {
        Column(Modifier.padding(14.dp)) {
            Text(
                job.progress.message.ifBlank { "正在准备生成任务" },
                style = McType.subSemibold, color = TextPrimary,
            )
            val percent = job.progress.percent
            Spacer(Modifier.height(8.dp))
            if (percent != null && percent.isFinite()) {
                ProgressBar(fraction = (percent / 100f).coerceIn(0f, 1f), tint = InfoBlue)
                Spacer(Modifier.height(4.dp))
                Text("${percent.coerceIn(0f, 100f).toInt()}%", style = McType.caption, color = TextMuted)
            } else {
                ProgressBar(fraction = 0.33f, tint = InfoBlue)
            }
            val blocks = SubtitleGenText.grouped(int("done_blocks").toLong()) to int("total_blocks")
            if (blocks.second > 0) {
                Text("翻译块 ${blocks.first}/${blocks.second}", style = McType.caption, color = TextMuted)
            }
            val events = SubtitleGenText.grouped(int("done_events").toLong()) to int("total_events")
            if (events.second > 0) {
                Text("对白 ${events.first}/${events.second} 条", style = McType.caption, color = TextMuted)
            }
            if (job.usage.requestCount > 0) {
                Text(
                    "模型调用 ${job.usage.requestCount} 次 · ${SubtitleGenText.grouped(job.usage.totalTokens)} token",
                    style = McType.caption, color = TextMuted,
                )
            }
            val limit = int("parallelism")
            val active = details?.get("active_blocks")?.let { runCatching { it.toString() }.getOrNull() }
            if (!active.isNullOrBlank() && active != "[]") {
                val nums = active.trim('[', ']').split(',').mapNotNull { it.trim().toIntOrNull().let { n -> n?.plus(1) } }
                val head = if (limit > 1) "并发上限 $limit 路 · " else ""
                val tail = int("oldest_active_seconds").takeIf { it > 0 }
                    ?.let { " · 最早一块已等待 ${SubtitleGenText.duration(it.toLong())}" } ?: ""
                Text("${head}正在处理第 ${nums.joinToString("、")} 块$tail", style = McType.caption, color = TextMuted)
            }
            if (int("rate_limit_count") > 0) {
                Text("模型服务繁忙 ${int("rate_limit_count")} 次，系统已自动降速重试。", style = McType.caption, color = Warning)
            }
            if (int("validation_retries") > 0) {
                Text("有 ${int("validation_retries")} 次返回格式不完整，系统已自动纠正。", style = McType.caption, color = Warning)
            }
            Spacer(Modifier.height(10.dp))
            val stages = SubtitleGenText.stages.toMutableList().also {
                if (usesOcr) it[0] = SubtitleGenText.stageOcr
            }
            val current = SubtitleGenText.stageIndex(phase)
            stages.forEachIndexed { index, label ->
                Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        (if (index < current) "✓ " else if (index == current) "● " else "○ ") + label,
                        style = if (index == current) McType.subSemibold else McType.sub,
                        color = when {
                            index < current -> TextMuted
                            index == current -> TextPrimary
                            else -> TextFaint
                        },
                    )
                    if (index == current) {
                        Spacer(Modifier.width(6.dp))
                        Text("进行中", style = McType.caption, color = InfoBlue)
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, style = McType.caption, color = TextFaint)
}

@Composable
private fun CheckRow(label: String, checked: Boolean, enabled: Boolean, onToggle: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = enabled) { onToggle(!checked) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(if (checked) "☑" else "☐", style = McType.sub, color = if (checked) InfoBlue else TextMuted)
        Spacer(Modifier.width(8.dp))
        Text(label, style = McType.sub, color = TextPrimary)
    }
}

@Composable
private fun LanguagePicker(label: String, value: String, enabled: Boolean, onPick: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    PickerRow(label, SubtitleGenText.outputLanguage(value), enabled) { expanded = true }
    if (expanded) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { expanded = false },
            confirmButton = {},
            title = { Text(label, style = McType.bodySemibold) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    SubtitleGenText.outputLanguages.forEach { (token, name) ->
                        Text(
                            name,
                            style = if (token == value) McType.subSemibold else McType.sub,
                            color = TextPrimary,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    expanded = false
                                    if (token != value) onPick(token)
                                }
                                .padding(vertical = 10.dp),
                        )
                    }
                }
            },
        )
    }
}

@Composable
private fun LanguageOptionsPicker(
    label: String,
    value: String,
    options: List<PgsLanguageOption>,
    onPick: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val current = options.firstOrNull { it.code == value }
    PickerRow(label, current?.label ?: "请选择", enabled = true) { expanded = true }
    if (expanded) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { expanded = false },
            confirmButton = {},
            title = { Text(label, style = McType.bodySemibold) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    options.forEach { option ->
                        Text(
                            option.label,
                            style = if (option.code == value) McType.subSemibold else McType.sub,
                            color = TextPrimary,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    expanded = false
                                    onPick(option.code)
                                }
                                .padding(vertical = 10.dp),
                        )
                    }
                }
            },
        )
    }
}

@Composable
private fun PickerRow(label: String, value: String, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Color.White.copy(alpha = 0.06f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = McType.sub, color = TextMuted, modifier = Modifier.weight(1f))
        Text(value, style = McType.sub, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Icon(Icons.Rounded.ArrowDropDown, contentDescription = null, tint = TextMuted, modifier = Modifier.size(18.dp))
    }
}

/**
 * 入口与弹层的动作集：由 `ItemDetailScreen` 从 VM 上接好、随状态一起递给 `Hero`
 * （Hero 拿不到 VM，与文件里其它回调同一个路子）。fileId 由界面按当前文件传入。
 */
internal data class SubtitleGenActions(
    val onEntryClick: (Long) -> Unit,
    val onTrack: (Long?) -> Unit,
    val onDismiss: () -> Unit,
    val onTargetLanguage: (Long, String) -> Unit,
    val onSecondaryLanguage: (Long, String) -> Unit,
    val onBilingual: (Long, Boolean) -> Unit,
    val onSourceKey: (Long, String) -> Unit,
    val onPgsLanguage: (String) -> Unit,
    val onConfirm: (Long) -> Unit,
    val onRetryPreview: (Long) -> Unit,
    val onCancelJob: () -> Unit,
    val onHandOffToAgent: (Long) -> Unit,
)

/** 弹层与入口共用的界面状态（数据与动作都在 `ItemDetailViewModel` 里） */
data class SubtitleGenUiState(
    val gate: LlmGate = LlmGate.CHECKING,
    val generated: Boolean = false,
    val mode: SubtitleGenMode? = null,
    val previewing: Boolean = false,
    val preview: SubtitleGenPreviewView? = null,
    val pendingMessage: String? = null,
    val requestError: String? = null,
    val job: JobView? = null,
    val starting: Boolean = false,
    val agentStarting: Boolean = false,
    val targetLanguage: String = "chs",
    val bilingual: Boolean = false,
    val secondaryLanguage: String = "eng",
    /** 用户指定的参考字幕（null = 用服务端默认策略） */
    val sourceKey: String? = null,
    /** PGS：原字幕语言（需确认时由用户选） */
    val pgsOcrLanguage: String = "",
)
