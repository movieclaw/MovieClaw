import SwiftUI

/// 欢迎页（docs/design/tvos-app.md §5）：没有登录中的账号时出现。与 iPhone 版、网页同一套星空与台词
/// （`CosmosBackdrop`、`WelcomeScene`，在 Shared/Welcome），按 `AppModel.phase` 给不同的卡片：
///
/// | 状态 | 电视上给什么 |
/// |---|---|
/// | 第一次使用（needsServer） | 片名 + 台词 +「连接服务器」→ 找服务器 → 登录 |
/// | 账号都退出了 / 登录过期（needsLogin） | 登录卡片（服务器沿用上次的；过期时用户名已预填） |
/// | 服务器是全新的（needsSetup） | 请在网页上完成初始化（在电视上建管理员要输两遍密码，不划算） |
/// | 当前服务器没有账号了、别处还有（chooseAccount） | 选择账号 |
/// | 冷启动连不上（unreachable） | 原因 + 重试 / 换服务器 / 切换账号 |
///
/// 登录卡片里的输入框标注了用户名 / 密码类型：附近的 iPhone 会弹出「用 iPhone 键盘输入」并可自动填充。
struct TVWelcomeView: View {
    @Environment(AppModel.self) private var model

    /// 本页内的步骤：介绍页 → 找服务器 → 登录
    enum Step: Equatable {
        case intro
        case server
        case signIn(ServerAddress)
    }

    @State private var step: Step = .intro
    @State private var scenes = WelcomeScene.all.shuffled()
    @State private var sceneIndex = 0

    var body: some View {
        ZStack {
            CosmosBackdrop(lit: true, dimmed: step != .intro)
                .ignoresSafeArea()
            content
                .padding(TVMetrics.edge)
        }
        .onAppear(perform: syncWithPhase)
        .onChange(of: model.phase) { _, _ in syncWithPhase() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-welcome")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .needsSetup:
            TVWelcomeCard(title: "这台服务器还没初始化", message: "请先在电脑或手机的浏览器里打开 \(model.server?.displayString ?? "服务器地址")，创建管理员账号，再回到这里登录。") {
                Button("我已完成，重新连接") { Task { await model.reconnect() } }
                Button("换一台服务器") { step = .server }
            }
        case .unreachable:
            TVWelcomeCard(title: "连不上服务器", message: model.launchError ?? "请检查网络，或确认服务器正在运行。") {
                Button("重试") { Task { await model.reconnect() } }
                    .accessibilityIdentifier("tv-welcome-retry")
                Button("换一台服务器") { step = .server }
                if !model.accountsOnOtherServers.isEmpty {
                    Button("切换到其他账号") { step = .intro }
                }
            }
        case .chooseAccount:
            TVAccountChooser(accounts: model.accountsOnOtherServers, title: "选择账号") {
                step = .server
            }
        default:
            switch step {
            case .intro:
                intro
            case .server:
                TVServerPicker { address in step = .signIn(address) }
            case let .signIn(address):
                TVSignInStep(server: address, prefilledUsername: model.expiredUsername, expired: model.expiredUsername != nil) {
                    step = .server
                }
            }
        }
    }

    /// 介绍页：片名 + 一句台词（像电影字幕一样轮播）+ 主按钮
    private var intro: some View {
        VStack(spacing: 60) {
            Spacer()
            Text("MovieClaw")
                .font(.welcomeSerif(size: 110))
                .tracking(6)
            if !scenes.isEmpty {
                let scene = scenes[sceneIndex % scenes.count]
                VStack(spacing: 18) {
                    Text(scene.line)
                        .font(.welcomeSerif(size: 40))
                        .multilineTextAlignment(.center)
                    if let original = scene.original {
                        Text(original)
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text("《\(scene.film)》\(scene.year)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .id(scene.id)
                .transition(.opacity)
                .frame(height: 260)
            }
            Spacer()
            Button(model.server == nil ? "连接服务器" : "登录") {
                if let server = model.server {
                    step = .signIn(server)
                } else {
                    step = .server
                }
            }
            .font(.headline)
            .accessibilityIdentifier("tv-welcome-start")
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
        // 台词 8 秒换一句（同 iPhone 版的轮播节奏）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                withAnimation(.easeInOut(duration: 1)) { sceneIndex += 1 }
            }
        }
    }

    /// 登录过期（预填了用户名）直接进登录卡片；其余从介绍页开始
    private func syncWithPhase() {
        if model.phase == .needsLogin, model.expiredUsername != nil, let server = model.server {
            step = .signIn(server)
        }
    }
}

/// 欢迎页上的一张说明卡：标题、说明、一排按钮
struct TVWelcomeCard<Buttons: View>: View {
    let title: String
    let message: String
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(title)
                .font(.welcomeSerif(size: 52))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 30) {
                buttons()
            }
            .padding(.top, 12)
        }
        .padding(60)
        .frame(width: 1100, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 48))
        .focusSection()
    }
}

/// 找服务器：局域网自动发现（与 iPhone 版同一个 `ServerDiscovery`）+ 本机登录过的 + 手动输入
struct TVServerPicker: View {
    let onPick: (ServerAddress) -> Void

    @Environment(AppModel.self) private var model
    @State private var discovering = true
    @State private var found: ServerDiscovery.Found?
    @State private var manual = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text("连接服务器")
                .font(.welcomeSerif(size: 52))
            Text("服务器地址就是在浏览器里打开 MovieClaw 时地址栏里的那一串。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if discovering {
                HStack(spacing: 18) {
                    ProgressView()
                    Text("正在局域网里寻找 MovieClaw…").foregroundStyle(.secondary)
                }
            }
            if let found {
                Button {
                    onPick(found.address)
                } label: {
                    Label("连接局域网里的「\(found.name)」· \(found.address.displayString)", systemImage: "wifi")
                }
                .accessibilityIdentifier("tv-server-found")
            } else if !discovering {
                HStack(spacing: 20) {
                    Text("没在局域网里找到服务器").foregroundStyle(.secondary)
                    Button("重新查找") { Task { await discover() } }
                }
            }

            let recent = model.savedServers.filter { $0.address != found?.address }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("登录过的服务器").font(.headline)
                    HStack(spacing: 24) {
                        ForEach(recent) { saved in
                            Button(saved.address.displayString) { onPick(saved.address) }
                        }
                    }
                }
                .focusSection()
            }

            HStack(spacing: 24) {
                TextField("手动输入地址，例如 http://192.168.0.100:3000", text: $manual)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .frame(width: 900)
                    .onSubmit(submitManual)
                    .accessibilityIdentifier("tv-server-address")
                Button("连接", action: submitManual)
                    .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("tv-server-connect")
            }
            .focusSection()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(60)
        .frame(width: 1400, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 48))
        .task { await discover() }
    }

    private func discover() async {
        // UI 自动化测试不做自动发现（同 iPhone 版）：用例自己输入地址
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else {
            discovering = false
            return
        }
        discovering = true
        found = await ServerDiscovery.findFirst()
        discovering = false
    }

    private func submitManual() {
        do {
            onPick(try ServerAddress(parsing: manual.trimmingCharacters(in: .whitespaces)))
            error = nil
        } catch {
            self.error = "地址格式不对：请填写完整地址，例如 http://192.168.0.100:3000"
        }
    }
}

/// 登录这一步：默认扫码（`TVPairingLogin`），可以改用账号密码（`TVSignInForm`）
struct TVSignInStep: View {
    let server: ServerAddress
    let prefilledUsername: String?
    let expired: Bool
    let onChangeServer: () -> Void

    @State private var usePassword = false

    var body: some View {
        if usePassword {
            TVSignInForm(server: server, prefilledUsername: prefilledUsername, expired: expired,
                         onUseQRCode: { usePassword = false }, onChangeServer: onChangeServer)
        } else {
            TVPairingLogin(server: server) { usePassword = true }
        }
    }
}

/// 账号密码登录（兜底方式）：输入框标注了类型，附近的 iPhone 会弹出「用 iPhone 键盘输入」并可自动填充
struct TVSignInForm: View {
    let server: ServerAddress
    let prefilledUsername: String?
    let expired: Bool
    let onUseQRCode: () -> Void
    let onChangeServer: () -> Void

    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    /// UI 自动化测试时关掉系统密码自动填充：「存储密码？」弹层会挡住后续操作（同 iPhone 版）
    private static let autofill = !ProcessInfo.processInfo.arguments.contains("--ui-testing")

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(expired ? "重新登录" : "登录 MovieClaw")
                .font(.welcomeSerif(size: 52))
            HStack(spacing: 20) {
                Label(server.displayString, systemImage: "server.rack")
                    .foregroundStyle(.secondary)
                Button("更换", action: onChangeServer)
                    .accessibilityIdentifier("tv-signin-change-server")
            }
            if expired, let prefilledUsername {
                Text("「\(prefilledUsername)」的登录已失效，请重新输入密码。")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
            }
            TextField("用户名", text: $username)
                .textContentType(Self.autofill ? .username : nil)
                .autocorrectionDisabled()
                .accessibilityIdentifier("tv-signin-username")
            SecureField("密码", text: $password)
                .textContentType(Self.autofill ? .password : nil)
                .onSubmit(submit)
                .accessibilityIdentifier("tv-signin-password")
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tv-signin-error")
            }
            HStack(spacing: 24) {
                Button(action: submit) {
                    HStack(spacing: 12) {
                        if busy { ProgressView() }
                        Text(busy ? "正在连接…" : "登录")
                    }
                }
                .disabled(busy || username.isEmpty || password.isEmpty)
                .accessibilityIdentifier("tv-signin-submit")
                Button("改用扫码登录", action: onUseQRCode)
            }
        }
        .padding(60)
        .frame(width: 1100, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 48))
        .focusSection()
        .onAppear {
            if username.isEmpty, let prefilledUsername { username = prefilledUsername }
        }
    }

    private func submit() {
        guard !busy, !username.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await model.signIn(to: server, username: username.trimmingCharacters(in: .whitespaces), password: password)
                if result == .needsSetup {
                    error = "这台服务器还没初始化：请先在浏览器里打开 \(server.displayString) 创建管理员账号。"
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// 选择账号：本机登录过的账号（可跨服务器），点一下就进，不用密码（同 iPhone 版的切换机制）
struct TVAccountChooser: View {
    let accounts: [SavedAccount]
    let title: String
    let onAddAccount: () -> Void

    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        VStack(spacing: 60) {
            Text(title)
                .font(.welcomeSerif(size: 64))
            HStack(spacing: 60) {
                ForEach(accounts) { saved in
                    TVProfileButton(account: saved.account, server: saved.server) {
                        Task {
                            do {
                                try await model.switchAccount(to: saved.account.username, on: saved.server)
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }
                Button(action: onAddAccount) {
                    VStack(spacing: 20) {
                        Image(systemName: "plus")
                            .font(.system(size: 64, weight: .light))
                            .frame(width: 220, height: 220)
                            .background(.white.opacity(0.1), in: .circle)
                        Text("添加账号").font(.headline)
                    }
                }
                .buttonStyle(.borderless)
            }
            .focusSection()
            if let error {
                Text(error).foregroundStyle(Theme.danger)
            }
        }
    }
}

/// 一个账号的大头像按钮（「谁在看」与选择账号共用）：圆形头像，下面昵称与服务器
struct TVProfileButton: View {
    let account: API.AccountView
    let server: ServerAddress
    var current = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 20) {
                TVProfileAvatarFocus {
                    // 获得焦点时头像放大 1.12 倍，按放大后的宽取图
                    TVAvatar(url: server.imageURL(AvatarURL.tagged(account.avatarUrl, username: account.username),
                                                  width: ImageWidth.points(220, zoom: TVMetrics.avatarFocusZoom)),
                             name: account.nickname, size: 220)
                }
                VStack(spacing: 6) {
                    Text(account.nickname).font(.headline)
                    // 从左上角头像打开时标出当前是谁
                    Text(current ? "正在使用 · \(server.hostLabel)" : server.hostLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(TVProfileButtonStyle())
        .accessibilityIdentifier("tv-profile-\(account.username)")
    }
}

/// 选人页大头像的按钮样式（同 Netflix 选人页）：获得焦点的那个整体提亮、头像放大套白边；其余压暗一点。
/// 不用系统的 `.borderless`：它只给能找到的 `Image` 加抬起效果，首字母头像、网络图头像都没有反应
struct TVProfileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .environment(\.tvProfileFocused, focused)
                .opacity(focused ? 1 : 0.65)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.2), value: focused)
        }
    }
}

extension EnvironmentValues {
    /// 所在的选人按钮获得了焦点（`TVProfileButtonStyle` 往下传，头像据此放大）
    @Entry var tvProfileFocused = false
}

/// 套在选人按钮的头像外面：获得焦点时放大、白边、投影（只动头像，下面的字不跟着放大）
struct TVProfileAvatarFocus<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.tvProfileFocused) private var focused

    var body: some View {
        content()
            .overlay {
                Circle().strokeBorder(.white, lineWidth: focused ? 6 : 0)
            }
            .scaleEffect(focused ? TVMetrics.avatarFocusZoom : 1)
            .shadow(color: .black.opacity(focused ? 0.55 : 0), radius: 28, y: 14)
            .animation(.easeOut(duration: 0.2), value: focused)
    }
}

/// 圆形头像：有图画图，没有就画昵称首字（同 iPhone 版 initials 口径）
struct TVAvatar: View {
    let url: URL?
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
            Text(Self.initials(name))
                .font(.system(size: size * 0.38, weight: .semibold))
            if let url {
                RemoteImage(url: url, placeholderText: "")
                    .clipShape(.circle)
            }
        }
        .frame(width: size, height: size)
    }

    static func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        if first.unicodeScalars.first.map({ (0x4E00 ... 0x9FFF).contains($0.value) }) == true {
            return String(first)
        }
        return String(trimmed.prefix(2)).uppercased()
    }
}
