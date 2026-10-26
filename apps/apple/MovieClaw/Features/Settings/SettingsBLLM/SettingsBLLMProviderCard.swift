import SwiftUI

/// 模型供应商详情：连接状态与测试留在正文，编辑和删除放在右上角。
struct SettingsBLLMProviderCard: View {
    let provider: API.LlmProviderView
    let preset: API.LlmPresetView?
    let busy: Bool
    let error: String?
    let onEdit: () -> Void
    let onReverify: () async -> Void
    let onDelete: () async -> Void

    var body: some View {
        Form {
            SettingsFormSection {
                LabeledContent(String(localized: .settingsLlmCardStatus)) { SettingsBLLMStatusPill(status: provider.status) }
                LabeledContent(String(localized: .settingsLlmUiProvider), value: serverManaged ? String(localized: .settingsLlmCardServerManaged) : preset?.displayName ?? provider.providerType)
                LabeledContent(String(localized: .settingsLlmCardLastChecked), value: provider.lastCheckedAt.map { Formatters.relative($0) } ?? String(localized: .settingsLlmCardNeverChecked))
                if failed, let reason = provider.lastError {
                    Text(reason).font(.footnote).foregroundStyle(Theme.danger)
                }
                if serverManaged {
                    Text(String(localized: .settingsLlmCardServerHint))
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                        .accessibilityIdentifier("llm-server-managed")
                } else {
                    SettingsBAsyncButton(action: onReverify) {
                        Label(String(localized: .settingsWebSearchUiRetest), systemImage: "arrow.clockwise")
                    }
                    .disabled(busy || SettingsBLLMStatus.inProgress(provider.status))
                    .accessibilityIdentifier("llm-reverify-\(provider.id)")
                }
            }
            SettingsFormSection(String(localized: .settingsLlmCardConnection)) {
                if !serverManaged {
                    SettingsBValueRow(label: String(localized: .settingsLlmUiEndpoint), value: provider.baseUrl ?? preset?.baseUrl ?? String(localized: .settingsLlmUiOfficialDefault), mono: true)
                }
                SettingsBValueRow(label: String(localized: .settingsLlmUiTestModel), value: provider.defaultModel, mono: true)
                if !serverManaged, let ua = provider.userAgent { SettingsBValueRow(label: "User-Agent", value: ua, mono: true) }
                if !serverManaged, let proto = provider.apiProtocol {
                    SettingsBValueRow(label: String(localized: .settingsLlmUiProtocol), value: SettingsBLLMFormat.protocolLabel(proto))
                }
                if !provider.extraModels.isEmpty {
                    LabeledContent(serverManaged ? String(localized: .settingsLlmCardAvailableModels) : String(localized: .settingsLlmCardCustomModels), value: String(localized: .settingsMcpControlsCountUnit(provider.extraModels.count)))
                }
            }
            if let error { SettingsFormSection { SettingsBNotice(text: error, tone: .danger) } }
        }
        .settingsBFormStyle()
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !serverManaged {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(String(localized: .settingsLlmCardEdit), systemImage: "pencil", action: onEdit)
                            .accessibilityIdentifier("llm-edit-\(provider.id)")
                        Button(String(localized: .settingsLlmCardDelete), systemImage: "trash", role: .destructive) { Task { await onDelete() } }
                            .accessibilityIdentifier("llm-delete-\(provider.id)")
                    } label: { Label(String(localized: .settingsLlmCardActions), systemImage: "ellipsis") }
                    .disabled(busy)
                    .accessibilityIdentifier("llm-provider-actions")
                }
            }
        }
    }

    private var failed: Bool { provider.status == "failed" }
    private var serverManaged: Bool { provider.providerType == "chatgpt" }


}

/// 状态胶囊：圆点 + 文案（已连接 / 测试中 / 待测试 / 连接失败）
struct SettingsBLLMStatusPill: View {
    let status: String

    var body: some View {
        let tone = SettingsBLLMStatus.tone(status)
        HStack(spacing: 5) {
            SettingsBDot(tone: tone, size: 6)
            Text(SettingsBLLMStatus.label(status)).font(.caption.weight(.medium))
        }
        .foregroundStyle(tone == .neutral ? Theme.textMuted : tone.color)

        .accessibilityIdentifier("llm-status")
    }
}
