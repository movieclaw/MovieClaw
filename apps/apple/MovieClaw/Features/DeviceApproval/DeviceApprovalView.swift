import SwiftUI

/// 批准设备登录（对应网页 /activate，见 docs/design/login-devices.md §4）。
///
/// 独立成页而不是「设置 → 设备」里的一块：批准是拿着一段配对码来做的一次性的事——扫电视上的二维码
/// （或输入配对码）→ 核对审批卡 → 批准 → 回到那台设备上。它和「管理已登录的设备」是两件事。
/// 入口：「我的」页右上角的扫码按钮（扫到后带着配对码进来）、「设置 → 设备」里的「批准新设备登录」、
/// 站内链接 /activate?code=…（以及旧的 /settings/devices?code=…）。
///
/// 防钓鱼：只按配对码查一条请求（服务端没有「列出全部待批准请求」的接口）；扫到码也不自动批准，
/// 人必须看过审批卡再按。批准的后果是「谁批准，设备就登录成谁」，所以写明当前账号。
struct DeviceApprovalView: View {
    var presetCode: String?
    /// 扫到的二维码里的服务器（主机:端口）：查不到请求时用来提示「设备连的可能是另一台服务器」
    var scannedHost: String?

    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @State private var code = ""
    @State private var host: String?
    @State private var request: API.DeviceRequestView?
    @State private var looking = false
    @State private var busy = false
    @State private var error: String?
    @State private var outcome: Outcome?
    @State private var scanning = false

    enum Outcome: Equatable {
        case approved(name: String)
        case denied
    }

    var body: some View {
        Group {
            if let outcome {
                resultView(outcome)
            } else {
                form
            }
        }
        .navigationTitle("批准设备登录")
        .navigationBarTitleDisplayMode(.inline)
        .appBackground()
        .task {
            host = scannedHost
            if let presetCode, !presetCode.isEmpty {
                code = presetCode
                await lookUp()
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            PairingScannerScreen(
                onScanned: { scanned in
                    scanning = false
                    host = scanned.host
                    code = scanned.code
                    Task { await lookUp() }
                },
                onManualEntry: { scanning = false }
            )
        }
    }

    private var form: some View {
        List {
            if let error {
                Section { SettingsNotice(text: error) }
            }
            if let request {
                Section {
                    DeviceApprovalCard(
                        request: request,
                        canApprove: permissions.isAdmin || !request.requiresAdmin,
                        isAdmin: permissions.isAdmin,
                        busy: busy,
                        onApprove: { Task { await decide(request, approve: true) } },
                        onDeny: { Task { await decide(request, approve: false) } }
                    )
                } footer: {
                    accountFooter
                }
                Section {
                    Button("暂不处理，换一个配对码") { reset() }
                        .disabled(busy)
                        .accessibilityIdentifier("device-approval-reset")
                }
            } else {
                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label("扫描二维码", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("device-approval-scan")
                } footer: {
                    Text("Apple TV、命令行（mclaw login）或 Mac 转码器发起配对后，屏幕上会显示一个二维码和一段形如 MCLW-7F3K 的配对码。")
                }
                Section {
                    HStack(spacing: 10) {
                        TextField("MCLW-XXXX", text: $code)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await lookUp() } }
                            .accessibilityIdentifier("pairing-code")
                        Button(looking ? "查询中…" : "查询") { Task { await lookUp() } }
                            .buttonStyle(.glass)
                            .disabled(looking || code.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("pairing-lookup")
                    }
                } header: {
                    Text("或者输入配对码")
                } footer: {
                    accountFooter
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// 「以谁的身份批准」：批准的后果是设备登录成这个账号，必须写明
    private var accountFooter: some View {
        let name = model.session.map { $0.nickname.isEmpty ? $0.username : $0.nickname } ?? "当前账号"
        return Text("将以「\(name)」的身份批准。要用别的账号批准，先在「我的」页切换账号。")
    }

    private func resultView(_ outcome: Outcome) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: outcome == .denied ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(outcome == .denied ? Theme.danger : Theme.success)
            switch outcome {
            case let .approved(name):
                Text("已批准").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                Text("「\(name)」会在几秒内自动登录，回到那台设备上继续就好。")
            case .denied:
                Text("已拒绝").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                Text("这台设备不会登录。如果它其实是你的，让它重新发起配对即可。")
            }
            Spacer()
            VStack(spacing: 12) {
                Button { dismiss() } label: { Text("完成").frame(maxWidth: .infinity) }
                    .settingsProminentButton()
                    .controlSize(.large)
                    .accessibilityIdentifier("device-approval-done")
                Button { reset() } label: { Text("批准另一台设备").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            .font(.body.weight(.semibold))
            .padding(.bottom, 24)
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textMuted)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-approval-result")
    }

    private func reset() {
        request = nil
        outcome = nil
        error = nil
        code = ""
        host = nil
    }

    private func lookUp() async {
        guard let target = PairingQRCode.normalize(code) else {
            error = "配对码形如 MCLW-7F3K，请对照设备上显示的重新输入。"
            return
        }
        code = target
        looking = true
        error = nil
        defer { looking = false }
        do {
            request = try await api.authDevicesRequest(userCode: target)
        } catch let failure as APIError where failure.status == 404 {
            error = "没有找到配对码 \(target) 的请求：请核对设备上显示的码，或让设备重新发起（配对码 5 分钟内有效）。" + serverMismatchHint
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 二维码来自另一台服务器时补一句：电视连的是 A，手机当前账号在 B，在 B 上当然查不到
    private var serverMismatchHint: String {
        guard let host, let origin = model.server?.origin, let current = origin.host else { return "" }
        let mine = origin.port.map { "\(current):\($0)" } ?? current
        guard mine.lowercased() != host.lowercased() else { return "" }
        return "\n二维码来自 \(host)，而当前账号连的是 \(mine)。如果那台设备连的是另一台服务器，请先在「我的」页切换到那台服务器上的账号。"
    }

    private func decide(_ request: API.DeviceRequestView, approve: Bool) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if approve {
                try await api.authDevicesApprove(userCode: request.userCode)
                outcome = .approved(name: request.clientName)
            } else {
                try await api.authDevicesDeny(userCode: request.userCode)
                outcome = .denied
            }
            self.request = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 审批卡

/// 用户做决定的全部依据都在这张卡上；配对码大号等宽字，便于和设备屏幕逐字比对
struct DeviceApprovalCard: View {
    let request: API.DeviceRequestView
    let canApprove: Bool
    let isAdmin: Bool
    let busy: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        let grant = DeviceText.grant(request.clientType, isAdmin: isAdmin)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.clientName).font(.body.weight(.semibold))
                Text(request.userCode)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("device-request-code")
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("类型").foregroundStyle(Theme.textFaint)
                    Text(DeviceText.clientType(request.clientType)).foregroundStyle(Theme.textMuted)
                }
                if let platform = request.platform {
                    GridRow {
                        Text("系统").foregroundStyle(Theme.textFaint)
                        Text([platform, request.clientVersion.map { "版本 \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                GridRow {
                    Text("来源").foregroundStyle(Theme.textFaint)
                    if request.sourceIp.isEmpty {
                        // 桥接网络的容器看到的是网桥网关，与其给个误导地址不如直说，把判断依据推回配对码
                        Text("无法确定 \(Text("容器网络改写了源地址，请以配对码为准").font(.caption))").foregroundStyle(Theme.textFaint)
                    } else {
                        Text(request.sourceIp).font(.subheadline.monospaced()).foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                Text(grant.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(grant.body).font(.subheadline).foregroundStyle(Theme.textMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accentSoft, in: .rect(cornerRadius: 12))
            if canApprove {
                Text("请确认上面的配对码与设备上显示的完全一致。如果这不是你刚发起的操作，选择拒绝。")
                    .font(.caption).foregroundStyle(Theme.textFaint)
            } else {
                SettingsNotice(text: "转码器只能由管理员批准：请把这个配对码告诉管理员，让他在网页或 App 的批准页输入并批准。", tone: .warn)
            }
            HStack(spacing: 10) {
                Button("批准登录", systemImage: "checkmark", action: onApprove)
                    .settingsProminentButton()
                    .disabled(!canApprove)
                    .accessibilityIdentifier("device-approve-\(request.userCode)")
                Button("拒绝", systemImage: "xmark", action: onDeny)
                    .buttonStyle(.glass)
                    .tint(Theme.danger)
                    .accessibilityIdentifier("device-deny-\(request.userCode)")
            }
            .disabled(busy)
        }
        .padding(.vertical, 6)
    }
}
