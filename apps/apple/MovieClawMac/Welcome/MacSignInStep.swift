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
    @Environment(\.macWelcomeCardStyle) private var style
    @Environment(\.macDialogCancel) private var cancel

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
            if style == .glass {
                serverRow
            }

            if !setup {
                Picker(String(localized: .authLoginMethod), selection: $method) {
                    Text(String(localized: .authLoginPasswordMethod)).tag(Method.password)
                    Text(String(localized: .authLoginQrMethod)).tag(Method.qrCode)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("mac-signin-method")
            }

            if style == .dialog {
                // 对话框：服务器与下面的用户名、密码排成同一列标签
                dialogServerRow
                    .padding(.top, 4)
            }

            loginForm

            if style == .dialog, method == .qrCode, !setup, let cancel {
                MacDialogFooter {
                    Spacer(minLength: 0)
                    Button(String(localized: .commonCancel), action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
            }

            if let onSwitchAccount {
                Button(String(localized: .authAccountsSwitchSaved), action: onSwitchAccount)
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
            Button(String(localized: .authServerChangeServer), action: onChangeServer)
                .buttonStyle(.link)
                .font(.system(size: 12))
                .accessibilityIdentifier("mac-signin-change-server")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .macWelcomeInset()
    }

    /// 对话框排版的服务器一行：「服务器  192.168.1.10:3000  更换…」
    private var dialogServerRow: some View {
        MacDialogRow(label: String(localized: .authInputServer)) {
            Text(target.server.displayString)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(String(localized: .authServerChangeEllipsis), action: onChangeServer)
                .buttonStyle(.link)
                .accessibilityIdentifier("mac-signin-change-server")
        }
    }

    private var title: String {
        if setup { return String(localized: .authSetupServer) }
        if method == .qrCode { return String(localized: .authPairingScan) }
        if target.expired { return String(localized: .authLoginAgain) }
        return purpose == .addAccount ? String(localized: .authAccountsAdd) : String(localized: .authLoginTitle)
    }

    private var subtitle: String {
        if setup {
            return String(localized: .authSetupIntro)
        }
        if method == .qrCode {
            return String(localized: .authPairingMacHint)
        }
        if target.expired, let name = target.username {
            return String(localized: .authLoginExpiredMac(name))
        }
        switch purpose {
        case .welcome: return String(localized: .authLoginCredentialsHint)
        case .addAccount: return String(localized: .authAccountsAddMacHint)
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

    @Environment(\.macWelcomeCardStyle) private var style
    @Environment(\.macDialogCancel) private var cancel

    var body: some View {
        Group {
            switch style {
            case .glass: glassBody
            case .dialog: dialogBody
            }
        }
        .onAppear {
            if username.isEmpty, let name = target.username { username = name }
            focus = username.isEmpty ? .username : .password
        }
    }

    /// 欢迎页：三个大号输入框叠放，下面通栏主按钮
    private var glassBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                usernameField
                passwordField
                if setup {
                    confirmField
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
    }

    /// 对话框：标签右对齐的表单行（与上面的「服务器」一行同一列），右下角「取消 / 登录」
    private var dialogBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                MacDialogRow(label: String(localized: .authInputUsername)) { usernameField }
                MacDialogRow(label: String(localized: .authInputPassword)) { passwordField }
                if setup {
                    MacDialogRow(label: String(localized: .authInputConfirmPassword)) { confirmField }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()

            if let error {
                MacWelcomeError(message: error)
                    .padding(.leading, MacWelcomeMetrics.dialogLabelWidth + 10)
            }

            MacDialogFooter {
                Spacer(minLength: 0)
                if let cancel {
                    Button(String(localized: .commonCancel), action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button(action: submit) {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(buttonTitle)
                    }
                    .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || !filled)
                .accessibilityIdentifier("mac-signin-submit")
            }
            .padding(.top, 8)
        }
    }

    private var usernameField: some View {
        TextField(String(localized: .authInputUsername), text: $username, prompt: Text(setup ? String(localized: .authInputAdminUsernameLong) : String(localized: .authInputUsername)))
            .textContentType(Self.autofill ? .username : nil)
            .focused($focus, equals: .username)
            .onSubmit { focus = .password }
            .accessibilityIdentifier("mac-signin-username")
    }

    private var passwordField: some View {
        SecureField(String(localized: .authInputPassword), text: $password, prompt: Text(setup ? String(localized: .authInputPasswordMinimum) : String(localized: .authInputPassword)))
            .textContentType(Self.autofill ? (setup ? .newPassword : .password) : nil)
            .focused($focus, equals: .password)
            .onSubmit { if setup { focus = .confirm } else { submit() } }
            .accessibilityIdentifier("mac-signin-password")
    }

    private var confirmField: some View {
        SecureField(String(localized: .authInputConfirmPassword), text: $confirm, prompt: Text(String(localized: .authInputRepeatPassword)))
            .textContentType(Self.autofill ? .newPassword : nil)
            .focused($focus, equals: .confirm)
            .onSubmit(submit)
            .accessibilityIdentifier("mac-signin-confirm")
    }

    private var filled: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && (!setup || !confirm.isEmpty)
    }

    private var buttonTitle: String {
        if setup { return busy ? String(localized: .authSetupCreating) : String(localized: .authSetupCreateAndEnter) }
        return busy ? String(localized: .authServerConnecting) : String(localized: .authLoginSubmit)
    }

    private func submit() {
        guard !busy, filled else { return }
        let name = username.trimmingCharacters(in: .whitespaces)
        if setup {
            // 与 Web /setup 相同的前端校验，后端仍会再校验一次
            if name.count < 3 { error = String(localized: .authValidationUsernameShort); focus = .username; return }
            if password.count < 8 { error = String(localized: .authValidationPasswordShort); focus = .password; return }
            if password != confirm { error = String(localized: .authValidationPasswordMismatch); focus = .confirm; return }
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
