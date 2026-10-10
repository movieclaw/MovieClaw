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
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accentSoft, in: .rect(cornerRadius: 9))
                Text("使用 AI 助手前").font(.headline).foregroundStyle(.white)
            }
            Text(destinationText)
                .fixedSize(horizontal: false, vertical: true)
            Text("MovieClaw 的开发者不会收到这些内容。服务商如何处理数据以其隐私政策为准；服务器管理员可以在「设置 → 模型接入」更换或移除服务商。")
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("agent-consent-cancel")
                Button("同意并发送") {
                    AgentAIConsent.grant()
                    dismiss()
                    onAgree()
                }
                .discoverProminentButton()
                .accessibilityIdentifier("agent-consent-agree")
            }
        }
        .font(.subheadline)
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(contentHeight)])
    }

    private var destinationText: String {
        let current: String = providers.isEmpty ? "" : "（当前：" + providers.joined(separator: "、") + "）"
        return "你发出的消息和图片，以及助手为了回答而查询的媒体库信息，会由你的 MovieClaw 服务器发送给服务器管理员接入的 AI 模型服务商处理" + current + "。"
    }
}
