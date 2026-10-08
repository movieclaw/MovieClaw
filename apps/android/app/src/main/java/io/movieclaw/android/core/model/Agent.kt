package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class SessionSummary(
    val id: String,
    val title: String? = null,
    val lastPrompt: String? = null,
    val entryCount: Int = 0,
    val running: Boolean = false,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class AgentSessionStart(
    val content: String,
    val sessionId: String? = null,
    val attachments: List<String> = emptyList(),
    val model: String = "",
    val thinkingLevel: String? = null,
)

@Serializable
data class SessionAccepted(val sessionId: String, val messageId: String = "")

/**
 * 待处理事项 → Agent 诊断工单（`POST /agent-handoff`）。
 *
 * 工单正文由**服务端**组装（发生了什么 / 现场自检判定了什么 / 系统已自动做过什么 /
 * 与界面一致的动作清单），前端不拼：Agent 能看到的证据必须比用户多，否则它只会
 * 得出和用户一样的错误结论。
 */
@Serializable
data class HandoffRequest(
    /** notice（ref=告警 id）/ download（ref=info_hash）/ job（ref=任务 id） */
    val kind: String,
    val ref: String,
)

@Serializable
data class HandoffPrompt(
    val title: String = "",
    val prompt: String = "",
)

@Serializable
data class AgentAttachment(
    val attachmentId: String,
    val name: String = "",
    val width: Int = 0,
    val height: Int = 0,
    val bytes: Long = 0,
)

@Serializable
data class ToolCallInfo(
    val id: String = "",
    val name: String = "",
    val arguments: String? = null,
)

@Serializable
data class AgentToolResultInfo(
    val toolCallId: String = "",
    val name: String = "",
    val output: String = "",
    val isError: Boolean = false,
    val elapsedMs: Long = 0,
)

@Serializable
data class AgentCompactionInfo(
    val summary: String = "",
    val tokensBefore: Int = 0,
    val tokensAfter: Int = 0,
)

@Serializable
data class AgentDoneInfo(
    val text: String? = null,
    val thinking: String? = null,
    val steps: Int = 1,
    val model: String = "",
    val provider: String = "",
    val elapsedMs: Long = 0,
)

/**
 * Agent SSE 事件:type 即 SSE 事件名。字段按类型有值——
 * agent_start / thinking_delta / text_delta / tool_call_start / tool_call_delta /
 * tool_call / tool_result / context_compacted / agent_done / agent_error / agent_cancelled。
 */
@Serializable
data class AgentEvent(
    val type: String = "",
    val runId: String = "",
    val delta: String? = null,
    val toolCall: ToolCallInfo? = null,
    val toolCallId: String? = null,
    val toolResult: AgentToolResultInfo? = null,
    val compaction: AgentCompactionInfo? = null,
    val provider: String? = null,
    val model: String? = null,
    val result: AgentDoneInfo? = null,
    val error: String? = null,
)

@Serializable
data class SessionMessage(
    val role: String = "user",
    /** str | list[ContentPart],原样保留后由客户端抽文本 */
    val content: JsonElement? = null,
    val toolCalls: List<ToolCallInfo>? = null,
    val toolCallId: String? = null,
    val name: String? = null,
)

/** 轨迹条目(message / compaction / handoff 三型联合,按出现字段判别) */
@Serializable
data class TranscriptEntry(
    val messageId: String? = null,
    val compactionId: String? = null,
    val handoffId: String? = null,
    val timestamp: String? = null,
    val message: SessionMessage? = null,
    val summary: String? = null,
    val tokensBefore: Int? = null,
    val tokensAfter: Int? = null,
    val model: String? = null,
    val sourceTitle: String? = null,
)

@Serializable
data class SessionTranscript(
    val session: SessionSummary = SessionSummary(id = ""),
    val entries: List<TranscriptEntry> = emptyList(),
)

@Serializable
data class SessionRename(val title: String)

@Serializable
data class SessionRetry(val messageId: String? = null)
