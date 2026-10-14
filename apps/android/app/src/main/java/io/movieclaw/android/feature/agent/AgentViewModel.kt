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
        /** show_media_cards_v1 的卡片组（角色 tool / assistant 的非空时按生成式 UI 画卡片） */
        val mediaCards: AgentMediaCardGroup? = null,
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
        /** 当前服务器 origin（媒体卡片的图片要按它解析） */
        val origin: String? = null,
        /** 已知技能名（小写）：气泡里的 `/skill:名字` 只把名单内的画成 chip；null = 还没拿到 */
        val knownSkills: Set<String>? = null,
        /** 正在「改写」的目标 user message 编号：非空时发送走 retry（替换该条并重跑） */
        val editTarget: String? = null,
        /** 对话框可选模型（`GET /llm/models`）；空 = 没接入模型，chip 不出现 */
        val models: List<io.movieclaw.android.core.model.LlmModelOption> = emptyList(),
        /** 本轮用的模型引用；null = 智能体默认（选回默认项即 nil，同 iOS） */
        val modelRef: String? = null,
        /** 本轮思考档位；null = 由模型自行决定（不发送思考参数） */
        val thinkingLevel: String? = null,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    private var streamJob: Job? = null

    /** 无 id 的工具事件（理论路径）用的单调序号：避免同一毫秒撞 key */
    private var toolSeq = 0

    init {
        loadTranscript()
        loadSkills()
        loadModels()
    }

    fun consumeNotice() = _ui.update { it.copy(notice = null) }

    /** 「改写这条提问」：把原文放回输入框，并记住目标消息——发送时替换它（服务端同一条 retry 路径） */
    fun beginEdit(messageId: String, content: String) {
        if (_ui.value.running) return
        _ui.update { it.copy(input = content, editTarget = messageId) }
    }

    fun setModel(ref: String?) {
        _ui.update { it.copy(modelRef = ref, thinkingLevel = null) }
        AgentComposerPrefs.save(context, AgentComposerPrefs.Choice(ref, null))
    }

    fun setThinkingLevel(level: String?) {
        _ui.update { it.copy(thinkingLevel = level) }
        AgentComposerPrefs.save(context, AgentComposerPrefs.Choice(_ui.value.modelRef, level))
    }

    /** 取一次模型清单（对话框的模型 chip）；顺带把会话上一条的模型/档位继承过来（iOS 同口径） */
    private fun loadModels() {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).llmModels().dataOrThrow() }
                .onSuccess { list ->
                    // 与 iOS 同口径：模型清单到手后校验上次的选择（无效就丢掉并落盘）
                    // iOS 口径：`modelChoice ?? sessionModel` —— 会话自己有模型就用会话的，
                    // 只有会话没定义（新会话/空轨迹）才回落到持久化偏好，不能反过来盖掉
                    val prefs = AgentComposerPrefs.reconcile(AgentComposerPrefs.load(context), list)
                    _ui.update {
                        it.copy(
                            models = list,
                            modelRef = it.modelRef ?: prefs.model,
                            thinkingLevel = it.thinkingLevel ?: prefs.thinking,
                        )
                    }
                }
        }
    }

    /** 取一次技能清单（气泡 chip 的门禁名单，与 iOS `AgentCatalog.knownSkills` 同源） */
    private fun loadSkills() {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).skillsList().dataOrThrow() }
                .onSuccess { list ->
                    _ui.update { it.copy(knownSkills = list.map { skill -> skill.name.lowercase() }.toSet()) }
                }
        }
    }
    fun onInput(value: String) = _ui.update { it.copy(input = value) }

    private var transcriptRetries = 0
    private var lastNotifiedBubbleCount = -1

    private fun retryTranscriptIfEmpty() {
        if (transcriptRetries >= 4 || _ui.value.bubbles.isNotEmpty()) return
        transcriptRetries++
        viewModelScope.launch {
            kotlinx.coroutines.delay(1000)
            loadTranscript()
        }
    }

    fun loadTranscript() {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).sessionTranscript(sessionId).dataOrThrow() }
                .onSuccess { transcript ->
                    _ui.update { state ->
                        state.copy(
                            loading = false,
                            error = null,
                            origin = origin,
                            title = transcript.session.title?.takeIf { it.isNotEmpty() } ?: "AI 助手",
                            running = transcript.session.running,
                            bubbles = transcript.entries.mapNotNull { it.toBubble() },
                            // 技能清单用于 chip 门禁；失败不影响对话（allow 为 null 时全部按 token 画）
                            knownSkills = _ui.value.knownSkills,
                        )
                    }
                    // 轨迹里的媒体卡片同样按编号现取数据（与 iOS 回放路径同口径）
                    _ui.value.bubbles.forEach { bubble ->
                        bubble.mediaCards?.let { resolveMediaCards(bubble.id, it) }
                    }
                    if (transcript.session.running) followStream()
                    // 会话自己的模型（轨迹里最后一条 user 消息带的）：与 iOS `sessionModel` 同源
                    transcript.entries.lastOrNull { it.message?.role == "user" }
                        ?.model?.takeIf { it.isNotBlank() }
                        ?.let { model -> _ui.update { it.copy(modelRef = model) } }
                    // 只在**真有变化**时通知列表（首次成功加载 / 气泡数变了）：
                    // 原来每次 loadTranscript（含空轨迹重试）都发，会把「我的」页刷屏
                    val loaded = _ui.value.bubbles
                    if (transcriptRetries == 0 || loaded.size != lastNotifiedBubbleCount) {
                        lastNotifiedBubbleCount = loaded.size
                        sessionRepository.notifyAgentSessionsChanged()
                    }
                    if (loaded.isNotEmpty()) transcriptRetries = 0   // 拿到内容就把重试计数归零
                    // 刚建好的会话：服务端可能还没把首条消息写进轨迹（此时 running 也已翻回 false，
                    // 挂不上流），页面就会空着等——空轨迹时隔一秒再拉，最多 4 次
                    retryTranscriptIfEmpty()
                }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
        }
    }

    /**
     * 按编号现取媒体卡片数据（与 iOS 各卡 `.task` 同口径）：逐张解析、逐张回填，
     * 单张失败画「未找到」而不是整组消失。「已订阅」斜标要的集合只在组里有影片卡时取一次。
     */
    private fun resolveMediaCards(bubbleId: String, group: AgentMediaCardGroup) {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            val subscribedRefs = if (group.cards.any { it.spec.kind == AgentMediaCardKind.TITLE }) {
                runCatching {
                    api.subscriptions().dataOrThrow()
                        .mapNotNull { sub -> sub.media.tmdbId?.let { "tmdb:${sub.media.kind}:$it" } }
                        .toSet()
                }.getOrDefault(emptySet())
            } else {
                emptySet()
            }
            group.cards.forEach { card ->
                val view = runCatching { AgentMediaCards.load(api, card.spec, subscribedRefs) }
                    .getOrElse { AgentMediaCards.failed(card.spec) }
                _ui.update { state ->
                    state.copy(
                        bubbles = state.bubbles.map { bubble ->
                            if (bubble.id != bubbleId) bubble
                            else bubble.copy(
                                mediaCards = bubble.mediaCards?.let { g ->
                                    g.copy(cards = g.cards.map { if (it.spec.key == card.spec.key) view else it })
                                },
                            )
                        },
                    )
                }
            }
        }
    }

    fun send() {
        val state = _ui.value
        val text = state.input.trim()
        if (text.isEmpty() && state.attachments.isEmpty()) return
        transcriptRetries = 0   // 新一轮开始，空轨迹重试次数重新计
        val editId = state.editTarget
        _ui.update { it.copy(input = "", streamingInFlight = true, running = true, error = null, editTarget = null) }
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching {
                if (editId != null) {
                    // 改写：替换那条提问并重跑（服务端会删掉它及其之后的轨迹）
                    apiFactory.forOrigin(origin)
                        .retryAgentSession(sessionId, SessionRetry(messageId = editId, content = text))
                        .dataOrThrow()
                    Unit
                } else {
                    apiFactory.forOrigin(origin).startAgentSession(
                        AgentSessionStart(
                            content = text,
                            sessionId = sessionId,
                            attachments = state.attachments.map { it.attachmentId },
                            // 空串 = 智能体默认（服务端按空值回落到 AI 设定）；档位 null = 不发送
                            model = state.modelRef ?: "",
                            thinkingLevel = state.thinkingLevel,
                        )
                    ).dataOrThrow()
                    Unit
                }
            }
                .onSuccess {
                    if (editId != null) {
                        // 轨迹已被服务端从那条消息起重写，重新拉一遍（与 iOS 改写后一致）
                        _ui.update { s -> s.copy(attachments = emptyList()) }
                        loadTranscript()
                    } else {
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
                        "tool_call_start", "tool_call" -> {
                            // 同一次调用会先后发 tool_call_start（仅 id/name）与 tool_call（参数定稿，id 相同）：
                            // 按 id upsert，两条事件只留一个气泡——此前各追加一个，id 都是 tool-<call_id>，
                            // LazyColumn 重复 key 直接闪退（真机 13:03 三连崩就是这个）
                            val callId = event.toolCall?.id?.takeIf { it.isNotBlank() }
                            val bubbleId = if (callId != null) "tool-$callId" else "tool-noid-${++toolSeq}"
                            val name = event.toolCall?.name?.takeIf { it.isNotBlank() }
                            // show_media_cards_v1：参数随 tool_call 定稿事件到达，解析成卡片组挂到气泡上
                            val cards = AgentMediaCards.parse(name, event.toolCall?.arguments)
                            val hadCards = _ui.value.bubbles.firstOrNull { it.id == bubbleId }?.mediaCards != null
                            _ui.update { state ->
                                val index = state.bubbles.indexOfFirst { it.id == bubbleId }
                                if (index >= 0) {
                                    val old = state.bubbles[index]
                                    state.copy(
                                        bubbles = state.bubbles.toMutableList().also {
                                            it[index] = old.copy(
                                                text = "调用工具:${name ?: old.toolName.orEmpty()}",
                                                toolName = name ?: old.toolName,
                                                mediaCards = cards ?: old.mediaCards,
                                            )
                                        },
                                    )
                                } else {
                                    state.copy(
                                        bubbles = state.bubbles + Bubble(
                                            id = bubbleId,
                                            role = "tool",
                                            text = "调用工具:${name ?: ""}",
                                            toolName = name,
                                            streaming = true,
                                            mediaCards = cards,
                                        ),
                                    )
                                }
                            }
                            if (cards != null && !hadCards) resolveMediaCards(bubbleId, cards)
                        }
                        "tool_result" -> _ui.update { state ->
                            val result = event.toolResult
                            // 有 toolCallId 就精确收尾那一条（并行调用互不干扰）；缺失时退回「收尾在流式的工具条」
                            val targetId = result?.toolCallId?.takeIf { it.isNotBlank() }?.let { "tool-$it" }
                            state.copy(
                                bubbles = state.bubbles.map { bubble ->
                                    if (bubble.role == "tool" && bubble.streaming && (targetId == null || bubble.id == targetId)) {
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
    fun attachImage(uri: android.net.Uri) {
        _ui.update { it.copy(uploading = true) }
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin
            if (origin == null) {
                _ui.update { it.copy(uploading = false) }
                return@launch
            }
            val api = apiFactory.forOrigin(origin)
            when (val outcome = uploadAgentAttachment(context, uri) { file, mime ->
                val part = okhttp3.MultipartBody.Part.createFormData(
                    "file", file.name, file.asRequestBody(mime.toMediaType()),
                )
                api.uploadAgentAttachment(part).dataOrThrow()
            }) {
                is UploadOutcome.Ok -> _ui.update {
                    it.copy(uploading = false, attachments = it.attachments + outcome.attachment)
                }
                UploadOutcome.Unreadable -> _ui.update {
                    it.copy(uploading = false, notice = McNotice("无法读取所选图片", FeedbackTone.Error))
                }
                is UploadOutcome.Failed -> _ui.update {
                    it.copy(uploading = false, notice = McNotice(friendlyMessage(outcome.error), FeedbackTone.Error))
                }
            }
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
    // user 消息：服务端把 `/skill:名字` 展开成了技能正文，读回来要还原成 token，
    // 气泡才能画 chip（iOS `AgentSkillText.toTokenForm` 同口径）
    val rawText = msg.extractText()
    val text = if (msg.role == "user") AgentSkillText.toTokenForm(rawText) else rawText
    // 思考块与正文块分开（iOS `AgentAPI`：content 是 text/thinking/image 内容块的联合，
    // thinking 块要单独成「处理过程」，不能混进正文——用户看到的整段英文推理就是这个）
    val thinking = msg.extractThinking()
    val toolCalls = msg.toolCalls.orEmpty()
    if (msg.role == "tool") {
        // 生成式 UI 的工具回执不画行：卡片（挂在 assistant 消息上）就是它的呈现——
        // 与 iOS 同口径，整个工具条目被卡片替代
        if (AgentMediaCards.isMediaCardsTool(msg.name)) return null
        return AgentConversationViewModel.Bubble(
            id = messageId ?: System.currentTimeMillis().toString(),
            role = "tool",
            text = "工具 ${msg.name ?: ""} 返回",
            toolOutput = text.take(2000),
        )
    }
    if (text.isEmpty() && thinking.isBlank() && toolCalls.isEmpty()) return null
    // show_media_cards_v1：工具参数 → 卡片组（参数缺失/不合法返回 null，退回普通「调用 X」行）
    val cards = toolCalls.firstNotNullOfOrNull { AgentMediaCards.parse(it.name, it.arguments) }
    return AgentConversationViewModel.Bubble(
        id = messageId ?: System.currentTimeMillis().toString(),
        role = msg.role,
        // 只带工具调用、没有正文的 assistant 消息不再合成「调用 X」伪正文：工具行本来就会
        // 出现在折叠的「处理过程」里（iOS AgentMessage.text 也只取 text 块）
        text = text,
        thinking = thinking.takeIf { it.isNotBlank() },
        toolName = toolCalls.firstOrNull()?.name,
        mediaCards = cards,
    )
}

/** content 是字符串或 ContentPart 数组；正文只取 type == "text" 的块（iOS `AgentMessage.text`） */
private fun io.movieclaw.android.core.model.SessionMessage.extractText(): String =
    when (val node = content) {
        null -> ""
        is JsonPrimitive -> node.content
        is JsonArray -> node.mapNotNull { part ->
            val obj = part as? kotlinx.serialization.json.JsonObject ?: return@mapNotNull null
            val type = (obj["type"] as? JsonPrimitive)?.content
            if (type != null && type != "text") return@mapNotNull null
            (obj["text"] as? JsonPrimitive)?.content
        }.joinToString("\n")
        else -> ""
    }

/** 思考块（iOS `AgentMessage.thinking`：type == "thinking" 的块拼接） */
private fun io.movieclaw.android.core.model.SessionMessage.extractThinking(): String =
    when (val node = content) {
        is JsonArray -> node.mapNotNull { part ->
            val obj = part as? kotlinx.serialization.json.JsonObject ?: return@mapNotNull null
            val type = (obj["type"] as? JsonPrimitive)?.content
            if (type != "thinking") return@mapNotNull null
            (obj["text"] as? JsonPrimitive)?.content
        }.joinToString("\n")
        else -> ""
    }
