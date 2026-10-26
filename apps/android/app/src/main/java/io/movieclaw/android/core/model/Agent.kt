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
    /**
     * 工具调用参数：服务端是**已解析的对象**（`movieclaw_llm.models.ToolCall.arguments: dict`），
     * iOS 侧对应 `arguments: AgentJSONObject?`。声明成 JsonElement 而不是 String——
     * 以前声明 String 时，带工具调用的历史会话一加载就整条失败
     * （kotlinx：Expected beginning of the string, but got {）。
     * JsonElement 对对象/数组/字符串都收，比 iOS 更宽容（老数据里若有字符串化参数也不炸）。
     */
    val arguments: kotlinx.serialization.json.JsonElement? = null,
    /** 供应商原始 JSON 串（服务端 `raw_arguments`；解析失败时保真展示用） */
    val rawArguments: String? = null,
    /** 参数 JSON 解析失败的原因（服务端 `parse_error`） */
    val parseError: String? = null,
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
data class SessionRetry(
    /** 要重新提问的 user message 编号（服务端会删掉它及其之后的轨迹） */
    val messageId: String? = null,
    /** 替换后的正文；留空 = 原文重试（`POST /sessions/{id}/retry`） */
    val content: String? = null,
)

/** 对话框模型选择器的一个选项（`GET /llm/models`，口径同 iOS `API.LlmModelOptionView`） */
@Serializable
data class LlmModelOption(
    /** 提交给 session.start 的模型引用：裸模型 id，或同 id 多实例时的「实例名/模型id」 */
    val ref: String = "",
    /** 展示文案：裸模型 id，冲突时为「模型id（实例名）」 */
    val label: String = "",
    val modelId: String? = null,
    val providerId: Int? = null,
    val providerName: String? = null,
    /** 是否为智能体默认模型（AI 设定）；清单里恰有一个 */
    val isDefault: Boolean = false,
    /** 该模型的思考档位菜单；空 = 隐藏档位选择 */
    val thinkingLevels: List<String> = emptyList(),
)

/** 一个可显式调用的 Agent 技能（`GET /skills`）；气泡里的 `/skill:名字` chip 用它做门禁 */
@Serializable
data class SkillView(
    val name: String = "",
    val description: String? = null,
    val scope: String? = null,
)
/** AI 设定（各用途默认模型）：GET/PUT /llm/defaults 的视图（iOS `API.LlmDefaultsView`） */
@kotlinx.serialization.Serializable
data class LlmDefaultsView(
    @kotlinx.serialization.SerialName("agent_model") val agentModel: String? = null,
    @kotlinx.serialization.SerialName("subtitle_model") val subtitleModel: String? = null,
    @kotlinx.serialization.SerialName("effective_agent_model") val effectiveAgentModel: String? = null,
    @kotlinx.serialization.SerialName("effective_subtitle_model") val effectiveSubtitleModel: String? = null,
)

/** 保存 AI 设定（iOS `API.LlmDefaultsPayload`）：只提交两个引用，null = 清空 */
@kotlinx.serialization.Serializable
data class LlmDefaultsPayload(
    @kotlinx.serialization.SerialName("agent_model") val agentModel: String? = null,
    @kotlinx.serialization.SerialName("subtitle_model") val subtitleModel: String? = null,
)
/** 推送通道与设备覆盖（iOS `API.PushChannelsView`）；字段给默认值，缺失不炸解码 */
@kotlinx.serialization.Serializable
data class PushChannelsView(
    @kotlinx.serialization.SerialName("cloud_state") val cloudState: String = "disconnected",
    val channels: List<PushChannelView> = emptyList(),
)

/** 一个推送通道（只取展示需要的字段） */
@kotlinx.serialization.Serializable
data class PushChannelView(
    val id: String = "",
    /** official / custom */
    val kind: String = "",
    val name: String = "",
    val enabled: Boolean = false,
    /** inactive / ok / warning / error */
    val state: String = "",
    @kotlinx.serialization.SerialName("status_text") val statusText: String = "",
)

/** 官方推送通道开关（iOS `API.OfficialChannelRequest`） */
@kotlinx.serialization.Serializable
data class OfficialChannelRequest(val enabled: Boolean = false)

/** IM 推送内容开关（iOS `API.ChannelPushConfigView`） */
@kotlinx.serialization.Serializable
data class ChannelPushConfigView(
    @kotlinx.serialization.SerialName("push_dispatch") val pushDispatch: Boolean = false,
    @kotlinx.serialization.SerialName("push_imported") val pushImported: Boolean = false,
)
/** MCP 总状态（iOS `API.StatusView`）；字段带默认值，服务端裁剪也不炸解码 */
@kotlinx.serialization.Serializable
data class McpStatusView(
    val enabled: Boolean = false,
    @kotlinx.serialization.SerialName("base_url") val baseUrl: String = "",
    @kotlinx.serialization.SerialName("external_url_configured") val externalUrlConfigured: Boolean = false,
    val endpoints: List<McpEndpointView> = emptyList(),
)

/** MCP 端点（iOS `API.EndpointView`，只取展示需要的字段） */
@kotlinx.serialization.Serializable
data class McpEndpointView(
    val id: String = "",
    val slug: String = "",
    val name: String = "",
    val description: String = "",
    val enabled: Boolean = false,
    val services: List<String> = emptyList(),
    @kotlinx.serialization.SerialName("tool_count") val toolCount: Int = 0,
    val url: String = "",
    @kotlinx.serialization.SerialName("last_used_at") val lastUsedAt: String? = null,
)

/** MCP 总开关请求（iOS `API.ToggleRequest`） */
@kotlinx.serialization.Serializable
data class McpToggleRequest(val enabled: Boolean = false)
/** Webhook 配置（iOS `API.WebhookConfigView`） */
@kotlinx.serialization.Serializable
data class WebhookConfigView(
    val enabled: Boolean = false,
    val endpoints: List<WebhookEndpointView> = emptyList(),
)

/** 一个 Webhook 端点（iOS `API.WebhookEndpointView`，展示用字段） */
@kotlinx.serialization.Serializable
data class WebhookEndpointView(
    val id: String = "",
    val name: String = "",
    val url: String = "",
    val format: String = "",
    val enabled: Boolean = false,
    val events: List<String> = emptyList(),
    val template: String = "",
    val headers: Map<String, String> = emptyMap(),
    @kotlinx.serialization.SerialName("egress_scope") val egressScope: String = "lan",
    @kotlinx.serialization.SerialName("secret_masked") val secretMasked: String = "",
    @kotlinx.serialization.SerialName("last_delivery") val lastDelivery: WebhookDeliveryView? = null,
)

/** 保存 Webhook：整份提交，现有端点必须原样带上（服务端按 id 保留 secret） */
@kotlinx.serialization.Serializable
data class WebhookEndpointPayload(
    val id: String = "",
    val name: String = "",
    val url: String = "",
    val format: String = "movieclaw",
    val enabled: Boolean = true,
    val events: List<String> = emptyList(),
    val template: String = "",
    val headers: Map<String, String> = emptyMap(),
    @kotlinx.serialization.SerialName("egress_scope") val egressScope: String = "lan",
)

@kotlinx.serialization.Serializable
data class WebhookConfigPayload(
    val enabled: Boolean = false,
    val endpoints: List<WebhookEndpointPayload> = emptyList(),
)

/** 一次投递结果（iOS `API.DeliveryView`） */
@kotlinx.serialization.Serializable
data class WebhookDeliveryView(
    @kotlinx.serialization.SerialName("event_id") val eventId: String = "",
    val event: String = "",
    val ok: Boolean = false,
    @kotlinx.serialization.SerialName("status_code") val statusCode: Int? = null,
    @kotlinx.serialization.SerialName("duration_ms") val durationMs: Int = 0,
    val attempts: Int = 0,
    val error: String = "",
    val at: String = "",
)
/** 刮削配置（iOS `API.ScrapeConfigView`）：只取 `effective` 生效值做展示 */
@kotlinx.serialization.Serializable
data class ScrapeConfigView(
    /** 可写的整份配置：保存时整份提交，只改用户编辑过的字段 */
    val setting: ScrapeSetting = ScrapeSetting(),
    val effective: ScrapeEffectiveView = ScrapeEffectiveView(),
)

/**
 * 刮削配置（iOS `API.MetadataScrapeSetting`）。字段与 iOS 一一对应；
 * **保存必须整份提交**——只发部分字段会把其余字段重置。
 */
@kotlinx.serialization.Serializable
data class ScrapeSetting(
    @kotlinx.serialization.SerialName("language_priority") val languagePriority: List<String> = emptyList(),
    @kotlinx.serialization.SerialName("cert_country_priority") val certCountryPriority: List<String> = emptyList(),
    @kotlinx.serialization.SerialName("poster_mode") val posterMode: String = "language",
    @kotlinx.serialization.SerialName("poster_language_priority") val posterLanguagePriority: List<String> = emptyList(),
    @kotlinx.serialization.SerialName("backdrop_language_priority") val backdropLanguagePriority: List<String> = emptyList(),
    @kotlinx.serialization.SerialName("logo_language_priority") val logoLanguagePriority: List<String>? = null,
    @kotlinx.serialization.SerialName("poster_min_width") val posterMinWidth: Int = 0,
    @kotlinx.serialization.SerialName("backdrop_min_width") val backdropMinWidth: Int = 0,
    @kotlinx.serialization.SerialName("poster_size") val posterSize: String = "original",
    @kotlinx.serialization.SerialName("backdrop_size") val backdropSize: String = "original",
    @kotlinx.serialization.SerialName("still_size") val stillSize: String = "original",
    @kotlinx.serialization.SerialName("profile_size") val profileSize: String = "original",
    @kotlinx.serialization.SerialName("image_quality") val imageQuality: String = "original",
    @kotlinx.serialization.SerialName("fanart_enabled") val fanartEnabled: Boolean? = null,
    @kotlinx.serialization.SerialName("poster_source_order") val posterSourceOrder: List<String>? = null,
    @kotlinx.serialization.SerialName("backdrop_source_order") val backdropSourceOrder: List<String>? = null,
    @kotlinx.serialization.SerialName("logo_source_order") val logoSourceOrder: List<String>? = null,
    @kotlinx.serialization.SerialName("season_poster_source_order") val seasonPosterSourceOrder: List<String>? = null,
    @kotlinx.serialization.SerialName("naming_entry_dir") val namingEntryDir: String = "",
    @kotlinx.serialization.SerialName("naming_movie_file") val namingMovieFile: String = "",
    @kotlinx.serialization.SerialName("naming_season_dir") val namingSeasonDir: String = "",
    @kotlinx.serialization.SerialName("naming_episode_file") val namingEpisodeFile: String = "",
    @kotlinx.serialization.SerialName("mirror_images") val mirrorImages: Boolean = false,
    @kotlinx.serialization.SerialName("mirror_nfo") val mirrorNfo: Boolean = false,
    @kotlinx.serialization.SerialName("mirror_episode_thumbs") val mirrorEpisodeThumbs: Boolean = false,
)

/** 生效值（iOS `API.ScrapeEffectiveView`）：跟随环境变量时展示「跟随中」 */
@kotlinx.serialization.Serializable
data class ScrapeEffectiveView(
    @kotlinx.serialization.SerialName("language_priority") val languagePriority: List<String> = emptyList(),
    @kotlinx.serialization.SerialName("cert_country_priority") val certCountryPriority: List<String> = emptyList(),
    @kotlinx.serialization.SerialName("poster_size") val posterSize: String = "",
    @kotlinx.serialization.SerialName("backdrop_size") val backdropSize: String = "",
    @kotlinx.serialization.SerialName("still_size") val stillSize: String = "",
    @kotlinx.serialization.SerialName("profile_size") val profileSize: String = "",
    @kotlinx.serialization.SerialName("image_quality") val imageQuality: String = "",
)
/** MovieClaw Cloud 状态（iOS `API.CloudStatusView`，取展示所需字段） */
@kotlinx.serialization.Serializable
data class CloudStatusView(
    /** disconnected / pairing / connected */
    val state: String = "disconnected",
    /** 已连接时：ok / unreachable / expired / unsupported */
    val health: String? = null,
    @kotlinx.serialization.SerialName("health_message") val healthMessage: String? = null,
    @kotlinx.serialization.SerialName("cloud_url") val cloudUrl: String = "",
    @kotlinx.serialization.SerialName("server_name") val serverName: String = "",
    @kotlinx.serialization.SerialName("report_stats") val reportStats: Boolean = false,
    @kotlinx.serialization.SerialName("last_report_at") val lastReportAt: String? = null,
)

/** 统计上报开关（iOS `API.CloudSettingsRequest`） */
@kotlinx.serialization.Serializable
data class CloudSettingsRequest(
    @kotlinx.serialization.SerialName("report_stats") val reportStats: Boolean = false,
)
/** 语言选项（iOS `API.LanguageOption`）：code=ISO 639-1，name=本族名 */
@kotlinx.serialization.Serializable
data class ScrapeLanguageOption(
    val code: String = "",
    val name: String = "",
    @kotlinx.serialization.SerialName("english_name") val englishName: String = "",
)

/** 地区选项（iOS `API.CountryOption`） */
@kotlinx.serialization.Serializable
data class ScrapeCountryOption(
    val code: String = "",
    val name: String = "",
)
/** Fanart.tv 密钥状态（iOS `API.FanartStatusView`） */
@kotlinx.serialization.Serializable
data class ScrapeFanartView(
    val configured: Boolean = false,
    @kotlinx.serialization.SerialName("key_invalid") val keyInvalid: Boolean = false,
    @kotlinx.serialization.SerialName("key_hint") val keyHint: String = "",
)

/** 保存 Fanart 密钥（iOS `API.FanartKeyPayload`） */
@kotlinx.serialization.Serializable
data class ScrapeFanartKeyPayload(val key: String = "")

/** 图片存储估算（iOS `API.ImageStorageEstimateView`，取展示所需字段） */
@kotlinx.serialization.Serializable
data class ScrapeStorageEstimate(
    @kotlinx.serialization.SerialName("current_quality") val currentQuality: String = "",
    @kotlinx.serialization.SerialName("current_bytes") val currentBytes: Long = 0,
    val presets: Map<String, Long> = emptyMap(),
)
