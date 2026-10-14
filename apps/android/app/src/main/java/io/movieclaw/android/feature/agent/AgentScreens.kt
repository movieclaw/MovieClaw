package io.movieclaw.android.feature.agent

import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.playback.PlayTarget
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Build
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.MarkdownText
import androidx.compose.foundation.layout.heightIn
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.SessionSummary

/** AI 助手会话列表 */
@Composable
fun AgentSessionsScreen(
    onBack: () -> Unit,
    onOpenSession: (String) -> Unit,
    onNewSession: () -> Unit,
    vm: AgentSessionsViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.statusBarsPadding().padding(horizontal = 4.dp),
        ) {
            McNavButton(
                icon = Icons.AutoMirrored.Rounded.ArrowBack,
                contentDescription = "返回",
                onClick = onBack,
            )
            Text("AI 助手", style = McType.headline)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onNewSession) {
                Icon(Icons.Rounded.Add, contentDescription = "新会话", tint = Accent)
            }
        }
        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::load)
            state.sessions.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("还没有会话", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(6.dp))
                    Text("点右上角「+」开始与 AI 助手对话", fontSize = 11.5.sp, color = TextFaint)
                }
            }
            else -> LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(state.sessions, key = { it.id }) { session ->
                    SessionRow(session, onOpen = { onOpenSession(session.id) }, onDelete = { vm.delete(session) })
                }
            }
        }
    }
}

@Composable
private fun SessionRow(session: SessionSummary, onOpen: () -> Unit, onDelete: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.045f))
            .clickable(onClick = onOpen)
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                session.title?.takeIf { it.isNotEmpty() } ?: "未命名会话",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (session.running) {
                CircularProgressIndicator(color = Accent, modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(6.dp))
                Text("运行中", fontSize = 10.5.sp, color = Accent)
            }
            IconButton(onClick = onDelete, modifier = Modifier.size(28.dp)) {
                Icon(Icons.Rounded.Delete, contentDescription = "删除", tint = TextFaint, modifier = Modifier.size(16.dp))
            }
        }
        session.lastPrompt?.takeIf { it.isNotEmpty() }?.let {
            Spacer(Modifier.height(4.dp))
            Text(it, fontSize = 11.5.sp, color = TextMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.height(5.dp))
        Text(
            "${session.entryCount} 条记录 · ${McFormat.relative(session.updatedAt)}",
            fontSize = 10.5.sp,
            color = TextFaint,
        )
    }
}

/** 对话页:流式渲染 */
@Composable
fun AgentConversationScreen(
    onBack: () -> Unit,
    /** 生成式 UI 媒体卡片的跳转（默认空实现，预览/测试环境不受影响） */
    onOpenTitle: (String) -> Unit = {},
    onOpenLibrary: (Long) -> Unit = {},
    onOpenItem: (Long, Long) -> Unit = { _, _ -> },
    onOpenSubscription: (Long) -> Unit = {},
    onPlay: (PlayTarget) -> Unit = {},
    vm: AgentConversationViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let(vm::attachImage)
    }

    val feedback = LocalFeedback.current

    LaunchedEffect(state.notice) {
        state.notice?.let {
            feedback.show(it)
            vm.consumeNotice()
        }
    }
    // 按「行」滚动到底（fold 之后行数少于气泡数，旧的 bubbles.size-1 会越界）
    val rowCount = remember(state.bubbles, state.running) {
        conversationRows(state.bubbles, active = state.running).size
    }
    LaunchedEffect(rowCount) {
        if (rowCount > 0) listState.animateScrollToItem(rowCount - 1)
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().imePadding()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.statusBarsPadding().padding(horizontal = 4.dp),
            ) {
                McNavButton(
                    icon = Icons.AutoMirrored.Rounded.ArrowBack,
                    contentDescription = "返回",
                    onClick = onBack,
                )
                Column(Modifier.weight(1f)) {
                    Text(
                        state.title,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (state.model != null) {
                        Text("${state.provider ?: ""} · ${state.model}", fontSize = 10.sp, color = TextFaint)
                    }
                }
                if (state.running) {
                    TextButton(onClick = vm::stop) {
                        Icon(Icons.Rounded.Stop, contentDescription = null, tint = Danger, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("停止", fontSize = 12.sp, color = Danger)
                    }
                }
            }

            // iOS AgentProcessBlock 同口径：连续的「思考 / 工具」折成一行「过程」，点开才看细节；
            // 媒体卡片不折叠（卡片就是那次调用的呈现）
            val rows = remember(state.bubbles, state.running) {
                conversationRows(state.bubbles, active = state.running)
            }
            when {
                state.loading -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted)
                }
                state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::loadTranscript)
                else -> {
                LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                ) {
                    items(rows, key = { it.key }) { row ->
                        when (row) {
                            is ConversationRow.Single -> BubbleRow(
                                bubble = row.bubble,
                                origin = state.origin,
                                knownSkills = state.knownSkills,
                                // 运行中不给改写入口（服务端会拒绝替换正在写轨迹的会话，同 iOS）
                                onEditMessage = if (state.running) {
                                    null
                                } else {
                                    { id, text -> vm.beginEdit(id, text) }
                                },
                                onOpenCard = { open ->
                                    when (open) {
                                        is AgentMediaCardOpen.Title -> onOpenTitle(open.titleRef)
                                        is AgentMediaCardOpen.Library -> onOpenLibrary(open.libraryId)
                                        is AgentMediaCardOpen.Item -> onOpenItem(open.libraryId, open.mediaItemId)
                                        is AgentMediaCardOpen.Subscription -> onOpenSubscription(open.subscriptionId)
                                    }
                                },
                                onPlay = onPlay,
                            )
                            is ConversationRow.Process -> ProcessBlock(
                                items = row.items,
                                active = row.active,
                                origin = state.origin,
                            )
                        }
                    }
                    if (state.running && state.bubbles.isEmpty()) {
                        item {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(color = Accent, modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.width(8.dp))
                                Text("思考中…", fontSize = 12.sp, color = TextMuted)
                            }
                        }
                    }
                }
                }
            }

            if (state.attachments.isNotEmpty() || state.uploading) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                ) {
                    state.attachments.forEach { attachment ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .background(AccentSoft)
                                .clickable { vm.removeAttachment(attachment.attachmentId) }
                                .padding(horizontal = 10.dp, vertical = 4.dp),
                        ) {
                            Icon(Icons.Rounded.Image, contentDescription = null, tint = Accent, modifier = Modifier.size(13.dp))
                            Spacer(Modifier.width(5.dp))
                            Text(attachment.name.take(18), fontSize = 11.sp, color = Accent)
                            Spacer(Modifier.width(5.dp))
                            Text("×", fontSize = 12.sp, color = Accent)
                        }
                    }
                    if (state.uploading) {
                        Text("上传中…", fontSize = 11.sp, color = TextFaint)
                    }
                }
            }

            // 与新会话页共用同一个 composer（附件 tray / 输入容器 / 工具行 / 模型菜单）
            AgentComposerBar(
                input = state.input,
                onInput = vm::onInput,
                placeholder = "问点什么,或让我干活…",
                attachments = state.attachments,
                uploading = state.uploading,
                onPickImage = {
                    pickImage.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                    )
                },
                onRemoveAttachment = vm::removeAttachment,
                models = state.models,
                modelRef = state.modelRef,
                thinkingLevel = state.thinkingLevel,
                onPickModel = vm::setModel,
                onPickThinking = vm::setThinkingLevel,
                sendEnabled = !state.running && !state.uploading,
                sending = state.running,
                onSend = vm::send,
                maxLines = 5,
                horizontalPadding = 12.dp,
            )
        }
    }
}

/** 模型 chip（iOS `toolRow` 里的那颗：标签 13sp 弱色 + 下拉箭头，高 44dp） */
@Composable
internal fun ModelChip(label: String, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .height(44.dp)
            .clip(RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 13.sp, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.width(4.dp))
        Icon(Icons.Rounded.KeyboardArrowDown, contentDescription = null, tint = TextMuted, modifier = Modifier.size(14.dp))
    }
}

/** 模型 + 思维链菜单（选项与档位文案都照 iOS `AgentModelMenu` / `AgentThinking`） */
@Composable
internal fun ModelMenu(
    models: List<io.movieclaw.android.core.model.LlmModelOption>,
    modelRef: String?,
    thinkingLevel: String?,
    onPickModel: (String?) -> Unit,
    onPickThinking: (String?) -> Unit,
) {
    val current = AgentThinking.resolve(models, modelRef)
    val stops = AgentThinking.stops(current?.thinkingLevels.orEmpty())
    Column(
        Modifier
            .width(272.dp)
            .heightIn(max = 416.dp)
            .verticalScroll(rememberScrollState())
            .padding(4.dp),
    ) {
        Text(
            "模型",
            fontSize = 13.sp,
            color = TextFaint,
            modifier = Modifier.padding(start = 10.dp, top = 4.dp, bottom = 2.dp),
        )
        models.forEach { option ->
            val selected = option.ref == current?.ref
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .clickable {
                        // 选回全局默认项 = 「默认」（nil）：续聊沿用、设置页改默认后自动跟随
                        onPickModel(if (option.isDefault) null else option.ref)
                    }
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    option.label,
                    fontSize = 15.sp,
                    color = if (selected) TextPrimary else TextMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (selected) {
                    Icon(Icons.Rounded.Check, contentDescription = null, tint = TextPrimary, modifier = Modifier.size(15.dp))
                }
            }
        }
        if (stops.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            Text(
                "思维链",
                fontSize = 15.sp,
                color = TextMuted,
                modifier = Modifier.padding(start = 10.dp, bottom = 6.dp),
            )
            // 分段（nil = 默认；iOS 两档时是开关、多档时是滑条，触屏上分段更好点）
            androidx.compose.foundation.layout.FlowRow(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier.padding(start = 10.dp, end = 10.dp, bottom = 6.dp),
            ) {
                val items = listOf<String?>(null) + stops
                items.forEach { level ->
                    val selected = level == thinkingLevel
                    Text(
                        AgentThinking.label(level),
                        fontSize = 14.sp,
                        color = if (selected) TextPrimary else TextMuted,
                        modifier = Modifier
                            .clip(RoundedCornerShape(9.dp))
                            .background(if (selected) Color.White.copy(alpha = 0.14f) else Color.Transparent)
                            .clickable { onPickThinking(level) }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                }
            }
        }
    }
}

/** 对话行：单条气泡，或折叠起来的「处理过程」（iOS AgentProcessBlock） */
private sealed interface ConversationRow {
    val key: String

    data class Single(
        override val key: String,
        val bubble: AgentConversationViewModel.Bubble,
    ) : ConversationRow

    data class Process(
        override val key: String,
        val items: List<AgentConversationViewModel.Bubble>,
        val active: Boolean,
    ) : ConversationRow
}

/**
 * 气泡流 → 行：连续的「思考 / 工具」合成一个处理块；同一条 assistant 气泡里既有推理又有正文时，
 * 推理进处理块、正文单独成行；媒体卡片不折叠、单独成行（iOS 同口径）。
 */
private fun conversationRows(
    bubbles: List<AgentConversationViewModel.Bubble>,
    active: Boolean,
): List<ConversationRow> {
    val rows = mutableListOf<ConversationRow>()
    var pending = mutableListOf<AgentConversationViewModel.Bubble>()
    fun flush(isActive: Boolean) {
        if (pending.isEmpty()) return
        rows += ConversationRow.Process("proc-" + pending.first().id, pending.toList(), isActive)
        pending = mutableListOf()
    }
    bubbles.forEach { b ->
        val foldable = b.mediaCards == null && (
            b.role == "tool" ||
                (
                    b.role == "assistant" && b.text.isBlank() &&
                        (b.toolName != null || !b.thinking.isNullOrBlank())
                    )
            )
        when {
            foldable -> pending += b
            else -> {
                if (b.role == "assistant" && !b.thinking.isNullOrBlank()) {
                    // 推理进处理块；正文行把 thinking 摘掉，免得同一段推理画两遍
                    pending += b.copy(text = "")
                    flush(false)
                    rows += ConversationRow.Single(b.id, b.copy(thinking = null))
                    return@forEach
                }
                flush(false)
                rows += ConversationRow.Single(b.id, b)
            }
        }
    }
    flush(active)
    return rows
}

/** 进行中的一句话状态（iOS AgentTimeline.processStatus，逐条对齐） */
private fun processStatus(items: List<AgentConversationViewModel.Bubble>): String {
    val tail = items.lastOrNull() ?: return "思考中…"
    if (tail.role != "tool") return "思考中…"
    // 安卓的 tool 气泡在调用事件到达时就有名字：还没有输出 = 正在执行
    if (tail.toolOutput == null) return "正在执行 ${tail.toolName ?: "工具"}…"
    return "思考中…" // 工具已返回，正在等模型的下一步
}

/** 已完成处理块的一句话总结（iOS AgentTimeline.processSummary 同文案） */
private fun processSummary(items: List<AgentConversationViewModel.Bubble>): String {
    var hasThinking = false
    var commands = 0
    var others = 0
    items.forEach { b ->
        if (b.role == "tool") {
            if (b.toolName == "bash") commands++ else others++
        } else {
            hasThinking = true
        }
    }
    val parts = buildList {
        if (hasThinking) add("思考")
        if (commands > 0) add("执行 $commands 次命令")
        if (others > 0) add("调用 $others 次工具")
    }
    return if (parts.isEmpty()) "处理过程" else "已" + parts.joinToString("，")
}

/** 进行中的呼吸感（iOS AgentPulse 同款：透明度往复） */
@Composable
private fun Modifier.pulse(active: Boolean): Modifier {
    if (!active) return this
    val t = remember { androidx.compose.animation.core.Animatable(1f) }
    LaunchedEffect(Unit) {
        // 往复呼吸（等价 iOS AgentPulse）：用两段 animateTo 循环，避免 repeatMode 参数名差异
        while (true) {
            t.animateTo(0.45f, androidx.compose.animation.core.tween(760, easing = androidx.compose.animation.core.LinearEasing))
            t.animateTo(1f, androidx.compose.animation.core.tween(760, easing = androidx.compose.animation.core.LinearEasing))
        }
    }
    return this.graphicsLayer { alpha = t.value }
}

/** 折叠的「处理过程」：一行状态/总结，点开看推理原文与工具行 */
@Composable
private fun ProcessBlock(
    items: List<AgentConversationViewModel.Bubble>,
    active: Boolean,
    origin: String?,
) {
    var open by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .clickable { open = !open }
                .padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                if (open) Icons.Rounded.ExpandMore else Icons.Rounded.ChevronRight,
                contentDescription = if (open) "收起过程" else "展开过程",
                tint = TextFaint,
                modifier = Modifier.size(17.dp),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                if (active) processStatus(items) else processSummary(items),
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = TextFaint,
                modifier = Modifier.pulse(active),
            )
        }
        if (open) {
            Column(
                Modifier.padding(start = 21.dp, top = 2.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items.forEach { item ->
                    key(item.id) {
                        if (item.role == "tool") {
                            ToolBubble(item)
                        } else {
                            MarkdownText(
                                markdown = item.thinking.orEmpty(),
                                baseSize = 13.sp,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .heightIn(max = 220.dp)
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(Color.White.copy(alpha = 0.03f))
                                    .padding(10.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

/** 工具行（原「tool」分支的内容；处理块展开后也用它） */
@Composable
private fun ToolBubble(bubble: AgentConversationViewModel.Bubble) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .padding(11.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Rounded.Build,
                contentDescription = null,
                tint = if (bubble.toolError) Danger else Info,
                modifier = Modifier.size(15.dp),
            )
            Spacer(Modifier.width(7.dp))
            Text(bubble.text, fontSize = 13.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            if (bubble.streaming) {
                CircularProgressIndicator(color = Info, modifier = Modifier.size(12.dp), strokeWidth = 2.dp)
            }
        }
        bubble.toolOutput?.takeIf { it.isNotBlank() }?.let { output ->
            Spacer(Modifier.height(6.dp))
            Text(
                output,
                fontSize = 13.sp,
                lineHeight = 18.sp,
                fontFamily = FontFamily.Monospace,
                color = if (bubble.toolError) Warning else TextMuted,
                maxLines = 12,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun BubbleRow(
    bubble: AgentConversationViewModel.Bubble,
    origin: String?,
    /** 已知技能名（小写）：`/skill:名字` 只把名单内的画成 chip（同 iOS knownSkills） */
    knownSkills: Set<String>?,
    /** 「改写这条提问」：null = 运行中不给入口 */
    onEditMessage: ((messageId: String, text: String) -> Unit)?,
    onOpenCard: (AgentMediaCardOpen) -> Unit,
    onPlay: (PlayTarget) -> Unit,
) {
    when (bubble.role) {
        "user" -> {
            // iOS `AgentUserBubble`：**半透明白玻璃**气泡（Color.white.opacity(0.1)、圆角 18、
            // 内距 16/12、正文 16pt），不是强调色实心块——安卓这边一直是 Accent 实心，
            // 与 iOS 的淡玻璃口径不同（用户 2026-10-13 反馈）
            var revealed by remember { mutableStateOf(false) }
            val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
            // `/skill:名字` → chip，正文只留用户自己的话（iOS `AgentSkillText.parseTokens`）
            val (skillNames, body) = remember(bubble.text, knownSkills) {
                AgentSkillText.parseTokens(bubble.text, knownSkills)
            }
            Column(
                Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.End,
            ) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    Column(
                        Modifier
                            .fillMaxWidth(0.85f)
                            .clip(RoundedCornerShape(18.dp))
                            .background(Color.White.copy(alpha = 0.10f))
                            .clickable { revealed = !revealed }
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    ) {
                        if (skillNames.isNotEmpty()) {
                            androidx.compose.foundation.layout.FlowRow(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                skillNames.forEach { name ->
                                    Text(
                                        "⚡ $name",
                                        fontSize = 13.sp,
                                        color = TextMuted,
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(8.dp))
                                            .background(Color.White.copy(alpha = 0.08f))
                                            .padding(horizontal = 8.dp, vertical = 2.dp),
                                    )
                                }
                            }
                            if (body.isNotBlank()) Spacer(Modifier.height(8.dp))
                        }
                        if (body.isNotBlank()) {
                            MarkdownText(markdown = body, baseSize = 16.sp)
                        }
                    }
                }
                // 点气泡浮现「复制 / 改写」（iOS tap-reveal 的同款位置：气泡下方、右对齐、
                // 两颗并排 8dp 间距、13sp 弱色）
                if (revealed) {
                    Spacer(Modifier.height(6.dp))
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(
                            Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable {
                                    clipboard.setText(androidx.compose.ui.text.AnnotatedString(bubble.text))
                                    revealed = false
                                }
                                .padding(horizontal = 4.dp, vertical = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                Icons.Rounded.ContentCopy,
                                contentDescription = null,
                                tint = TextFaint,
                                modifier = Modifier.size(13.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                            Text("复制", fontSize = 13.sp, color = TextFaint)
                        }
                        if (onEditMessage != null) {
                            Row(
                                Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickable {
                                        revealed = false
                                        onEditMessage(bubble.id, bubble.text)
                                    }
                                    .padding(horizontal = 4.dp, vertical = 2.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(
                                    Icons.Rounded.Edit,
                                    contentDescription = null,
                                    tint = TextFaint,
                                    modifier = Modifier.size(13.dp),
                                )
                                Spacer(Modifier.width(4.dp))
                                Text("改写", fontSize = 13.sp, color = TextFaint)
                            }
                        }
                    }
                }
            }
        }
        "system" -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Text(
                bubble.text,
                fontSize = 10.5.sp,
                color = TextFaint,
                modifier = Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .background(Color.White.copy(alpha = 0.05f))
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            )
        }
        "tool" -> if (bubble.mediaCards != null) {
            // 生成式 UI：工具行被卡片组替代（iOS 同口径，卡片就是这次调用的呈现）
            AgentMediaCardsRow(bubble.mediaCards, origin = origin, onOpen = onOpenCard, onPlay = onPlay)
        } else {
            ToolBubble(bubble)
        }
        else -> Column(Modifier.fillMaxWidth()) {
            // 推理不再画在正文里：`conversationRows` 已把它归进折叠的「处理过程」块
            // （iOS AgentProcessBlock 同口径）
            if (bubble.text.isEmpty() && bubble.streaming) {
                Text("…", fontSize = 14.sp, lineHeight = 21.sp, color = Color.White.copy(alpha = 0.92f))
            } else if (bubble.text.isNotBlank() || bubble.mediaCards == null) {
                // AI 回复按 Markdown 渲染(标题/列表/代码块/表格/引用)；只有卡片没有正文时不画空块
                MarkdownText(markdown = bubble.text, baseSize = 14.sp)
            }
            bubble.mediaCards?.let { group ->
                if (bubble.text.isNotBlank()) Spacer(Modifier.height(8.dp))
                AgentMediaCardsRow(group, origin = origin, onOpen = onOpenCard, onPlay = onPlay)
            }
        }
    }
}
