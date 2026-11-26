import Foundation
import Testing
@testable import MovieClaw

struct LLMProviderPayloadTests {
    private static func model(_ id: String, requiresResponses: Bool? = nil) -> API.ModelInfo {
        API.ModelInfo(
            id: id,
            contextWindow: 1_050_000,
            maxInputTokens: nil,
            maxInputTokensThinking: nil,
            maxOutputTokens: 128_000,
            defaultOutputTokens: nil,
            supportsTools: true,
            requiresResponsesForTools: requiresResponses,
            chatToolsRequireNoReasoning: nil,
            maxTokensParameter: nil,
            samplingRequiresNoReasoning: nil,
            fixedSampling: nil,
            supportsParallelToolCalls: true,
            supportsThinking: false,
            maxThinkingTokens: nil,
            thinkingControl: nil,
            modalities: ["text"]
        )
    }

    private static let compatPreset = API.LlmPresetView(
        id: "openai_compat",
        displayName: "OpenAI 兼容端点",
        baseUrl: nil,
        requiresBaseUrl: true,
        defaultUserAgent: "AsyncOpenAI/Python 2.0.0",
        protocol: "openai_chat",
        selectableProtocols: ["openai_chat", "openai_responses"],
        models: []
    )

    private static let openaiPreset = API.LlmPresetView(
        id: "openai",
        displayName: "OpenAI",
        baseUrl: "https://api.openai.com/v1",
        requiresBaseUrl: false,
        defaultUserAgent: "AsyncOpenAI/Python 2.0.0",
        protocol: "openai_responses",
        selectableProtocols: ["openai_responses", "openai_chat"],
        models: [
            model("gpt-6.1-sol", requiresResponses: true),
            model("gpt-6-luna", requiresResponses: false),
        ]
    )

    private static func provider(
        providerType: String = "openai_compat",
        baseUrl: String? = "http://127.0.0.1:18339/v1",
        apiProtocol: String? = "openai_responses",
        defaultModel: String = "gpt-6.2-sol",
        extraModels: [API.ModelInfo] = [model("gpt-6.1-sol"), model("gpt-6.2-sol")]
    ) -> API.LlmProviderView {
        API.LlmProviderView(
            id: 42,
            name: "合成中转",
            providerType: providerType,
            chatgptAccount: nil,
            baseUrl: baseUrl,
            userAgent: nil,
            apiProtocol: apiProtocol,
            defaultModel: defaultModel,
            status: "active",
            usable: true,
            lastError: nil,
            lastCheckedAt: nil,
            availableModels: nil,
            extraModels: extraModels,
            createdAt: "2026-11-19T00:00:00Z",
            updatedAt: "2026-11-19T00:00:00Z"
        )
    }

    @Test func editingUnrelatedFieldPreservesConfiguredTestModel() throws {
        let existing = Self.provider()
        let payload = SettingsBLLMProviderForm.makePayload(
            provider: existing,
            name: "合成中转-改名",
            fallbackName: "OpenAI 兼容端点",
            providerType: existing.providerType,
            preset: Self.compatPreset,
            baseUrl: existing.baseUrl ?? "",
            userAgent: "custom-ua/1.0",
            apiProtocol: existing.apiProtocol ?? "",
            apiKey: "",
            extraModels: existing.extraModels + [Self.model("gpt-6.3-mini")]
        )

        #expect(payload.defaultModel == "gpt-6.2-sol")
        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["default_model"] as? String == "gpt-6.2-sol")
        #expect(json["api_key"] == nil)
    }

    @Test func editingCompatWithCatalogBackedDefaultModelPreservesIt() {
        // 测试模型来自公共目录而非 extra_models 时（CLI 配置常见形态），编辑无关字段同样不应冲掉
        let existing = Self.provider(
            defaultModel: "gpt-6.2-sol",
            extraModels: [Self.model("gpt-6.1-sol")]
        )
        let payload = SettingsBLLMProviderForm.makePayload(
            provider: existing,
            name: "合成中转-换名",
            fallbackName: "OpenAI 兼容端点",
            providerType: existing.providerType,
            preset: Self.compatPreset,
            baseUrl: existing.baseUrl ?? "",
            userAgent: "",
            apiProtocol: existing.apiProtocol ?? "",
            apiKey: "sk-new-synthetic",
            extraModels: existing.extraModels
        )

        #expect(payload.defaultModel == "gpt-6.2-sol")
    }

    @Test func editingPresetProviderPreservesConfiguredTestModel() {
        let existing = Self.provider(
            providerType: "openai",
            baseUrl: nil,
            apiProtocol: "openai_responses",
            defaultModel: "gpt-6-luna",
            extraModels: []
        )
        let payload = SettingsBLLMProviderForm.makePayload(
            provider: existing,
            name: "官方改名",
            fallbackName: "OpenAI",
            providerType: "openai",
            preset: Self.openaiPreset,
            baseUrl: "",
            userAgent: "",
            apiProtocol: "openai_responses",
            apiKey: "",
            extraModels: []
        )

        #expect(payload.defaultModel == "gpt-6-luna")
    }

    @Test func creatingProviderLeavesDefaultModelNil() throws {
        let payload = SettingsBLLMProviderForm.makePayload(
            provider: nil,
            name: "新建中转",
            fallbackName: "OpenAI 兼容端点",
            providerType: "openai_compat",
            preset: Self.compatPreset,
            baseUrl: "http://127.0.0.1:18339/v1",
            userAgent: "",
            apiProtocol: "",
            apiKey: "sk-create",
            extraModels: [Self.model("gpt-6.1-sol")]
        )

        #expect(payload.defaultModel == nil)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["default_model"] == nil)
    }

    @Test func switchingProviderTypeResetsDefaultModelToNil() {
        let existing = Self.provider(providerType: "openai_compat", defaultModel: "gpt-6.2-sol")
        let payload = SettingsBLLMProviderForm.makePayload(
            provider: existing,
            name: "切到官方",
            fallbackName: "OpenAI",
            providerType: "openai",
            preset: Self.openaiPreset,
            baseUrl: "",
            userAgent: "",
            apiProtocol: "",
            apiKey: "sk-switched",
            extraModels: []
        )

        #expect(payload.defaultModel == nil)
    }

    @Test func removingConfiguredCustomModelFallsBackToNil() {
        let existing = Self.provider(
            defaultModel: "gpt-6.2-sol",
            extraModels: [Self.model("gpt-6.1-sol"), Self.model("gpt-6.2-sol")]
        )
        let payload = SettingsBLLMProviderForm.makePayload(
            provider: existing,
            name: existing.name,
            fallbackName: "OpenAI 兼容端点",
            providerType: existing.providerType,
            preset: Self.compatPreset,
            baseUrl: existing.baseUrl ?? "",
            userAgent: "",
            apiProtocol: existing.apiProtocol ?? "",
            apiKey: "",
            extraModels: [Self.model("gpt-6.1-sol")]
        )

        #expect(payload.defaultModel == nil)
    }

    @Test func switchingToChatProtocolDropsResponsesOnlyDefaultModel() {
        let existing = Self.provider(
            providerType: "openai",
            baseUrl: nil,
            apiProtocol: "openai_responses",
            defaultModel: "gpt-6.1-sol",
            extraModels: []
        )
        let payload = SettingsBLLMProviderForm.makePayload(
            provider: existing,
            name: existing.name,
            fallbackName: "OpenAI",
            providerType: "openai",
            preset: Self.openaiPreset,
            baseUrl: "",
            userAgent: "",
            apiProtocol: "openai_chat",
            apiKey: "",
            extraModels: []
        )

        #expect(payload.defaultModel == nil)
    }
}
