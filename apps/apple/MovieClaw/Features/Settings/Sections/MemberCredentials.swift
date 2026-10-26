import SwiftUI

struct MemberPasswordResult: Identifiable {
    let id = UUID()
    let title: String
    let username: String
    let password: String
}

struct CreateMemberSheet: View {
    let onCreated: (API.MemberView) -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var nickname = ""
    @State private var password = Self.generatePassword()
    @State private var result: MemberPasswordResult?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingClose = false
    @State private var discarding = false
    @FocusState private var focused: Field?
    private enum Field { case username, nickname }

    var body: some View {
        NavigationStack {
            Form {
                if let result { MemberCredentialFields(result: result) }
                else {
                    SettingsFormSection {
                        TextField(String(localized: .settingsMembersCredentialsUsername), text: $username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused, equals: .username).submitLabel(.next)
                            .onSubmit { focused = .nickname }
                            .accessibilityIdentifier("member-create-username")
                    } footer: { Text(String(localized: .settingsMemberNewUsernameHint)) }
                    SettingsFormSection {
                        TextField(String(localized: .settingsMemberNewNickname), text: $nickname)
                            .focused($focused, equals: .nickname).submitLabel(.done).onSubmit { focused = nil }
                            .accessibilityIdentifier("member-create-nickname")
                    } footer: { Text(String(localized: .settingsMemberNewNicknameHint)) }
                    SettingsFormSection(String(localized: .settingsMembersCredentialsInitialPassword)) {
                        Text(password).font(.body.monospaced()).textSelection(.enabled)
                        Button(String(localized: .settingsMembersCredentialsRegenerate), systemImage: "arrow.clockwise") { password = Self.generatePassword() }
                            .accessibilityIdentifier("member-create-regenerate")
                    }
                    SettingsFormSection {
                        Text(String(localized: .settingsMemberNewDefaultsHint))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let error { SettingsFormSection { Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("member-create-error") } }
                }
            }
            .subsFormStyle()
            .modifier(SubsFittedDetents())
            .scrollDismissesKeyboard(.interactively)
            .disabled(busy)
            .navigationTitle(result == nil ? String(localized: .settingsMembersUiAdd) : String(localized: .settingsMemberNewSaveCredentials))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if result == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: .commonCancel)) {
                            if username.isEmpty && nickname.isEmpty { dismiss() } else { discarding = true }
                        }.disabled(busy).accessibilityIdentifier("sheet-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if busy { ProgressView() }
                        else {
                            Button(String(localized: .settingsFormCreate)) { Task { await create() } }
                                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                                .accessibilityIdentifier("member-create-submit")
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: .settingsDevicesUiDone)) { confirmingClose = true }.accessibilityIdentifier("password-result-done")
                    }
                }
            }
            .alert(String(localized: .settingsMemberNewSavedTitle), isPresented: $confirmingClose) {
                Button(String(localized: .settingsFormKeepSaving), role: .cancel) { }
                Button(String(localized: .settingsDevicesManualSaved)) { dismiss() }
            } message: { Text(String(localized: .settingsMemberNewSavedHint)) }
            .alert(String(localized: .settingsMemberNewDiscard), isPresented: $discarding) {
                Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
                Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
            }
        }
        .interactiveDismissDisabled(busy || result != nil || !username.isEmpty || !nickname.isEmpty)
    }

    private static func generatePassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzACDEFGHJKLMNPQRSTUVWXYZ2345679")
        return String((0..<14).map { _ in alphabet.randomElement()! })
    }

    private func create() async {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, name.count >= 3 else { return }
        focused = nil
        busy = true
        error = nil
        defer { busy = false }
        do {
            let member = try await api.membersCreate(body: .init(username: name, password: password,
                                                                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines)))
            result = .init(title: String(localized: .settingsMembersCredentialsCreated), username: member.username, password: password)
            onCreated(member)
        } catch { self.error = error.localizedDescription }
    }
}

struct MemberPasswordSheet: View {
    let result: MemberPasswordResult
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClose = false

    var body: some View {
        NavigationStack {
            Form { MemberCredentialFields(result: result) }
                .subsFormStyle()
                .modifier(SubsFittedDetents())
                .navigationTitle(String(localized: .settingsMemberNewSaveCredentials))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: .settingsDevicesUiDone)) { confirmingClose = true }.accessibilityIdentifier("password-result-done")
                    }
                }
                .alert(String(localized: .settingsMemberNewSavedTitle), isPresented: $confirmingClose) {
                    Button(String(localized: .settingsFormKeepSaving), role: .cancel) { }
                    Button(String(localized: .settingsDevicesManualSaved)) { dismiss() }
                } message: { Text(String(localized: .settingsMemberNewSavedHint)) }
        }
        .interactiveDismissDisabled()
    }
}

private struct MemberCredentialFields: View {
    let result: MemberPasswordResult
    var body: some View {
        SettingsFormSection {
            Label(result.title, systemImage: "checkmark.circle").foregroundStyle(Theme.success)
            Text(String(localized: .settingsMemberNewSaveFirst))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        SettingsFormSection(String(localized: .settingsMembersCredentialsUsername)) {
            Text(result.username).textSelection(.enabled)
            MemberCopyButton(value: result.username, title: String(localized: .settingsMemberNewCopyUsername)).accessibilityIdentifier("credential-账号") // i18n-ignore: UI test identifier
        }
        SettingsFormSection(String(localized: .authLoginPassword)) {
            Text(result.password).font(.body.monospaced()).textSelection(.enabled)
            MemberCopyButton(value: result.password, title: String(localized: .settingsMemberNewCopyPassword)).accessibilityIdentifier("credential-密码") // i18n-ignore: UI test identifier
        }
        SettingsFormSection {
            MemberCopyButton(value: String(localized: .settingsMembersCredentialsAllDetails(result.username, result.password)), title: String(localized: .settingsMembersCredentialsCopyAll))
                .accessibilityIdentifier("credential-copy-all")
        }
    }
}

private struct MemberCopyButton: View {
    let value: String
    let title: String
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
        } label: {
            Label(copied ? String(localized: .commonCopied) : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}
