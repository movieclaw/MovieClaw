package io.movieclaw.android.feature.agent

import io.movieclaw.android.core.designsystem.FeedbackTone
import io.movieclaw.android.core.designsystem.McNotice
import android.content.Context
import android.net.Uri
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.model.AgentEvent
import io.movieclaw.android.core.model.AgentSessionStart
import io.movieclaw.android.core.model.SessionRetry
import io.movieclaw.android.core.model.SessionSummary
import io.movieclaw.android.core.model.TranscriptEntry
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.EventStream
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import java.io.File
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody.Companion.asRequestBody

/** 会话列表 */
@HiltViewModel
class AgentSessionsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
) : ViewModel() {

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val sessions: List<SessionSummary> = emptyList(),
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            runCatching { apiFactory.forOrigin(origin).sessions().dataOrThrow() }
                .onSuccess { list -> _ui.update { it.copy(loading = false, sessions = list) } }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
        }
    }

    fun delete(session: SessionSummary) {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).deleteSession(session.id).dataOrThrow() }
            load()
        }
    }
}

/** 对话页:轨迹加载 + SSE 流式增量 + 发送/停止/重试 + 图片附件 */
@HiltViewModel
class AgentConversationViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
    private val eventStream: EventStream,
    private val sessionRepository: SessionRepository,
    private val json: Json,
) : ViewModel() {

    val sessionId: String = savedStateHandle.get<String>("sessionId").orEmpty()

    /** 轨迹里一条渲染项 */
    data class Bubble(
        val id: String,
        val role: String,
        val text: String,
        val thinking: String? = null,
        val toolName: String? = null,
        val toolOutput: String? = null,
        val toolError: Boolean = false,
        val tokens: Pair<Int, Int>? = null,
        val streaming: Boolean = false,
    )

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val notice: McNotice? = null,
        val title: String = "AI 助手",
        val running: Boolean = false,
        val streamingInFlight: Boolean = false,
        val bubbles: List<Bubble> = emptyList(),
        val input: String = "",
        val attachments: List<io.movieclaw.android.core.model.AgentAttachment> = emptyList(),
        val uploading: Boolean = false,
        val provider: String? = null,
        val model: String? = null,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    private var streamJob: Job? = null

    init {
        loadTranscript()
    }

    fun consumeNotice() = _ui.update { it.copy(notice = null) }
    fun onInput(value: String) = _ui.update { it.copy(input = value) }

    fun loadTranscript() {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).sessionTranscript(sessionId).dataOrThrow() }
                .onSuccess { transcript ->
                    _ui.update { state ->
                        state.copy(
                            loading = false,
                            error = null,
                            title = transcript.session.title?.takeIf { it.isNotEmpty() } ?: "AI 助手",
                            running = transcript.session.running,
                            bubbles = transcript.entries.mapNotNull { it.toBubble() },
                        )
                    }
                    if (transcript.session.running) followStream()
                }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
        }
    }

    fun send() {
        val state = _ui.value
        val text = state.input.trim()
        if (text.isEmpty() && state.attachments.isEmpty()) return
        _ui.update { it.copy(input = "", streamingInFlight = true, running = true, error = null) }
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).startAgentSession(
                    AgentSessionStart(
                        content = text,
                        sessionId = sessionId,
                        attachments = state.attachments.map { it.attachmentId },
                    )
                ).dataOrThrow()
            }
                .onSuccess {
                    _ui.update { s ->
                        s.copy(
                            attachments = emptyList(),
                            bubbles = s.bubbles + Bubble(
                                id = "user-${System.currentTimeMillis()}",
                                role = "user",
                                text = text.ifEmpty { "(图片)" },
                            ),
                        )
                    }
                    followStream()
                }
                .onFailure { e ->
                    _ui.update { it.copy(running = false, streamingInFlight = false, notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) }
                }
        }
    }

    fun stop() {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).stopAgentSession(sessionId).dataOrThrow() }
            _ui.update { it.copy(notice = McNotice("已请求停止", FeedbackTone.Success)) }
        }
    }

    fun retry() {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).retryAgentSession(sessionId, SessionRetry()).dataOrThrow() }
                .onSuccess { followStream() }
                .onFailure { e -> _ui.update { it.copy(notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }

    fun compactContext() {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).compactAgentContext(sessionId) }
            _ui.update { it.copy(notice = McNotice("已请求压缩上下文", FeedbackTone.Success)) }
        }
    }

    /** 订阅会话事件流:增量拼接正文/思维链/工具调用,终止事件收尾后重载轨迹 */
    private fun followStream() {
        streamJob?.cancel()
        streamJob = viewModelScope.launch {
            runCatching {
                eventStream.reliableEvents("sessions/$sessionId/events").collect { sse ->
                    val event = runCatching { json.decodeFromString<AgentEvent>(sse.data) }.getOrNull() ?: return@collect
                    when (event.type) {
                        "agent_start" -> _ui.update {
                            it.copy(running = true, provider = event.provider, model = event.model)
                        }
                        "thinking_delta" -> appendDelta("assistant", event.delta, thinking = true)
                        "text_delta" -> appendDelta("assistant", event.delta, thinking = false)
                        "tool_call_start", "tool_call" -> _ui.update { state ->
                            state.copy(
                                bubbles = state.bubbles + Bubble(
                                    id = "tool-${event.toolCall?.id ?: System.currentTimeMillis()}",
                                    role = "tool",
                                    text = "调用工具:${event.toolCall?.name ?: ""}",
                                    toolName = event.toolCall?.name,
                                    streaming = true,
                                ),
                            )
                        }
                        "tool_result" -> _ui.update { state ->
                            val result = event.toolResult
                            state.copy(
                                bubbles = state.bubbles.map { bubble ->
                                    if (bubble.role == "tool" && bubble.streaming) {
                                        bubble.copy(
                                            text = "工具 ${result?.name ?: bubble.toolName} ${if (result?.isError == true) "失败" else "完成"}",
                                            toolOutput = result?.output?.take(2000),
                                            toolError = result?.isError == true,
                                            streaming = false,
                                        )
                                    } else {
                                        bubble
                                    }
                                },
                            )
                        }
                        "context_compacted" -> _ui.update { state ->
                            val compaction = event.compaction
                            state.copy(
                                bubbles = state.bubbles + Bubble(
                                    id = "compact-${System.currentTimeMillis()}",
                                    role = "system",
                                    text = "上下文已压缩(${compaction?.tokensBefore ?: 0} → ${compaction?.tokensAfter ?: 0} tokens)",
                                ),
                            )
                        }
                        "agent_done", "agent_error", "agent_cancelled" -> {
                            _ui.update { state ->
                                state.copy(
                                    running = false,
                                    streamingInFlight = false,
                                    notice = event.error?.let { McNotice(it, FeedbackTone.Error) },
                                    bubbles = state.bubbles.map { if (it.streaming) it.copy(streaming = false) else it },
                                )
                            }
                            loadTranscript()
                        }
                    }
                }
            }.onFailure { e ->
                _ui.update { it.copy(running = false, streamingInFlight = false, notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) }
            }
        }
    }

    private fun appendDelta(role: String, delta: String?, thinking: Boolean) {
        if (delta.isNullOrEmpty()) return
        _ui.update { state ->
            val last = state.bubbles.lastOrNull()
            if (last != null && last.role == role && last.streaming) {
                state.copy(
                    bubbles = state.bubbles.dropLast(1) + last.copy(
                        text = if (thinking) last.text else last.text + delta,
                        thinking = if (thinking) (last.thinking ?: "") + delta else last.thinking,
                    ),
                )
            } else {
                state.copy(
                    bubbles = state.bubbles + Bubble(
                        id = "assistant-${System.currentTimeMillis()}",
                        role = role,
                        text = if (thinking) "" else delta,
                        thinking = if (thinking) delta else null,
                        streaming = true,
                    ),
                )
            }
        }
    }

    /** 图片附件:读字节 → multipart 上传 → 记录 attachment_id */
    fun attachImage(uri: Uri) {
        _ui.update { it.copy(uploading = true) }
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            val bytes = withContext(Dispatchers.IO) {
                runCatching {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                }.getOrNull()
            }
            if (bytes == null) {
                _ui.update { it.copy(uploading = false, notice = McNotice("无法读取所选图片", FeedbackTone.Success)) }
                return@launch
            }
            val temp = File(context.cacheDir, "agent_upload_${System.currentTimeMillis()}.jpg")
            withContext(Dispatchers.IO) { runCatching { temp.writeBytes(bytes) } }
            runCatching {
                val part = MultipartBody.Part.createFormData("file", temp.name, temp.asRequestBody("image/jpeg".toMediaType()))
                apiFactory.forOrigin(origin).uploadAgentAttachment(part).dataOrThrow()
            }
                .onSuccess { attachment ->
                    _ui.update { it.copy(uploading = false, attachments = it.attachments + attachment) }
                }
                .onFailure { e -> _ui.update { it.copy(uploading = false, notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }

    fun removeAttachment(id: String) = _ui.update { state ->
        state.copy(attachments = state.attachments.filterNot { it.attachmentId == id })
    }

    override fun onCleared() {
        streamJob?.cancel()
        super.onCleared()
    }
}

/** 轨迹条目 → 渲染气泡(message 三型;compaction/handoff 用系统条展示) */
private fun TranscriptEntry.toBubble(): AgentConversationViewModel.Bubble? {
    if (compactionId != null) {
        return AgentConversationViewModel.Bubble(
            id = compactionId,
            role = "system",
            text = "上下文已压缩(${tokensBefore ?: 0} → ${tokensAfter ?: 0} tokens)",
        )
    }
    if (handoffId != null) {
        return AgentConversationViewModel.Bubble(
            id = handoffId,
            role = "system",
            text = "承接自会话:${sourceTitle ?: ""}",
        )
    }
    val msg = message ?: return null
    val text = msg.extractText()
    val toolCalls = msg.toolCalls.orEmpty()
    if (msg.role == "tool") {
        return AgentConversationViewModel.Bubble(
            id = messageId ?: System.currentTimeMillis().toString(),
            role = "tool",
            text = "工具 ${msg.name ?: ""} 返回",
            toolOutput = text.take(2000),
        )
    }
    if (text.isEmpty() && toolCalls.isEmpty()) return null
    return AgentConversationViewModel.Bubble(
        id = messageId ?: System.currentTimeMillis().toString(),
        role = msg.role,
        text = text.ifEmpty { toolCalls.joinToString("、") { "调用 ${it.name}" } },
        toolName = toolCalls.firstOrNull()?.name,
    )
}

/** content 可能是字符串或 ContentPart 数组,统一抽成文本 */
private fun io.movieclaw.android.core.model.SessionMessage.extractText(): String = when (val node = content) {
    null -> ""
    is JsonPrimitive -> node.content
    is JsonArray -> node.mapNotNull { part ->
        (part as? kotlinx.serialization.json.JsonObject)
            ?.get("text")
            ?.let { (it as? JsonPrimitive)?.content }
    }.joinToString("\n")
    else -> ""
}
