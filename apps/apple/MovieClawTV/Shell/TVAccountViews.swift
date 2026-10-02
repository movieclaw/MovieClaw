import SwiftUI

/// 「谁在看」的开关（docs/design/tvos-app.md §5.2）：电视上登录过不止一个账号时，启动先问一句「谁在看」；
/// 账号页的「切换账号」也是重新打开它。放进环境，主界面任何地方都能唤起。
@Observable
final class TVProfileGate {
    /// 本次启动已经选过人了（或已按 Apple TV 的系统用户自动选好，见 `TVUserProfiles`）
    private(set) var picked: Bool

    init(picked: Bool) {
        self.picked = picked
    }

    func pickedProfile() { picked = true }
    func show() { picked = false }
}

/// 谁在看：本机登录过的全部账号（跨服务器）大头像横排，焦点放大，按确认键进入。
/// 选的就是当前账号直接进主界面；选别人就换一枚令牌（不联网、不用密码），主界面整棵重建
struct TVWhoIsWatchingView: View {
    @Environment(AppModel.self) private var model
    @Environment(TVProfileGate.self) private var gate
    @State private var error: String?
    @State private var addingAccount = false

    private var accounts: [SavedAccount] {
        model.savedServers.flatMap { saved in saved.accounts.map { SavedAccount(server: saved.address, account: $0) } }
    }

    var body: some View {
        ZStack {
            CosmosBackdrop(lit: true, dimmed: true)
                .ignoresSafeArea()
            VStack(spacing: 70) {
                Text("谁在看？")
                    .font(.welcomeSerif(size: 72))
                // 放得下就居中摆一排；账号太多才横向滚动
                ViewThatFits(in: .horizontal) {
                    profiles
                    ScrollView(.horizontal) { profiles }
                        .scrollClipDisabled()
                }
                .defaultFocus($focusedAccount, currentID)
                if let error {
                    Text(error).foregroundStyle(Theme.danger)
                }
            }
        }
        .fullScreenCover(isPresented: $addingAccount) {
            TVAddAccountView()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-who-is-watching")
    }

    @FocusState private var focusedAccount: String?

    private var profiles: some View {
        HStack(spacing: 70) {
            ForEach(accounts) { saved in
                TVProfileButton(account: saved.account, server: saved.server) {
                    Task { await pick(saved) }
                }
                .focused($focusedAccount, equals: saved.id)
            }
            Button { addingAccount = true } label: {
                VStack(spacing: 20) {
                    ZStack {
                        Circle().fill(.white.opacity(0.1))
                        Image(systemName: "plus").font(.system(size: 64, weight: .light))
                    }
                    .frame(width: 220, height: 220)
                    Text("添加账号").font(.headline)
                    Text(" ").font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("tv-profile-add")
        }
        .padding(.horizontal, TVMetrics.edge)
        .padding(.vertical, 40)
    }

    private var currentID: String? {
        guard let server = model.server, let username = model.session?.username else { return nil }
        return "\(server.origin.absoluteString)#\(username)"
    }

    private func pick(_ saved: SavedAccount) async {
        if saved.server == model.server, saved.account.username == model.session?.username {
            gate.pickedProfile()
            return
        }
        do {
            try await model.switchAccount(to: saved.account.username, on: saved.server)
            gate.pickedProfile()
        } catch AppModel.AccountError.needsPassword {
            // 这个账号的登录失效了：打开登录（服务器与用户名预填）
            error = "「\(saved.account.nickname)」的登录已失效，请在「添加账号」里重新登录"
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 侧边栏最上面的账号页：当前是谁、在哪台服务器，以及切换账号 / 添加账号 / 关于 / 退出登录
struct TVAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(TVProfileGate.self) private var gate
    @Environment(TVRouter.self) private var router
    @Environment(\.api) private var api
    @State private var confirmingLogout = false
    @State private var addingAccount = false

    var body: some View {
        VStack(spacing: 50) {
            if let session = model.session, let server = model.server {
                TVAvatar(url: server.imageURL(AvatarURL.tagged(session.avatarUrl, username: session.username)),
                         name: session.nickname, size: 260)
                VStack(spacing: 12) {
                    Text(session.nickname)
                        .font(.title.weight(.bold))
                    Text("\(session.roleLabel) · \(server.hostLabel)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 30) {
                Button { gate.show() } label: {
                    Label("切换账号", systemImage: "person.2")
                }
                .accessibilityIdentifier("tv-account-switch")
                Button { addingAccount = true } label: {
                    Label("添加账号", systemImage: "person.badge.plus")
                }
                .accessibilityIdentifier("tv-account-add")
                Button { router.push(.about) } label: {
                    Label("关于", systemImage: "info.circle")
                }
                .accessibilityIdentifier("tv-account-about")
                Button(role: .destructive) { confirmingLogout = true } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("tv-account-logout")
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("退出登录？", isPresented: $confirmingLogout) {
            Button("退出", role: .destructive) {
                TVTopShelfPublisher.clear()
                Task { await model.logout() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台 Apple TV 上的登录会在服务器上一并注销。同一台服务器上还有别的账号时会自动切过去。")
        }
        .fullScreenCover(isPresented: $addingAccount) {
            TVAddAccountView()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-account")
    }
}

/// 添加账号：找服务器 → 登录（与欢迎页同一套卡片）。登录成功后 AppModel 直接切到新账号、主界面整棵重建
struct TVAddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var server: ServerAddress?

    var body: some View {
        ZStack {
            CosmosBackdrop(lit: true, dimmed: true)
                .ignoresSafeArea()
            if let server {
                TVSignInStep(server: server, prefilledUsername: nil, expired: false) { self.server = nil }
            } else {
                TVServerPicker { self.server = $0 }
            }
        }
        .onAppear { server = model.server }
        .onExitCommand { dismiss() }
    }
}
