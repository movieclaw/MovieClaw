package io.movieclaw.android.feature.agent

import io.movieclaw.android.core.designsystem.LocalFeedback
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.rounded.Build
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Image
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
    LaunchedEffect(state.bubbles.size) {
        if (state.bubbles.isNotEmpty()) listState.animateScrollToItem(state.bubbles.size - 1)
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

            when {
                state.loading -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted)
                }
                state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::loadTranscript)
                else -> LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                ) {
                    items(state.bubbles, key = { it.id }) { bubble -> BubbleRow(bubble) }
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

            Row(
                verticalAlignment = Alignment.Bottom,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                IconButton(onClick = {
                    pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }) {
                    Icon(Icons.Rounded.Image, contentDescription = "添加图片", tint = TextMuted)
                }
                TextField(
                    value = state.input,
                    onValueChange = vm::onInput,
                    placeholder = { Text("问点什么,或让我干活…", fontSize = 13.sp, color = TextFaint) },
                    maxLines = 5,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { vm.send() }),
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.White.copy(alpha = 0.06f),
                        unfocusedContainerColor = Color.White.copy(alpha = 0.06f),
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        cursorColor = Accent,
                    ),
                    shape = RoundedCornerShape(18.dp),
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                IconButton(
                    onClick = vm::send,
                    enabled = !state.running,
                    modifier = Modifier.size(44.dp).background(
                        if (state.running) Color.White.copy(alpha = 0.08f) else Accent,
                        CircleShape,
                    ),
                ) {
                    if (state.running) {
                        CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(
                            Icons.AutoMirrored.Rounded.Send,
                            contentDescription = "发送",
                            tint = Color(0xFF0A0E12),
                            modifier = Modifier.size(19.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun BubbleRow(bubble: AgentConversationViewModel.Bubble) {
    when (bubble.role) {
        "user" -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            MarkdownText(
                markdown = bubble.text,
                baseSize = 14.sp,
                modifier = Modifier
                    .fillMaxWidth(0.85f)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Accent)
                    .padding(horizontal = 12.dp, vertical = 9.dp),
            )
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
        "tool" -> Column(
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
                Text(bubble.text, fontSize = 12.5.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                if (bubble.streaming) {
                    CircularProgressIndicator(color = Info, modifier = Modifier.size(12.dp), strokeWidth = 2.dp)
                }
            }
            bubble.toolOutput?.takeIf { it.isNotBlank() }?.let {
                Spacer(Modifier.height(6.dp))
                Text(
                    it,
                    fontSize = 10.5.sp,
                    lineHeight = 15.sp,
                    fontFamily = FontFamily.Monospace,
                    color = if (bubble.toolError) Warning else TextMuted,
                    maxLines = 12,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        else -> Column(Modifier.fillMaxWidth()) {
            bubble.thinking?.takeIf { it.isNotBlank() }?.let { thinking ->
                MarkdownText(
                    markdown = "思考:$thinking",
                    baseSize = 11.sp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 160.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color.White.copy(alpha = 0.03f))
                        .padding(10.dp),
                )
                Spacer(Modifier.height(6.dp))
            }
            if (bubble.text.isEmpty() && bubble.streaming) {
                Text("…", fontSize = 13.5.sp, lineHeight = 21.sp, color = Color.White.copy(alpha = 0.92f))
            } else {
                // AI 回复按 Markdown 渲染(标题/列表/代码块/表格/引用)
                MarkdownText(markdown = bubble.text, baseSize = 14.sp)
            }
        }
    }
}
