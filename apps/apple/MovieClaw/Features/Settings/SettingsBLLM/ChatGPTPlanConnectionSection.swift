import SwiftUI

/// 手机直接完成官方浏览器授权，令牌仍由当前服务器保存。
struct ChatGPTPlanConnectionSection: View {
    var provider: API.LlmProviderView?
    var onConnected: () -> Void
    var signIn: ChatGPTSignIn
    @Environment(\.api) private var api
    @State private var copied = false
    @State private var showPlanConfirmation = false

    private var command: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MovieClaw"
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "mclaw llm chatgpt login --app-name " + quoted
            + (provider.map { " --provider \($0.id)" } ?? "")
    }

    var body: some View {
        SettingsFormSection {
            Text("ChatGPT 订阅接入目前为预览功能。使用 ChatGPT Plus / Pro 订阅，无需 API Key。额度与其他使用该订阅的 App 共享。")
                .font(.subheadline).foregroundStyle(Theme.textMuted)
            if let email = (signIn.connected ?? provider)?.chatgptAccount, !email.isEmpty {
                LabeledContent("已连接账号", value: email)
            }
            Button {
                let existing = signIn.connected ?? provider
                signIn.begin(api: api, providerID: existing?.id) {
                    onConnected()
                    if existing == nil { showPlanConfirmation = true }
                }
            } label: {
                HStack {
                    if signIn.busy { ProgressView().tint(Color(uiColor: .systemBackground)) }
                    Text(signIn.exchanging ? "正在连接服务器…" : "Continue with ChatGPT")
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .disabled(signIn.busy)
            .accessibilityIdentifier("chatgpt-sign-in")
            Text("在官方登录页登录并允许使用订阅，即可自动连接到当前服务器。")
                .font(.caption).foregroundStyle(Theme.textFaint)
            if let error = signIn.error {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("chatgpt-sign-in-error")
            }
            if signIn.connected != nil {
                Text("已连接，服务器正在验证模型。可返回列表查看结果。")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                    .accessibilityIdentifier("chatgpt-sign-in-success")
            }
            Link("管理 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
            DisclosureGroup("也可通过电脑连接") {
                Text(command).font(.footnote.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("chatgpt-login-command")
                Button(copied ? "已复制" : "复制连接命令", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = command
                    copied = true
                }
                .accessibilityIdentifier("chatgpt-copy-command")
            }
        } header: {
            Text("连接 ChatGPT 订阅")
        }
        .alert("正在使用 ChatGPT 订阅", isPresented: $showPlanConfirmation) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("这个接入的模型调用使用你的 ChatGPT 订阅额度，可在 ChatGPT 用量设置中管理。")
        }
    }
}
