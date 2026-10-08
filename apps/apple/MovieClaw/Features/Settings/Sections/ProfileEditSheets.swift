import SwiftUI

/// 字符数与服务端的 Unicode 字符限制一致；密码保留原始空白。
enum ProfileSettingsValidation {
    static func nickname(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "昵称不能为空" }
        return text.unicodeScalars.count > 32 ? "昵称最多 32 个字符" : nil
    }
}

struct ProfilePasswordDraft: Equatable {
    var current = ""
    var new = ""
    var confirmation = ""
    var signOutPaired = false

    var changed: Bool { self != Self() }
    var validation: String? {
        if current.unicodeScalars.count > 128 { return "当前密码最多 128 个字符" }
        if !new.isEmpty, !(8...128).contains(new.unicodeScalars.count) { return "新密码需为 8–128 个字符" }
        if !confirmation.isEmpty, confirmation != new { return "两次输入的新密码不一致" }
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
        SubsSheetScaffold(title: "修改昵称", onClose: cancel,
            confirm: SubsSheetConfirm(title: "保存", enabled: changed && validation == nil,
                                      busy: busy, identifier: "profile-nickname-save", action: save)) {
            SettingsFormSection {
                TextField("昵称", text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done).onSubmit(save)
                    .accessibilityIdentifier("profile-nickname-field")
            } footer: { Text("昵称用于展示，最多 32 个字符。登录用户名保持不变。") }
            if let message = error ?? (changed ? validation : nil) {
                SettingsFormSection { Text(message).foregroundStyle(Theme.danger).accessibilityIdentifier("profile-nickname-error") }
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || changed)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { dismiss() }
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
        SubsSheetScaffold(title: "修改密码", onClose: cancel,
            confirm: SubsSheetConfirm(title: "保存", enabled: draft.valid, busy: busy,
                                      identifier: "profile-change-password", action: save)) {
            SettingsFormSection {
                LabeledContent("当前密码") {
                    SecureField("输入当前密码", text: $draft.current)
                        .textContentType(.password)
                        .accessibilityIdentifier("profile-old-password")
                }
                LabeledContent("新密码") {
                    SecureField("8–128 个字符", text: $draft.new)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("profile-new-password")
                }
                LabeledContent("确认密码") {
                    SecureField("再次输入新密码", text: $draft.confirmation)
                        .textContentType(.newPassword)
                        .submitLabel(.done).onSubmit(save)
                        .accessibilityIdentifier("profile-confirm-password")
                }
            } footer: {
                Text("修改成功后，其他使用密码登录的设备会下线，本机保持登录。")
            }
            if pairedCount != 0 {
                SettingsFormSection {
                    Toggle("同时注销配对设备", isOn: $draft.signOutPaired)
                        .accessibilityIdentifier("profile-sign-out-paired")
                } footer: {
                    Text("\(pairedCount.map { "当前有 \($0) 台。" } ?? "")包括命令行、转码器和手工令牌。默认保留这些设备的连接。")
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
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { dismiss() }
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
