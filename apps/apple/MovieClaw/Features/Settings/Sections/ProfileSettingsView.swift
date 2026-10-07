import PhotosUI
import SwiftUI

/// 当前账号总览；每项编辑在独立浮层中完成，保存后同步「我的」和头像页签。
struct ProfileSettingsView: View {
    private enum Editor: String, Identifiable {
        case nickname, password
        var id: String { rawValue }
    }
    @Environment(\.api) private var api
    @Environment(AppModel.self) private var model
    @Environment(Feedback.self) private var feedback
    @Environment(Router.self) private var router
    @State private var editor: Editor?
    @State private var savedMessage: String?
    @State private var avatarItem: PhotosPickerItem?
    @State private var pickingAvatar = false
    @State private var avatarBusy = false
    @State private var avatarError: String?
    @State private var clearing = false
    @State private var loggingOut = false

    private var busy: Bool { avatarBusy || clearing || loggingOut }

    var body: some View {
        if let session = model.session {
            Form {
                SettingsFormSection {
                    identity(session)
                        .settingsRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                SettingsFormSection("账号信息") {
                    LabeledContent("用户名", value: session.username)
                    Button { editor = .nickname } label: {
                        row("昵称", value: session.nickname)
                    }
                    .accessibilityIdentifier("profile-nickname-edit")
                }
                SettingsFormSection("安全") {
                    Button { editor = .password } label: { row("修改密码") }
                        .accessibilityIdentifier("profile-password-edit")
                }
                SettingsFormSection {
                    Button { router.present(.accountSwitcher) } label: { row("切换账号") }
                        .accessibilityIdentifier("profile-switch-account")
                } footer: { Text("长按底部头像也能切换账号。") }
                SettingsFormSection {
                    Button("退出登录", role: .destructive) { Task { await logout(session) } }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("logout")
                }
            }
            .settingsBFormStyle()
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if clearing || loggingOut { ProgressView() } else {
                        Menu {
                            Button("清空观看记录", systemImage: "clock.arrow.circlepath", role: .destructive) {
                                Task { await clearHistory() }
                            }
                            .accessibilityIdentifier("profile-clear-history")
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("个人信息操作")
                        .accessibilityIdentifier("profile-actions")
                        .disabled(busy)
                    }
                }
            }
            .sheet(item: $editor, onDismiss: {
                if let savedMessage { feedback.success(savedMessage); self.savedMessage = nil }
            }) { editor in
                switch editor {
                case .nickname:
                    ProfileNicknameSheet(nickname: session.nickname) { updated in
                        model.update(session: updated)
                        savedMessage = "昵称已保存"
                    }
                    .sheetFeedback()
                case .password:
                    ProfilePasswordSheet { updated, revokedPaired in
                        model.update(session: updated)
                        savedMessage = revokedPaired
                            ? "密码已修改，其他登录设备与配对设备已下线。本机保持登录。"
                            : "密码已修改，其他密码登录设备已下线。本机保持登录。"
                    }
                    .sheetFeedback()
                }
            }
            .photosPicker(isPresented: $pickingAvatar, selection: $avatarItem, matching: .images)
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                avatarItem = nil
                Task { await uploadAvatar(item) }
            }
        } else { ProgressView() }
    }

    private func identity(_ session: API.SessionView) -> some View {
        VStack(spacing: 10) {
            Button { pickingAvatar = true } label: {
                VStack(spacing: 10) {
                    ZStack {
                        AvatarBadge(session: session, size: 88)
                        if avatarBusy {
                            Circle().fill(.black.opacity(0.5))
                            ProgressView().tint(.white)
                        }
                    }
                    .frame(width: 88, height: 88)
                    Text(avatarBusy ? "正在上传…" : "更换头像").font(.subheadline)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel(avatarBusy ? "正在上传头像" : "更换头像")
            .accessibilityIdentifier("profile-avatar")
            Text(session.nickname.isEmpty ? session.username : session.nickname)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("profile-nickname-display")
            Text(session.role == "member" ? "成员" : "超级管理员")
                .font(.subheadline).foregroundStyle(.secondary)
            if let avatarError {
                Text(avatarError).font(.footnote).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("profile-avatar-error")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func row(_ title: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            LabeledContent(title) {
                if let value { Text(value).foregroundStyle(.secondary) }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(Theme.text)
        .contentShape(.rect)
    }

    private func logout(_ session: API.SessionView) async {
        guard await feedback.confirm("退出当前账号？",
            message: "将退出「\(session.nickname)」在本机的登录，其他已登录账号会保留。",
            confirmTitle: "退出登录", destructive: true) else { return }
        loggingOut = true
        await model.logout()
        loggingOut = false
    }

    /// 选图后：压到 512px JPEG 再上传（头像不需要大图），成功即同步全局会话
    private func uploadAvatar(_ item: PhotosPickerItem) async {
        avatarBusy = true
        avatarError = nil
        defer { avatarBusy = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                avatarError = "读取图片失败"
                return
            }
            guard let jpeg = APIClient.compressedJPEG(data, maxEdge: 512) else {
                avatarError = "图片解码失败，请换一张试试"
                return
            }
            let session = try await api.upload(
                "/auth/avatar",
                file: (name: "file", filename: "avatar.jpg", mimeType: "image/jpeg", data: jpeg),
                as: API.SessionView.self
            )
            model.update(session: session)
        } catch is CancellationError {
        } catch {
            avatarError = error.localizedDescription.isEmpty ? "上传失败，请重试" : error.localizedDescription
        }
    }

    /// 只删当前登录身份自己的记录；成功提示用后端返回的中文 message（同 Web）
    private func clearHistory() async {
        let ok = await feedback.confirm(
            "清空全部观看记录？",
            message: "所有作品的续播进度、已看标记和播放次数都会清除，首页「最近观看」与播放器的「继续观看」随即清空，无法恢复。只影响你自己的记录；应用更新前的自动备份仍包含历史记录。",
            confirmTitle: "清空",
            destructive: true
        )
        guard ok else { return }
        clearing = true
        defer { clearing = false }
        do {
            let envelope: APIEnvelope<API.PlaybackHistoryClearView> = try await api.raw(
                "DELETE", "/playback/history", query: [URLQueryItem(name: "scope", value: "all")]
            )
            feedback.success(envelope.message ?? "观看记录已清空")
        } catch {
            feedback.error(error)
        }
    }
}
