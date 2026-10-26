import SwiftUI

/// 接入 / 编辑一个模型供应商实例（对应 Web `LlmProviderForm`，新增与编辑共用）。
///
/// 字段随所选供应商的预设动态变化（判据与 Web 完全一致）：
/// - **端点与 User-Agent** 只对「预设没有固定端点」的供应商开放（OpenAI 可配镜像、通用兼容端点必填）；
///   百炼 / DeepSeek / Kimi / GLM 这类官方固定渠道两者都不展示，提交时 UA 一律回传 null，
///   避免切换供应商后残留上一个自定义端点的 UA。
/// - **模型目录**：有内置目录的官方渠道以预设为准、不开放自定义；无目录的兼容端点必须自己补录
///   （可「借用」其它预设目录里的同名模型，参数原样复制；或展开参数子表单填一个自定义模型）。
///   切换供应商不删除已补录的条目，切回即恢复。
/// - **API Key** 出于安全后端不回传（接口也要求必填），编辑时同样要重新填写；输入默认遮罩、可切换显示。
///
/// 保存后由后端异步测试连接，列表页随后轮询状态，所以这里保存成功即关闭弹层（Web 同样不弹 Toast）。
/// 失败原因（后端中文）显示在表单顶部，弹层保持打开以便修改。
struct SettingsBLLMProviderForm: View {
    /// 被编辑的实例；nil 表示新增
    let provider: API.LlmProviderView?
    let presets: [API.LlmPresetView]
    /// 其它实例已占用的实例名（实例名全局唯一）
    let takenNames: [String]
    let onSaved: () -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var providerType: String
    @State private var baseUrl: String
    @State private var userAgent: String
    /// 空串 = 跟随预设默认协议（不编码，后端沿用原值或用默认）
    @State private var apiProtocol: String
    @State private var advancedOpen: Bool
    @State private var apiKey = ""
    @State private var showApiKey = false
    /// 自定义模型目录（随配置持久化）：无内置目录的兼容端点靠它定义可用模型
    @State private var extraModels: [API.ModelInfo]
    /// 「自定义模型」参数子表单：只在用户选择添加自定义模型时展开
    @State private var addingCustom = false
    @State private var draft = SettingsBLLMModelDraft()
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false

    init(provider: API.LlmProviderView?, presets: [API.LlmPresetView], takenNames: [String], onSaved: @escaping () -> Void) {
        self.provider = provider
        self.presets = presets
        self.takenNames = takenNames
        self.onSaved = onSaved
        _name = State(initialValue: provider?.name ?? "")
        _providerType = State(initialValue: provider?.providerType ?? "bailian")
        _baseUrl = State(initialValue: provider?.baseUrl ?? "")
        _userAgent = State(initialValue: provider?.userAgent ?? "")
        _apiProtocol = State(initialValue: provider?.apiProtocol ?? "")
        _advancedOpen = State(initialValue: provider?.userAgent != nil || provider?.apiProtocol != nil)
        _extraModels = State(initialValue: provider?.extraModels ?? [])
    }

    // MARK: - 派生状态（与 Web 同名变量一一对应）

    private var preset: API.LlmPresetView? { presets.first { $0.id == providerType } }
    private var catalog: [API.ModelInfo] { preset?.models ?? [] }
    private var isCustomEndpoint: Bool { catalog.isEmpty }
    private var extras: [API.ModelInfo] { isCustomEndpoint ? extraModels : [] }
    private var needBaseUrl: Bool { preset?.requiresBaseUrl ?? false }
    /// 端点没有预设默认值 = 用户自定义接入点，只有这类才需要端点与 User-Agent 输入
    private var canCustomizeEndpoint: Bool { preset?.baseUrl == nil }
    /// 协议可切换的预设（OpenAI / 通用兼容端点）才展示协议选择
    private var protocolOptions: [String] { preset?.selectableProtocols ?? [] }
    private var canChooseProtocol: Bool { protocolOptions.count > 1 }

    /// 无内置目录的端点：把其它预设目录的模型也纳入可添加（换端点时模型名与参数往往一致）
    private var borrowedGroups: [(label: String, models: [API.ModelInfo])] {
        guard isCustomEndpoint else { return [] }
        return presets
            .filter { $0.id != providerType && !$0.models.isEmpty }
            .map { p in (p.displayName, p.models.filter { m in !extras.contains { $0.id == m.id } }) }
            .filter { !$0.1.isEmpty }
    }

    private var trimmedBaseUrl: String { baseUrl.trimmingCharacters(in: .whitespaces) }
    private var trimmedUA: String { userAgent.trimmingCharacters(in: .whitespaces) }

    /// 编辑时 Key 可留空沿用；但类型或端点变了必须重填（与后端同一判据），免得旧 Key 被发往新地址
    private var apiKeyRequired: Bool {
        guard let provider else { return true }
        var url = trimmedBaseUrl
        while url.hasSuffix("/") { url.removeLast() }
        return providerType != provider.providerType || (url.isEmpty ? nil : url) != provider.baseUrl
    }

    private var baseUrlValid: Bool {
        if trimmedBaseUrl.isEmpty { return !needBaseUrl }
        return trimmedBaseUrl.range(of: #"^https?://.+"#, options: .regularExpression) != nil
    }

    /// 请求头值只能是可打印 ASCII（与后端校验同一判据），空即用 SDK 默认
    private var userAgentValid: Bool {
        trimmedUA.isEmpty || trimmedUA.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    private var submitHint: String? {
        if name.contains("/") { return String(localized: .settingsLlmUiNameInvalid) }
        if apiKeyRequired && apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return provider == nil ? String(localized: .settingsLlmUiKeyRequired) : String(localized: .settingsLlmUiKeyChanged)
        }
        if !baseUrlValid { return String(localized: .settingsLlmUiEndpointInvalid) }
        if isCustomEndpoint && extras.isEmpty { return String(localized: .settingsLlmFormNeedModel) }
        if !userAgentValid { return String(localized: .settingsLlmUiUaInvalid) }
        return nil
    }

    private var dirty: Bool {
        return name != (provider?.name ?? "") || providerType != (provider?.providerType ?? "bailian")
            || baseUrl != (provider?.baseUrl ?? "") || userAgent != (provider?.userAgent ?? "")
            || apiProtocol != (provider?.apiProtocol ?? "")
            || !apiKey.isEmpty || extraModels != (provider?.extraModels ?? [])
            || (addingCustom && draft != SettingsBLLMModelDraft())
    }

    // MARK: - 界面

    var body: some View {
        SubsSheetScaffold(title: provider == nil ? String(localized: .settingsLlmUiAddTitle) : String(localized: .settingsLlmFormEditTitle), onClose: {
            if dirty { discarding = true } else { dismiss() }
        }, confirm: SubsSheetConfirm(title: String(localized: .settingsLlmUiSave),
                                     enabled: submitHint == nil,
                                     busy: busy, identifier: "llm-form-save") {
            Task { await submit() }
        }) {
                if let error {
                    SettingsFormSection {
                        SettingsBNotice(text: error, tone: .danger)
                            .accessibilityIdentifier("llm-form-error")
                    }
                }
                providerSection
                connectionSection
                catalogSection
                if isCustomEndpoint && addingCustom {
                    customModelSection
                }
                if let submitHint {
                    SettingsFormSection {
                        Text(submitHint)
                            .font(.caption)
                            .foregroundStyle(Theme.textFaint)
                            .accessibilityIdentifier("llm-form-hint")
                    }
                }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || dirty)
        .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
        }
        .onChange(of: providerType) { _, _ in
            // 换供应商：端点 / UA / 高级设置 / 参数子表单都与上一家无关，一并清掉
            baseUrl = ""
            userAgent = ""
            apiProtocol = ""
            advancedOpen = false
            addingCustom = false
        }
    }

    /// 供应商（下拉）+ 所选供应商的提示卡
    private var providerSection: some View {
        SettingsFormSection {
            Picker(String(localized: .settingsLlmUiProvider), selection: $providerType) {
                if presets.isEmpty {
                    Text(String(localized: .settingsLlmUiLoadingProviders)).tag(providerType)
                }
                ForEach(presets, id: \.id) { item in
                    Text(item.displayName).tag(item.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(presets.isEmpty)
            .accessibilityIdentifier("llm-form-provider")
            if let preset {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName).font(.subheadline.weight(.semibold))
                    Text(SettingsBLLMFormat.providerHint(preset)).font(.caption).foregroundStyle(Theme.textFaint)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("llm-form-provider-hint")
            }
        } header: {
            Text(String(localized: .settingsLlmUiProvider))
        } footer: {
            Text(String(localized: .settingsLlmUiAutoTest))
        }
    }

    /// 实例名 / API 端点 / API Key / 高级设置（User-Agent）
    private var connectionSection: some View {
        SettingsFormSection {
            SettingsBTextField(
                label: String(localized: .settingsLlmUiName),
                text: $name,
                placeholder: preset?.displayName ?? String(localized: .settingsLlmUiNamePlaceholder),
                hint: String(localized: .settingsLlmUiNameHint),
                identifier: "llm-form-name"
            )

            // 端点固定的官方渠道不展示端点输入；OpenAI 保留可选输入（代理/镜像），通用兼容端点必填
            if canCustomizeEndpoint {
                SettingsBTextField(
                    label: String(localized: .settingsLlmUiEndpoint) + (needBaseUrl ? " *" : String(localized: .settingsLlmUiOptional)),
                    text: $baseUrl,
                    placeholder: needBaseUrl ? "http://192.168.1.5:8000/v1" : String(localized: .settingsLlmFormOfficialEndpoint),
                    hint: needBaseUrl ? nil : String(localized: .settingsLlmFormEndpointHint),
                    mono: true,
                    keyboard: .URL,
                    identifier: "llm-form-base-url"
                )
            }

            apiKeyField

            // API 协议与 User-Agent 都是低频字段，默认折叠以缩短主流程
            if canCustomizeEndpoint {
                DisclosureGroup(isExpanded: $advancedOpen) {
                    if canChooseProtocol {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker(String(localized: .settingsLlmUiProtocol), selection: Binding(
                                mcGet: { apiProtocol.isEmpty ? (preset?.protocol ?? protocolOptions[0]) : apiProtocol },
                                set: { apiProtocol = $0 }
                            )) {
                                ForEach(protocolOptions, id: \.self) { id in
                                    Text(SettingsBLLMFormat.protocolLabel(id) + (id == preset?.protocol ? String(localized: .settingsLlmUiDefaultSuffix) : ""))
                                        .tag(id)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("llm-form-api-protocol")
                            Text(String(localized: .settingsLlmFormApiHint))
                                .font(.caption)
                                .foregroundStyle(Theme.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: .settingsLlmUiUserAgent)).font(.subheadline).foregroundStyle(Theme.textMuted)
                        // 占位符直接展示留空时实际发送的 SDK 自带 UA（后端按 SDK 版本现算）
                        TextField(preset?.defaultUserAgent ?? String(localized: .settingsLlmUiUaPlaceholder), text: $userAgent)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("llm-form-user-agent")
                        Text(userAgentValid
                             ? String(localized: .settingsLlmUiUaHint)
                             : String(localized: .settingsLlmUiUaAscii))
                            .font(.caption)
                            .foregroundStyle(userAgentValid ? Theme.textFaint : Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    HStack {
                        Text(String(localized: .settingsLlmUiAdvanced))
                        Spacer()
                        if !advancedOpen {
                            Text(canChooseProtocol ? String(localized: .settingsLlmUiAdvancedSummary) : "User-Agent")
                                .font(.caption).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
                .accessibilityIdentifier("llm-form-advanced")
            }
        }
    }

    /// API Key：默认遮罩，右侧「显示 / 隐藏」切换；不回显已保存的密钥
    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(apiKeyRequired ? "API Key *" : "API Key").font(.subheadline).foregroundStyle(Theme.textMuted)
            HStack {
                Group {
                    if showApiKey {
                        TextField(apiKeyRequired ? "sk-…" : String(localized: .settingsLlmUiKeepKey), text: $apiKey)
                    } else {
                        SecureField(apiKeyRequired ? "sk-…" : String(localized: .settingsLlmUiKeepKey), text: $apiKey)
                    }
                }
                .font(.body.monospaced())
                .textContentType(nil)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("llm-form-api-key")
                Button(showApiKey ? String(localized: .settingsLlmUiHide) : String(localized: .settingsLlmUiShow)) { showApiKey.toggle() }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showApiKey ? String(localized: .settingsLlmUiHideKey) : String(localized: .settingsLlmUiShowKey))
                    .accessibilityIdentifier("llm-form-api-key-toggle")
            }
            if provider != nil {
                Text(apiKeyRequired ? String(localized: .settingsLlmUiKeyChangedHint) : String(localized: .settingsLlmUiKeyPrivacy))
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// 模型目录：兼容端点列出已补录的模型 + 「添加模型」菜单；官方渠道只写一句预设说明
    @ViewBuilder
    private var catalogSection: some View {
        if isCustomEndpoint {
            SettingsFormSection {
                ForEach(extras, id: \.id) { m in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.id).font(.subheadline.weight(.medium)).lineLimit(1)
                            let detail = [SettingsBLLMFormat.specs(m), SettingsBLLMFormat.hints(m)]
                                .filter { !$0.isEmpty }.joined(separator: " · ")
                            Text(detail.isEmpty ? String(localized: .settingsLlmUiSpecsFallback) : detail)
                                .font(.caption)
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Button(String(localized: .settingsDrivesRemove)) { extraModels.removeAll { $0.id == m.id } }
                            .font(.caption)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.textMuted)
                            .accessibilityIdentifier("llm-model-remove-\(m.id)")
                    }
                    .accessibilityIdentifier("llm-model-\(m.id)")
                }
                Menu {
                    // 其它预设目录的模型：选中即入列，参数复用
                    ForEach(borrowedGroups, id: \.label) { group in
                        SettingsFormSection(String(localized: .settingsLlmUiBorrowedCatalog(group.label))) {
                            ForEach(group.models, id: \.id) { m in
                                let hints = SettingsBLLMFormat.hints(m)
                                Button(m.id + (hints.isEmpty ? "" : "（\(hints)）")) { borrow(m) }
                            }
                        }
                    }
                    Button(String(localized: .settingsLlmUiCustomModelOption)) { addingCustom = true }
                } label: {
                    Label(String(localized: .settingsLlmFormAddModel), systemImage: "plus")
                }
                .accessibilityIdentifier("llm-form-add-model")
            } header: {
                Text(String(localized: .settingsLlmFormCatalog))
            } footer: {
                Text(String(localized: .settingsLlmFormCustomCatalogHint))
            }
        } else if let preset {
            SettingsFormSection {
                Text(String(localized: .settingsLlmFormPresetCatalog(preset.displayName, catalog.count)))
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("llm-form-catalog-note")
            }
        }
    }

    /// 自定义模型参数子表单：这些参数是 agent 做上下文 / 思考预算决策的依据，必填项带 *
    private var customModelSection: some View {
        SettingsFormSection {
            SettingsBTextField(label: String(localized: .settingsLlmUiModelId), text: $draft.id, placeholder: String(localized: .settingsLlmUiModelPlaceholder), mono: true, identifier: "llm-custom-id")
            SettingsBNumberField(label: String(localized: .settingsLlmUiContextWindow), text: $draft.contextWindow, placeholder: "131072", identifier: "llm-custom-context")
            SettingsBNumberField(label: String(localized: .settingsLlmUiMaxOutput), text: $draft.maxOutput, placeholder: "8192", identifier: "llm-custom-max-output")
            SettingsBNumberField(label: String(localized: .settingsLlmUiMaxInput), text: $draft.maxInput, placeholder: String(localized: .settingsLlmUiInputPlaceholder), identifier: "llm-custom-max-input")

            Toggle(String(localized: .settingsLlmUiTools), isOn: Binding(
                get: { draft.supportsTools },
                set: { draft.supportsTools = $0; draft.parallel = $0 && draft.parallel }
            ))
            .accessibilityIdentifier("llm-custom-tools")
            Toggle(String(localized: .settingsLlmUiParallelTools), isOn: $draft.parallel)
                .disabled(!draft.supportsTools)
                .accessibilityIdentifier("llm-custom-parallel")
            Toggle(String(localized: .settingsLlmUiThinkingOutput), isOn: Binding(
                get: { draft.thinking },
                set: { draft.thinking = $0; if !$0 { draft.thinkingKind = .none } }
            ))
            .accessibilityIdentifier("llm-custom-thinking")
            Toggle(String(localized: .settingsLlmUiImageInput), isOn: $draft.vision).accessibilityIdentifier("llm-custom-vision")
            Toggle(String(localized: .settingsLlmUiVideoInput), isOn: $draft.video).accessibilityIdentifier("llm-custom-video")

            if draft.thinking {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsBNumberField(label: String(localized: .settingsLlmFormThinkingBudget), text: $draft.thinkingBudget, placeholder: String(localized: .settingsLlmUiBudgetPlaceholder), identifier: "llm-custom-thinking-budget")
                    Text(String(localized: .settingsLlmUiBudgetHint))
                        .font(.caption).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Picker(String(localized: .settingsLlmUiThinkingControl), selection: $draft.thinkingKind) {
                        ForEach(SettingsBLLMModelDraft.ThinkingKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("llm-custom-thinking-kind")
                    Text(String(localized: .settingsLlmFormThinkingHint))
                        .font(.caption).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if draft.thinkingKind == .effort {
                    SettingsBFlow {
                        ForEach(SettingsBLLMModelDraft.declarableLevels, id: \.self) { level in
                            SettingsBSelectChip(
                                title: SettingsBLLMModelDraft.levelLabels[level] ?? level,
                                selected: draft.thinkingLevels.contains(level),
                                identifier: "llm-custom-level-\(level)"
                            ) {
                                draft.toggleLevel(level)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if draft.thinkingKind == .effort || draft.thinkingKind == .budget {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(String(localized: .settingsLlmUiSupportsOff), isOn: $draft.supportsOff)
                            .accessibilityIdentifier("llm-custom-supports-off")
                        Text(String(localized: .settingsLlmFormOffHint))
                            .font(.caption).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !draft.isValid {
                Text(draft.hint).font(.caption).foregroundStyle(Theme.textFaint)
            }
            HStack(spacing: 10) {
                Button {
                    addCustomModel()
                } label: {
                    Text(String(localized: .settingsLlmUiAddToCatalog)).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .discoverProminentButton()
                .disabled(!draft.isValid)
                .accessibilityIdentifier("llm-custom-add")
                Button {
                    draft = SettingsBLLMModelDraft()
                    addingCustom = false
                } label: {
                    Text(String(localized: .commonCancel)).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("llm-custom-cancel")
            }
        } header: {
            Text(String(localized: .settingsLlmUiCustomParameters))
        } footer: {
            Text(String(localized: .settingsLlmUiCustomParametersHint))
        }
    }

    // MARK: - 动作

    private func borrow(_ model: API.ModelInfo) {
        guard !extraModels.contains(where: { $0.id == model.id }) else { return }
        extraModels.append(model)
    }

    /// 把参数子表单里的自定义模型加进目录（同 id 覆盖旧条目：改参数重存是常见操作）
    private func addCustomModel() {
        let custom = draft.build()
        extraModels = extraModels.filter { $0.id != custom.id } + [custom]
        draft = SettingsBLLMModelDraft()
        addingCustom = false
    }

    /// 留空时按供应商显示名保存；同类型第二家会撞唯一实例名，自动加序号（「OpenAI 2」）
    private func fallbackName() -> String {
        let base = preset?.displayName ?? providerType
        var candidate = base
        var i = 2
        while takenNames.contains(candidate) {
            candidate = "\(base) \(i)"
            i += 1
        }
        return candidate
    }

    private func submit() async {
        guard submitHint == nil else { return }
        busy = true
        error = nil
        defer { busy = false }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let payload = API.LlmProviderPayload(
            name: trimmedName.isEmpty ? fallbackName() : trimmedName,
            providerType: providerType,
            baseUrl: trimmedBaseUrl.isEmpty ? nil : trimmedBaseUrl,
            // 端点固定的官方渠道不开放 UA 配置，一律回传 null
            userAgent: canCustomizeEndpoint && !trimmedUA.isEmpty ? trimmedUA : nil,
            // 没选过就不编码：新增跟随预设默认，编辑沿用原值
            apiProtocol: canChooseProtocol && !apiProtocol.isEmpty ? apiProtocol : nil,
            // 留空不编码：编辑时沿用原 Key
            apiKey: apiKey.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKey.trimmingCharacters(in: .whitespaces),
            // 连接测试模型由服务端取目录第一个；官方渠道不回传自定义目录
            defaultModel: nil,
            extraModels: extras.map(\.settingsBLLMInput)
        )
        do {
            if let provider {
                _ = try await api.llmProvidersUpdate(providerId: provider.id, body: payload)
            } else {
                _ = try await api.llmProvidersCreate(body: payload)
                LLMCapabilityProbe.shared.invalidate()
            }
            // 增改后对话框的模型清单立即失效（Web afterChange → invalidateModelOptionsCache）
            AgentCatalog.invalidateModels()
            onSaved()
            dismiss()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
