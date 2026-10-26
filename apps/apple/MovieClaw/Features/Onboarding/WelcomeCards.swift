import SwiftUI

/// 欢迎页「选择账号」：当前服务器上已经没有登录中的账号，别的服务器上还有（比如刚退出了这台上的最后一个账号）。
/// 列出来一点即进，不用输密码；那个账号的登录也过期了，就转到登录卡片、预填好服务器与用户名。
struct WelcomeAccountChooser: View {
    var onSignInAnother: () -> Void
    var onNeedsPassword: (ServerAddress, String) -> Void

    @Environment(AppModel.self) private var model
    /// 正在切换的那一行（`SavedAccount.id`）
    @State private var switching: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: .authAccountsChoose))
                    .font(.welcomeSerif(size: 22))
                    .foregroundStyle(Theme.text)
                Text(String(localized: .authAccountsSavedHint))
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(model.accountsOnOtherServers.enumerated()), id: \.element.id) { index, saved in
                    if index > 0 { Divider().overlay(Theme.line) }
                    row(saved)
                }
            }
            .welcomeInset()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onSignInAnother) {
                Text(String(localized: .authAccountsOther))
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityIdentifier("welcome-sign-in-another")
        }
        .welcomeCard()
    }

    private func row(_ saved: SavedAccount) -> some View {
        Button {
            Task { await pick(saved) }
        } label: {
            HStack(spacing: 12) {
                AvatarBadge(session: nil, avatarUrl: saved.account.avatarUrl, nickname: saved.account.nickname, size: 38)
                    // 头像地址是那台服务器上的相对路径，按那台服务器解析；地址里带着这个账号的标记，
                    // 图片加载器据此用它自己的令牌去取（AvatarURL）
                    .environment(\.api, APIClient(server: saved.server))
                VStack(alignment: .leading, spacing: 2) {
                    Text(saved.account.nickname)
                        .foregroundStyle(Theme.text)
                    Text("@\(saved.account.username) · \(saved.server.hostLabel)")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if switching == saved.id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(switching != nil)
        .accessibilityIdentifier("welcome-account-row")
    }

    private func pick(_ saved: SavedAccount) async {
        switching = saved.id
        error = nil
        defer { switching = nil }
        do {
            try await model.switchAccount(to: saved.account.username, on: saved.server)
        } catch AppModel.AccountError.needsPassword(let server, let username) {
            onNeedsPassword(server, username)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 欢迎页「连不上服务器」：冷启动连不上当前服务器时。
///
/// 连不上不等于要重新登录——令牌还在钥匙串里，服务器恢复后点「重试」就能进，不用再输密码，
/// 所以这里不给登录表单，而是：重试 / 修改服务器地址（换了 IP、换了域名）/ 切换到别的服务器上的账号。
/// 从后台回到前台时自动重试一次（常见情形：NAS 刚开机、手机刚连上家里的 Wi-Fi）。
struct WelcomeUnreachableCard: View {
    var onEditAddress: () -> Void
    var onChooseAccount: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var retrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: .authServerUnreachable))
                    .font(.welcomeSerif(size: 22))
                    .foregroundStyle(Theme.text)
                Text(String(localized: .authServerRetryHint))
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(model.server?.displayString ?? "", systemImage: "server.rack")
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                if let launchError = model.launchError {
                    Text(launchError)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("welcome-unreachable-reason")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .welcomeInset()

            Button {
                Task { await retry() }
            } label: {
                HStack(spacing: 8) {
                    if retrying { ProgressView().tint(.black) }
                    Text(retrying ? String(localized: .authServerConnecting) : String(localized: .commonRetry))
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accentStrong)
            .foregroundStyle(Color.black.opacity(0.85))
            .controlSize(.large)
            .disabled(retrying)
            .accessibilityIdentifier("welcome-retry")

            HStack {
                Button(String(localized: .authServerEdit), action: onEditAddress)
                    .accessibilityIdentifier("welcome-edit-address")
                if let onChooseAccount {
                    Spacer()
                    Button(String(localized: .authAccountsSwitchOther), action: onChooseAccount)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.accentStrong)
            .frame(maxWidth: .infinity)
        }
        .welcomeCard()
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await retry() } }
        }
    }

    private func retry() async {
        guard !retrying else { return }
        retrying = true
        defer { retrying = false }
        await model.reconnect()
    }
}

extension View {
    /// 欢迎页卡片的统一外观：液态玻璃大圆角
    func welcomeCard() -> some View {
        padding(22).glassEffect(.regular, in: .rect(cornerRadius: 30))
    }

    /// 卡片里的内嵌分组底（输入框组、账号列表、服务器信息）
    func welcomeInset() -> some View {
        background(Theme.surfaceInset, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line))
    }
}
