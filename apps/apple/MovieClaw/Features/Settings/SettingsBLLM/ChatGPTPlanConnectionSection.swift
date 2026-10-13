import SwiftUI

/// 手机继续连接自己的服务器；订阅 OAuth 由电脑 loopback 助手完成。
struct ChatGPTPlanConnectionSection: View {
    var provider: API.LlmProviderView?
    @State private var copied = false

    private var command: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MovieClaw"
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "mclaw llm chatgpt login --app-name " + quoted
            + (provider.map { " --provider \($0.id)" } ?? "")
    }

    var body: some View {
        SettingsFormSection {
            Text("使用 ChatGPT Plus / Pro 订阅，无需 API Key。额度与其他使用该订阅的 App 共享。")
                .font(.subheadline).foregroundStyle(Theme.textMuted)
            if let email = provider?.chatgptAccount, !email.isEmpty {
                LabeledContent("已连接账号", value: email)
            }
            Text("在运行浏览器的电脑上先用 mclaw login 配对这台服务器，再执行下面的连接命令。")
                .font(.subheadline).foregroundStyle(Theme.textMuted)
            Text(command).font(.footnote.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("chatgpt-login-command")
            Button(copied ? "已复制" : "复制连接命令", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = command
                copied = true
            }
            .accessibilityIdentifier("chatgpt-copy-command")
            Text("在官方页面选择 Continue with ChatGPT 并允许使用订阅。授权会自动传回服务器并加密保存；完成后回到这里刷新接入。")
                .font(.caption).foregroundStyle(Theme.textFaint)
            Link("管理 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
        } header: {
            Text("连接 ChatGPT 订阅")
        }
    }
}
