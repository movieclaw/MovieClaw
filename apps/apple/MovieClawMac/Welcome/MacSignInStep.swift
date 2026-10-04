import SwiftUI

/// 登录这一步：服务器已经选好（卡片顶部写明是哪台，可「更换」），两种登录方式用分段控件切换——
/// 账号密码（Mac 上有键盘，默认这个；输入框标注了用户名 / 密码类型，钥匙串里存的密码可以自动填充）与
/// 扫码登录（`MacPairingLogin`：手机扫码或输配对码批准，同 Apple TV 版）。
///
/// 服务器是全新的（还没创建过管理员）时，卡片原地切到「初始化」形态：补一个确认密码，用同一组账号创建超级管理员
/// （同 Web /setup、iPhone 版），已经填好的内容保留；初始化时没有扫码这条路（还没有任何人能批准）。
/// 欢迎页与「添加账号」sheet 共用这张卡片（`Purpose`），只是标题、说明不同。
struct MacSignInStep: View {
    enum Purpose {
        /// 欢迎页：没有登录中的账号
        case welcome
        /// 已登录时再添加一个账号
        case addAccount
    }

    enum Method: Hashable {
        case password
        case qrCode
    }

    let target: MacSignInTarget
    var purpose: Purpose = .welcome
    var onBack: (() -> Void)?
    let onChangeServer: () -> Void
    /// 「切换到其他账号」：别的服务器上还有登录中的账号时才给
    var onSwitchAccount: (() -> Void)?
    /// 登录 / 创建成功之后（添加账号的 sheet 用它关掉自己）
    var onSignedIn: (() -> Void)?

    @State private var method: Method = .password
    /// 是否为「初始化」形态：已知服务器是全新的，或登录时才发现
    @State private var setup: Bool

    init(target: MacSignInTarget, purpose: Purpose = .welcome, onBack: (() -> Void)? = nil,
         onChangeServer: @escaping () -> Void, onSwitchAccount: (() -> Void)? = nil, onSignedIn: (() -> Void)? = nil) {
        self.target = target
        self.purpose = purpose
        self.onBack = onBack
        self.onChangeServer = onChangeServer
        self.onSwitchAccount = onSwitchAccount
        self.onSignedIn = onSignedIn
        _setup = State(initialValue: target.setup)
    }

    var body: some View {
        MacWelcomeCard(title: title, subtitle: subtitle, onBack: onBack) {
            serverRow

            if !setup {
                Picker("登录方式", selection: $method) {
                    Text("账号密码").tag(Method.password)
                    Text("扫码登录").tag(Method.qrCode)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("mac-signin-method")
            }

            loginForm

            if let onSwitchAccount {
                Button("切换到本机登录过的其他账号", action: onSwitchAccount)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("mac-signin-switch-account")
            }
        }
        .animation(.smooth(duration: 0.25), value: setup)
        .animation(.smooth(duration: 0.25), value: method)
    }

    /// 当前登录方式对应的内容（初始化时只有账号密码）
    @ViewBuilder
    private var loginForm: some View {
        if method == .qrCode && !setup {
            MacPairingLogin(server: target.server, onSignedIn: onSignedIn)
        } else {
            MacPasswordForm(target: target, setup: $setup, onSignedIn: onSignedIn)
        }
    }

    /// 要登录的服务器：写明是哪台（不同服务器上的账号互不相通，登错台是最常见的「密码不对」）
    private var serverRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(Theme.textMuted)
            Text(target.server.displayString)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("更换服务器", action: onChangeServer)
                .buttonStyle(.link)
                .font(.system(size: 12))
                .accessibilityIdentifier("mac-signin-change-server")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .macWelcomeInset()
    }

    private var title: String {
        if setup { return "初始化这台服务器" }
        if method == .qrCode { return "用手机扫码登录" }
        if target.expired { return "重新登录" }
        return purpose == .addAccount ? "添加账号" : "登录 MovieClaw"
    }

    private var subtitle: String {
        if setup {
            return "这是一台全新的服务器。将用下面的账号创建超级管理员——它是本站唯一的管理身份，此流程仅在首次部署时出现。"
        }
        if method == .qrCode {
            return "用手机相机或 iPhone 上 MovieClaw 的扫码扫一下，在手机上批准；也可以在 iPhone「设置 → 设备」或已登录的浏览器里输入配对码。谁批准，这台 Mac 就登录成谁。"
        }
        if target.expired, let name = target.username {
            return "「\(name)」在这台 Mac 上的登录已失效（可能在「我的设备」里被注销，或改过密码），请重新输入密码。"
        }
        switch purpose {
        case .welcome: return "输入这台服务器上的账号与密码。"
        case .addAccount: return "可以是这台服务器上的另一个账号；要登录别的服务器，点「更换服务器」。原来的账号仍留在这台 Mac 上，随时切回。"
        }
    }
}

/// 账号密码表单：用户名、密码（初始化时再加确认密码）、出错说明、主按钮。
/// 回车：在用户名里跳到密码，在最后一格里提交；主按钮也是窗口的默认按钮。
struct MacPasswordForm: View {
    let target: MacSignInTarget
    @Binding var setup: Bool
    var onSignedIn: (() -> Void)?

    private enum Field: Hashable {
        case username, password, confirm
    }

    /// UI 自动化测试时关掉系统密码自动填充：「存储密码？」弹层会挡住后续操作（同 iPhone 版）
    private static let autofill = !ProcessInfo.processInfo.arguments.contains("--ui-testing")

    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                TextField("用户名", text: $username, prompt: Text(setup ? "管理员用户名（至少 3 个字符）" : "用户名"))
                    .textContentType(Self.autofill ? .username : nil)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("mac-signin-username")
                SecureField("密码", text: $password, prompt: Text(setup ? "密码（至少 8 位）" : "密码"))
                    .textContentType(Self.autofill ? (setup ? .newPassword : .password) : nil)
                    .focused($focus, equals: .password)
                    .onSubmit { if setup { focus = .confirm } else { submit() } }
                    .accessibilityIdentifier("mac-signin-password")
                if setup {
                    SecureField("确认密码", text: $confirm, prompt: Text("再输一遍密码"))
                        .textContentType(Self.autofill ? .newPassword : nil)
                        .focused($focus, equals: .confirm)
                        .onSubmit(submit)
                        .accessibilityIdentifier("mac-signin-confirm")
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .autocorrectionDisabled()

            if let error {
                MacWelcomeError(message: error)
            }

            Button(action: submit) {
                MacWelcomeButtonLabel(title: buttonTitle, busy: busy)
            }
            .macWelcomePrimary()
            .disabled(busy || !filled)
            .padding(.top, 4)
            .accessibilityIdentifier("mac-signin-submit")
        }
        .onAppear {
            if username.isEmpty, let name = target.username { username = name }
            focus = username.isEmpty ? .username : .password
        }
    }

    private var filled: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && (!setup || !confirm.isEmpty)
    }

    private var buttonTitle: String {
        if setup { return busy ? "创建中…" : "创建账号并进入" }
        return busy ? "正在连接…" : "登录"
    }

    private func submit() {
        guard !busy, filled else { return }
        let name = username.trimmingCharacters(in: .whitespaces)
        if setup {
            // 与 Web /setup 相同的前端校验，后端仍会再校验一次
            if name.count < 3 { error = "用户名至少 3 个字符"; focus = .username; return }
            if password.count < 8 { error = "密码至少 8 位，建议混用字母与数字"; focus = .password; return }
            if password != confirm { error = "两次输入的密码不一致"; focus = .confirm; return }
        }
        error = nil
        busy = true
        let server = target.server
        Task {
            defer { busy = false }
            do {
                if setup {
                    try await model.createAdmin(on: server, username: name, password: password)
                    onSignedIn?()
                } else if try await model.signIn(to: server, username: name, password: password) == .needsSetup {
                    // 登录时才发现服务器是全新的：原地切到初始化，补一个确认密码
                    setup = true
                    focus = .confirm
                } else {
                    onSignedIn?()
                }
            } catch AppModel.ConnectError.alreadyInitialized {
                // 别的设备抢先完成了初始化：退回普通登录
                setup = false
                self.error = AppModel.ConnectError.alreadyInitialized.localizedDescription
            } catch {
                self.error = error.localizedDescription
                focus = .password
            }
        }
    }
}
