import SwiftUI

/// 设置 → 设备（Web devices-section.tsx，设计见 docs/design/login-devices.md）。
///
/// 所有人都能进（成员看自己的设备），这一页承担四件事：
/// 1. **「批准新设备登录」入口**：批准本身在独立的批准页（DeviceApprovalView，对应网页 /activate），
///    「我的」页右上角扫码也直达那里。拿着配对码来批准是一次性的事，与管理已登录的设备是两件事；
/// 2. **我的设备**：登录着这个账号的浏览器、App、命令行、转码器与播放器，当前这台置顶；可以改名、注销。
///    注销是唯一的事后止损手段，注销即断——它正在播的片、正在跑的转码一并停止；
/// 3. **全部成员的设备**（超管）：多一列「属于谁」；
/// 4. **手工令牌**（超管）：给没人能按批准的环境（NAS 定时任务、CI、命令行模式的转码器）。明文只在创建
///    响应里出现一次，给出可直接粘贴的两行环境变量，关闭前二次确认。
struct DevicesSettingsView: View {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback
    @Environment(AppModel.self) private var model

    @State private var devices: Loadable<[API.LoginDeviceView]> = .loading
    @State private var showAll = false
    @State private var busy: String?
    @State private var error: String?
    @State private var cleaning = false
    @State private var showDeviceList = false
    @State private var selectedGroup = "browser"
    @State private var deviceListLimits: [String: Int] = [:]
    @State private var deviceListPositions: [String: String] = [:]
    @State private var requestID = 0

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
            approvalEntry
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
            cleanupEntry
            if permissions.isAdmin { manualTokenSection }
        }
        .scrollDismissesKeyboard(.immediately)
        .appBackground()
        .task(id: showAll) { await load() }
        // 在线状态会变（转码器连上 / 断开、别的设备刚用过）：页面开着时每 15 秒静默刷新一次
        .polling(every: 15) { await load() }
        .task {
            // 对外访问地址：进入分区就先拉，等按下创建再拉会多等一个往返；拿不到就回落当前服务器地址
            if permissions.isAdmin, let config = try? await api.appShow() { externalUrl = config.externalUrl }
        }
        .refreshable { await load() }
        .onChange(of: showAll) { _, _ in
            showDeviceList = false
            deviceListLimits = [:]
            deviceListPositions = [:]
        }
        .sheet(isPresented: $showDeviceList) {
            deviceListSheet.sheetFeedback()
        }
        .sheet(isPresented: $cleaning) {
            DeviceCleanupSheet(all: showAll) { message in
                cleaning = false
                feedback.success(message)
                Task { await load() }
            }
            .sheetFeedback()
        }
    }

    private func load() async {
        requestID += 1
        let request = requestID
        let all = showAll
        do {
            let next = try await api.authDevicesList(all: all)
            guard request == requestID, !Task.isCancelled else { return }
            devices = .loaded(next)
            error = nil
        } catch {
            guard request == requestID, !Task.isCancelled else { return }
            if devices.value == nil { devices = .failed(error.localizedDescription) }
            self.error = error.localizedDescription
        }
    }

    // MARK: 批准新设备

    private var approvalEntry: some View {
        Section {
            Button {
                router.push(.deviceApproval())
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder").font(.title3).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("批准新设备登录").foregroundStyle(Theme.text)
                        Text("扫码或输入 Apple TV、Mac、命令行、转码器上的配对码").font(.caption).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
            }
            .accessibilityIdentifier("devices-approve-entry")
        }
    }

    // MARK: 清理

    /// 「清理长期没用的设备」：一次注销 N 天没用过的设备（本机、连着的转码器不清）。
    /// 只有本机一台时没东西可清，不出现
    @ViewBuilder
    private var cleanupEntry: some View {
        if let list = devices.value, list.contains(where: { !$0.current }) {
            Section {
                Button {
                    cleaning = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.body).foregroundStyle(Theme.textMuted).frame(width: 36)
                        Text(showAll ? "清理全部成员长期没用的设备" : "清理长期没用的设备").foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textFaint)
                    }
                }
                .accessibilityIdentifier("devices-cleanup-entry")
            }
        }
    }

    // MARK: 设备列表

    /// 与网页一致的四类：空组保留，区分没有在线设备与没有设备记录。
    private struct DeviceGroup: Identifiable {
        let id: String
        let title: String
        let items: [API.LoginDeviceView]
    }

    private func groups(_ list: [API.LoginDeviceView]) -> [DeviceGroup] {
        return [
            DeviceGroup(id: "browser", title: "浏览器", items: list.filter { $0.kind == "web" }),
            DeviceGroup(id: "app", title: "App", items: list.filter { ["ios", "tvos", "macos", "android"].contains($0.kind) }),
            DeviceGroup(id: "paired", title: "命令行与转码器", items: list.filter { !["web", "ios", "tvos", "macos", "android", "jellyfin"].contains($0.kind) }),
            DeviceGroup(id: "player", title: "播放器", items: list.filter { $0.kind == "jellyfin" }),
        ]
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
                let online = group.items.filter { DeviceText.isLive($0) }
                Section {
                    ForEach(Array(online.prefix(5)), id: \.id) { device in
                        deviceRow(device, compact: true)
                    }
                    if online.isEmpty {
                        Text(group.items.isEmpty ? "暂无设备记录，登录或配对后会显示在这里" : "暂无在线设备，离线记录可在查看全部中找到")
                            .font(.subheadline).foregroundStyle(Theme.textMuted)
                            .accessibilityIdentifier("devices-empty-\(group.id)")
                    }
                    if !group.items.isEmpty {
                        Button {
                            selectedGroup = group.id
                            showDeviceList = true
                        } label: {
                            HStack {
                                Text("查看全部").foregroundStyle(Theme.text)
                                Spacer()
                                Text("\(group.items.count) 条记录").font(.caption).foregroundStyle(Theme.textMuted)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textFaint)
                            }
                        }
                        .accessibilityIdentifier("devices-all-\(group.id)")
                    }
                } header: {
                    HStack { Text(group.title); Spacer(); Text("\(online.count) 在线") }
                } footer: {
                    if group.id == "player" { Text("摘要只显示当前在线的前 5 台设备；查看全部包含在线和离线记录。") }
                }
            }
        }
    }

    private var deviceListSheet: some View {
        let allGroups = groups(devices.value ?? [])
        let group = allGroups.first { $0.id == selectedGroup } ?? allGroups[0]
        return NavigationStack {
            VStack(spacing: 0) {
                Picker("设备类型", selection: $selectedGroup) {
                    ForEach(allGroups) { item in
                        Text(item.id == "paired" ? "命令行" : item.title).tag(item.id)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 12)
                .accessibilityIdentifier("devices-list-category")
                deviceList(group)
            }
            .appBackground()
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showDeviceList = false }
                        .accessibilityIdentifier("devices-list-done")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func deviceList(_ group: DeviceGroup) -> some View {
        let online = group.items.filter { DeviceText.isLive($0) }
        let ordered = online + group.items.filter { !DeviceText.isLive($0) }
        let limit = deviceListLimits[group.id] ?? 20
        let visible = Array(ordered.prefix(limit))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("\(online.count) 在线 · 共 \(ordered.count) 条记录")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 12)
                if let error { SettingsNotice(text: error) }
                if ordered.isEmpty {
                    Text("暂无设备记录，登录或配对后会显示在这里")
                        .font(.subheadline).foregroundStyle(Theme.textMuted).padding(.vertical, 40)
                        .accessibilityIdentifier("devices-list-empty")
                }
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, device in
                    VStack(alignment: .leading, spacing: 0) {
                        if index == 0 || index == online.count {
                            Text(DeviceText.isLive(device) ? "当前在线" : "离线 · 最近使用优先")
                                .font(.caption).foregroundStyle(Theme.textFaint).padding(.vertical, 12)
                        }
                        deviceRow(device).padding(.vertical, 12)
                        Divider()
                    }
                    .id(device.id)
                }
                if visible.count < ordered.count {
                    Text("继续滚动，自动载入")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                        .id("load-\(group.id)-\(limit)")
                        .onAppear { deviceListLimits[group.id] = limit + 20 }
                } else if !ordered.isEmpty {
                    Text("已显示全部记录").font(.caption).foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
        }
        .scrollPosition(id: Binding(
            get: { deviceListPositions[group.id] },
            set: { if let id = $0 { deviceListPositions[group.id] = id } }
        ), anchor: .top)
        .refreshable { await load() }
        .accessibilityIdentifier("devices-list-scroll")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(visible.count) / \(ordered.count) 条记录")
                    .accessibilityIdentifier("devices-list-count")
                Spacer()
                Text("下拉刷新")
            }
            .font(.caption).foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }

    /// 一行设备：图标（在线时右下角亮绿点）+ 名字 + 系统与版本 + 最近活跃 + 提示，⋯ 菜单贴右上角。
    /// 说明文字只在整段之间换行（见 DeviceText.metaLine）；分隔线统一从文字列开始，不随提示行左右跳
    private func deviceRow(_ device: API.LoginDeviceView, compact: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            DeviceBadge(symbol: DeviceText.symbol(device), live: DeviceText.isLive(device))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(device.name).font(.body.weight(.medium)).lineLimit(2)
                    if device.current {
                        Text("本机")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accentSoft, in: .capsule)
                            .fixedSize()
                    }
                }
                ForEach(compact ? [DeviceText.identityParts(device, showOwner: showAll)] : [DeviceText.identityParts(device, showOwner: showAll), DeviceText.activityParts(device)], id: \.self) { parts in
                    if !parts.isEmpty {
                        Text(DeviceText.metaLine(parts)).font(.caption).foregroundStyle(Theme.textFaint)
                    }
                }
                if !compact, DeviceText.isDormant(device) {
                    rowNote("clock", "超过 90 天没有用过，不认识或不再用的设备可以注销", color: Theme.warning)
                }
                // App 收不到推送时说一句为什么（能收到就不提，docs/design/cloud-push.md §7.3）
                if !compact, let push = device.push, push.status != "ok" {
                    rowNote("bell.slash", push.statusText, color: push.status == "not_registered" ? Theme.textMuted : Theme.warning)
                        .accessibilityIdentifier("device-push-\(device.name)")
                }
            }
            .padding(.top, 1)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 4)
            Menu {
                if device.renamable {
                    Button("改名", systemImage: "pencil") { Task { await rename(device) } }
                }
                Button(device.current ? "注销本机（退出登录）" : "注销", systemImage: "xmark.circle", role: .destructive) {
                    Task { await revoke(device) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(busy == device.id)
            .accessibilityLabel("管理 \(device.name)")
            .accessibilityIdentifier("device-menu-\(device.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-row-\(device.name)")
    }

    private func rowNote(_ symbol: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).font(.caption2)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.top, 2)
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
        case "macos": "Mac"
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
        if type == "macos" {
            // Mac App 扫码登录：与 Apple TV 同一口径（文案同 Web devices-display.ts）
            return Grant(
                title: isAdmin ? "将获得：这台 Mac 以你的超级管理员身份登录" : "将获得：这台 Mac 以你的身份登录",
                body: "等同你在这台 Mac 上输入账号密码登录：它能看到你能看到的媒体库、记录你的观看进度。只批准你面前这台 Mac 上显示的配对码。"
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

    /// 行首图标：形态一眼可辨，说明行里就不再重复「iOS App」「浏览器」
    static func symbol(_ device: API.LoginDeviceView) -> String {
        if device.kind == "worker" || device.scope == "transcode" { return "cpu" }
        switch device.kind {
        case "ios", "android": return "iphone"
        case "tvos": return "appletv"
        case "macos": return "laptopcomputer"
        case "web": return "globe"
        case "jellyfin": return "play.rectangle"
        default: return "terminal"
        }
    }

    /// 第一行说明：系统、型号、版本（全部成员视图前面带上主人）。浏览器、带系统信息的 App 由图标说明形态，
    /// 不再写类型名；命令行、令牌、播放器这类图标说不清的照写（同 Web devices-display.ts identityParts）
    static func identityParts(_ device: API.LoginDeviceView, showOwner: Bool) -> [String] {
        var parts: [String] = []
        if showOwner { parts.append(device.ownerNickname) }
        let platform = (device.platform ?? "").components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let isApp = ["ios", "tvos", "macos", "android"].contains(device.kind)
        if device.kind != "web", !(isApp && !platform.isEmpty) { parts.append(device.kindLabel) }
        if device.scope == "transcode", device.kind != "worker" { parts.append("仅转码") }
        parts += platform
        if let version = device.clientVersion { parts.append("版本 \(version)") }
        return parts
    }

    /// 第二行说明：正在使用 / 最近活跃、来源 IP
    static func activityParts(_ device: API.LoginDeviceView) -> [String] {
        var parts = [device.current ? "正在使用" : activity(device)]
        if let ip = device.lastSeenIp { parts.append(ip) }
        return parts
    }

    /// 把几段说明拼成一行：段内字符用 U+2060（不断行）连住，分隔点用不换行空格贴在前一段末尾，
    /// 窄屏只会在「· 」之后换行——不会把「2026/10/05」拆开，也不会出现以点开头的行
    static func metaLine(_ parts: [String]) -> String {
        parts.map { part in
            part.map { $0 == " " ? "\u{00A0}" : String($0) }.joined(separator: "\u{2060}")
        }
        .joined(separator: "\u{00A0}· ")
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

// MARK: - 行首图标

/// 设备图标；在线时右下角亮一个绿点（不在线不画，灰点只是噪音）
private struct DeviceBadge: View {
    let symbol: String
    let live: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if live {
                    Circle()
                        .fill(Theme.success)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.85), lineWidth: 2).padding(-2))
                        .shadow(color: Theme.success.opacity(0.6), radius: 4)
                        .offset(x: 2, y: 2)
                        .accessibilityLabel("在线")
                }
            }
    }
}

// MARK: - 清理长期没用的设备

/// 选多少天没用过，先让服务端列出会注销哪几台（dry_run），看清了再一次注销。清理就是注销——
/// 被清掉的要重新登录或配对，所以名单摆在确认按钮前面。本机与连着的转码器服务端永远不清
/// （同 Web devices-section.tsx CleanupDialog）
private struct DeviceCleanupSheet: View {
    let all: Bool
    let onDone: (String) -> Void
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @State private var days = 30
    @State private var preview: Loadable<[API.DeviceCleanupItem]> = .loading
    @State private var busy = false

    var body: some View {
        let count = preview.value?.count ?? 0
        SettingsSheetScaffold(
            title: "清理设备",
            confirmTitle: count > 0 ? "注销 \(count) 台" : "注销",
            confirmDisabled: count == 0,
            busy: busy,
            confirmIdentifier: "devices-cleanup-submit",
            onConfirm: { Task { await submit() } }
        ) {
            Section {
                Picker("多久没用过", selection: $days) {
                    ForEach([7, 30, 90], id: \.self) { Text("\($0) 天").tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("devices-cleanup-days")
            } header: {
                Text("多久没用过")
            } footer: {
                Text(all ? "清理全部成员的设备。被注销的要重新登录或配对才能再用；正在用的这台、连着的转码器不会被清理。"
                    : "被注销的要重新登录或配对才能再用；正在用的这台、连着的转码器不会被清理。")
            }
            Section {
                switch preview {
                case .loading:
                    SettingsLoadingRow()
                case let .failed(message):
                    Text(message).font(.subheadline).foregroundStyle(Theme.danger)
                case let .loaded(items) where items.isEmpty:
                    Text("没有超过 \(days) 天没用过的设备").foregroundStyle(Theme.textMuted)
                case let .loaded(items):
                    ForEach(items, id: \.id) { item in
                        HStack {
                            Text(item.name).lineLimit(1)
                            Spacer()
                            if all { Text(item.ownerNickname).font(.caption).foregroundStyle(Theme.textFaint) }
                        }
                    }
                }
            } header: {
                if let items = preview.value, !items.isEmpty { Text("将注销 \(items.count) 台") }
            }
        }
        .task(id: days) { await load() }
    }

    private func load() async {
        preview = .loading
        do {
            preview = .loaded(try await api.authDevicesCleanup(body: .init(inactiveDays: days, all: all, dryRun: true)).devices)
        } catch {
            preview = .failed(error.localizedDescription)
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await api.authDevicesCleanup(body: .init(inactiveDays: days, all: all, dryRun: false))
            onDone("已注销 \(result.devices.count) 台设备")
        } catch {
            feedback.error(error)
        }
    }
}
