import SwiftUI

/// 设置 → 通知（所有人，docs/design/cloud-push.md §5、§7.3；对应网页 /settings/notifications）。
///
/// 推送按人发，每个人自己管收什么：
/// - 这台手机的系统通知权限：关掉了给「去系统设置开启」，还没问过给「开启通知」；
/// - 服务器还没有可用的推送通道时：管理员看到「开启手机通知」，在这里一步走完连接 MovieClaw Cloud；
///   成员看到「管理员还没有开启手机通知」（开关照样能改，开启后立刻生效）；
/// - 事件开关按 `group` 分组，乐观更新；连点时按顺序写，失败按服务器上的为准；
/// - 发一条测试通知（发给能收到的那几台）。
///
/// 设备只在「设置 → 设备」一个地方管：这里不列设备，都好就什么也不说；有收不到的才提一句，带去「设备」页看是哪台。
struct NotificationSettingsView: View {
    @Environment(\.api) private var api

    var body: some View {
        NotificationSettingsContent(model: NotificationSettingsModel(api: api), connection: CloudConnection(api: api))
    }
}

/// 「通知」页的数据：我的通知设置、开关、测试通知（docs/design/cloud-push.md §7.3）
@Observable
final class NotificationSettingsModel {
    private(set) var state: Loadable<API.MyPushView> = .loading
    @ObservationIgnored private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func load() async {
        do {
            state = .loaded(try await api.pushMeShow())
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error.localizedDescription) }
        }
    }

    /// 写入排队：连点几下时请求按点的顺序一个个发，服务器上最后生效的就是最后点的那次
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var writes = 0

    /// 发一次写入（界面已经乐观更新过）。只采用最后一次的结果：前面的回来晚了不能把界面盖回旧的；
    /// 最后一次失败就重新从服务器读一遍，界面和服务器保持一致
    private func write(_ send: @escaping @Sendable () async throws -> API.MyPushView) async throws {
        writes += 1
        let mine = writes
        let previous = lastWrite
        let request = Task { () -> Result<API.MyPushView, any Error> in
            await previous?.value
            do { return .success(try await send()) } catch { return .failure(error) }
        }
        lastWrite = Task { _ = await request.value }
        switch await request.value {
        case let .success(view):
            if mine == writes { state = .loaded(view) }
        case let .failure(error):
            if mine == writes { await load() }
            throw error
        }
    }

    /// 改一个事件的开关：乐观更新，失败按服务器上的为准
    func setEvent(_ key: String, enabled: Bool) async throws {
        guard var next = state.value, let index = next.events.firstIndex(where: { $0.key == key }) else { return }
        next.events[index].enabled = enabled
        state = .loaded(next)
        let api = api
        try await write { try await api.pushMePreferencesSet(body: .init(events: [key: enabled])) }
    }

    /// 「媒体库有新片」的事件键
    static let libraryEvent = "library.items.arrived"

    /// 勾 / 取消勾一个库（乐观更新，失败按服务器上的为准）：原来是「全部」就从全部里去掉它；勾到全部都选上回到「全部」
    /// （包括以后新建的库）；一个都不剩 = 关掉「媒体库有新片」并回到「全部」，下次打开就是全勾上（同网页）
    func toggleLibrary(_ id: Int) async throws {
        guard let current = state.value else { return }
        let change = Self.librarySelection(after: id, selected: current.libraryIds, all: current.libraries.map(\.id))
        var optimistic = current
        let body: LibrarySelection
        switch change {
        case let .libraries(next):
            optimistic.libraryIds = next
            body = LibrarySelection(ids: next)
        case .turnOff:
            optimistic.libraryIds = nil
            if let index = optimistic.events.firstIndex(where: { $0.key == Self.libraryEvent }) { optimistic.events[index].enabled = false }
            body = LibrarySelection(ids: nil, events: [Self.libraryEvent: false])
        }
        state = .loaded(optimistic)
        let api = api
        try await write { try await api.send("PUT", "/push/me/preferences", body: body) }
    }

    enum LibrarySelectionChange: Equatable {
        /// 一个都不剩：关掉「媒体库有新片」，选择回到「全部」
        case turnOff
        /// 新的 `library_ids`（nil = 全部，包括以后新建的库）
        case libraries([Int]?)
    }

    /// 点了一个库之后的选择（`selected` 为 nil 表示全部）；结果按库的顺序排
    static func librarySelection(after tapped: Int, selected: [Int]?, all: [Int]) -> LibrarySelectionChange {
        var chosen = selected ?? all
        if chosen.contains(tapped) { chosen.removeAll { $0 == tapped } } else { chosen.append(tapped) }
        if chosen.isEmpty { return .turnOff }
        return .libraries(Set(chosen) == Set(all) ? nil : all.filter(chosen.contains))
    }

    /// `library_ids` 要能明确发 null（= 全部）：生成的 `PushPreferencesRequest` 遇到 nil 是不发这个字段（= 不改），
    /// 所以这一个请求手写；编码在 APIClient 中执行，不继承界面模型的主线程隔离。
    nonisolated struct LibrarySelection: Encodable, Sendable {
        let ids: [Int]?
        var events: [String: Bool]?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ids, forKey: .libraryIds)
            try container.encodeIfPresent(events, forKey: .events)
        }

        enum CodingKeys: String, CodingKey {
            case libraryIds = "library_ids"
            case events
        }
    }

    /// 恢复一部片的推送（长按通知「这部剧不再提醒」静音的）：先从列表里拿掉，失败按服务器上的为准
    func unmute(_ id: Int) async throws {
        guard var next = state.value else { return }
        next.mutedItems?.removeAll { $0.id == id }
        state = .loaded(next)
        let api = api
        try await write { try await api.pushMeMutedRemove(itemId: id) }
    }

    /// 给自己的设备发一条测试通知（10 秒内只能发一次，后端拒绝时带可读的原因）
    func sendTest() async throws -> API.PushTestView {
        try await api.pushMeTest()
    }

    /// 事件按 `group` 分组，组的先后按第一次出现的顺序
    static func groups(_ events: [API.PushEventView]) -> [(title: String, events: [API.PushEventView])] {
        var order: [String] = []
        var grouped: [String: [API.PushEventView]] = [:]
        for event in events {
            if grouped[event.group] == nil { order.append(event.group) }
            grouped[event.group, default: []].append(event)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

private struct NotificationSettingsContent: View {
    @State var model: NotificationSettingsModel
    @State var connection: CloudConnection
    @Environment(PushCenter.self) private var push
    @Environment(Feedback.self) private var feedback
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            permissionSection
            switch model.state {
            case .loading:
                SettingsFormSection { SettingsLoadingRow() }
            case let .failed(message):
                SettingsFormSection {
                    SettingsBNotice(text: message, tone: .danger)
                    SettingsBAsyncButton(String(localized: .commonRetry)) { await model.load() }
                }
            case let .loaded(settings):
                readinessSections(settings)
                attentionSection(settings)
                eventSections(settings)
                mutedSection(settings)
                testSection(settings)
            }
        }
        .settingsBFormStyle()
        // 每登记完一轮推送（启动、登录、权限变化后）刷新一次：能收到的设备数、收不到的提示跟着变
        .task(id: push.registrationRound) { await model.load() }
        // 进来时补登记一次：启动时那一轮要是没成功（服务器当时连不上），这里再试；内容没变不会重发
        .task { await push.sync() }
        .refreshable { await model.load() }
        .task(id: needsCloudStatus) {
            if needsCloudStatus { await connection.load() }
        }
        .cloudApprovalPage(connection)
        .onChange(of: connection.value?.state) { old, new in
            guard old != nil, old != "connected", new == "connected" else { return }
            feedback.success(String(localized: .settingsPhonePushEnabled))
            Task { await reloadUntilReady() }
        }
    }

    /// 管理员、服务器还没有可用通道：要知道连没连上 MovieClaw Cloud，才知道该给「开启」还是去「MovieClaw Cloud」看看
    private var needsCloudStatus: Bool {
        guard let settings = model.state.value else { return false }
        return settings.isAdmin && !settings.instanceReady
    }

    /// 刚连上云：官方通道可能要过一会儿才可用，没好就隔几秒再问两次
    private func reloadUntilReady() async {
        for delay in [0, 3, 6] {
            try? await Task.sleep(for: .seconds(delay))
            await model.load()
            if model.state.value?.instanceReady == true { return }
        }
    }

    // MARK: 系统权限

    private var permissionSection: some View {
        SettingsFormSection {
            HStack(spacing: 12) {
                Label(String(localized: .settingsPhonePushSystem), systemImage: push.permission == .denied ? "bell.slash" : "bell")
                Spacer(minLength: 8)
                Text(push.permission.label)
                    .foregroundStyle(push.permission == .denied ? Theme.warning : Theme.textMuted)
                    .accessibilityIdentifier("notifications-permission")
            }
            switch push.permission {
            case .denied:
                Button(String(localized: .settingsPhonePushOpenSettings)) {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("notifications-open-settings")
            case .notDetermined:
                SettingsBAsyncButton(String(localized: .settingsPhonePushAllow)) { await push.requestAuthorization() }
                    .accessibilityIdentifier("notifications-request")
            default:
                EmptyView()
            }
        } footer: {
            if push.unsupportedBuild {
                Text(String(localized: .settingsPhonePushSideloaded))
            } else if push.permission == .denied {
                Text(String(localized: .settingsPhonePushDeniedHint))
            }
        }
    }

    // MARK: 服务器有没有推送通道

    @ViewBuilder
    private func readinessSections(_ settings: API.MyPushView) -> some View {
        if settings.instanceReady {
            if settings.isAdmin, let status = connection.value, status.state == "connected" {
                // 刚在这里开启：给一句确认
                SettingsFormSection {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.success)
                        SettingsRowText(title: String(localized: .settingsPhonePushEnabled),
                                        detail: status.connection.map { String(localized: .settingsPhonePushConnectedTo($0.instanceName, $0.accountDisplay)) })
                        Spacer(minLength: 8)
                        SettingsBBadge(text: String(localized: .settingsDrivesHealthy), tone: .ok)
                    }
                }
            }
        } else if !settings.isAdmin {
            SettingsFormSection {
                SettingsBNotice(text: String(localized: .settingsPhonePushAdminPending), tone: .info)
                    .accessibilityIdentifier("notifications-not-ready")
            }
        } else if connection.isConnected, let status = connection.value {
            // 连着 MovieClaw Cloud，但没有能用的通道（版本不受支持、官方通道被停用……）：去「MovieClaw Cloud」看原因
            SettingsFormSection {
                SettingsBNotice(text: status.healthMessage ?? String(localized: .settingsPhonePushNoChannel), tone: .warn)
                NavigationLink(value: AppRoute.settingsSection(.cloud)) {
                    Label(SettingsSection.cloud.title, systemImage: SettingsSection.cloud.systemImage)
                }
            } footer: {
                Text(String(localized: .settingsPhonePushRelayHint))
            }
        } else {
            enableCard
        }
    }

    /// 管理员的「开启手机通知」：连接 MovieClaw Cloud，网页框里批准完自动回到这里
    private var enableCard: some View {
        SettingsFormSection {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: .settingsPhonePushTurnOn)).font(.headline)
                Text(String(localized: .settingsPhonePushConnectPitch(connection.value?.serverName ?? app.server?.hostLabel ?? String(localized: .settingsPhonePushThisServer))))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            if connection.pendingPairing != nil || connection.endedPairing != nil {
                CloudPairingRows(connection: connection)
            } else {
                HStack {
                    Spacer()
                    SettingsBAsyncButton {
                        do {
                            try await connection.connect(instanceName: nil)
                        } catch {
                            feedback.error(error)
                        }
                    } label: {
                        Text(String(localized: .settingsPhonePushEnableButton)).font(.body.weight(.semibold))
                    }
                    .settingsProminentButton()
                    .accessibilityIdentifier("notifications-enable")
                    Spacer()
                }
            }
        } footer: {
            Text(String(localized: .settingsPhonePushAccountHint))
        }
    }

    // MARK: 事件开关

    @ViewBuilder
    private func eventSections(_ settings: API.MyPushView) -> some View {
        let groups = NotificationSettingsModel.groups(settings.events)
        ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
            SettingsFormSection {
                ForEach(group.events, id: \.key) { event in
                    Toggle(isOn: Binding(get: { event.enabled }, set: { value in
                        Task {
                            do { try await model.setEvent(event.key, enabled: value) } catch { feedback.error(error) }
                        }
                    })) {
                        SettingsRowText(title: event.title, detail: event.description)
                    }
                    .accessibilityIdentifier("notifications-event-\(event.key)")
                    if event.key == NotificationSettingsModel.libraryEvent, event.enabled, settings.libraries.count > 1 {
                        libraryRows(settings)
                    }
                }
            } header: {
                Text(group.title)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if group.events.contains(where: { $0.key == NotificationSettingsModel.libraryEvent && $0.enabled }),
                       settings.libraries.count > 1 {
                        Text(settings.libraryIds == nil ? String(localized: .settingsNotificationPreferencesAllLibrariesHint) : String(localized: .settingsNotificationPreferencesSelectedLibrariesHint))
                    }
                    if index == groups.count - 1, !settings.instanceReady {
                        Text(String(localized: .settingsPhonePushTogglesSaved))
                    }
                }
            }
        }
    }

    /// 「媒体库有新片」打开时，下面列出能看到的库，打勾的才通知；全勾上 = 全部（包括以后新建的库）
    @ViewBuilder
    private func libraryRows(_ settings: API.MyPushView) -> some View {
        ForEach(settings.libraries, id: \.id) { library in
            let selected = settings.libraryIds?.contains(library.id) ?? true
            Button {
                Task {
                    do { try await model.toggleLibrary(library.id) } catch { feedback.error(error) }
                }
            } label: {
                HStack {
                    Text(library.name).foregroundStyle(Theme.text)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accentStrong)
                    }
                }
                .padding(.leading, 12)
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("notifications-library-\(library.name)")
        }
    }

    // MARK: 不再提醒的剧

    /// 长按通知点过「这部剧不再提醒」的片：一部一行，点「恢复」重新提醒。没有就不显示
    @ViewBuilder
    private func mutedSection(_ settings: API.MyPushView) -> some View {
        if let muted = settings.mutedItems, !muted.isEmpty {
            SettingsFormSection {
                ForEach(muted, id: \.id) { item in
                    HStack(spacing: 12) {
                        Text(item.year.map { "\(item.title)（\($0)）" } ?? item.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        SettingsBAsyncButton(String(localized: .settingsPluginsRestore)) {
                            do { try await model.unmute(item.id) } catch { feedback.error(error) }
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("notifications-unmute-\(item.id)")
                    }
                }
            } header: {
                Text(String(localized: .settingsNotificationPreferencesMuted))
            } footer: {
                Text(String(localized: .settingsPhonePushMutedHint))
            }
        }
    }

    // MARK: 收不到的设备

    /// 有设备收不到时提一句（都好就不显示），去「设备」页看是哪台、为什么
    @ViewBuilder
    private func attentionSection(_ settings: API.MyPushView) -> some View {
        if settings.instanceReady, !settings.attention.isEmpty {
            SettingsFormSection {
                SettingsBNotice(text: Self.attentionText(settings.attention), tone: .warn)
                    .accessibilityIdentifier("notifications-attention")
                NavigationLink(value: AppRoute.settingsSection(.devices)) {
                    Label(SettingsSection.devices.title, systemImage: SettingsSection.devices.systemImage)
                }
            }
        }
    }

    /// 「客厅的 iPad：这台设备关掉了通知」；多台时一台一行
    static func attentionText(_ items: [API.PushAttentionView]) -> String {
        let lines = items.map { "\($0.deviceName)：\($0.statusText)" }
        return (items.count == 1 ? String(localized: .settingsPhonePushOneUnreachable) : String(localized: .settingsPhonePushManyUnreachable(items.count))) + "\n" + lines.joined(separator: "\n")
    }

    // MARK: 测试

    private func testSection(_ settings: API.MyPushView) -> some View {
        let count = settings.readyDevices
        // IM 也是通知的渠道，测试通知一并发过去（旧服务器没有这个字段）
        let im = settings.imAccounts ?? 0
        return SettingsFormSection {
            HStack(spacing: 12) {
                SettingsRowText(title: String(localized: .settingsNotificationPreferencesSendTest), detail: Self.testTarget(devices: count, im: im))
                Spacer(minLength: 8)
                SettingsBAsyncButton(String(localized: .agentComposerSend)) { await sendTest() }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.glass)
                    .disabled(count == 0 && im == 0)
                    .accessibilityIdentifier("notifications-test")
            }
        } footer: {
            if count == 0 && im == 0 {
                Text(settings.instanceReady ? String(localized: .settingsPhonePushCheckDevices) : String(localized: .settingsPhonePushServerFirst))
            }
        }
    }

    /// 「发给你的 2 台设备和 1 个 IM 账号」（与 Web testTargetHint 同一口径）
    static func testTarget(devices: Int, im: Int) -> String {
        let targets = [devices > 0 ? String(localized: .settingsPushChannelsDeviceCount(devices)) : nil, im > 0 ? String(localized: .settingsNotificationPreferencesImAccounts(im)) : nil].compactMap { $0 }
        return targets.isEmpty ? String(localized: .settingsPhonePushNoneReachable) : String(localized: .settingsPhonePushSendTo(targets.joined(separator: String(localized: .settingsPhonePushTargetJoin))))
    }

    private func sendTest() async {
        do {
            let result = try await model.sendTest()
            if result.sent > 0 {
                // IM 也是通知渠道（device_id 为 im），回执里单说，不算进「台设备」
                let im = result.results.contains { $0.deviceId == "im" && $0.result == "ok" }
                let devices = result.sent - (im ? 1 : 0)
                let target = [devices > 0 ? String(localized: .settingsPushChannelsDeviceCount(devices)) : nil, im ? "IM" : nil].compactMap { $0 }
                feedback.success(String(localized: .settingsPhonePushSentTo(target.joined(separator: String(localized: .settingsPhonePushTargetJoin)))))
            } else {
                feedback.info(result.results.map(\.message).first { !$0.isEmpty } ?? String(localized: .settingsPhonePushNoDevices))
            }
        } catch {
            feedback.error(error)
        }
    }
}
