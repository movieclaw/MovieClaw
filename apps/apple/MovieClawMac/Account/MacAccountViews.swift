import SwiftUI

/// 侧边栏最底下的当前账号：头像 + 昵称 + 服务器。点开一块玻璃浮层（`MacAccountPanel`）：
/// 切换到本机登录过的其他账号（跨服务器，换一枚令牌、不联网、不用密码，主界面整棵重建）、添加账号、关于、退出登录。
/// Mac 上与账号有关的操作都在这里与菜单栏的「账号」菜单里（docs/design/macos-app.md §5）
struct MacAccountButton: View {
    @Environment(AppModel.self) private var model
    @State private var showsPanel = false
    @State private var hovering = false

    var body: some View {
        Button { showsPanel.toggle() } label: {
            HStack(spacing: 10) {
                MacAvatar(url: MacAccounts.avatarURL(model.session?.avatarUrl, username: model.session?.username, server: model.server, size: 30),
                          name: model.session?.nickname ?? "", size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.session?.nickname ?? "账号")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(model.server?.hostLabel ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(.white.opacity(hovering || showsPanel ? 0.08 : 0), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $showsPanel, arrowEdge: .top) {
            MacAccountPanel(close: { showsPanel = false })
        }
        .help("切换账号")
        .accessibilityLabel("当前账号 \(model.session?.nickname ?? "")，点按切换")
        .accessibilityIdentifier("mac-account-button")
    }
}

/// 账号浮层：当前账号（大头像、昵称、身份与服务器）→ 其他账号（点一下就切过去）→ 添加账号 / 关于 / 退出登录
struct MacAccountPanel: View {
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    @State private var addingAccount = false
    @State private var confirmingLogout = false
    @State private var switching: String?

    private var others: [SavedAccount] {
        MacAccounts.all(model).filter { $0.id != MacAccounts.currentID(model) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            current
                .padding(16)
            if !others.isEmpty {
                Divider()
                Text("切换到")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                VStack(spacing: 2) {
                    ForEach(others) { saved in
                        MacAccountRow(saved: saved, busy: switching == saved.id) {
                            Task { await pick(saved) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            VStack(spacing: 2) {
                MacPanelAction(title: "添加账号…", symbol: "person.badge.plus") { addingAccount = true }
                    .accessibilityIdentifier("mac-account-add")
                MacPanelAction(title: "关于 MovieClaw", symbol: "info.circle") {
                    close()
                    openWindow(id: "about")
                }
                MacPanelAction(title: "退出登录…", symbol: "rectangle.portrait.and.arrow.right", destructive: true) {
                    confirmingLogout = true
                }
                .accessibilityIdentifier("mac-account-logout")
            }
            .padding(6)
        }
        .frame(width: 300)
        .sheet(isPresented: $addingAccount) {
            MacAddAccountView()
        }
        .alert("退出登录？", isPresented: $confirmingLogout) {
            Button("退出", role: .destructive) {
                close()
                Task { await model.logout() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(model.session?.nickname ?? "")」在这台 Mac 上的登录会在服务器上一并注销。同一台服务器上还有别的账号时会自动切过去。")
        }
        .accessibilityIdentifier("mac-account-panel")
    }

    private var current: some View {
        HStack(spacing: 12) {
            MacAvatar(url: MacAccounts.avatarURL(model.session?.avatarUrl, username: model.session?.username, server: model.server, size: 52),
                      name: model.session?.nickname ?? "", size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.session?.nickname ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text([model.session?.username, model.session?.roleLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(model.server?.hostLabel ?? "", systemImage: "server.rack")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .help("正在使用")
        }
    }

    private func pick(_ saved: SavedAccount) async {
        error = nil
        switching = saved.id
        defer { switching = nil }
        do {
            try await model.switchAccount(to: saved.account.username, on: saved.server)
            close()
        } catch AppModel.AccountError.needsPassword {
            error = "「\(saved.account.nickname)」的登录已失效，请用「添加账号」重新登录"
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 浮层里的一个其他账号
private struct MacAccountRow: View {
    let saved: SavedAccount
    let busy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MacAvatar(url: MacAccounts.avatarURL(saved.account.avatarUrl, username: saved.account.username, server: saved.server, size: 30),
                          name: saved.account.nickname, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(saved.account.nickname)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(saved.server.hostLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(hovering ? 0.08 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .accessibilityLabel("切换到 \(saved.account.nickname)，\(saved.server.hostLabel)")
        .accessibilityIdentifier("mac-account-\(saved.account.username)")
    }
}

/// 浮层底部的一项操作（整行可点、悬停高亮，像菜单项）
private struct MacPanelAction: View {
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .foregroundStyle(destructive ? Theme.danger : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(hovering ? 0.08 : 0), in: .rect(cornerRadius: 8))
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 账号相关的小工具（浮层、菜单栏「账号」菜单共用）
enum MacAccounts {
    /// 本机登录过的全部账号（跨服务器）
    static func all(_ model: AppModel) -> [SavedAccount] {
        model.savedServers.flatMap { saved in saved.accounts.map { SavedAccount(server: saved.address, account: $0) } }
    }

    static func currentID(_ model: AppModel) -> String? {
        guard let server = model.server, let username = model.session?.username else { return nil }
        return "\(server.origin.absoluteString)#\(username)"
    }

    /// 头像地址：带上账号标记（图片加载器据此用这个账号的令牌取图，跨服务器、跨账号都取得到）
    static func avatarURL(_ raw: String?, username: String?, server: ServerAddress?, size: CGFloat) -> URL? {
        guard let server, let username else { return nil }
        return server.imageURL(AvatarURL.tagged(raw, username: username), width: ImageWidth.points(size))
    }
}
