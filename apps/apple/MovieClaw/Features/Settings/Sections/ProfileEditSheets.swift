import SwiftUI

/// 字符数与服务端的 Unicode 字符限制一致；密码保留原始空白。
enum ProfileSettingsValidation {
    static func nickname(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return String(localized: .settingsProfileNicknameEmpty) }
        return text.unicodeScalars.count > 32 ? String(localized: .settingsProfileEditNicknameTooLong) : nil
    }
}

struct ProfilePasswordDraft: Equatable {
    var current = ""
    var new = ""
    var confirmation = ""
    var signOutPaired = false

    var changed: Bool { self != Self() }
    var validation: String? {
        if current.unicodeScalars.count > 128 { return String(localized: .settingsProfileEditCurrentTooLong) }
        if !new.isEmpty, !(8...128).contains(new.unicodeScalars.count) { return String(localized: .settingsProfileEditNewLength) }
        if !confirmation.isEmpty, confirmation != new { return String(localized: .settingsProfilePasswordMismatch) }
        return nil
    }
    var valid: Bool { !current.isEmpty && !new.isEmpty && !confirmation.isEmpty && validation == nil }
}

struct ProfileNicknameSheet: View {
    let nickname: String
    let onSaved: (API.SessionView) -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false

    init(nickname: String, onSaved: @escaping (API.SessionView) -> Void) {
        self.nickname = nickname
        self.onSaved = onSaved
        _draft = State(initialValue: nickname)
    }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmed != nickname }
    private var validation: String? { ProfileSettingsValidation.nickname(draft) }

    var body: some View {
        SubsSheetScaffold(title: String(localized: .settingsProfileEditNicknameTitle), onClose: cancel,
            confirm: SubsSheetConfirm(title: String(localized: .commonSave), enabled: changed && validation == nil,
                                      busy: busy, identifier: "profile-nickname-save", action: save)) {
            SettingsFormSection {
                TextField(String(localized: .settingsProfileNickname), text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done).onSubmit(save)
                    .accessibilityIdentifier("profile-nickname-field")
            } footer: { Text(String(localized: .settingsProfileEditNicknameHint)) }
            if let message = error ?? (changed ? validation : nil) {
                SettingsFormSection { Text(message).foregroundStyle(Theme.danger).accessibilityIdentifier("profile-nickname-error") }
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || changed)
        .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
        }
    }

    private func cancel() {
        if changed { discarding = true } else { dismiss() }
    }
    private func save() {
        guard !busy, changed, validation == nil else { return }
        busy = true
        error = nil
        Task {
            do {
                onSaved(try await api.authProfileUpdate(body: .init(nickname: trimmed)))
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct ProfilePasswordSheet: View {
    let onSaved: (API.SessionView, Bool) -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProfilePasswordDraft()
    @State private var pairedCount: Int?
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false

    var body: some View {
        SubsSheetScaffold(title: String(localized: .settingsProfileChangePassword), onClose: cancel,
            confirm: SubsSheetConfirm(title: String(localized: .commonSave), enabled: draft.valid, busy: busy,
                                      identifier: "profile-change-password", action: save)) {
            SettingsFormSection {
                LabeledContent(String(localized: .settingsProfileCurrentPassword)) {
                    SecureField(String(localized: .settingsProfileEditCurrent), text: $draft.current)
                        .textContentType(.password)
                        .accessibilityIdentifier("profile-old-password")
                }
                LabeledContent(String(localized: .settingsProfileNewPassword)) {
                    SecureField(String(localized: .settingsProfileEditNewPlaceholder), text: $draft.new)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("profile-new-password")
                }
                LabeledContent(String(localized: .setupAccountConfirmPassword)) {
                    SecureField(String(localized: .settingsProfileEditConfirm), text: $draft.confirmation)
                        .textContentType(.newPassword)
                        .submitLabel(.done).onSubmit(save)
                        .accessibilityIdentifier("profile-confirm-password")
                }
            } footer: {
                Text(String(localized: .settingsProfileEditPasswordHint))
            }
            if pairedCount != 0 {
                SettingsFormSection {
                    Toggle(String(localized: .settingsProfileEditSignOutPaired), isOn: $draft.signOutPaired)
                        .accessibilityIdentifier("profile-sign-out-paired")
                } footer: {
                    Text((pairedCount.map { String(localized: .settingsProfileEditPairedCount($0)) } ?? "") + String(localized: .settingsProfileEditPairedHint))
                }
            }
            if let message = error ?? draft.validation {
                SettingsFormSection { Text(message).foregroundStyle(Theme.danger).accessibilityIdentifier("profile-password-error") }
            }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .disabled(busy)
        .interactiveDismissDisabled(busy || draft.changed)
        .task {
            if let devices = try? await api.authDevicesList() { pairedCount = devices.filter { $0.family == "paired" }.count }
        }
        .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
        }
    }

    private func cancel() {
        if draft.changed { discarding = true } else { dismiss() }
    }
    private func save() {
        guard !busy, draft.valid else { return }
        busy = true
        error = nil
        Task {
            do {
                let session = try await api.authPasswordUpdate(body: .init(
                    oldPassword: draft.current, newPassword: draft.new, signOutPaired: draft.signOutPaired))
                onSaved(session, draft.signOutPaired)
                draft = ProfilePasswordDraft()
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
