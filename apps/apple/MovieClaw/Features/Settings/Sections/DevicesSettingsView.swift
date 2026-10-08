import SwiftUI

/// 设备管理：分类 → 完整列表 → 设备详情。批准、创建令牌和批量清理各自形成独立任务。
struct DevicesSettingsView: View {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var devices: Loadable<[API.LoginDeviceView]> = .loading
    @State private var showAll = false
    @State private var busy: String?
    @State private var error: String?
    @State private var cleaning = false
    @State private var creatingToken = false
    @State private var showDeviceList = false
    @State private var selectedGroup = "browser"
    @State private var selectedDevice: API.LoginDeviceView?
    @State private var selectedCurrentDevice: API.LoginDeviceView?
    @State private var search = ""
    @State private var requestID = 0

    var body: some View {
        List {
            SettingsFormSection {
                Button { router.push(.deviceApproval()) } label: {
                    Label("批准新设备登录", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("devices-approve-entry")
                if permissions.isAdmin {
                    Button { creatingToken = true } label: {
                        Label("创建访问令牌", systemImage: "key")
                    }
                    .accessibilityIdentifier("token-create-open")
                }
            }
            if permissions.isAdmin {
                SettingsFormSection {
                    Picker("设备范围", selection: $showAll) {
                        Text("我的设备").tag(false)
                        Text("全部成员").tag(true)
                    }
                    .modifier(DeviceScopeStyle(accessibility: typeSize.isAccessibilitySize))
                    .accessibilityIdentifier("devices-scope")
                }
            }
            deviceSections
        }
        .listStyle(.insetGrouped)
        .appBackground()
        .task(id: showAll) { await load() }
        .polling(every: 15) { await load() }
        .refreshable { await load() }
        .onChange(of: showAll) { _, _ in
            devices = .loading
            error = nil
            search = ""
        }
        .navigationDestination(isPresented: $showDeviceList) { deviceList }
        .navigationDestination(item: $selectedCurrentDevice) { device in deviceDetail(device) }
        .sheet(isPresented: $creatingToken) {
            DeviceTokenSheet { Task { await load() } }.sheetFeedback()
        }
    }

    private func load() async {
        requestID += 1
        let request = requestID
        let all = showAll
        do {
            let next = try await api.authDevicesList(all: all)
            guard request == requestID, all == showAll, !Task.isCancelled else { return }
            devices = .loaded(next)
            error = nil
        } catch {
            guard request == requestID, all == showAll, !Task.isCancelled else { return }
            if devices.value == nil { devices = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    private var groups: [DeviceGroup] { DeviceGroup.make(devices.value ?? []) }

    @ViewBuilder
    private var deviceSections: some View {
        switch devices {
        case .loading:
            SettingsFormSection { SettingsLoadingRow() }
        case let .failed(message):
            SettingsFormSection { retryRow(message) }
        case let .loaded(list):
            if let error { SettingsFormSection { retryRow(error) } }
            if let current = list.first(where: \.current) {
                SettingsFormSection("当前设备") { deviceLink(current) }
            }
            SettingsFormSection {
                ForEach(groups) { group in
                    Button {
                        selectedGroup = group.id
                        search = ""
                        showDeviceList = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: group.symbol)
                                .font(.title3).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title).foregroundStyle(.primary)
                                let online = group.items.filter { DeviceText.isLive($0) }.count
                                let layout = typeSize.isAccessibilitySize
                                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                    : AnyLayout(HStackLayout(spacing: 8))
                                layout {
                                    Text("\(group.items.count) 台设备").foregroundStyle(.secondary)
                                    DeviceOnlineLabel(online: online > 0, title: "\(online) 在线")
                                }
                                .font(.subheadline)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("devices-all-\(group.id)")
                }
            } header: {
                Text(showAll ? "全部成员的设备" : "我的设备")
            } footer: {
                Text("包含在线和离线设备。点按设备可查看详情、改名或注销。")
            }
        }
    }

    private func retryRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("重试") { Task { await load() } }
        }
    }

    private var deviceList: some View {
        let group = groups.first { $0.id == selectedGroup } ?? groups[0]
        let filtered = group.matching(search)
        let online = filtered.filter { DeviceText.isLive($0) }
        let offline = filtered.filter { !DeviceText.isLive($0) }
        return List {
            if let error { SettingsFormSection { retryRow(error) } }
            if !online.isEmpty {
                SettingsFormSection("在线 · \(online.count)") {
                    ForEach(online, id: \.id) { deviceLink($0) }
                }
            }
            if !offline.isEmpty {
                SettingsFormSection("离线 · \(offline.count)") {
                    ForEach(offline, id: \.id) { deviceLink($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .appBackground()
        .overlay {
            if filtered.isEmpty {
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("暂无\(group.title)设备", systemImage: group.symbol,
                                           description: Text("登录或配对后，设备会出现在这里。"))
                        .accessibilityIdentifier("devices-list-empty")
                } else {
                    ContentUnavailableView.search(text: search)
                        .accessibilityIdentifier("devices-search-empty")
                }
            }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: showAll ? "搜索设备或成员" : "搜索设备")
        .navigationDestination(item: $selectedDevice) { device in deviceDetail(device) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清理", role: .destructive) { cleaning = true }
                    .tint(Theme.danger)
                    .accessibilityLabel("清理不活跃的\(group.title)设备")
                    .accessibilityIdentifier("devices-cleanup-entry")
                    .popover(isPresented: Binding(get: { cleaning && !typeSize.isAccessibilitySize },
                                                  set: { cleaning = $0 }), arrowEdge: .top) {
                        cleanupContent(group)
                    }
                    .sheet(isPresented: Binding(get: { cleaning && typeSize.isAccessibilitySize },
                                                set: { cleaning = $0 })) {
                        cleanupContent(group)
                    }
            }
        }
        .onChange(of: selectedGroup) { _, _ in search = "" }
        .refreshable { await load() }
        .accessibilityIdentifier("devices-list")
    }

    private func cleanupContent(_ group: DeviceGroup) -> some View {
        DeviceCleanupPopover(group: group, all: showAll,
                             onChanged: { Task { await load() } }) { message in
            cleaning = false
            feedback.success(message)
        }
        .sheetFeedback()
    }

    private func deviceLink(_ device: API.LoginDeviceView) -> some View {
        Button {
            if showDeviceList { selectedDevice = device }
            else { selectedCurrentDevice = device }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: DeviceText.symbol(device))
                    .font(.title3).foregroundStyle(.secondary).frame(width: 28)
                    .padding(.top, 3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.body).foregroundStyle(.primary)
                    let identity = DeviceText.identityParts(device, showOwner: showAll).joined(separator: " · ")
                    if !identity.isEmpty { Text(identity).font(.subheadline).foregroundStyle(.secondary) }
                    DeviceOnlineLabel(online: DeviceText.isLive(device),
                                      title: device.current ? "本机 · 正在使用" : DeviceText.isLive(device) ? "在线" : DeviceText.activity(device))
                        .font(.caption)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.top, 5)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("device-row-\(device.name)")
    }

    private func deviceDetail(_ initial: API.LoginDeviceView) -> some View {
        let device = devices.value?.first { $0.id == initial.id } ?? initial
        return Form {
            SettingsFormSection {
                LabeledContent("名称", value: device.name)
                LabeledContent("类型", value: device.kindLabel)
                LabeledContent("状态") {
                    DeviceOnlineLabel(online: DeviceText.isLive(device),
                                      title: device.current ? "本机 · 正在使用" : DeviceText.isLive(device) ? "在线" : "离线")
                }
                if showAll { LabeledContent("所属成员", value: device.ownerNickname) }
                if let platform = device.platform, !platform.isEmpty { LabeledContent("系统", value: platform) }
                if let version = device.clientVersion { LabeledContent("版本", value: version) }
            }
            SettingsFormSection("活动") {
                LabeledContent("最近使用", value: DeviceText.activity(device))
                if let ip = device.lastSeenIp { LabeledContent("来源地址", value: ip).textSelection(.enabled) }
                LabeledContent("首次登录", value: SettingsTime.deviceRelative(device.createdAt))
            }
            if let push = device.push {
                SettingsFormSection("通知") {
                    Label(push.statusText, systemImage: push.status == "ok" ? "bell" : "bell.slash")
                        .accessibilityIdentifier("device-push-\(device.name)")
                }
            }
            SettingsFormSection {
                LabeledContent("访问权限", value: device.scope == "transcode" ? "仅限转码" : "与所属账号相同")
            } footer: {
                if DeviceText.isDormant(device) { Text("超过 90 天没有使用。不认识或不再使用的设备可以注销。") }
            }
            SettingsFormSection {
                Button(device.current ? "退出本机登录" : "注销设备", role: .destructive) {
                    Task { await revoke(device) }
                }
                .disabled(busy != nil)
                .accessibilityIdentifier("device-revoke")
            } footer: {
                Text(device.kind == "worker" || device.scope == "transcode"
                     ? "注销会断开转码器并中止正在进行的转码，再次使用需要重新配对。"
                     : "注销会终止这台设备的访问和播放，再次使用需要重新登录。")
            }
        }
        .appBackground()
        .navigationTitle("设备详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if device.renamable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("改名") { Task { await rename(device) } }
                        .disabled(busy != nil)
                        .accessibilityIdentifier("device-rename")
                }
            }
        }
    }

    private func rename(_ device: API.LoginDeviceView) async {
        guard let name = await feedback.prompt("给设备改名", message: "例如：客厅的 iPad。", initial: device.name,
                                              confirmTitle: "保存", maxLength: 64)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != device.name else { return }
        busy = device.id
        defer { busy = nil }
        do {
            _ = try await api.authDevicesRename(deviceId: device.id, body: .init(name: name))
            await load()
        } catch { feedback.error(error) }
    }

    private func revoke(_ device: API.LoginDeviceView) async {
        if device.current {
            guard await feedback.confirm("退出登录？", message: "这台设备需要重新登录才能再次访问。",
                                         confirmTitle: "退出登录", destructive: true) else { return }
            await model.logout()
            return
        }
        let message = device.kind == "worker" || device.scope == "transcode"
            ? "转码器会立即断开，正在进行的转码会中止，需要重新配对才能再次接入。"
            : "这台设备会立即失去访问权限，正在播放的也会停止。其他设备不受影响。"
        guard await feedback.confirm("注销「\(device.name)」？", message: message,
                                     confirmTitle: "注销", destructive: true) else { return }
        busy = device.id
        defer { busy = nil }
        do {
            try await api.authDevicesRevoke(deviceId: device.id)
            selectedDevice = nil
            selectedCurrentDevice = nil
            await load()
        } catch { feedback.error(error) }
    }
}

private struct DeviceOnlineLabel: View {
    let online: Bool
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            if online {
                Circle().fill(Theme.success).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(title)
        }
        .foregroundStyle(online ? Theme.success : Theme.textMuted)
    }
}

private struct DeviceScopeStyle: ViewModifier {
    let accessibility: Bool
    func body(content: Content) -> some View {
        if accessibility { content.pickerStyle(.menu) }
        else { content.pickerStyle(.segmented) }
    }
}

struct DeviceGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [API.LoginDeviceView]

    static func make(_ list: [API.LoginDeviceView]) -> [Self] {
        [
            Self(id: "browser", title: "浏览器", symbol: "globe", items: list.filter { $0.kind == "web" }),
            Self(id: "app", title: "App", symbol: "apps.iphone", items: list.filter { ["ios", "tvos", "macos", "android", "androidtv"].contains($0.kind) }),
            Self(id: "paired", title: "命令行与转码器", symbol: "terminal", items: list.filter { !["web", "ios", "tvos", "macos", "android", "androidtv", "jellyfin"].contains($0.kind) }),
            Self(id: "player", title: "播放器", symbol: "play.rectangle", items: list.filter { $0.kind == "jellyfin" }),
        ]
    }

    func matching(_ query: String) -> [API.LoginDeviceView] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { device in
            query.isEmpty || [device.name, device.ownerNickname, device.platform ?? ""].contains { $0.localizedStandardContains(query) }
        }
    }

    /// 使用服务端的不活跃判定，再限制到当前分类；不会因页面搜索词变化扩大清理范围。
    func cleanupCandidates(_ preview: [API.DeviceCleanupItem]) -> [API.DeviceCleanupItem] {
        let ids = Set(items.map(\.id))
        return preview.filter { ids.contains($0.id) }
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
        case "androidtv": "Android TV"
        case "manual": "手工令牌"
        default: "未知类型"
        }
    }

    /// 「将获得」：令牌就是批准者本人的权限——超管批的是完全权限，成员批的是他自己的那份
    static func grant(_ type: String, isAdmin: Bool) -> Grant {
        if type == "worker" {
            return Grant(title: "将获得：仅限转码", body: "这台机器不能查看或修改你的订阅、媒体库和设置。")
        }
        if type == "androidtv" {
            // Android TV 扫码登录（docs/design/androidtv-app.md §2，文案同 Web devices-display.ts）
            return Grant(
                title: isAdmin ? "将获得：这台 Android TV 以你的超级管理员身份登录" : "将获得：这台 Android TV 以你的身份登录",
                body: "等同你在这台电视上输入账号密码登录：它能看到你能看到的媒体库、记录你的观看进度。只批准你面前这台电视上显示的配对码。"
            )
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
        case "androidtv": return "tv"
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
        let isApp = ["ios", "tvos", "macos", "android", "androidtv"].contains(device.kind)
        if device.kind != "web", !(isApp && !platform.isEmpty) { parts.append(device.kindLabel) }
        if device.scope == "transcode", device.kind != "worker" { parts.append("仅转码") }
        parts += platform
        if let version = device.clientVersion { parts.append("版本 \(version)") }
        return parts
    }

    /// 靠长连接在线的转码器（配对来的 worker，或「仅限转码」的手工令牌）
    private static func isTranscoder(_ device: API.LoginDeviceView) -> Bool {
        device.kind == "worker" || device.scope == "transcode"
    }

    /// 转码器按长连接判断在线；其余设备看最近 5 分钟有没有使用，本机恒为在线。
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
