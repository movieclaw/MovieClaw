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
                        TextField(String(localized: .settingsTokenSheetNamePlaceholder), text: $name)
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
                    } header: { Text(String(localized: .settingsTokenSheetName)) }
                    footer: { Text(String(localized: .settingsTokenSheetNameHint)) }
                    SettingsFormSection {
                        Picker(String(localized: .settingsTokenSheetAccess), selection: $scope) {
                            Text(String(localized: .settingsDevicesManualFull)).tag("full")
                            Text(String(localized: .settingsDevicesManualTranscode)).tag("transcode")
                        }
                        .accessibilityIdentifier("token-scope")
                    } footer: {
                        Text(scope == "transcode" ? DeviceText.transcodeManualGrant.body : DeviceText.manualGrant.body)
                    }
                    SettingsFormSection {
                        Text(String(localized: .settingsTokenSheetUsageHint))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let error { SettingsFormSection { SettingsNotice(text: error) } }
                }
            }
            .appBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(created == nil ? String(localized: .settingsTokenSheetCreateTitle) : String(localized: .settingsTokenSheetSaveTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: .commonCancel)) { dismiss() }
                            .disabled(busy).accessibilityIdentifier("token-create-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if busy { ProgressView() }
                        else {
                            Button(String(localized: .settingsFormCreate)) { Task { await create() } }
                                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("token-create-submit")
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: .commonDone)) { confirmingClose = true }
                            .accessibilityIdentifier("token-created-dismiss")
                    }
                }
            }
            .alert(String(localized: .settingsTokenSheetSavedTitle), isPresented: $confirmingClose) {
                Button(String(localized: .settingsFormKeepSaving), role: .cancel) { }
                Button(String(localized: .settingsDevicesManualSaved)) { dismiss() }
            } message: { Text(String(localized: .settingsTokenSheetSavedHint)) }
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
            Label(String(localized: .settingsDevicesManualCreated(token.name)), systemImage: "checkmark.circle")
                .accessibilityIdentifier("token-created-card")
            Text(String(localized: .settingsTokenSheetCopyFirst))
                .foregroundStyle(.secondary)
        }
        SettingsFormSection {
            Text(token.token)
                .font(.footnote.monospaced()).textSelection(.enabled)
            DeviceCredentialCopyButton(text: token.token, title: String(localized: .settingsMcpControlsCopyToken))
                .accessibilityIdentifier("token-copy")
        } header: { Text(String(localized: .settingsMcpControlsAccessToken)) }
        SettingsFormSection {
            Text(snippet).font(.footnote.monospaced()).textSelection(.enabled)
            DeviceCredentialCopyButton(text: snippet, title: transcode ? String(localized: .settingsTokenSheetCopyArgs) : String(localized: .settingsTokenSheetCopyEnv))
        } header: { Text(transcode ? String(localized: .settingsTokenSheetArgs) : String(localized: .settingsNetworkProxyEnv)) }
        footer: {
            if transcode { Text(String(localized: .settingsTokenSheetArgsHint)) }
        }
        if !configured {
            SettingsFormSection {
                Label(String(localized: .settingsTokenSheetReachHint),
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
            Label(copied ? String(localized: .commonCopied) : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}
