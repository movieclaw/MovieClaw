import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct AgentQuickModelTests {
    @Test func quickEntryKeepsSelectedModelAndEffortAndResetsOnModelChange() throws {
        let previous = AgentComposerPrefs.load()
        defer { previous.save() }
        AgentComposerPrefs().save()
        let options = try JSONDecoder().decode([API.LlmModelOptionView].self, from: Data(#"""
        [
          {"ref":"gpt-6.1-sol","label":"gpt-6.1-sol","model_id":"gpt-6.1-sol","provider_id":1,"provider_name":"ChatGPT","is_default":true,"thinking_levels":["low","medium","high","xhigh","max"]},
          {"ref":"other","label":"other","model_id":"other","provider_id":2,"provider_name":"Other","is_default":false,"thinking_levels":["low","high"]}
        ]
        """#.utf8))
        let quick = AgentQuickDraft()
        quick.applyModelOptions(options)
        quick.chooseThinking("max")
        #expect(quick.choice == AgentComposerPrefs(model: nil, thinking: "max"))
        #expect(AgentComposerPrefs.load() == quick.choice)
        quick.chooseModel("other")
        #expect(quick.choice == AgentComposerPrefs(model: "other", thinking: nil))
        quick.chooseThinking("high")
        #expect(quick.choice.thinking == "high")
        quick.chooseThinking("max")
        #expect(quick.choice.thinking == nil)
        quick.applyModelOptions([options[0]])
        #expect(quick.choice == AgentComposerPrefs())
    }
}
