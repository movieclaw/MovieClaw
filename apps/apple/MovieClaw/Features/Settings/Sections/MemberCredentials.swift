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
                        TextField("用户名", text: $username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused, equals: .username).submitLabel(.next)
                            .onSubmit { focused = .nickname }
                            .accessibilityIdentifier("member-create-username")
                    } footer: { Text("至少 3 个字符，用于登录，创建后不可修改。") }
                    SettingsFormSection {
                        TextField("昵称（选填）", text: $nickname)
                            .focused($focused, equals: .nickname).submitLabel(.done).onSubmit { focused = nil }
                            .accessibilityIdentifier("member-create-nickname")
                    } footer: { Text("留空时使用用户名作为显示名称。") }
                    SettingsFormSection("初始密码") {
                        Text(password).font(.body.monospaced()).textSelection(.enabled)
                        Button("重新生成密码", systemImage: "arrow.clockwise") { password = Self.generatePassword() }
                            .accessibilityIdentifier("member-create-regenerate")
                    }
                    SettingsFormSection {
                        Text("新成员默认可以订阅和浏览共享媒体库，资源搜索默认关闭。创建后可在成员详情调整权限。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let error { SettingsFormSection { Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("member-create-error") } }
                }
            }
            .subsFormStyle()
            .modifier(SubsFittedDetents())
            .scrollDismissesKeyboard(.interactively)
            .disabled(busy)
            .navigationTitle(result == nil ? "添加成员" : "保存登录信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if result == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            if username.isEmpty && nickname.isEmpty { dismiss() } else { discarding = true }
                        }.disabled(busy).accessibilityIdentifier("sheet-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if busy { ProgressView() }
                        else {
                            Button("创建") { Task { await create() } }
                                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                                .accessibilityIdentifier("member-create-submit")
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { confirmingClose = true }.accessibilityIdentifier("password-result-done")
                    }
                }
            }
            .alert("已保存登录信息？", isPresented: $confirmingClose) {
                Button("继续保存", role: .cancel) { }
                Button("我已保存") { dismiss() }
            } message: { Text("关闭后无法再次查看这个密码。未保存时，需要重置密码。") }
            .alert("放弃添加成员？", isPresented: $discarding) {
                Button("继续编辑", role: .cancel) { }
                Button("放弃修改", role: .destructive) { dismiss() }
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
            result = .init(title: "成员已创建", username: member.username, password: password)
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
                .navigationTitle("保存登录信息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { confirmingClose = true }.accessibilityIdentifier("password-result-done")
                    }
                }
                .alert("已保存登录信息？", isPresented: $confirmingClose) {
                    Button("继续保存", role: .cancel) { }
                    Button("我已保存") { dismiss() }
                } message: { Text("关闭后无法再次查看这个密码。未保存时，需要重置密码。") }
        }
        .interactiveDismissDisabled()
    }
}

private struct MemberCredentialFields: View {
    let result: MemberPasswordResult
    var body: some View {
        SettingsFormSection {
            Label(result.title, systemImage: "checkmark.circle").foregroundStyle(Theme.success)
            Text("请先保存账号和密码，再点完成。密码仅在此显示一次。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        SettingsFormSection("用户名") {
            Text(result.username).textSelection(.enabled)
            MemberCopyButton(value: result.username, title: "复制用户名").accessibilityIdentifier("credential-账号")
        }
        SettingsFormSection("密码") {
            Text(result.password).font(.body.monospaced()).textSelection(.enabled)
            MemberCopyButton(value: result.password, title: "复制密码").accessibilityIdentifier("credential-密码")
        }
        SettingsFormSection {
            MemberCopyButton(value: "账号：\(result.username)\n密码：\(result.password)", title: "复制全部登录信息")
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
            Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}
