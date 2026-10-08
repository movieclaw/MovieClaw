import SwiftUI

/// 设置 → AI 设定（Web ai-settings-section.tsx）：什么场景用哪个模型。
///
/// 与「模型接入」分开：接入回答「怎么连上」，这里回答「智能体 / 字幕处理默认用哪个模型」。
/// 选项是所有已接入实例的模型清单（`GET /llm/models`）；服务端保证接入过供应商就一定有默认值，
/// 所以这里显示的永远是真实存的值。一个都没接入时给空态，引导去「模型接入」。
/// 抽屉内选择并确认保存（`PUT /llm/defaults`），失败留在抽屉；另一项若已失效不能原样回传，
/// 传空让服务端按推荐补齐。
struct AIDefaultsSettingsView: View {
    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback

    @State private var defaults: API.LlmDefaultsView?
    @State private var options: [API.LlmModelOptionView] = []
    @State private var error: String?
    @State private var saving: Purpose?
    @State private var selecting: Purpose?

    enum Purpose: String, CaseIterable, Identifiable {
        var id: String { rawValue }
        case agent, subtitle

        var label: String { self == .agent ? "智能体默认模型" : "字幕处理默认模型" }
        var desc: String {
            self == .agent
                ? "对话框未选模型时、微信 / Telegram / Discord 对话、命令行不带 --model 时使用"
                : "字幕翻译与生成任务使用；任务创建时固定，改动不影响已开始的任务"
        }

        func value(_ d: API.LlmDefaultsView) -> String? { self == .agent ? d.agentModel : d.subtitleModel }
        func effective(_ d: API.LlmDefaultsView) -> String? { self == .agent ? d.effectiveAgentModel : d.effectiveSubtitleModel }
    }

    var body: some View {
        List {
            if defaults != nil, options.isEmpty {
                emptyState
            } else {
                if let error { SettingsFormSection { SettingsNotice(text: error) } }
                if let defaults {
                    ForEach(Purpose.allCases, id: \.self) { purpose in
                        purposeSection(purpose, defaults)
                    }
                    SettingsFormSection {
                        Button { router.push(.settingsSection(.llm)) } label: {
                            HStack {
                                Text("模型接入").foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }.accessibilityIdentifier("ai-manage-providers")
                    } footer: { Text("可选模型来自已接入供应商的模型目录。") }
                } else if error == nil {
                    SettingsFormSection { SettingsLoadingRow() }
                }
            }
        }
        .settingsBFormStyle()
        .refreshable { await load() }
        .sheet(item: $selecting) { purpose in
            if let defaults {
                AIModelSelectionSheet(title: purpose.label, explanation: purpose.desc,
                                      options: options, original: purpose.value(defaults)) { value in
                    await save(purpose, value)
                    return error
                }
                .sheetFeedback()
            }
        }
        .task { await load() }
    }

    private var emptyState: some View {
        SettingsFormSection {
            VStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title).foregroundStyle(Theme.textMuted)
                Text("还没有可选的模型").font(.body.weight(.medium))
                Text("先在「模型接入」接入至少一家供应商。接入后这里会自动把智能体和字幕处理的默认模型设为该供应商目录里的第一个模型，你可以随时改成别的。")
                    .font(.subheadline).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
                Button("去接入模型供应商") { router.push(.settingsSection(.llm)) }
                    .settingsProminentButton()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    private func purposeSection(_ purpose: Purpose, _ defaults: API.LlmDefaultsView) -> some View {
        let value = purpose.value(defaults)
        // 未设定时可由服务端自动选择；只有明确保存过、但已退出目录的引用才属于失效。
        let stale = AIModelSelection.isStale(value, in: options)
        let effective = purpose.effective(defaults)
        let display = label(of: value == nil || stale ? effective : value) ?? "选择模型"
        return SettingsFormSection {
            Button { selecting = purpose } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(purpose == .agent ? "智能体" : "字幕处理").foregroundStyle(Theme.text)
                        Text(value == nil && effective != nil ? "自动 · \(display)" : display)
                            .font(.subheadline).foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .disabled(saving != nil)
            .accessibilityIdentifier("ai-\(purpose.rawValue)-model")
            if stale {
                Text("原设定的模型已不可用，当前使用\(label(of: purpose.effective(defaults)) ?? "无")，请选择新模型。")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        } footer: { Text(purpose.desc) }
    }

    private func label(of ref: String?) -> String? {
        options.first { $0.ref == ref }?.label ?? ref
    }

    private func load() async {
        do {
            async let d = api.llmDefaultsShow()
            async let o = api.llmModels()
            let (loadedDefaults, loadedOptions) = try await (d, o)
            options = loadedOptions
            defaults = loadedDefaults
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ purpose: Purpose, _ value: String?) async {
        guard let previous = defaults else { return }
        saving = purpose
        error = nil
        defer { saving = nil }
        /// 另一项若已失效，传空让服务端按推荐补齐（原样回传会被整体拒绝）
        func sibling(_ ref: String?) -> String? { AIModelSelection.validReference(ref, in: options) }
        do {
            defaults = try await api.llmDefaultsUpdate(body: .init(
                agentModel: purpose == .agent ? value : sibling(previous.agentModel),
                subtitleModel: purpose == .subtitle ? value : sibling(previous.subtitleModel)
            ))
            AgentCatalog.invalidateModels()
            feedback.success("AI 设定已保存")
        } catch {
            defaults = previous
            self.error = error.localizedDescription
        }
    }
}

/// 模型目录可能在编辑期间发生变化；失效的同级默认值必须交由服务端重新推荐。
enum AIModelSelection {
    static func isStale(_ ref: String?, in options: [API.LlmModelOptionView]) -> Bool {
        ref != nil && validReference(ref, in: options) == nil
    }

    static func validReference(_ ref: String?, in options: [API.LlmModelOptionView]) -> String? {
        guard let ref, options.contains(where: { $0.ref == ref }) else { return nil }
        return ref
    }

    static func filtered(_ options: [API.LlmModelOptionView], query: String) -> [API.LlmModelOptionView] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter { "\($0.label) \($0.providerName)".localizedCaseInsensitiveContains(query) }
    }
}

private struct AIModelSelectionSheet: View {
    let title: String
    let explanation: String
    let options: [API.LlmModelOptionView]
    let original: String?
    let onSave: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false

    init(title: String, explanation: String, options: [API.LlmModelOptionView], original: String?,
         onSave: @escaping (String) async -> String?) {
        self.title = title
        self.explanation = explanation
        self.options = options
        self.original = original
        self.onSave = onSave
        _selected = State(initialValue: original)
    }

    private var dirty: Bool { selected != original }

    var body: some View {
        SubsSheetScaffold(title: title, onClose: {
            if dirty { discarding = true } else { dismiss() }
        }, confirm: SubsSheetConfirm(title: "保存", enabled: dirty && AIModelSelection.validReference(selected, in: options) != nil,
                                     busy: busy, identifier: "ai-model-save") {
            guard let selected else { return }
            Task {
                busy = true
                error = await onSave(selected)
                busy = false
                if error == nil { dismiss() }
            }
        }) {
            SettingsFormSection {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索模型或供应商", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("ai-model-search")
                }
            } footer: { Text(explanation) }
            SettingsFormSection {
                let visible = AIModelSelection.filtered(options, query: query)
                if visible.isEmpty { Text("没有匹配的模型").foregroundStyle(.secondary) }
                ForEach(visible, id: \.ref) { option in
                    Button { selected = option.ref } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label).foregroundStyle(Theme.text)
                                Text(option.providerName + (option.thinkingLevels.isEmpty ? "" : " · 支持思考档位"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if selected == option.ref { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                    .accessibilityAddTraits(selected == option.ref ? .isSelected : [])
                    .accessibilityIdentifier("ai-model-option-\(option.ref)")
                }
            }
            if let error { SettingsFormSection { SettingsNotice(text: error) } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || dirty)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { dismiss() }
        }
    }
}
