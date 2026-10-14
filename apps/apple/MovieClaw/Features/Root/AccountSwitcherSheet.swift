import SwiftUI

/// 切换账号（Web components/account-switcher-dialog.tsx，设计见 docs/design/account-switching.md）。
/// 入口：长按底部头像页签（半屏抽屉，见 TabBarAccountGestures）、个人信息页的「切换账号」。
///
/// 列出本机登录过的全部账号，**可以跨服务器**：每台服务器一个分组（只有一台时不显示服务器名）。
/// 每个账号在本机是一枚设备令牌（docs/design/login-devices.md），切换就是换用它的令牌，没有账号数上限。
/// - 点其他账号即切换，不用再输密码；换到另一台服务器上的账号也一样。那个账号的登录已失效
///   （在「我的设备」里被注销、改了密码）时，打开登录卡片、预填服务器与用户名，只需输密码；
/// - 行尾 × 移除（也可左滑）；
/// - 底部「添加账号」打开和欢迎页同一张登录卡片：服务器预填当前这台、可以改，改了就是登录到另一台服务器；
///   「退出全部账号」退出本机所有服务器上的全部账号。
///
/// 列表先用本机快照（`AppModel.savedServers`）立即画出来，再逐台向服务器刷新；取不到的那台照样列出，
/// 标上「连不上」；登录已失效的账号标上「需要重新登录」。切换后 RootView 以「服务器 + 用户名」为 id
/// 重建整棵界面树，不会串数据。
struct AccountSwitcherSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Feedback.self) private var feedback
    @Environment(\.dismiss) private var dismiss

    /// 某台服务器的账号列表此刻取没取到
    private enum Freshness {
        case loading
        case fresh
        case unreachable
    }

    /// 打开登录卡片：添加账号，或给某个过期账号重新输密码
    private struct CardRequest: Identifiable {
        var server: ServerAddress?
        var username: String?
        var id: String { "\(server?.origin.absoluteString ?? "")#\(username ?? "")" }
    }

    @State private var freshness: [URL: Freshness] = [:]
    @State private var busy = false
    @State private var card: CardRequest?

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, saved in
                    Section {
                        if saved.accounts.isEmpty, freshness[saved.id] == .loading {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        }
                        ForEach(saved.accounts, id: \.username) { account in
                            row(account, on: saved)
                                .swipeActions {
                                    Button("退出", role: .destructive) { Task { await remove(account, on: saved.address) } }
                                }
                        }
                    } header: {
                        header(saved, first: index == 0)
                    }
                }
                Section {
                    Button {
                        card = CardRequest(server: model.server, username: nil)
                    } label: {
                        Label("添加账号", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("account-add")
                    Button(role: .destructive) {
                        Task { await logoutEverywhere() }
                    } label: {
                        Label("退出全部账号", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } footer: {
                    Text("添加账号时改一下服务器地址，就能登录到另一台 MovieClaw。")
                }
            }
            .disabled(busy)
            .navigationTitle("切换账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .fullScreenCover(item: $card) { request in
                WelcomeView(mode: .addAccount(server: request.server, username: request.username), phase: model.phase) {
                    card = nil
                }
            }
        }
        .task { refreshAll() }
        // 半屏抽屉（长按头像页签弹出，同 Instagram）：账号一般就几个，半屏放得下；多了可以上拉到全屏
        .presentationDetents([.medium, .large])
    }

    /// 要列出的服务器：有账号的，外加当前服务器（快照还没取回来时也要占个位转圈）；当前服务器排第一
    private var servers: [SavedServer] {
        let listed = model.savedServers.filter { !$0.accounts.isEmpty || $0.address == model.server }
        return listed.filter { $0.address == model.server } + listed.filter { $0.address != model.server }
    }

    private var multipleServers: Bool { servers.count > 1 }

    @ViewBuilder
    private func header(_ saved: SavedServer, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if first {
                Text("本机已登录的账号，点击即可切换，不用再输密码。")
            }
            if multipleServers {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                    Text(saved.address.hostLabel)
                    switch freshness[saved.id] {
                    case .unreachable: Text("· 连不上").foregroundStyle(Theme.warning)
                    default: EmptyView()
                    }
                }
                .font(.caption.weight(.medium))
            }
        }
        .textCase(nil)
    }

    private func row(_ account: API.AccountView, on saved: SavedServer) -> some View {
        let isCurrent = saved.address == model.server && account.username == model.session?.username
        return HStack(spacing: 10) {
            Button {
                Task { await switchTo(account.username, on: saved.address) }
            } label: {
                HStack(spacing: 12) {
                    AvatarBadge(session: nil, avatarUrl: account.avatarUrl, nickname: account.nickname, size: 40)
                        // 头像地址是那台服务器上的相对路径：按那台服务器解析；地址里带着这个账号的标记，
                        // 图片加载器据此用它自己的令牌去取（AvatarURL）
                        .environment(\.api, APIClient(server: saved.address))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.nickname).foregroundStyle(Theme.text)
                        Text("@\(account.username) · \(account.role == "admin" ? "超级管理员" : "成员")")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                        if !isCurrent, !model.hasToken(for: account.username, on: saved.address) {
                            Text("登录已失效，点一下重新输入密码")
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                        }
                    }
                    Spacer()
                    if isCurrent {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark").font(.caption2.weight(.bold))
                            Text("当前")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            // 当前账号不可点，但不置灰（Web 当前行是高亮而不是禁用色）
            .allowsHitTesting(!isCurrent)
            // 行尾 ×：从本机移除该账号（Web AccountRow 行尾常驻）
            Button {
                Task { await remove(account, on: saved.address) }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("从本机移除 \(account.nickname)")
        }
        // 一行两个按钮：各自 borderless，避免 List 把整行点击同时派给两者
        .buttonStyle(.borderless)
    }

    /// 逐台刷新账号列表：各台并行（连不上的那台要等超时，不能拖住其他台）
    private func refreshAll() {
        for saved in servers {
            freshness[saved.id] = .loading
            let address = saved.address
            Task {
                do {
                    try await model.refreshAccounts(on: address)
                    freshness[address.origin] = .fresh
                } catch {
                    freshness[address.origin] = .unreachable
                }
            }
        }
    }

    private func switchTo(_ username: String, on address: ServerAddress) async {
        busy = true
        defer { busy = false }
        do {
            // 落在「我的」：长按头像页签松手时底下已经是「我的」、从个人信息页打开时人也在「我的」
            try await model.switchAccount(to: username, on: address, landingOn: .more)
            dismiss()
        } catch AppModel.AccountError.needsPassword(let server, let username) {
            // 登录过期：打开登录卡片，预填服务器与用户名，只需输密码
            card = CardRequest(server: server, username: username)
        } catch {
            feedback.error(error)
        }
    }

    private func remove(_ account: API.AccountView, on address: ServerAddress) async {
        let isCurrent = address == model.server && account.username == model.session?.username
        let message = isCurrent
            ? "这是当前账号。退出后本机不再保留它的登录状态，会自动切到其他账号；再回来需要重新输入密码。"
            : "本机将不再保留它的登录状态，再回来需要重新输入密码。账号本身不受影响。"
        guard await feedback.confirm("退出「\(account.nickname)」？", message: message, confirmTitle: "退出", destructive: true) else { return }
        if isCurrent { await OfflineDownloadCleanup.askOnLogout(feedback: feedback) }
        busy = true
        defer { busy = false }
        do {
            try await model.removeAccount(account.username, on: address)
            if isCurrent { dismiss() }
        } catch {
            feedback.error(error)
        }
    }

    private func logoutEverywhere() async {
        let count = model.savedAccountCount
        let serverCount = model.savedServers.filter { !$0.accounts.isEmpty }.count
        let scope = serverCount > 1 ? "本机登录过的 \(count) 个账号（\(serverCount) 台服务器）" : "本机里的 \(count) 个账号"
        guard await feedback.confirm(
            "退出全部账号？",
            message: "\(scope)都会退出登录，再回来需要逐个重新输入密码。共用设备时建议这样做。",
            confirmTitle: "全部退出", destructive: true
        ) else { return }
        await OfflineDownloadCleanup.askOnLogoutEverywhere(feedback: feedback)
        dismiss()
        model.logoutEverywhere()
    }
}
