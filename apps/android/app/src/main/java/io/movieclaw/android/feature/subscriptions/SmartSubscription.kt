package io.movieclaw.android.feature.subscriptions

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warn
import io.movieclaw.android.core.model.SmartDefaultsPayload
import io.movieclaw.android.core.model.SmartMemoryView
import io.movieclaw.android.core.model.SmartPlanView
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/**
 * 订阅弹层里管理员做的选择（字幕回答、改过的画质与记住的范围），随创建请求提交、由服务端写入记忆
 * （docs/design/smart-subscription-memory.md；Web `smart-plan-card.tsx`、iOS `SmartPlanSection` 同口径）。
 */
data class SmartChoice(
    val language: String? = null,
    val resolution: String? = null,
    val source: String? = null,
    val scope: String = "only",
) {
    fun qualityChanged(plan: SmartPlanView): Boolean =
        (resolution ?: plan.resolution) != plan.resolution || (source ?: plan.source) != plan.source
}

/** 创建请求里的智能字段。题目出现时即使没改也回传默认答案：答过就不再问；成员什么都不带。 */
data class SmartFields(
    val language: String?,
    val resolution: String?,
    val source: String?,
    val scope: String?,
    val memoryRevision: Long?,
)

fun smartFields(plan: SmartPlanView, choice: SmartChoice): SmartFields {
    if (!plan.canEdit) return SmartFields(null, null, null, null, null)
    val language = choice.language ?: if (plan.question != null) "subtitles" else null
    val resolution = choice.resolution?.takeIf { it != plan.resolution }
    val source = choice.source?.takeIf { it != plan.source }
    return SmartFields(language, resolution, source, choice.scope.takeIf { resolution != null || source != null }, plan.memoryRevision)
}

internal fun qualityText(resolution: String?, source: String?): String =
    "${if (resolution == "2160p") "4K" else resolution.orEmpty()} " +
        (mapOf("web-dl" to "WEB-DL", "blu-ray" to "蓝光", "remux" to "Remux")[source] ?: source.orEmpty())

internal fun waitText(seconds: Int): String = when {
    seconds == 0 -> "尽快下载"
    seconds % 86400 == 0 -> "最多等 ${seconds / 86400} 天"
    else -> "最多等 ${seconds / 3600} 小时"
}

/** 智能等待状态 → 分集行的标签与说明（只补充智能特有的状态，其余沿用原有分集状态）。 */
fun smartPresentation(state: JsonObject?, status: String): Pair<String, String>? {
    if (status != "wanted" || state == null) return null
    val reason = (state["reason"] as? JsonPrimitive)?.content ?: return null
    val hasCandidate = (state["candidate_key"] as? JsonPrimitive)?.isString == true
    return when (reason) {
        "awaiting_subtitles" -> "等字幕" to "已有 ${(state["subtitle_blocked"] as? JsonPrimitive)?.intOrNull ?: 1} 个原版，在等带字幕的版本"
        "deadline_awaiting_subtitles" -> "等字幕" to "等待期已过，仍没有字幕版；原版不会自动下载"
        "identity_unconfirmed" -> "寻找中" to "部分资源未通过影片身份核验，已跳过，继续寻找。"
        "user_extended" -> "观察中" to "按你延长的时间继续等待合适版本"
        "waiting_target", "waiting_series" -> if (hasCandidate) "等版本" to "已有合格候选，等待更合适的版本" else null
        "manual_requested" -> "选择中" to "已请求立即下载，正在核验当前候选"
        "observing" -> if (hasCandidate) "观察中" to "已有合格候选，短暂观察更合适的版本" else null
        else -> null
    }
}

/** 服务端时间是不带时区的 UTC（或带偏移）→ 本地「10-21 16:30」 */
internal fun localTimeText(iso: String, zone: java.time.ZoneId = java.time.ZoneId.systemDefault()): String {
    val instant = runCatching { java.time.OffsetDateTime.parse(iso).toInstant() }.getOrNull()
        ?: runCatching { java.time.LocalDateTime.parse(iso).toInstant(java.time.ZoneOffset.UTC) }.getOrNull()
        ?: return iso
    return java.time.format.DateTimeFormatter.ofPattern("MM-dd HH:mm").withZone(zone).format(instant)
}

internal fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

@Composable
private fun RadioRow(label: String, selected: Boolean, tag: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .semantics { role = Role.RadioButton; this.selected = selected }
            .testTag(tag)
            .padding(horizontal = 4.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(18.dp).clip(CircleShape).border(if (selected) 5.dp else 1.5.dp, if (selected) Accent else TextMuted, CircleShape),
        )
        Spacer(Modifier.width(10.dp))
        Text(label, fontSize = 14.sp, color = TextPrimary)
    }
}

@Composable
private fun ChoiceGroup(title: String, options: List<Pair<String, String>>, current: String, tag: String, onPick: (String) -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Text(title, fontSize = 13.5.sp, color = TextPrimary, fontWeight = FontWeight.Medium, modifier = Modifier.padding(vertical = 4.dp))
        options.forEach { (value, label) ->
            RadioRow(label, value == current, "$tag-$value") { onPick(value) }
        }
    }
}

@Composable
private fun Segmented(options: List<Pair<String, String>>, current: String, tag: String, onPick: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.06f)).padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        options.forEach { (value, label) ->
            val on = value == current
            Text(
                label,
                fontSize = 13.sp,
                fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                color = if (on) Color(0xFF141821) else TextMuted,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (on) Accent else Color.Transparent)
                    .clickable { onPick(value) }
                    .semantics { selected = on }
                    .testTag("$tag-$value")
                    .padding(vertical = 8.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
}

/** 订阅弹层的智能选择卡片：摘要来自服务端；管理员可回答语言问题、改字幕回答、改画质、改设置。 */
@Composable
fun SmartPlanCard(
    plan: SmartPlanView?,
    choice: SmartChoice,
    onChoice: (SmartChoice) -> Unit,
    onEditSettings: () -> Unit,
    onEditQuality: () -> Unit,
    editingSubtitle: Boolean,
    onEditSubtitle: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.05f))
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(14.dp))
            .padding(14.dp)
            .testTag("smart-card"),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("智能选择", fontSize = 12.5.sp, color = TextMuted, modifier = Modifier.weight(1f))
            if (plan?.canEdit == true && plan.configured) {
                Text("修改设置", fontSize = 13.sp, color = Accent, modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onEditSettings).testTag("smart-edit").padding(6.dp))
            }
        }
        when {
            plan == null -> Text("正在读取设置…", fontSize = 13.sp, color = TextMuted)
            !plan.configured && plan.canEdit -> {
                Spacer(Modifier.height(6.dp))
                Text("设置一次，电影和剧集都按它来", fontSize = 13.sp, color = TextMuted)
                Spacer(Modifier.height(8.dp))
                Text(
                    "设置智能偏好",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color(0xFF141821),
                    modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(Accent).clickable(onClick = onEditSettings).testTag("smart-setup").padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
            !plan.configured -> Text("请管理员先完成智能设置，或选择规则模式。", fontSize = 13.sp, color = TextMuted, modifier = Modifier.padding(top = 6.dp).testTag("smart-needs-admin"))
            else -> {
                val changed = choice.qualityChanged(plan)
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (changed) "优先 ${qualityText(choice.resolution ?: plan.resolution, choice.source ?: plan.source)}" else plan.qualityLabel.orEmpty(),
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f).testTag("smart-quality-label"),
                    )
                    if (plan.canEdit) {
                        Text("改画质", fontSize = 13.sp, color = Accent, modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onEditQuality).testTag("smart-quality").padding(6.dp))
                    }
                }
                if (!changed) plan.qualityNote?.let { Text(it, fontSize = 12.sp, color = TextMuted, modifier = Modifier.testTag("smart-quality-note")) }
                if (!changed) plan.qualityShadow?.let { Text(it, fontSize = 12.sp, color = TextMuted, modifier = Modifier.testTag("smart-quality-shadow")) }
                if (changed) {
                    val scope = plan.scopeOptions.firstOrNull { it.value == choice.scope }?.label ?: "只这部"
                    Text(if (choice.scope == "only") "只这部" else "以后「$scope」都这样", fontSize = 12.sp, color = TextMuted)
                }
                plan.waitLabel?.let { Text(it, fontSize = 12.5.sp, color = TextMuted, modifier = Modifier.padding(top = 2.dp)) }
                val language = plan.subtitleLanguageLabel
                val line = plan.subtitleLine
                if (language != null && line != null) {
                    Spacer(Modifier.height(10.dp))
                    val answer = choice.language ?: if (plan.subtitleUnderstood == true) "understood" else "subtitles"
                    val question = plan.question
                    if (plan.canEdit && (question != null || editingSubtitle)) {
                        ChoiceGroup(
                            title = question?.prompt ?: "${language}看得懂吗？",
                            options = listOf(
                                "subtitles" to (question?.subtitlesLabel ?: if (plan.subtitleUnderstood == true) "要，只下带字幕的" else line.replace("$language · ", "要，")),
                                "understood" to (question?.understoodLabel ?: "不用，我看得懂$language"),
                            ),
                            current = answer,
                            tag = "smart-language",
                        ) { onChoice(choice.copy(language = it)) }
                    } else {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                            Text(
                                if (choice.language == "understood") "$language · 不需要字幕" else line,
                                fontSize = 13.5.sp,
                                modifier = Modifier.weight(1f).testTag("smart-subtitle-line"),
                            )
                            if (plan.canEdit) {
                                Text("改", fontSize = 13.sp, color = Accent, modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onEditSubtitle).testTag("smart-language-edit").padding(6.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 改画质：只改这一部，或记成某类作品的习惯（范围选项来自这部作品本身）。 */
@OptIn(ExperimentalMaterial3Api::class, androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun SmartQualitySheet(plan: SmartPlanView, choice: SmartChoice, onChoice: (SmartChoice) -> Unit, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Color(0xFF15161A), contentColor = TextPrimary) {
        Column(Modifier.fillMaxWidth().semantics { testTagsAsResourceId = true }.padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("画质", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Text("完成", fontSize = 15.sp, color = Accent, modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onDismiss).testTag("smart-quality-done").padding(6.dp))
            }
            Spacer(Modifier.height(12.dp))
            Segmented(listOf("2160p" to "4K", "1080p" to "1080p"), choice.resolution ?: plan.resolution.orEmpty(), "smart-quality-resolution") { onChoice(choice.copy(resolution = it)) }
            Spacer(Modifier.height(8.dp))
            Segmented(listOf("web-dl" to "WEB-DL", "blu-ray" to "蓝光", "remux" to "Remux"), choice.source ?: plan.source.orEmpty(), "smart-quality-source") { onChoice(choice.copy(source = it)) }
            if (choice.qualityChanged(plan)) {
                Spacer(Modifier.height(16.dp))
                ChoiceGroup("以后也这样吗？", plan.scopeOptions.map { it.value to it.label }, choice.scope, "smart-scope") { onChoice(choice.copy(scope = it)) }
                Spacer(Modifier.height(6.dp))
                Text("选「只这部」只改这一部；其他选项会记住，同类作品以后都这样。", fontSize = 12.sp, color = TextFaint)
            }
        }
    }
}

/** 智能设置（一套）：画质、洗版、最低要求共用，电影和剧集各一个等待上限；下面是它记住的东西。 */
@OptIn(ExperimentalMaterial3Api::class, androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun SmartSettingsSheet(
    draft: SmartDefaultsPayload?,
    configured: Boolean,
    memory: SmartMemoryView?,
    busy: Boolean,
    error: String?,
    onDraft: (SmartDefaultsPayload) -> Unit,
    onSave: () -> Unit,
    onLanguage: (String, Boolean) -> Unit,
    onRemoveHabit: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Color(0xFF15161A), contentColor = TextPrimary) {
        Column(Modifier.fillMaxWidth().semantics { testTagsAsResourceId = true }.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("取消", fontSize = 15.sp, color = TextMuted, modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onDismiss).testTag("smart-cancel-edit").padding(6.dp))
                Text("智能设置", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                Text(
                    if (busy) "保存中…" else "保存",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (draft != null && !busy) Accent else TextFaint,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = draft != null && !busy, onClick = onSave).testTag("smart-save").padding(6.dp),
                )
            }
            error?.let { Text(it, fontSize = 12.5.sp, color = Danger, modifier = Modifier.padding(top = 8.dp)) }
            if (draft == null) {
                Text("正在读取智能设置…", fontSize = 13.sp, color = TextMuted, modifier = Modifier.padding(vertical = 16.dp))
                return@Column
            }
            Text(if (configured) "新订阅和还在等待的订阅都会按新设置来，已经下载的不受影响。" else "只需设置一次，电影和剧集都按它来。", fontSize = 12.sp, color = TextFaint, modifier = Modifier.padding(vertical = 10.dp))
            Text("优先分辨率", fontSize = 12.5.sp, color = TextMuted)
            Spacer(Modifier.height(6.dp))
            Segmented(listOf("2160p" to "4K", "1080p" to "1080p"), draft.resolution, "smart-resolution") { onDraft(draft.copy(resolution = it)) }
            Spacer(Modifier.height(12.dp))
            Text("优先片源", fontSize = 12.5.sp, color = TextMuted)
            Spacer(Modifier.height(6.dp))
            Segmented(listOf("web-dl" to "WEB-DL", "blu-ray" to "蓝光", "remux" to "Remux"), draft.source, "smart-source") { onDraft(draft.copy(source = it)) }
            Spacer(Modifier.height(12.dp))
            WaitChoice("电影最多等", draft.movieWaitSeconds, "smart-movie-wait") { onDraft(draft.copy(movieWaitSeconds = it)) }
            Spacer(Modifier.height(12.dp))
            WaitChoice("剧集每集最多等", draft.tvWaitSeconds, "smart-tv-wait") { onDraft(draft.copy(tvWaitSeconds = it)) }
            SwitchRow("允许后续洗版", draft.allowUpgrade, "smart-upgrade") { onDraft(draft.copy(allowUpgrade = it)) }
            SwitchRow("只接受 ${if (draft.resolution == "2160p") "4K" else "1080p"}，到期也不降低分辨率", draft.strictResolution, "smart-strict-resolution") { onDraft(draft.copy(strictResolution = it)) }
            if (configured && memory != null) {
                Spacer(Modifier.height(18.dp))
                Text("看得懂的语言", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text("这些语言的作品不带字幕也能看；其他语言只下带字幕的版本。", fontSize = 12.sp, color = TextFaint)
                memory.languages.forEach { language ->
                    MemoryRow(
                        title = language.label,
                        detail = if (!language.removable) "默认" else language.sourceTitle?.let { "订阅《$it》时加入" } ?: "在设置里加入",
                        tag = "smart-language-${language.key}",
                        onRemove = if (language.removable) ({ onLanguage(language.key, false) }) else null,
                        removeLabel = "移除${language.label}",
                    )
                }
                if (memory.addableLanguages.isNotEmpty()) {
                    Spacer(Modifier.height(6.dp))
                    Text("添加一种语言", fontSize = 12.5.sp, color = TextMuted)
                    Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        memory.addableLanguages.take(5).forEach { option ->
                            Text(
                                option.label,
                                fontSize = 12.5.sp,
                                modifier = Modifier.clip(RoundedCornerShape(999.dp)).border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(999.dp))
                                    .clickable { onLanguage(option.key, true) }.testTag("smart-language-add-${option.key}").padding(horizontal = 10.dp, vertical = 5.dp),
                            )
                        }
                    }
                }
                if (memory.habits.isNotEmpty()) {
                    Spacer(Modifier.height(18.dp))
                    Text("画质习惯", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    Text("订阅时改过画质并选了「以后也这样」，就记在这里。", fontSize = 12.sp, color = TextFaint)
                    memory.habits.forEach { habit ->
                        MemoryRow(
                            title = "${habit.label} · ${habit.qualityLabel}",
                            detail = habit.sourceTitle?.let { "来自《$it》" } ?: "来自原来的剧集设置",
                            tag = "smart-habit",
                            onRemove = { onRemoveHabit(habit.key) },
                            removeLabel = "移除${habit.label}",
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MemoryRow(title: String, detail: String, tag: String, onRemove: (() -> Unit)?, removeLabel: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag(tag), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 14.sp)
            Text(detail, fontSize = 11.5.sp, color = TextFaint)
        }
        if (onRemove != null) {
            Text(
                "移除",
                fontSize = 13.sp,
                color = Accent,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onRemove)
                    .semantics { contentDescription = removeLabel }.padding(6.dp),
            )
        }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            modifier = Modifier.testTag(tag),
            colors = SwitchDefaults.colors(checkedThumbColor = Color.White, checkedTrackColor = Accent),
        )
    }
}

/** 等待上限：预设三档、自定义 1–7 天；旧版本存下的整小时值原样保留为一档。 */
@Composable
private fun WaitChoice(title: String, seconds: Int, tag: String, onChange: (Int) -> Unit) {
    val presets = listOf(0 to "不等待", 10800 to "3 小时", 86400 to "1 天")
    val custom = seconds !in presets.map { it.first } && seconds % 86400 == 0
    val legacy = seconds !in presets.map { it.first } && seconds % 86400 != 0
    Text(title, fontSize = 12.5.sp, color = TextMuted)
    Spacer(Modifier.height(6.dp))
    val options = presets + listOf(-1 to "自定义") + (if (legacy) listOf(seconds to "原有 ${seconds / 3600} 小时") else emptyList())
    Segmented(options.map { it.first.toString() to it.second }, if (custom) "-1" else seconds.toString(), tag) { value ->
        onChange(if (value == "-1") (maxOf(1, minOf(7, (seconds + 86399) / 86400))) * 86400 else value.toInt())
    }
    if (custom) {
        val days = seconds / 86400
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("最多等待", fontSize = 13.sp, color = TextMuted, modifier = Modifier.weight(1f))
            Text("−", fontSize = 18.sp, color = if (days > 1) TextPrimary else TextFaint, modifier = Modifier.clip(CircleShape).clickable(enabled = days > 1) { onChange((days - 1) * 86400) }.testTag("$tag-minus").padding(horizontal = 12.dp, vertical = 4.dp))
            Text("$days 天", fontSize = 14.sp, modifier = Modifier.testTag("$tag-days"))
            Text("+", fontSize = 18.sp, color = if (days < 7) TextPrimary else TextFaint, modifier = Modifier.clip(CircleShape).clickable(enabled = days < 7) { onChange((days + 1) * 86400) }.testTag("$tag-plus").padding(horizontal = 12.dp, vertical = 4.dp))
        }
    }
}

/** 订阅详情里一个单元的智能等待面板：依据、操作；只有看不懂的原版时提供「这次先下原版」。 */
@Composable
fun SmartWantedPanel(
    state: JsonObject,
    kind: String,
    subtitleLine: String?,
    actionable: Boolean,
    busy: Boolean,
    onDownload: (String) -> Unit,
    onExtend: (Int) -> Unit,
) {
    val reason = state.text("reason")
    val awaiting = reason == "awaiting_subtitles" || reason == "deadline_awaiting_subtitles"
    Column(Modifier.fillMaxWidth().padding(top = 6.dp).testTag(if (awaiting) "smart-awaiting-subtitles" else "smart-selection")) {
        state.text("wait_explanation")?.let { Text(it, fontSize = 12.5.sp, color = TextMuted) }
        if (awaiting) subtitleLine?.let { Text(it, fontSize = 12.5.sp, color = TextMuted, modifier = Modifier.testTag("smart-subtitle-requirement")) }
        if (reason != "deadline_awaiting_subtitles") state.text("deadline")?.let {
            Text("最晚等待至 ${localTimeText(it)}", fontSize = 12.5.sp, fontWeight = FontWeight.Medium, color = TextPrimary)
        }
        state.text("candidate_title")?.let { Text(if (awaiting) "原版：$it" else "当前候选：$it", fontSize = 12.sp, color = TextFaint) }
        val key = state.text("candidate_key")
        if (actionable && key != null) {
            Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    if (busy) "正在处理…" else if (awaiting) "这次先下原版" else "立即下载当前候选",
                    fontSize = 13.sp,
                    color = if (awaiting) TextPrimary else Color(0xFF141821),
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(if (awaiting) Color.White.copy(alpha = 0.08f) else Accent)
                        .clickable(enabled = !busy) { onDownload(key) }
                        .testTag(if (awaiting) "smart-download-original" else "smart-download-now")
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                )
                if (!awaiting) {
                    val seconds = if (kind == "movie") 86400 else 7200
                    Text(
                        if (kind == "movie") "延长 1 天" else "延长 2 小时",
                        fontSize = 13.sp,
                        modifier = Modifier.clip(RoundedCornerShape(999.dp)).border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(999.dp))
                            .clickable(enabled = !busy) { onExtend(seconds) }.testTag("smart-extend-wait").padding(horizontal = 14.dp, vertical = 8.dp),
                    )
                }
            }
        }
        if (reason == "deadline_awaiting_subtitles") Text("出现带字幕的版本会立即选择。", fontSize = 12.sp, color = Warn, modifier = Modifier.padding(top = 4.dp))
    }
}
