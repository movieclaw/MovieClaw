import SwiftUI

/// 第一次把消息发给 AI 助手前的说明与同意（App Store 审核条款 5.1.2(i)：个人数据交给第三方 AI 前，
/// 要说清楚发到哪里并取得用户同意）。同意记在本机，之后不再询问；取消则这条消息不发，草稿保留。
enum AgentAIConsent {
    private static let key = "mc.agentAIConsent.v1"

    static var granted: Bool { UserDefaults.standard.bool(forKey: key) }

    static func grant() { UserDefaults.standard.set(true, forKey: key) }

    /// 说明里点名的服务商：取模型清单里的实例名，去重保序
    static func providers(_ options: [API.LlmModelOptionView]) -> [String] {
        var seen = Set<String>()
        return options.map(\.providerName).filter { seen.insert($0).inserted }
    }
}

/// 发送前的说明弹层：数据去向、开发者收不到、在哪里更换服务商
struct AgentAIConsentSheet: View {
    let providers: [String]
    let onAgree: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32)
                            .background(Theme.accentSoft, in: .rect(cornerRadius: 9))
                        Text(String(localized: .agentConsentTitle)).font(.headline).foregroundStyle(.white)
                    }
                    Text(destinationText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(localized: .agentConsentPrivacy))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("agent-consent-content")
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        agreeButton
                        cancelButton
                    }
                } else {
                    HStack(spacing: 12) {
                        cancelButton
                        agreeButton
                    }
                }
            }
            .controlSize(.large)
            .font(.body.weight(.medium))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .adaptiveDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var agreeButton: some View {
        Button {
            AgentAIConsent.grant()
            dismiss()
            onAgree()
        } label: {
            Text(String(localized: .agentConsentAgree))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .discoverProminentButton()
        .accessibilityIdentifier("agent-consent-agree")
    }

    private var cancelButton: some View {
        Button(role: .cancel) { dismiss() } label: {
            Text(String(localized: .commonCancel))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("agent-consent-cancel")
    }

    private var destinationText: String {
        providers.isEmpty ? String(localized: .agentConsentDestination)
            : String(localized: .agentConsentDestinationProviders(AppFormatting.list(providers)))
    }
}
