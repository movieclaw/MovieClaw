import SwiftUI

/// 欢迎页的登录卡片：服务器地址 + 用户名 + 密码一张表，一次提交完成「测通服务器 → 登录」。
/// 首次登录、登录过期后重新登录、已登录时「添加账号」都是这一张卡片，只是标题与预填不同（`Purpose`）；
/// 服务器地址始终可以改——改成别的地址，就是登录到另一台服务器，原来那台的账号照样留在本机。
///
/// 服务器是全新的（还没创建过管理员）时，`AppModel.signIn` 返回 `.needsSetup`，
/// 卡片原地切到「初始化」：补一个确认密码，用同一组账号创建超级管理员（同 Web /setup），
/// 用户已经填好的内容全部保留。改动服务器地址会退回普通登录，因为换了服务器就得重新判断。
///
/// 第一次使用（没有任何可预填的服务器）时，卡片一出现就在局域网里自动发现服务器（`ServerDiscovery`），
/// 找到了直接填进地址栏；找的过程中用户自己动手填了，就以手填为准。
struct WelcomeSignInPanel: View {
    /// 这张卡片是干什么的：决定标题与说明
    enum Purpose: Equatable {
        /// 第一次使用：本机还没连过任何服务器（首页按钮「连接服务器」）
        case connect
        /// 连过服务器、账号全部退出后再登录（首页按钮「登录」）
        case signIn
        /// 登录过期，重新输密码（用户名已预填）
        case reauth
        /// 已登录时再添加一个账号（这台或另一台服务器）
        case addAccount
    }

    /// 打开时预填的服务器与用户名
    struct Prefill: Hashable {
        var server: ServerAddress?
        var username: String?
    }

    private enum Field: Hashable {
        case address, username, password, confirm
    }

    /// 局域网自动发现的进度
    private enum Discovery: Equatable {
        case idle
        case searching
        /// 找到并已填入：记下填入的地址，用户改掉之后就不再显示「已填入」
        case found(name: String, address: String)
        case notFound
    }

    /// UI 自动化测试时关掉系统密码自动填充：「存储密码？」弹层会挡住后续操作
    private static let autofill = !ProcessInfo.processInfo.arguments.contains("--ui-testing")
    /// UI 自动化测试时也不做自动发现：用例要往空白地址栏里输入，自动填值会把输入搅乱
    private static let discovers = !ProcessInfo.processInfo.arguments.contains("--ui-testing")

    /// 是否正在输入：交给欢迎页决定要不要收起顶部片名
    @Binding var editing: Bool
    let purpose: Purpose
    let prefill: Prefill
    /// 卡片出现后是否直接弹键盘：用户点按钮打开的才弹，页面自己出现的（冷启动发现登录过期）不抢焦点
    var autoFocus = true
    /// 「切换到其他账号」：别的服务器上还有登录中的账号时才给
    var onSwitchAccount: (() -> Void)?
    /// 登录 / 创建成功之后（添加账号的卡片用它关掉自己：登的若正是当前账号，主界面不会重建）
    var onSignedIn: (() -> Void)?
    /// 右上角 ×：收起卡片（回首页，或关掉添加账号）
    var onClose: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    /// 判定为全新服务器时的地址。地址一改就不算数了——换了服务器得重新判断它是否已初始化
    @State private var setupAddress: String?
    @State private var busy = false
    @State private var error: String?
    @State private var discovery: Discovery = .idle
    /// 加一就重新找一遍（「重新查找」）
    @State private var discoveryRun = 0
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.welcomeSerif(size: 22))
                        .foregroundStyle(Theme.text)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let onClose {
                    closeButton(onClose)
                }
            }

            if !setup, purpose != .addAccount, let launchError = model.launchError {
                Label(launchError, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }

            fields

            discoveryStatus

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("login-error")
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(.black) }
                    Text(buttonTitle)
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accentStrong)
            .foregroundStyle(Color.black.opacity(0.85))
            .controlSize(.large)
            .disabled(busy || !filled)
            .accessibilityIdentifier("login-submit")

            if let onSwitchAccount {
                Button("切换到其他账号", action: onSwitchAccount)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accentStrong)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("welcome-switch-account")
            }
        }
        .welcomeCard()
        .animation(.smooth, value: setup)
        .animation(.smooth, value: discovery)
        .onAppear(perform: applyPrefill)
        .task(id: discoveryRun) { await discover() }
        .onChange(of: focus) {
            withAnimation(.smooth(duration: 0.35)) { editing = focus != nil }
        }
    }

    /// 输入框组：同一块内嵌底色里用细线分隔，像系统设置里的分组
    private var fields: some View {
        VStack(spacing: 0) {
            row(icon: "server.rack") {
                TextField("服务器地址", text: $address, prompt: Text(verbatim: "例如 http://192.168.0.100:3000"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focus = .username }
                    .accessibilityIdentifier("server-address")
                // 地址常是预填的（添加账号、重新登录）：要换一台服务器时一下清空，不用逐字删
                if focus == .address, !address.isEmpty {
                    Button {
                        address = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空服务器地址")
                    .accessibilityIdentifier("server-address-clear")
                }
            }
            Divider().overlay(Theme.line)
            row(icon: "person") {
                TextField("用户名", text: $username, prompt: Text(setup ? "管理员用户名" : "用户名"))
                    .textContentType(Self.autofill ? .username : nil)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("login-username")
            }
            Divider().overlay(Theme.line)
            row(icon: "lock") {
                SecureField("密码", text: $password, prompt: Text(setup ? "密码（至少 8 位）" : "密码"))
                    .textContentType(Self.autofill ? (setup ? .newPassword : .password) : nil)
                    .focused($focus, equals: .password)
                    .submitLabel(setup ? .next : .go)
                    .onSubmit { if setup { focus = .confirm } else { submit() } }
                    .accessibilityIdentifier("login-password")
            }
            if setup {
                Divider().overlay(Theme.line)
                row(icon: "lock.rotation") {
                    SecureField("确认密码", text: $confirm)
                        .textContentType(Self.autofill ? .newPassword : nil)
                        .focused($focus, equals: .confirm)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .accessibilityIdentifier("login-confirm")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .welcomeInset()
        .tint(Theme.accentStrong)
    }

    /// 自动发现的状态行：找的时候转个小圈；找到了说一声填的是谁；没找到就请用户手填，也可以再找一次
    @ViewBuilder
    private var discoveryStatus: some View {
        switch discovery {
        case .searching where address.isEmpty:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("正在局域网里寻找 MovieClaw…")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textMuted)
        case let .found(name, filled) where filled == address:
            Label {
                Text("已填入局域网里发现的「\(name)」")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            }
            .font(.footnote)
            .foregroundStyle(Theme.textMuted)
            .accessibilityIdentifier("discovery-found")
        case .notFound where address.isEmpty:
            HStack(spacing: 6) {
                Text("没在局域网里找到服务器，请手动填写")
                    .foregroundStyle(Theme.textMuted)
                Button("重新查找") { discoveryRun += 1 }
                    .foregroundStyle(Theme.accentStrong)
            }
            .font(.footnote)
        default:
            EmptyView()
        }
    }

    private func row(icon: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 22)
            field()
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }

    /// 服务器是全新的：同一组账号改为创建超级管理员
    private var setup: Bool { setupAddress != nil && setupAddress == address }

    private var filled: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && (!setup || !confirm.isEmpty)
    }

    /// 右上角 ×：卡片本身已是液态玻璃，按钮不再叠一层玻璃（玻璃套玻璃发糊），用内嵌底色的小圆
    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceInset, in: .circle)
                .overlay(Circle().strokeBorder(Theme.line))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
        .accessibilityIdentifier("welcome-close")
    }

    private var title: String {
        if setup { return "初始化这台服务器" }
        switch purpose {
        case .connect: return "连接服务器"
        case .signIn: return "登录 MovieClaw"
        case .reauth: return "重新登录"
        case .addAccount: return "添加账号"
        }
    }

    private var subtitle: String {
        if setup {
            return "这是一台全新的服务器。将用下面的账号创建超级管理员——它是本站唯一的管理身份，此流程仅在首次部署时出现。"
        }
        switch purpose {
        case .connect: return "服务器地址即在浏览器里打开 MovieClaw 时地址栏中的那一串。"
        case .signIn: return "服务器地址沿用上次的；要登录别的服务器，改一下地址就行。"
        case .reauth: return "「\(prefill.username ?? "")」的登录已失效，请重新输入密码。"
        case .addAccount: return "可以是这台服务器上的另一个账号；要登录别的服务器，改一下地址就行。"
        }
    }

    private var buttonTitle: String {
        if setup { return busy ? "创建中…" : "创建账号并进入" }
        return busy ? "正在连接…" : "登录"
    }

    /// 按传进来的预填填好地址与用户名，光标落到第一个还空着的格子
    private func applyPrefill() {
        if address.isEmpty, let server = prefill.server {
            address = server.displayString
        }
        if username.isEmpty, let name = prefill.username {
            username = name
        }
        // 冷启动时查到这台服务器是全新的：直接是初始化的样子
        if model.phase == .needsSetup, prefill.server == model.server { setupAddress = address }
        guard autoFocus else { return }
        // 等卡片升起的动画走完再弹键盘，否则两段动画挤在一起会卡顿
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            focus = address.isEmpty ? .address : username.isEmpty ? .username : .password
        }
    }

    /// 局域网自动发现：只在没有任何可预填的服务器（第一次使用）、地址栏还空着时做
    private func discover() async {
        guard Self.discovers, prefill.server == nil, address.isEmpty else { return }
        discovery = .searching
        let found = await ServerDiscovery.findFirst()
        guard !Task.isCancelled else { return }
        // 找的过程中用户自己填了地址：以手填为准，不覆盖
        guard address.isEmpty else {
            discovery = .idle
            return
        }
        guard let found else {
            discovery = .notFound
            return
        }
        address = found.address.displayString
        discovery = .found(name: found.name, address: address)
        // 光标还停在地址栏（自动聚焦的）就挪到用户名，省一次点击
        if focus == .address { focus = .username }
    }

    private func submit() {
        guard !busy, filled else { return }
        let server: ServerAddress
        do {
            server = try ServerAddress(parsing: address)
        } catch {
            self.error = error.localizedDescription
            focus = .address
            return
        }
        let name = username.trimmingCharacters(in: .whitespaces)
        if setup {
            // 与 Web /setup 相同的前端校验，后端仍会再校验一次
            if name.count < 3 { error = "用户名至少 3 个字符"; return }
            if password.count < 8 { error = "密码至少 8 位，建议混用字母与数字"; return }
            if password != confirm { error = "两次输入的密码不一致"; return }
        }
        error = nil
        busy = true
        focus = nil
        let typed = address
        Task {
            defer { busy = false }
            // 只写了主机（如 192.168.1.10）时试一下 3000 / 80 / https，免得默认落到 80 端口连不上
            let target = await ServerDiscovery.settle(server, typed: typed)
            do {
                if setup {
                    try await model.createAdmin(on: target, username: name, password: password)
                    onSignedIn?()
                } else if try await model.signIn(to: target, username: name, password: password) == .needsSetup {
                    setupAddress = typed
                    focus = .confirm
                } else {
                    onSignedIn?()
                }
            } catch AppModel.ConnectError.alreadyInitialized {
                setupAddress = nil
                self.error = AppModel.ConnectError.alreadyInitialized.localizedDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
