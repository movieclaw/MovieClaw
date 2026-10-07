import Testing
@testable import MovieClaw

@MainActor
struct AIConnectionSettingsTests {
    private var options: [API.LlmModelOptionView] {
        [
            .init(ref: "home/Qwen", label: "Qwen（家庭）", modelId: "Qwen", providerId: 1,
                  providerName: "家庭", isDefault: true, thinkingLevels: []),
            .init(ref: "OpenAI/gpt", label: "GPT", modelId: "gpt", providerId: 2,
                  providerName: "OpenAI", isDefault: false, thinkingLevels: ["high"]),
        ]
    }

    @Test func staleSiblingModelIsNotSubmitted() {
        #expect(AIModelSelection.validReference("home/Qwen", in: options) == "home/Qwen")
        #expect(AIModelSelection.validReference("removed/model", in: options) == nil)
        #expect(AIModelSelection.validReference(nil, in: options) == nil)
        #expect(!AIModelSelection.isStale(nil, in: options))
        #expect(AIModelSelection.isStale("removed/model", in: options))
        #expect(!AIModelSelection.isStale("home/Qwen", in: options))
    }

    @Test func modelSearchMatchesSupplierAndIgnoresCaseAndWhitespace() {
        #expect(AIModelSelection.filtered(options, query: " OPENAI ").map(\.ref) == ["OpenAI/gpt"])
        #expect(AIModelSelection.filtered(options, query: "家庭").map(\.ref) == ["home/Qwen"])
        #expect(AIModelSelection.filtered(options, query: " \n ").count == 2)
        #expect(AIModelSelection.filtered(options, query: "missing").isEmpty)
    }

    @Test func invalidTimeoutCannotSilentlyPreservePreviousValue() {
        var draft = SettingsBMCPDraft()
        draft.name = "客厅"
        draft.services = ["library"]
        for invalid in ["", "abc", "4", "901", "10.5"] {
            draft.timeout = invalid
            #expect(!draft.valid)
        }
        for valid in ["5", "300", "900", " 60 "] {
            draft.timeout = valid
            #expect(draft.valid)
        }
        draft.services = []
        #expect(!draft.valid)
    }

    @Test func endpointSlugValidationPreservesUniquenessAndReadOnlyExistingSlug() {
        #expect(SettingsBMCPEndpointFields.slugError("LivingRoom", editable: true, taken: []) != nil)
        #expect(SettingsBMCPEndpointFields.slugError("living-room", editable: true, taken: ["living-room"]) != nil)
        #expect(SettingsBMCPEndpointFields.slugError("living-room", editable: true, taken: []) == nil)
        #expect(SettingsBMCPEndpointFields.slugError("living-room", editable: false, taken: ["living-room"]) == nil)
    }
}
