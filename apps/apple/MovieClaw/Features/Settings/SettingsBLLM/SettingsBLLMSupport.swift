import SwiftUI

// 「设置 → 模型接入」的纯逻辑小件：状态文案、token 数格式化、模型能力短标、
// 自定义模型草稿与 View→Input 转换。与 Web `llm-config-section.tsx` 里的同名函数逐一对应，
// 界面文件只管排版，口径集中在这里，改文案 / 改判据只动一处。

// MARK: - 连接状态

/// 连接状态 → 文案与语义色（与 Web STATUS_META 同一套：已连接 / 测试中 / 待测试 / 连接失败）
enum SettingsBLLMStatus {
    static func label(_ status: String) -> String {
        switch status {
        case "active": String(localized: .settingsDevicesLabelsConnected)
        case "verifying": String(localized: .settingsLlmUiTesting)
        case "pending": String(localized: .settingsLlmUiPending)
        case "failed": String(localized: .settingsLlmUiFailed)
        default: status
        }
    }

    static func tone(_ status: String) -> SettingsBTone {
        switch status {
        case "active": .ok
        case "verifying": .info
        case "failed": .danger
        default: .neutral
        }
    }

    /// 需要轮询测试进度的中间态（Web IN_PROGRESS）
    static func inProgress(_ status: String) -> Bool {
        status == "pending" || status == "verifying"
    }
}

// MARK: - 格式化

enum SettingsBLLMFormat {
    /// token 数 → 简短可读。2 的幂按 1024 进制（65536 → 64K），其余十进制（1050000 → 1.05M）。
    /// 与 Web formatTokens 同口径，避免两端同一个模型写出不同的「上下文 128K / 131K」。
    static func tokens(_ n: Int) -> String {
        if n % 1024 == 0 && n < 1_000_000 { return "\(n / 1024)K" }
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : String(format: "%.2fM", m)
        }
        return "\(Int((Double(n) / 1000).rounded()))K"
    }

    /// 能力短标（思考 / 档位可控 / 视觉 / 视频）。「档位可控」同 Web 看服务端推导的 `thinking_levels` 是否非空
    ///（预算分段模式没设预算上限时没有档位菜单，只看是否声明了 thinking_control 会误标）。
    static func hints(_ m: API.ModelInfo) -> String {
        [
            m.supportsThinking ? String(localized: .settingsLlmUiThinking) : nil,
            !m.thinkingLevels.isEmpty ? String(localized: .settingsLlmUiAdjustable) : nil,
            m.modalities.contains("image") ? String(localized: .settingsLlmUiVision) : nil,
            m.modalities.contains("video") ? String(localized: .settingsLlmUiVideo) : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// 规格说明：上下文 / 最大输出 / 思考预算 / 并发工具，未公布的字段不显示
    static func specs(_ m: API.ModelInfo) -> String {
        [
            m.contextWindow.map { String(localized: .settingsLlmUiContextSpec(tokens($0))) },
            m.maxOutputTokens.map { String(localized: .settingsLlmUiOutputSpec(tokens($0))) },
            m.maxThinkingTokens.map { String(localized: .settingsLlmUiBudgetSpec(tokens($0))) },
            m.supportsParallelToolCalls ? String(localized: .settingsLlmUiParallelTools) : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// 供应商提示：固定端点显示域名，其余说明接入方式（Web providerHint）
    /// API 协议的展示名（与 Web PROTOCOL_LABELS 一致）
    static func protocolLabel(_ id: String) -> String {
        switch id {
        case "openai_chat": return "Chat Completions"
        case "openai_responses": return "Responses API"
        default: return id
        }
    }

    static func providerHint(_ preset: API.LlmPresetView) -> String {
        if preset.id == "bailian" { return String(localized: .settingsLlmUiBailianHint) }
        if preset.id == "openai" { return String(localized: .settingsLlmSupportOfficial) }
        if preset.requiresBaseUrl { return String(localized: .settingsLlmUiCompatHint) }
        if let base = preset.baseUrl {
            return URL(string: base)?.host() ?? base
        }
        return String(localized: .settingsLlmUiOfficialEndpoint)
    }
}

// MARK: - 自定义模型草稿

/// 「自定义模型参数」子表单的输入状态（数字以字符串暂存，提交时转换；同 Web NewModelDraft）
struct SettingsBLLMModelDraft: Equatable {
    /// 思考控制方言：none = 不可控（只展示思考内容，即不声明 thinking_control）
    enum ThinkingKind: String, CaseIterable, Identifiable {
        case none, effort, budget, toggle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: String(localized: .settingsLlmSupportUncontrolled)
            case .effort: String(localized: .settingsLlmUiEffortControl)
            case .budget: String(localized: .settingsLlmUiBudgetControl)
            case .toggle: String(localized: .settingsLlmUiToggleControl)
            }
        }
    }

    /// effort 制可声明的档位（词汇表排除 off——关闭走「支持关闭思考」开关）
    static let declarableLevels = ["minimal", "low", "medium", "high", "xhigh", "max"]
    static let levelLabels = ["minimal": String(localized: .settingsLlmUiMinimal), "low": String(localized: .settingsLlmUiLow), "medium": String(localized: .settingsLlmUiMedium), "high": String(localized: .settingsLlmUiHigh), "xhigh": String(localized: .settingsLlmUiXhigh), "max": String(localized: .settingsLlmUiMax)]

    var id = ""
    var contextWindow = ""
    var maxInput = ""
    var maxOutput = ""
    var thinkingBudget = ""
    var supportsTools = true
    var parallel = false
    var thinking = false
    var vision = false
    var video = false
    var thinkingKind: ThinkingKind = .none
    var thinkingLevels: [String] = []
    var supportsOff = false

    private static func positive(_ s: String) -> Int? {
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return n
    }

    /// 必填校验：id / 上下文 / 最大输出；开思考则预算也必填；档位直传制至少声明一档
    var isValid: Bool {
        !id.trimmingCharacters(in: .whitespaces).isEmpty
            && Self.positive(contextWindow) != nil
            && Self.positive(maxOutput) != nil
            && (!thinking || Self.positive(thinkingBudget) != nil)
            && (thinkingKind != .effort || !thinkingLevels.isEmpty)
    }

    var hint: String {
        thinkingKind == .effort && thinkingLevels.isEmpty
            ? String(localized: .settingsLlmUiEffortRequired)
            : String(localized: .settingsLlmUiDraftRequired)
    }

    /// 切换一个档位（按固定词汇表顺序归一，声明不是有序集合）
    mutating func toggleLevel(_ level: String) {
        let on = !thinkingLevels.contains(level)
        thinkingLevels = Self.declarableLevels.filter { $0 == level ? on : thinkingLevels.contains($0) }
    }

    /// 草稿 → 目录条目（与 Web addCustomModel 同构）
    func build() -> API.ModelInfo {
        let control: API.ThinkingControl? = (!thinking || thinkingKind == .none) ? nil : API.ThinkingControl(
            kind: thinkingKind.rawValue,
            levels: thinkingKind == .effort ? thinkingLevels : [],
            // toggle 的意义就是可关，隐含 supports_off；其余按勾选
            supportsOff: thinkingKind == .toggle ? true : supportsOff
        )
        return API.ModelInfo(
            id: id.trimmingCharacters(in: .whitespaces),
            contextWindow: Self.positive(contextWindow),
            maxInputTokens: Self.positive(maxInput),
            maxOutputTokens: Self.positive(maxOutput),
            supportsTools: supportsTools,
            supportsParallelToolCalls: parallel,
            supportsThinking: thinking,
            maxThinkingTokens: thinking ? Self.positive(thinkingBudget) : nil,
            thinkingControl: control,
            modalities: ["text"] + (vision ? ["image"] : []) + (video ? ["video"] : [])
        )
    }
}

// MARK: - View → Input

extension API.ModelInfo {
    /// 读到的目录条目（View）→ 提交用的 Input：编辑时原样回传已有的自定义目录
    var settingsBLLMInput: API.ModelInfoInput {
        API.ModelInfoInput(
            id: id,
            contextWindow: contextWindow,
            maxInputTokens: maxInputTokens,
            maxOutputTokens: maxOutputTokens,
            supportsTools: supportsTools,
            requiresResponsesForTools: requiresResponsesForTools,
            chatToolsRequireNoReasoning: chatToolsRequireNoReasoning,
            maxTokensParameter: maxTokensParameter,
            samplingRequiresNoReasoning: samplingRequiresNoReasoning,
            fixedSampling: fixedSampling,
            supportsParallelToolCalls: supportsParallelToolCalls,
            supportsThinking: supportsThinking,
            maxThinkingTokens: maxThinkingTokens,
            thinkingControl: thinkingControl.map {
                API.ThinkingControlInput(kind: $0.kind, levels: $0.levels, supportsOff: $0.supportsOff)
            },
            modalities: modalities
        )
    }
}
