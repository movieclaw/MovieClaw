import AppKit
import SwiftUI

// 欢迎页的几张卡片：卡片外壳（`MacWelcomeCard`）、找服务器（`MacServerPicker`）、连不上（`MacUnreachableCard`）、
// 选择账号（`MacAccountChooser`）。登录卡片在 MacSignInStep.swift，扫码登录在 MacPairingLogin.swift。
//
// 每张卡片需要的数据（已存的服务器、账号、出错原因）都从参数传进来，只在按钮动作里才用 `AppModel`：
// 欢迎页与「添加账号」sheet 共用同一套卡片，各自决定传什么。

/// 尺寸
enum MacWelcomeMetrics {
    /// 卡片宽：放得下「二维码 + 配对码」并排，也不至于让一行输入框长得空旷
    static let cardWidth: CGFloat = 460
    static let cardCorner: CGFloat = 26
    /// 卡片里的内嵌分组（服务器列表、账号列表、服务器信息）圆角
    static let insetCorner: CGFloat = 12
}

extension EnvironmentValues {
    /// 卡片是否自己套一层液态玻璃：欢迎页浮在星空上要套；「添加账号」sheet 本身就是一层材质，不再套（玻璃套玻璃发糊）
    @Entry var macWelcomeCardOnGlass = true
}

// MARK: - 卡片外壳

/// 欢迎页卡片的统一外壳：可选的「返回」（Esc）、宋体标题、说明，下面是内容。
struct MacWelcomeCard<Content: View>: View {
    let title: String
    let subtitle: String?
    /// 返回上一步；给了才显示左上角「返回」，并占用 Esc
    var onBack: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @Environment(\.macWelcomeCardOnGlass) private var onGlass

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                if let onBack {
                    Button(action: onBack) {
                        Label("返回", systemImage: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("返回上一步（Esc）")
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("mac-welcome-back")
                }
                Text(title)
                    .font(.welcomeSerif(size: 24))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if onGlass {
            card
                .padding(28)
                .frame(width: MacWelcomeMetrics.cardWidth)
                .glassEffect(.regular, in: .rect(cornerRadius: MacWelcomeMetrics.cardCorner))
        } else {
            card
                .padding(24)
                .frame(width: MacWelcomeMetrics.cardWidth)
        }
    }
}

extension View {
    /// 卡片里的内嵌分组底（服务器列表、账号列表、服务器信息）
    func macWelcomeInset() -> some View {
        background(Theme.surfaceInset, in: .rect(cornerRadius: MacWelcomeMetrics.insetCorner))
            .overlay(RoundedRectangle(cornerRadius: MacWelcomeMetrics.insetCorner).strokeBorder(Theme.line))
    }

    /// 卡片的主按钮：冷银底、黑字（同 iPhone 版登录按钮的银色），是窗口的默认按钮（回车触发）
    func macWelcomePrimary() -> some View {
        buttonStyle(MacWelcomePrimaryStyle())
            .keyboardShortcut(.defaultAction)
    }
}

/// 主按钮样式。不用系统的 `.glassProminent` + 银色 tint：Mac 上它把浅色 tint 画成深灰玻璃，黑字几乎看不清
/// （离屏实测）；自己画一枚冷银胶囊，按下略暗、不可用时退成浅灰底灰字
struct MacWelcomePrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? Color.black.opacity(0.85) : Theme.textFaint)
                .padding(.horizontal, 16)
                .frame(minHeight: 34)
                .background(fill, in: .capsule)
                .contentShape(.capsule)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var fill: Color {
            guard enabled else { return .white.opacity(0.1) }
            if configuration.isPressed { return Theme.accent.opacity(0.8) }
            return hovering ? .white : Theme.accentStrong
        }
    }
}

/// 主按钮的标签：忙的时候前面转个小圈
struct MacWelcomeButtonLabel: View {
    let title: String
    var busy = false

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small).tint(.black)
            }
            Text(title)
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(maxWidth: .infinity)
    }
}

/// 出错说明：红色，可选中复制（错误文案里常带地址与错误码，方便贴给别人看）
struct MacWelcomeError: View {
    let message: String
    var symbol = "exclamationmark.triangle.fill"
    var color = Theme.danger

    var body: some View {
        Label {
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 12))
        .foregroundStyle(color)
        .accessibilityIdentifier("mac-welcome-error")
    }
}

/// 列表里的一行（服务器、账号）：整行可点、悬停提亮，右侧箭头或转圈
private struct MacWelcomeRow<Leading: View>: View {
    let title: String
    let subtitle: String
    var busy = false
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 找服务器

/// 第一步：找服务器。局域网自动发现（与 iPhone、Apple TV 同一个 `ServerDiscovery`）+ 本机登录过的服务器 + 手填地址。
/// 点一行或填好地址回车就进入登录；这一步只校验地址格式，连不连得上、是不是 MovieClaw、要不要初始化，
/// 在登录那一步提交时由 `AppModel.signIn` 一并测出来并逐条说明（同 iPhone 版）。
struct MacServerPicker: View {
    /// 本机登录过的服务器
    let saved: [SavedServer]
    var onBack: (() -> Void)?
    let onPick: (ServerAddress) -> Void

    /// 局域网自动发现的进度
    enum Discovery: Equatable {
        case searching
        case found(ServerDiscovery.Found)
        case notFound
    }

    /// UI 自动化测试不做自动发现（同 iPhone 版）：用例自己输入地址
    private static let discovers = !ProcessInfo.processInfo.arguments.contains("--ui-testing")

    @State private var discovery: Discovery = .searching
    /// 加一就重新找一遍（「重新查找」）
    @State private var discoveryRun = 0
    @State private var manual = ""
    @State private var error: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        MacWelcomeCard(title: "连接服务器",
                       subtitle: "服务器地址就是在浏览器里打开 MovieClaw 时地址栏里的那一串。",
                       onBack: onBack) {
            VStack(alignment: .leading, spacing: 4) {
                if let found = foundServer {
                    MacWelcomeRow(title: found.name, subtitle: "局域网 · \(found.address.hostLabel)", action: { onPick(found.address) }) {
                        rowIcon("wifi")
                    }
                    .accessibilityIdentifier("mac-server-found")
                }
                ForEach(recent) { server in
                    MacWelcomeRow(title: server.address.hostLabel, subtitle: Self.accountsLine(server), action: { onPick(server.address) }) {
                        rowIcon("clock.arrow.circlepath")
                    }
                }
                // 找到了就不再多一行「找到了」：上面那一行已写明「局域网」
                if foundServer == nil {
                    discoveryStatus
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .padding(4)
            .macWelcomeInset()

            VStack(alignment: .leading, spacing: 8) {
                Text("或者手动输入地址")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                HStack(spacing: 10) {
                    TextField("服务器地址", text: $manual, prompt: Text(verbatim: "例如 http://192.168.0.100:3000"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .focused($addressFocused)
                        .onSubmit(submitManual)
                        .accessibilityIdentifier("mac-server-address")
                    Button(action: submitManual) {
                        Text("连接").frame(minWidth: 56)
                    }
                    .macWelcomePrimary()
                    .fixedSize()
                    .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("mac-server-connect")
                }
            }

            if let error {
                MacWelcomeError(message: error)
            }
        }
        .animation(.smooth(duration: 0.25), value: discovery)
        .task(id: discoveryRun) { await discover() }
        .onAppear { addressFocused = true }
    }

    private var foundServer: ServerDiscovery.Found? {
        if case let .found(found) = discovery { return found }
        return nil
    }

    /// 登录过的服务器（最近用过的在前），自动发现找到的那台已经在上面了就不重复
    private var recent: [SavedServer] {
        saved.filter { $0.address != foundServer?.address }.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// 「登录过 · 小明、小红」
    private static func accountsLine(_ server: SavedServer) -> String {
        let names = server.accounts.map(\.nickname)
        guard !names.isEmpty else { return "登录过" }
        let shown = names.prefix(3).joined(separator: "、")
        return "登录过 · " + (names.count > 3 ? "\(shown) 等 \(names.count) 个账号" : shown)
    }

    private func rowIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.06), in: .circle)
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        switch discovery {
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在局域网里寻找 MovieClaw…")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
        case .found:
            EmptyView()
        case .notFound:
            // 自动发现靠服务端的「Jellyfin 兼容」监听 UDP 7359：关了它、或 Docker 没映射这个端口都找不到
            VStack(alignment: .leading, spacing: 4) {
                Text("没在局域网里找到服务器。可能不在同一网络，或服务器关闭了「Jellyfin 兼容」（Docker 部署还需映射 UDP 7359），请在下面手动填写地址。")
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新查找") { discoveryRun += 1 }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("mac-server-rediscover")
            }
            .font(.system(size: 12))
        }
    }

    private func discover() async {
        guard Self.discovers else {
            discovery = .notFound
            return
        }
        discovery = .searching
        let found = await ServerDiscovery.findFirst()
        guard !Task.isCancelled else { return }
        discovery = found.map { .found($0) } ?? .notFound
    }

    private func submitManual() {
        let raw = manual.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        do {
            let address = try ServerAddress(parsing: raw)
            error = nil
            onPick(address)
        } catch {
            self.error = error.localizedDescription
            addressFocused = true
        }
    }
}

// MARK: - 连不上服务器

/// 冷启动连不上当前服务器。连不上不等于要重新登录——令牌还在钥匙串里，服务器恢复后点「重试」就能进，
/// 所以这里不给登录表单，而是：重试 / 换一台服务器 / 切换到别的服务器上的账号。
/// App 回到前台时自动重试一次（常见情形：NAS 刚开机、Mac 刚连上家里的网络）。
struct MacUnreachableCard: View {
    let server: ServerAddress?
    /// 连不上的原因（`AppModel.launchError`，已写明发生了什么、该怎么办）
    let reason: String?
    let onChangeServer: () -> Void
    var onChooseAccount: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var retrying = false

    var body: some View {
        MacWelcomeCard(title: "连不上服务器",
                       subtitle: "登录状态还在。服务器恢复后点「重试」即可进入，不用重新输入密码。") {
            VStack(alignment: .leading, spacing: 8) {
                if let server {
                    Label(server.displayString, systemImage: "server.rack")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
                MacWelcomeError(message: reason ?? "请检查网络，或确认服务器正在运行。",
                                symbol: "wifi.exclamationmark", color: Theme.warning)
                    .accessibilityIdentifier("mac-unreachable-reason")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .macWelcomeInset()

            Button {
                Task { await retry() }
            } label: {
                MacWelcomeButtonLabel(title: retrying ? "正在连接…" : "重试", busy: retrying)
            }
            .macWelcomePrimary()
            .disabled(retrying)
            .accessibilityIdentifier("mac-unreachable-retry")

            HStack(spacing: 10) {
                Button(action: onChangeServer) {
                    Text("换一台服务器").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("mac-unreachable-change-server")
                if let onChooseAccount {
                    Button(action: onChooseAccount) {
                        Text("切换到其他账号").frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await retry() }
        }
    }

    private func retry() async {
        guard !retrying else { return }
        retrying = true
        defer { retrying = false }
        await model.reconnect()
    }
}

// MARK: - 选择账号

/// 选择账号：当前服务器上已经没有登录中的账号、别的服务器上还有（比如刚退出了这台上的最后一个账号）。
/// 列出来一点即进，不用输密码（换用它的令牌）；那个账号的登录也失效了，就转到登录卡片、预填好服务器与用户名。
struct MacAccountChooser: View {
    let accounts: [SavedAccount]
    var onBack: (() -> Void)?
    let onSignInAnother: () -> Void
    let onNeedsPassword: (ServerAddress, String) -> Void

    @Environment(AppModel.self) private var model
    /// 正在切换的那一行（`SavedAccount.id`）
    @State private var switching: String?
    @State private var error: String?

    var body: some View {
        MacWelcomeCard(title: "选择账号",
                       subtitle: "这些账号在这台 Mac 上还登录着，点一下直接进入，不用输密码。",
                       onBack: onBack) {
            VStack(spacing: 2) {
                ForEach(accounts) { saved in
                    MacWelcomeRow(title: saved.account.nickname,
                                  subtitle: "@\(saved.account.username) · \(saved.server.hostLabel)",
                                  busy: switching == saved.id,
                                  action: { Task { await pick(saved) } }) {
                        MacAvatar(url: MacAccounts.avatarURL(saved.account.avatarUrl, username: saved.account.username,
                                                             server: saved.server, size: 36),
                                  name: saved.account.nickname, size: 36)
                    }
                    .disabled(switching != nil)
                    .accessibilityLabel("进入 \(saved.account.nickname)，\(saved.server.hostLabel)")
                    .accessibilityIdentifier("mac-chooser-\(saved.account.username)")
                }
            }
            .padding(4)
            .macWelcomeInset()

            if let error {
                MacWelcomeError(message: error)
            }

            Button(action: onSignInAnother) {
                Text("登录其他账号").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("mac-chooser-sign-in-another")
        }
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
