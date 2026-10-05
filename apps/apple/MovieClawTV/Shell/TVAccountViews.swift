import SwiftUI

/// 谁在看：本机登录过的全部账号（跨服务器）大头像横排，星空背景，焦点放大，按确认键进入
/// （docs/design/tvos-app.md §5.2，同 Netflix 的选人页、tvOS 26 唤醒时的选人）。
/// 放在侧边栏的「账号」页签里：当前账号默认获得焦点。选自己回首页；选别人就换一枚令牌
/// （不联网、不用密码），主界面整棵重建。返回键交给系统（焦点回侧边栏）。
/// 底部一行「关于」「退出登录」——电视上与账号有关的操作都在这一页，不再有单独的账号页。
/// 启动时不再弹这一页，直接以上次用的账号进入（2026-10-04 用户要求）
struct TVWhoIsWatchingView: View {
    /// 选了自己：回首页
    let onClose: () -> Void
    /// 「账号」页签里的「关于」：在本页签里压栈打开关于页
    var onAbout: (() -> Void)?

    @Environment(AppModel.self) private var model
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
                // 这一排横贯整屏做成焦点区，打开时、从下面一行往上回来时都落在当前账号上，不按位置挑最近的
                .frame(maxWidth: .infinity)
                .focusSection()
                .defaultFocus($focusedAccount, currentID, priority: .userInitiated)
                if let error {
                    Text(error).foregroundStyle(Theme.danger)
                }
                actions
            }
        }
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
    @FocusState private var aboutFocused: Bool

    private var profiles: some View {
        HStack(spacing: 70) {
            ForEach(accounts) { saved in
                TVProfileButton(account: saved.account, server: saved.server, current: saved.id == currentID) {
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
            .focused($aboutFocused)
            .accessibilityIdentifier("tv-profiles-about")
            Button(role: .destructive) { confirmingLogout = true } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("tv-profiles-logout")
        }
        .font(.callout)
        .focusSection()
        // 从头像往下进这一行先落在「关于」上：系统按位置挑的常是「退出登录」，手一滑就点到了
        .defaultFocus($aboutFocused, true, priority: .userInitiated)
    }

    private var currentID: String? {
        guard let server = model.server, let username = model.session?.username else { return nil }
        return "\(server.origin.absoluteString)#\(username)"
    }

    private func pick(_ saved: SavedAccount) async {
        if saved.server == model.server, saved.account.username == model.session?.username {
            onClose()
            return
        }
        do {
            try await model.switchAccount(to: saved.account.username, on: saved.server)
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
