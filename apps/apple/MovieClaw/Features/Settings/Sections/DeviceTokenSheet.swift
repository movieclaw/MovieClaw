import SwiftUI

/// 创建与一次性凭据展示留在同一任务内，避免离开设备列表时无意丢失令牌。
struct DeviceTokenSheet: View {
    let onCreated: () -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scope = "full"
    @State private var busy = false
    @State private var error: String?
    @State private var created: API.ApiTokenCreatedView?
    @State private var externalURL = ""
    @State private var confirmingClose = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let created { credential(created) }
                else {
                    SettingsFormSection {
                        TextField("名称，例如 NAS 定时任务", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { nameFocused = false }
                            .onChange(of: name) { _, value in
                                name = String(value.prefix(64))
                                error = nil
                            }
                            .accessibilityIdentifier("token-name")
                    } header: { Text("令牌名称") }
                    footer: { Text("用于识别使用这枚令牌的程序或设备。") }
                    SettingsFormSection {
                        Picker("访问权限", selection: $scope) {
                            Text("完全权限").tag("full")
                            Text("仅限转码").tag("transcode")
                        }
                        .accessibilityIdentifier("token-scope")
                    } footer: {
                        Text(scope == "transcode" ? DeviceText.transcodeManualGrant.body : DeviceText.manualGrant.body)
                    }
                    SettingsFormSection {
                        Text("用于定时任务、CI 或无界面的转码器。能扫码的设备请使用“批准新设备登录”。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let error { SettingsFormSection { SettingsNotice(text: error) } }
                }
            }
            .appBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(created == nil ? "创建访问令牌" : "保存访问令牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                            .disabled(busy).accessibilityIdentifier("token-create-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if busy { ProgressView() }
                        else {
                            Button("创建") { Task { await create() } }
                                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("token-create-submit")
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { confirmingClose = true }
                            .accessibilityIdentifier("token-created-dismiss")
                    }
                }
            }
            .alert("已保存这枚令牌？", isPresented: $confirmingClose) {
                Button("继续保存", role: .cancel) { }
                Button("我已保存") { dismiss() }
            } message: { Text("关闭后无法再次查看令牌明文。未保存的令牌只能注销后重建。") }
        }
        .interactiveDismissDisabled(busy || created != nil || !name.isEmpty)
        .task {
            if let config = try? await api.appShow() { externalURL = config.externalUrl }
        }
    }

    @ViewBuilder
    private func credential(_ token: API.ApiTokenCreatedView) -> some View {
        let configured = !externalURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let address = (configured ? externalURL : api.server.origin.absoluteString)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcode = token.scope == "transcode"
        let snippet = transcode
            ? "--nas-url \(address) --token \(token.token)"
            : "MOVIECLAW_SERVER=\(address)\nMOVIECLAW_TOKEN=\(token.token)"
        SettingsFormSection {
            Label("已创建「\(token.name)」", systemImage: "checkmark.circle")
                .accessibilityIdentifier("token-created-card")
            Text("令牌只显示这一次，请先复制并保存，再点完成。")
                .foregroundStyle(.secondary)
        }
        SettingsFormSection {
            Text(token.token)
                .font(.footnote.monospaced()).textSelection(.enabled)
            DeviceCredentialCopyButton(text: token.token, title: "复制令牌")
                .accessibilityIdentifier("token-copy")
        } header: { Text("访问令牌") }
        SettingsFormSection {
            Text(snippet).font(.footnote.monospaced()).textSelection(.enabled)
            DeviceCredentialCopyButton(text: snippet, title: transcode ? "复制启动参数" : "复制环境变量")
        } header: { Text(transcode ? "转码器启动参数" : "环境变量") }
        footer: {
            if transcode { Text("接在 movieclaw-transcoder --headless 后使用。") }
        }
        if !configured {
            SettingsFormSection {
                Label("请确认目标设备能访问这个服务器地址。可在“设置 → 网络”配置对外访问地址。",
                      systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty else { return }
        busy = true
        error = nil
        nameFocused = false
        defer { busy = false }
        do {
            created = try await api.authTokensCreate(body: .init(name: trimmed, scope: scope))
            onCreated()
        } catch { self.error = error.localizedDescription }
    }
}

/// 复制结果就地显示，避免浮动提示遮住上方的完成操作。
private struct DeviceCredentialCopyButton: View {
    let text: String
    let title: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}
