import SwiftUI

/// 打开批准流程的参数（Router.deviceApproval）
struct DeviceApprovalLaunch: Identifiable, Hashable {
    let id = UUID()
    /// 已知的配对码（站内链接 /activate?code=…）；nil = 让人扫码或手输
    var code: String?
    /// 二维码里的服务器（主机:端口），查不到请求时用来提示「设备连的可能是另一台服务器」
    var host: String?
    /// 一打开就是相机（「我的」页右上角的扫码钮）
    var scanFirst = false
}

/// 批准设备登录（对应网页 /activate，见 docs/design/login-devices.md §4）。全屏呈现，一气呵成：
/// 相机取景 → 扫到后换成登录页同款的星空，底部升起一张液态玻璃卡片：设备、配对码、将获得的权限、
/// 以谁的身份批准，以及「批准登录 / 拒绝」→ 卡片换成结果。
///
/// 为什么批准 / 拒绝放在卡片里、不放导航栏右上角：导航栏的「取消 / 完成」是编辑类表单的确认
/// （日历「新建日程」的「添加」）；这里是一个有安全后果的决定，苹果自家的同类场景——iPhone 帮
/// Apple TV 登录、AirPods 配对——都是底部卡片里的大按钮，拇指够得着、看完信息顺手按。
/// 扫到码也不自动批准：人必须看过卡片再按，这是防钓鱼的那道闸（服务端也只按配对码查一条请求）。
///
/// 入口：「我的」页右上角扫码（scanFirst）、「设置 → 设备」的「批准新设备登录」（手输或再扫码）、
/// 站内链接 /activate?code=…（以及旧的 /settings/devices?code=…）。
struct DeviceApprovalFlow: View {
    let launch: DeviceApprovalLaunch

    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @State private var stage: Stage
    @State private var code: String
    @State private var host: String?
    @State private var busy = false
    @State private var error: String?
    @State private var lit = false
    @FocusState private var codeFocused: Bool

    enum Stage: Equatable {
        case scanning
        case input
        case looking
        case request(API.DeviceRequestView)
        case approved(name: String)
        case denied
    }

    init(launch: DeviceApprovalLaunch) {
        self.launch = launch
        _stage = State(initialValue: launch.scanFirst ? .scanning : (launch.code?.isEmpty == false ? .looking : .input))
        _code = State(initialValue: launch.code ?? "")
        _host = State(initialValue: launch.host)
    }

    var body: some View {
        ZStack {
            if stage == .scanning {
                PairingScannerScreen(
                    onScanned: { scanned in
                        host = scanned.host
                        code = scanned.code
                        withAnimation(.smooth(duration: 0.35)) { stage = .looking }
                        Task { await lookUp() }
                    },
                    onManualEntry: { withAnimation(.smooth(duration: 0.35)) { stage = .input } }
                )
                .transition(.opacity)
            } else {
                approvalScene.transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if stage == .looking { await lookUp() }
        }
    }

    // MARK: 星空 + 底部卡片

    private var approvalScene: some View {
        ZStack(alignment: .bottom) {
            CosmosBackdrop(lit: lit, dimmed: false).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("关闭")
                    .accessibilityIdentifier("device-approval-close")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                Spacer(minLength: 24)
                card
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { lit = true } }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch stage {
            case .scanning, .input: inputContent
            case .looking: lookingContent
            case let .request(request): requestContent(request)
            case let .approved(name):
                resultContent(approved: true, message: "「\(name)」会在几秒内自动登录，回到那台设备上继续就好。")
            case .denied:
                resultContent(approved: false, message: "这台设备不会登录。如果它其实是你的，让它重新发起配对即可。")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 36))
        .animation(.smooth(duration: 0.35), value: stage)
    }

    // MARK: 输入配对码

    @ViewBuilder
    private var inputContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("批准设备登录").font(.title2.weight(.bold))
            Text("输入 Apple TV、Mac、命令行或转码器上显示的配对码，或者扫它旁边的二维码。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 8) {
            TextField("MCLW-XXXX", text: $code)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .tracking(3)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                // 配对码只有字母数字：直接给英文键盘，免得中文输入法先出候选词
                .keyboardType(.asciiCapable)
                .submitLabel(.go)
                .onSubmit { Task { await lookUp() } }
                .focused($codeFocused)
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 18))
                .accessibilityIdentifier("pairing-code")
                // 手输进来时直接弹键盘（等卡片升起再聚焦，免得动画和键盘挤在一起）；带着码进来的不抢
                .task {
                    guard code.isEmpty else { return }
                    try? await Task.sleep(for: .milliseconds(450))
                    codeFocused = true
                }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger).accessibilityIdentifier("device-approval-error")
            }
        }
        VStack(spacing: 10) {
            Button { Task { await lookUp() } } label: { Text("继续").frame(maxWidth: .infinity) }
                .prominentCardButton()
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("pairing-lookup")
            Button {
                error = nil
                withAnimation(.smooth(duration: 0.35)) { stage = .scanning }
            } label: {
                Label("扫描二维码", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityIdentifier("device-approval-scan")
        }
        accountLine
    }

    private var lookingContent: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text("正在查找 \(code) 的请求…").font(.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    // MARK: 审批

    @ViewBuilder
    private func requestContent(_ request: API.DeviceRequestView) -> some View {
        let grant = DeviceText.grant(request.clientType, isAdmin: permissions.isAdmin)
        // 转码器只能由超管批准（转码占用的是整台服务器的资源）：成员看到时说清原因、不给批准按钮
        let blocked = request.requiresAdmin && !permissions.isAdmin
        HStack(spacing: 14) {
            Image(systemName: Self.symbol(request.clientType))
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.1), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.clientName).font(.title3.weight(.semibold))
                Text(request.platform ?? DeviceText.clientType(request.clientType))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(request.userCode)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .tracking(5)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("device-request-code")
            // 配对码是这张卡真正的安全控制：大号等宽字，让人真的去和设备屏幕逐字比对
            Text("先核对与设备屏幕上显示的配对码完全一致")
                .font(.footnote).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(grant.title).font(.subheadline.weight(.semibold))
            Text(grant.body).font(.footnote).foregroundStyle(.secondary)
            // 来源地址认得出时才写；桥接网络的容器只看得到网桥网关，那时不如不写，判断依据就是配对码
            if !request.sourceIp.isEmpty {
                Text("来源 \(request.sourceIp)").font(.footnote.monospaced()).foregroundStyle(.tertiary).padding(.top, 2)
            }
        }
        if blocked {
            Text("转码器只能由管理员批准：请把这个配对码告诉管理员，让他在网页或 App 的批准页输入。")
                .font(.footnote).foregroundStyle(Theme.warning)
        }
        if let error {
            Text(error).font(.footnote).foregroundStyle(Theme.danger)
        }
        VStack(spacing: 10) {
            if !blocked {
                Button { Task { await decide(request, approve: true) } } label: {
                    Label("批准登录", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .prominentCardButton()
                .accessibilityIdentifier("device-approve-\(request.userCode)")
            }
            Button(role: .destructive) { Task { await decide(request, approve: false) } } label: {
                Text("拒绝").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityIdentifier("device-deny-\(request.userCode)")
        }
        .disabled(busy)
        accountLine
    }

    /// 「以谁的身份批准」：批准的后果是设备登录成这个账号，必须写明
    private var accountLine: some View {
        let name = model.session.map { $0.nickname.isEmpty ? $0.username : $0.nickname } ?? "当前账号"
        return Text("以「\(name)」的身份批准 · 换账号请先在「我的」页切换")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    // MARK: 结果

    @ViewBuilder
    private func resultContent(approved: Bool, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(approved ? Theme.success : Theme.danger)
            Text(approved ? "已批准" : "已拒绝").font(.title2.weight(.bold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-approval-result")
        Button { dismiss() } label: { Text("完成").frame(maxWidth: .infinity) }
            .prominentCardButton()
            .accessibilityIdentifier("device-approval-done")
    }

    // MARK: 动作

    private func lookUp() async {
        guard let target = PairingQRCode.normalize(code) else {
            error = "配对码形如 MCLW-7F3K，请对照设备上显示的重新输入。"
            stage = .input
            return
        }
        code = target
        error = nil
        stage = .looking
        do {
            let request = try await api.authDevicesRequest(userCode: target)
            stage = .request(request)
        } catch let failure as APIError where failure.status == 404 {
            error = "没有找到配对码 \(target) 的请求：请核对设备上显示的码，或让设备重新发起（配对码 5 分钟内有效）。" + serverMismatchHint
            stage = .input
        } catch {
            self.error = error.localizedDescription
            stage = .input
        }
    }

    /// 二维码来自另一台服务器时补一句：电视连的是 A，手机当前账号在 B，在 B 上当然查不到
    private var serverMismatchHint: String {
        guard let host, let origin = model.server?.origin, let current = origin.host else { return "" }
        let mine = origin.port.map { "\(current):\($0)" } ?? current
        guard mine.lowercased() != host.lowercased() else { return "" }
        return "二维码来自 \(host)，而当前账号连的是 \(mine)；如果那台设备连的是另一台服务器，请先在「我的」页切换到那台服务器上的账号。"
    }

    private func decide(_ request: API.DeviceRequestView, approve: Bool) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if approve {
                try await api.authDevicesApprove(userCode: request.userCode)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                stage = .approved(name: request.clientName)
            } else {
                try await api.authDevicesDeny(userCode: request.userCode)
                stage = .denied
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func symbol(_ clientType: String) -> String {
        switch clientType {
        case "tvos": "appletv.fill"
        case "macos": "macwindow"
        case "cli": "terminal.fill"
        case "worker": "cpu"
        default: "desktopcomputer"
        }
    }
}

private extension View {
    /// 卡片里的主按钮：亮银实底 + 深色字（同登录页的主按钮），通栏大号
    func prominentCardButton() -> some View {
        buttonStyle(.glassProminent)
            .tint(Theme.accentStrong)
            .foregroundStyle(Color.black.opacity(0.85))
            .controlSize(.large)
            .fontWeight(.semibold)
    }
}
