import SwiftUI

/// 设置 → 设备（Web devices-section.tsx，设计见 docs/design/login-devices.md）。
///
/// 所有人都能进（成员看自己的设备），这一页承担四件事：
/// 1. **按配对码批准**：命令行、转码器发起配对后显示一段 `MCLW-XXXX`，在这里输入（链接带 `?code=` 时预填）
///    后只显示这一条请求。批准是防钓鱼的唯一一道人工闸：审批卡上的名称、类型、来源、配对码与「将获得」
///    的大白话权限说明就是用户做决定的全部依据。谁批准，令牌就是谁的；转码器只有超管能批；
/// 2. **我的设备**：登录着这个账号的浏览器、App、命令行、转码器与播放器，当前这台置顶；可以改名、注销。
///    注销是唯一的事后止损手段，注销即断——它正在播的片、正在跑的转码一并停止；
/// 3. **全部成员的设备**（超管）：多一列「属于谁」；
/// 4. **手工令牌**（超管）：给没人能按批准的环境（NAS 定时任务、CI、命令行模式的转码器）。明文只在创建
///    响应里出现一次，给出可直接粘贴的两行环境变量，关闭前二次确认。
struct DevicesSettingsView: View {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(\.routeQuery) private var routeQuery
    @Environment(Feedback.self) private var feedback
    @Environment(AppModel.self) private var model

    @State private var devices: Loadable<[API.LoginDeviceView]> = .loading
    @State private var showAll = false
    @State private var busy: String?
    @State private var error: String?

    // 按配对码批准
    @State private var code = ""
    @State private var request: API.DeviceRequestView?
    @State private var looking = false

    // 手工令牌
    @State private var tokenStage: TokenStage = .idle
    @State private var tokenName = ""
    @State private var tokenScope = "full"
    @State private var tokenNameError: String?
    @State private var creating = false
    @State private var created: API.ApiTokenCreatedView?
    @State private var externalUrl = ""

    enum TokenStage { case idle, form }

    var body: some View {
        List {
            if let error {
                Section { SettingsNotice(text: error) }
            }
            pairingSection
            if permissions.isAdmin {
                Section {
                    Picker("范围", selection: $showAll) {
                        Text("我的设备").tag(false)
                        Text("全部成员").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("devices-scope")
                }
            }
            devicesSections
            if permissions.isAdmin { manualTokenSection }
        }
        .scrollDismissesKeyboard(.immediately)
        .appBackground()
        .task(id: showAll) { await load() }
        // 在线状态会变（转码器连上 / 断开、别的设备刚用过）：页面开着时每 15 秒静默刷新一次
        .polling(every: 15) { await load() }
        .task {
            if let preset = routeQuery["code"], !preset.isEmpty {
                code = preset
                await lookUp()
            }
            // 对外访问地址：进入分区就先拉，等按下创建再拉会多等一个往返；拿不到就回落当前服务器地址
            if permissions.isAdmin, let config = try? await api.appShow() { externalUrl = config.externalUrl }
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            devices = .loaded(try await api.authDevicesList(all: showAll))
        } catch {
            if devices.value == nil { devices = .failed(error.localizedDescription) }
            self.error = error.localizedDescription
        }
    }

    // MARK: 按配对码批准

    @ViewBuilder
    private var pairingSection: some View {
        Section {
            if let request {
                ApprovalCard(
                    request: request,
                    canApprove: permissions.isAdmin || !request.requiresAdmin,
                    isAdmin: permissions.isAdmin,
                    busy: busy == request.userCode,
                    onApprove: { Task { await approve(request) } },
                    onDeny: { Task { await deny(request) } }
                )
            } else {
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
                        .disabled(looking || normalizedCode.isEmpty)
                        .accessibilityIdentifier("pairing-lookup")
                }
            }
        } header: {
            Text("批准新设备")
        } footer: {
            if request == nil {
                Text("在终端运行 mclaw login，或在 Mac 转码器里发起配对，设备会显示一段配对码。在这里输入它，核对无误后批准。")
            }
        }
    }

    /// 配对码规整：大写、补上 MCLW- 前缀（只输了后四位也认）
    private var normalizedCode: String {
        let raw = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !raw.isEmpty else { return "" }
        return raw.hasPrefix("MCLW-") ? raw : "MCLW-\(raw)"
    }

    private func lookUp() async {
        let target = normalizedCode
        guard !target.isEmpty else { return }
        looking = true
        error = nil
        defer { looking = false }
        do {
            request = try await api.authDevicesRequest(userCode: target)
        } catch let failure as APIError where failure.status == 404 {
            error = "没有找到配对码 \(target) 的请求：请核对设备上显示的码，或让设备重新发起（配对码 5 分钟内有效）"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func approve(_ request: API.DeviceRequestView) async {
        busy = request.userCode
        error = nil
        defer { busy = nil }
        do {
            try await api.authDevicesApprove(userCode: request.userCode)
            feedback.success("已批准「\(request.clientName)」接入，设备上稍等片刻就会显示配对成功")
            self.request = nil
            code = ""
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deny(_ request: API.DeviceRequestView) async {
        busy = request.userCode
        error = nil
        defer { busy = nil }
        do {
            try await api.authDevicesDeny(userCode: request.userCode)
            self.request = nil
            code = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: 设备列表

    /// 按类别分组：网页与 App、命令行与转码器、播放器（Jellyfin 客户端）
    private struct DeviceGroup: Identifiable {
        let id: String
        let title: String
        let footer: String?
        let items: [API.LoginDeviceView]
    }

    private func groups(_ list: [API.LoginDeviceView]) -> [DeviceGroup] {
        let apps = list.filter { ["web", "ios", "tvos", "android"].contains($0.kind) }
        let programs = list.filter { ["cli", "worker", "manual"].contains($0.kind) }
        let players = list.filter { $0.kind == "jellyfin" }
        return [
            DeviceGroup(id: "apps", title: "网页与 App", footer: "用账号密码登录的。改密码后，除了你正在用的这台，其余全部下线。", items: apps),
            DeviceGroup(id: "programs", title: "命令行与转码器", footer: "配对或手工创建的，改密码时默认保留（转码器常年无人值守）。怀疑密码泄露时，改密时勾选一并注销。", items: programs),
            DeviceGroup(id: "players", title: "播放器", footer: "Infuse 等 Jellyfin 客户端。", items: players),
        ].filter { !$0.items.isEmpty }
    }

    @ViewBuilder
    private var devicesSections: some View {
        switch devices {
        case .loading:
            Section { SettingsLoadingRow() }
        case let .failed(message):
            Section { Text(message).font(.subheadline).foregroundStyle(Theme.danger) }
        case let .loaded(list):
            ForEach(groups(list)) { group in
                Section {
                    ForEach(group.items, id: \.id) { device in
                        deviceRow(device)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if let footer = group.footer { Text(footer) }
                }
            }
        }
    }

    private func deviceRow(_ device: API.LoginDeviceView) -> some View {
        let live = DeviceText.isLive(device)
        return HStack(spacing: 12) {
            SettingsStatusDot(color: live ? Theme.success : Color.white.opacity(0.25), glow: live)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).font(.body.weight(.medium)).lineLimit(1)
                    if device.current {
                        Text("本机")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accentSoft, in: .capsule)
                    }
                }
                Text(DeviceText.summary(device, showOwner: showAll))
                    .font(.caption).foregroundStyle(Theme.textFaint).lineLimit(2)
                if DeviceText.isDormant(device) {
                    Text("超过 90 天没有用过，不认识或不再用的设备可以注销")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Spacer(minLength: 8)
            Menu {
                if device.renamable {
                    Button("改名", systemImage: "pencil") { Task { await rename(device) } }
                }
                Button(device.current ? "注销本机（退出登录）" : "注销", systemImage: "xmark.circle", role: .destructive) {
                    Task { await revoke(device) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(busy == device.id)
            .accessibilityLabel("管理 \(device.name)")
            .accessibilityIdentifier("device-menu-\(device.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-row-\(device.name)")
    }

    private func rename(_ device: API.LoginDeviceView) async {
        guard let name = await feedback.prompt("给设备改名", message: "起一个认得出的名字，比如「客厅的 iPad」。", initial: device.name, confirmTitle: "保存", maxLength: 64)?
            .trimmingCharacters(in: .whitespaces), !name.isEmpty, name != device.name else { return }
        busy = device.id
        defer { busy = nil }
        do {
            _ = try await api.authDevicesRename(deviceId: device.id, body: .init(name: name))
            await load()
        } catch {
            feedback.error(error)
        }
    }

    private func revoke(_ device: API.LoginDeviceView) async {
        if device.current {
            // 注销本机 = 退出当前账号：交给 AppModel，它会在服务端注销、删掉本机令牌、切到下一个账号或回欢迎页
            guard await feedback.confirm("退出登录？", message: "这台设备上的登录会被注销，再回来需要重新输入密码。", confirmTitle: "退出", destructive: true) else { return }
            await model.logout()
            return
        }
        let message = device.kind == "worker"
            ? "这台转码器会立即断开，正在进行的转码会中止，需要重新配对才能再次接入。"
            : "这台设备会立即失去访问权限，正在播放的也会停止；要再用需要重新登录或重新配对。其他设备不受影响。"
        guard await feedback.confirm("注销「\(device.name)」？", message: message, confirmTitle: "注销", destructive: true) else { return }
        busy = device.id
        error = nil
        defer { busy = nil }
        do {
            try await api.authDevicesRevoke(deviceId: device.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: 手工令牌

    @ViewBuilder
    private var manualTokenSection: some View {
        Section {
            if let created {
                createdCard(created)
            } else if tokenStage == .form {
                VStack(alignment: .leading, spacing: 6) {
                    Text("名字").font(.subheadline.weight(.medium)).foregroundStyle(Theme.textMuted)
                    TextField("nas-cron", text: $tokenName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { Task { await createToken() } }
                        .onChange(of: tokenName) { _, value in
                            if value.count > 64 { tokenName = String(value.prefix(64)) }
                            tokenNameError = nil
                        }
                        .accessibilityIdentifier("token-name")
                    Text(tokenNameError ?? "日后在上面的设备列表里就靠它认出这枚令牌、决定要不要注销。")
                        .font(.caption)
                        .foregroundStyle(tokenNameError == nil ? Theme.textFaint : Theme.danger)
                }
                Picker("权限", selection: $tokenScope) {
                    Text("完全权限").tag("full")
                    Text("仅限转码").tag("transcode")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("token-scope")
                grantNote(tokenScope == "transcode" ? DeviceText.transcodeManualGrant : DeviceText.manualGrant)
                HStack(spacing: 10) {
                    Button(creating ? "创建中…" : "创建令牌") { Task { await createToken() } }
                        .settingsProminentButton()
                        .disabled(creating)
                        .accessibilityIdentifier("token-create-submit")
                    Button("取消") {
                        tokenStage = .idle
                        tokenName = ""
                        tokenScope = "full"
                        tokenNameError = nil
                    }
                    .buttonStyle(.glass)
                    .disabled(creating)
                    .accessibilityIdentifier("token-create-cancel")
                }
            } else {
                Text("没法按下批准的环境——NAS 上的定时任务、CI、无界面容器、命令行模式的转码器——在这里创建一枚令牌，用 MOVIECLAW_SERVER 和 MOVIECLAW_TOKEN 两个环境变量注入。能打开浏览器的机器请直接运行 mclaw login 配对，不必走这里。")
                    .font(.subheadline).foregroundStyle(Theme.textMuted)
            }
        } header: {
            HStack {
                Text("手工创建令牌")
                Spacer()
                if tokenStage == .idle, created == nil {
                    Button { tokenStage = .form } label: { Label("创建令牌", systemImage: "plus") }
                        .font(.subheadline)
                        .textCase(nil)
                        .accessibilityIdentifier("token-create-open")
                }
            }
        }
    }

    private func grantNote(_ grant: DeviceText.Grant) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(grant.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            Text(grant.body).font(.subheadline).foregroundStyle(Theme.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.2)))
    }

    /// 注入地址：优先「对外访问地址」（用户明确声明的），没配时回落 App 当前连接的地址并说破
    private var serverAddress: (url: String, configured: Bool) {
        var configured = externalUrl.trimmingCharacters(in: .whitespaces)
        while configured.hasSuffix("/") { configured.removeLast() }
        if !configured.isEmpty { return (configured, true) }
        var origin = api.server.origin.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        return (origin, false)
    }

    /// 一次性凭据卡：全站唯一一处「现在不存就永远没了」的地方。
    /// 完全权限的令牌给 mclaw 用的两行环境变量；仅限转码的给命令行模式转码器的启动参数
    /// （它只认 `--nas-url` / `--token`，不读环境变量，见 macos/MovieClawTranscoder/README.md）
    @ViewBuilder
    private func createdCard(_ token: API.ApiTokenCreatedView) -> some View {
        let address = serverAddress
        let transcode = token.scope == "transcode"
        let snippet = transcode
            ? "--nas-url \(address.url) --token \(token.token)"
            : "MOVIECLAW_SERVER=\(address.url)\nMOVIECLAW_TOKEN=\(token.token)"
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark").foregroundStyle(Theme.success)
            VStack(alignment: .leading, spacing: 3) {
                Text("已创建「\(token.name)」").font(.body.weight(.semibold))
                Text("令牌明文只显示这一次。关掉这张卡就再也读不到，只能注销后重建。")
                    .font(.subheadline).foregroundStyle(Theme.warning)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("token-created-card")
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(transcode ? "填进转码器的启动参数" : "粘贴到目标环境").font(.subheadline.weight(.medium)).foregroundStyle(Theme.textMuted)
                Spacer()
                SettingsCopyButton(text: snippet, title: transcode ? "复制参数" : "复制两行")
                    .buttonStyle(.glass).controlSize(.small)
            }
            Group {
                if transcode {
                    Text("\(Text("--nas-url ").foregroundStyle(Theme.accent2))\(Text(address.url).foregroundStyle(Theme.text)) \(Text("--token ").foregroundStyle(Theme.accent2))\(Text(token.token).foregroundStyle(Theme.warning))")
                } else {
                    Text("\(Text("MOVIECLAW_SERVER=").foregroundStyle(Theme.accent2))\(Text(address.url).foregroundStyle(Theme.text))\n\(Text("MOVIECLAW_TOKEN=").foregroundStyle(Theme.accent2))\(Text(token.token).foregroundStyle(Theme.warning))")
                }
            }
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.28), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
        }
        if transcode {
            Text("接在 movieclaw-transcoder --headless 后面即可，--worker-id、--ffmpeg 等其余参数照常。")
                .font(.caption).foregroundStyle(Theme.textFaint)
        }
        if address.configured {
            Text("地址取自「设置 → 网络」里填写的对外访问地址。").font(.caption).foregroundStyle(Theme.textFaint)
        } else {
            SettingsNotice(
                text: "上面这行地址取自 App 当前连接的服务器地址，只是猜测——目标机器不一定连得到。请到「设置 → 网络」填写对外访问地址，之后这里会直接给出正确的一行。",
                tone: .warn
            )
        }
        HStack {
            SettingsCopyButton(text: token.token, title: "仅复制令牌")
                .buttonStyle(.glass)
            Spacer()
            Button("我已保存，关闭") { Task { await dismissCreated() } }
                .settingsProminentButton()
                .accessibilityIdentifier("token-created-dismiss")
        }
    }

    private func createToken() async {
        let name = tokenName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            tokenNameError = "先给它起个名字，否则日后没法在列表里认出是哪台机器。"
            return
        }
        creating = true
        error = nil
        defer { creating = false }
        do {
            created = try await api.authTokensCreate(body: .init(name: name, scope: tokenScope))
            tokenStage = .idle
            tokenName = ""
            tokenScope = "full"
            tokenNameError = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 关闭一次性凭据卡要过确认：明文关掉就再也读不到，误点的代价是注销重建
    private func dismissCreated() async {
        let ok = await feedback.confirm(
            "关闭后就看不到这枚令牌了？",
            message: "令牌明文只显示这一次。确认你已经把它存进目标机器，或者复制到了安全的地方。",
            confirmTitle: "我已保存"
        )
        if ok { created = nil }
    }
}

// MARK: - 审批卡

/// 用户做决定的全部依据都在这张卡上；配对码大号等宽字，便于和设备屏幕逐字比对
private struct ApprovalCard: View {
    let request: API.DeviceRequestView
    let canApprove: Bool
    let isAdmin: Bool
    let busy: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        let grant = DeviceText.grant(request.clientType, isAdmin: isAdmin)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.clientName).font(.body.weight(.semibold))
                Spacer()
                Text(request.userCode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .tracking(3.5)
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
                SettingsNotice(text: "转码器只能由管理员批准：请让管理员在网页或 App 的「设置 → 设备」里输入这个配对码。", tone: .warn)
            }
            HStack(spacing: 10) {
                Button("批准接入", systemImage: "checkmark", action: onApprove)
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

// MARK: - 展示口径（Web lib/devices-display.ts，措辞是安全设计的一部分）

enum DeviceText {
    struct Grant {
        let title: String
        let body: String
    }

    static func clientType(_ type: String) -> String {
        switch type {
        case "worker": "转码器"
        case "cli": "命令行 / Agent"
        case "tvos": "Apple TV"
        case "manual": "手工令牌"
        default: "未知类型"
        }
    }

    /// 「将获得」：令牌就是批准者本人的权限——超管批的是完全权限，成员批的是他自己的那份
    static func grant(_ type: String, isAdmin: Bool) -> Grant {
        if type == "worker" {
            return Grant(title: "将获得：仅限转码", body: "这台机器不能查看或修改你的订阅、媒体库和设置。")
        }
        if type == "tvos" {
            // Apple TV 扫码登录（docs/design/tvos-app.md §5.1，文案同 Web devices-display.ts）
            return Grant(
                title: isAdmin ? "将获得：这台 Apple TV 以你的超级管理员身份登录" : "将获得：这台 Apple TV 以你的身份登录",
                body: "等同你在这台电视上输入账号密码登录：它能看到你能看到的媒体库、记录你的观看进度。只批准你面前这台电视上显示的配对码。"
            )
        }
        if isAdmin {
            return Grant(
                title: "将获得：与你相同的完全权限",
                body: "这台机器上的程序将能做你在网页上能做的一切，包括删除媒体文件。只在你清楚这台机器上正在运行什么程序时才批准。"
            )
        }
        return Grant(
            title: "将获得：与你相同的权限",
            body: "这台机器上的程序将以你的身份操作，能做你在网页上能做的一切。只在你清楚这台机器上正在运行什么程序时才批准。"
        )
    }

    static let manualGrant = Grant(
        title: "将获得：与你相同的完全权限",
        body: "持有这枚令牌的程序将能做你在网页上能做的一切，包括删除媒体文件。令牌不会自动过期，只能在这里注销——只把它放进你自己掌握的机器。"
    )

    static let transcodeManualGrant = Grant(
        title: "将获得：仅限转码",
        body: "给命令行模式（Headless）的转码器用：只能连转码链路，不能查看或修改你的订阅、媒体库和设置。令牌不会自动过期，只能在这里注销。"
    )

    /// 设备行的说明：「iOS App · iOS 26.0 · iPhone18,4 · 版本 0.28 · 3 分钟前 · 192.168.1.20」，全部成员视图前面带上主人
    static func summary(_ device: API.LoginDeviceView, showOwner: Bool) -> String {
        var parts: [String] = []
        if showOwner { parts.append(device.ownerNickname) }
        parts.append(device.kindLabel)
        if device.scope == "transcode", device.kind != "worker" { parts.append("仅转码") }
        if let platform = device.platform { parts.append(platform) }
        if let version = device.clientVersion { parts.append("版本 \(version)") }
        parts.append(device.current ? "正在使用" : activity(device))
        if let ip = device.lastSeenIp { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

    /// 靠长连接在线的转码器（配对来的 worker，或「仅限转码」的手工令牌）
    private static func isTranscoder(_ device: API.LoginDeviceView) -> Bool {
        device.kind == "worker" || device.scope == "transcode"
    }

    /// 列表上的绿点：转码器看此刻连没连着（它只在握手时验一次凭证、之后靠心跳在线，按最近
    /// 验签时间判断的话，连着的转码器 5 分钟后就会变灰）；其余设备没有长连接，仍按最近 5 分钟
    /// 有没有用过，本机恒为在线
    static func isLive(_ device: API.LoginDeviceView) -> Bool {
        if device.current { return true }
        if isTranscoder(device) { return device.connected }
        return SettingsTime.isLive(device.lastSeenAt)
    }

    /// 活跃那一段：连着的转码器写「已连接」，其余写最近活跃的相对时间
    static func activity(_ device: API.LoginDeviceView) -> String {
        if isTranscoder(device), device.connected { return "已连接" }
        return SettingsTime.deviceRelative(device.lastSeenAt)
    }

    /// 超过 90 天没用过：给一行提示，不自动失效（自动过期等于让用户某天莫名其妙掉线）
    static func isDormant(_ device: API.LoginDeviceView, now: Date = .now) -> Bool {
        guard !device.current, let seen = Formatters.date(device.lastSeenAt ?? device.createdAt) else { return false }
        return now.timeIntervalSince(seen) > 90 * 24 * 3600
    }
}
