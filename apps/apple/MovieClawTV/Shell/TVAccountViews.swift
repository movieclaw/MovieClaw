import SwiftUI

/// 「谁在看」的开关（docs/design/tvos-app.md §5.2）：电视上登录过不止一个账号时，启动先问一句「谁在看」。
/// 主界面里点顶栏的头像打开的是同一页，但那是盖在主界面上的（`TVMainView`），不经过这个开关。
@Observable
final class TVProfileGate {
    /// 本次启动已经选过人了（或已按 Apple TV 的系统用户自动选好，见 `TVUserProfiles`）
    private(set) var picked: Bool

    init(picked: Bool) {
        self.picked = picked
    }

    func pickedProfile() { picked = true }
}

/// 谁在看：本机登录过的全部账号（跨服务器）大头像横排，星空背景，焦点放大，按确认键进入
/// （docs/design/tvos-app.md §5.2，同 Netflix 的选人页、tvOS 26 唤醒时的选人）。两种打开方式：
/// - **启动时**（`onClose == nil`）：这台电视上登录过不止一个账号，先问一句，选好了才进主界面；
/// - **点顶栏左上角的头像**（`onClose` 有值）：盖在主界面上，当前账号默认获得焦点。返回键或选自己就关掉，
///   回到原来的页面、浏览位置不丢；选别人就换一枚令牌（不联网、不用密码），主界面整棵重建。
///   底部多一行「关于」「退出登录」——电视上与账号有关的操作都在这一页，不再有单独的账号页。
struct TVWhoIsWatchingView: View {
    /// 从顶栏打开时的关闭动作；启动时的选人页为 nil（没有可以退回去的页面）
    var onClose: (() -> Void)?
    /// 从顶栏打开时「关于」：关掉本页、在当前页签里压栈打开关于页
    var onAbout: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(TVProfileGate.self) private var gate
    @State private var error: String?
    @State private var addingAccount = false
    @State private var confirmingLogout = false

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
                if onClose != nil {
                    actions
                }
            }
        }
        .onExitCommand(perform: onClose)
        .fullScreenCover(isPresented: $addingAccount) {
            TVAddAccountView()
        }
        .alert("退出登录？", isPresented: $confirmingLogout) {
            Button("退出", role: .destructive) {
                TVTopShelfPublisher.clear()
                Task { await model.logout() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(model.session?.nickname ?? "")」在这台 Apple TV 上的登录会在服务器上一并注销。同一台服务器上还有别的账号时会自动切过去。")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-who-is-watching")
    }

    @FocusState private var focusedAccount: String?

    private var profiles: some View {
        HStack(spacing: 70) {
            ForEach(accounts) { saved in
                TVProfileButton(account: saved.account, server: saved.server, current: onClose != nil && saved.id == currentID) {
                    Task { await pick(saved) }
                }
                .focused($focusedAccount, equals: saved.id)
            }
            Button { addingAccount = true } label: {
                VStack(spacing: 20) {
                    TVProfileAvatarFocus {
                        ZStack {
                            Circle().fill(.white.opacity(0.1))
                            Image(systemName: "plus").font(.system(size: 64, weight: .light))
                        }
                        .frame(width: 220, height: 220)
                    }
                    Text("添加账号").font(.headline)
                    Text(" ").font(.caption)
                }
            }
            .buttonStyle(TVProfileButtonStyle())
            .accessibilityIdentifier("tv-profile-add")
        }
        .padding(.horizontal, TVMetrics.edge)
        .padding(.vertical, 40)
    }

    /// 次要操作：小一号、靠下，不和选人抢视线
    private var actions: some View {
        HStack(spacing: 30) {
            Button { onAbout?() } label: {
                Label("关于", systemImage: "info.circle")
            }
            .accessibilityIdentifier("tv-profiles-about")
            Button(role: .destructive) { confirmingLogout = true } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("tv-profiles-logout")
        }
        .font(.callout)
        .focusSection()
    }

    private var currentID: String? {
        guard let server = model.server, let username = model.session?.username else { return nil }
        return "\(server.origin.absoluteString)#\(username)"
    }

    private func pick(_ saved: SavedAccount) async {
        if saved.server == model.server, saved.account.username == model.session?.username {
            gate.pickedProfile()
            onClose?()
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
