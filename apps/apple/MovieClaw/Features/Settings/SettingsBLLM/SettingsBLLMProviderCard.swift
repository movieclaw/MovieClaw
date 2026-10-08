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
                LabeledContent("连接状态") { SettingsBLLMStatusPill(status: provider.status) }
                LabeledContent("供应商", value: preset?.displayName ?? provider.providerType)
                LabeledContent("上次检查", value: provider.lastCheckedAt.map { Formatters.relative($0) } ?? "尚未检查")
                if failed, let reason = provider.lastError {
                    Text(reason).font(.footnote).foregroundStyle(Theme.danger)
                }
                SettingsBAsyncButton(action: onReverify) {
                    Label("重新测试连接", systemImage: "arrow.clockwise")
                }
                .disabled(busy || SettingsBLLMStatus.inProgress(provider.status))
                .accessibilityIdentifier("llm-reverify-\(provider.id)")
            }
            SettingsFormSection("连接信息") {
                SettingsBValueRow(label: "API 端点", value: provider.baseUrl ?? preset?.baseUrl ?? "官方默认", mono: true)
                SettingsBValueRow(label: "连接测试模型", value: provider.defaultModel, mono: true)
                if let ua = provider.userAgent { SettingsBValueRow(label: "User-Agent", value: ua, mono: true) }
                if !provider.extraModels.isEmpty {
                    LabeledContent("自定义模型", value: "\(provider.extraModels.count) 个")
                }
            }
            if let error { SettingsFormSection { SettingsBNotice(text: error, tone: .danger) } }
        }
        .settingsBFormStyle()
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("编辑配置", systemImage: "pencil", action: onEdit)
                        .accessibilityIdentifier("llm-edit-\(provider.id)")
                    Button("删除供应商", systemImage: "trash", role: .destructive) { Task { await onDelete() } }
                        .accessibilityIdentifier("llm-delete-\(provider.id)")
                } label: { Label("供应商操作", systemImage: "ellipsis") }
                .disabled(busy)
                .accessibilityIdentifier("llm-provider-actions")
            }
        }
    }

    private var failed: Bool { provider.status == "failed" }


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
