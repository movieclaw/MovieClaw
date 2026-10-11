package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * AI 模型供应商（服务端 `schemas/llm.py`）。「去接入」的落点用它。
 * 全部管理员接口；API Key **绝不回传**（只有写入口）。
 */

/** 一个可接入的供应商预设（服务端 `LlmPresetView`）。 */
@Serializable
data class LlmPresetView(
    val id: String = "",
    val displayName: String = "",
    /** 预设自带端点；null = 必须自己填（自建 vLLM / Ollama 等） */
    val baseUrl: String? = null,
    val requiresBaseUrl: Boolean = false,
    val defaultUserAgent: String = "",
    /** 默认 API 协议：openai_chat / openai_responses（旧服务端不返回） */
    val protocol: String? = null,
    /** 实例可切换的协议（含默认）；空 = 不可切换，不展示选择 */
    val selectableProtocols: List<String> = emptyList(),
    val models: List<LlmModelInfo> = emptyList(),
)

/** 一个模型的规格（服务端 `ModelInfo`）。 */
@Serializable
data class LlmModelInfo(
    val id: String = "",
    val contextWindow: Int? = null,
    val maxInputTokens: Int? = null,
    val maxOutputTokens: Int? = null,
    val supportsTools: Boolean = true,
    val supportsParallelToolCalls: Boolean = false,
    val supportsThinking: Boolean = false,
    val maxThinkingTokens: Int? = null,
    /** 思考强度控制的方言；null = 强度不可控（只展示思考内容） */
    val thinkingControl: LlmThinkingControl? = null,
    val modalities: List<String> = listOf("text"),
    /** 该模型支持的思考强度档位（服务端目录里可选） */
    val thinkingLevels: List<String> = emptyList(),
)

/** 思考强度控制的方言（服务端 `ThinkingControl`）：`kind` + 可选档位 + 能否关闭 */
@Serializable
data class LlmThinkingControl(
    val kind: String = "",
    val levels: List<String> = emptyList(),
    val supportsOff: Boolean = false,
)

/** 已接入的一个供应商实例（服务端 `LlmProviderView`，脱敏）。 */
@Serializable
data class LlmProviderView(
    val id: Int = 0,
    val name: String = "",
    val providerType: String = "",
    val baseUrl: String? = null,
    val userAgent: String? = null,
    /** 选用的 API 协议；null = 跟随预设默认 */
    val apiProtocol: String? = null,
    /** 连接测试用的模型 id（目录里第一个） */
    val defaultModel: String = "",
    /** pending / verifying / active / failed */
    val status: String = "pending",
    /** 可用 = 连接测试通过 */
    val usable: Boolean = false,
    val lastError: String? = null,
    val lastCheckedAt: String? = null,
    val availableModels: List<String>? = null,
    val extraModels: List<LlmModelInfo> = emptyList(),
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

/** 新建/编辑供应商（服务端 `LlmProviderPayload`）。 */
@Serializable
data class LlmProviderPayload(
    val name: String,
    /** openai / bailian / openai_compat */
    val providerType: String,
    val baseUrl: String? = null,
    val userAgent: String? = null,
    /** API 协议；null 不编码（explicitNulls=false）= 新增跟随默认、编辑沿用原值 */
    val apiProtocol: String? = null,
    /** 新增必填；编辑时 null 沿用原 Key（改了类型或端点须重填） */
    val apiKey: String? = null,
    val defaultModel: String? = null,
    val extraModels: List<LlmModelInfo> = emptyList(),
)
