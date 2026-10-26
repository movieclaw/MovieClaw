import SwiftUI

/// 设置 → MovieClaw Cloud（管理员，docs/design/cloud-push.md §1、§7.1；对应网页 /settings/cloud）。
///
/// 把整台服务器连到管理员的 MovieClaw 账号：连上之后官方推送就能用，家人的 App 都能收到通知。叫「连接」，
/// 不叫登录、绑定——服务器拿到的是它自己的凭证，只能用授予它的能力（本期只有推送），碰不到账号本身。
/// 四种样子：未连接（讲清楚会发什么、不会发什么）/ 配对中 / 已连接 / 异常（续签失败、版本不受支持）。
struct CloudSettingsView: View {
    @Environment(\.api) private var api

    var body: some View {
        CloudSettingsContent(connection: CloudConnection(api: api))
    }
}

private struct CloudSettingsContent: View {
    @State var connection: CloudConnection
    @Environment(Feedback.self) private var feedback
    @State private var connecting = false
    @State private var showingDetails = false
    @State private var busy = false

    var body: some View {
        Form {
            switch connection.status {
            case .loading:
                SettingsFormSection { SettingsLoadingRow() }
            case let .failed(message):
                SettingsFormSection {
                    SettingsBNotice(text: message, tone: .danger)
                    SettingsBAsyncButton(String(localized: .commonRetry)) { await connection.load() }
                }
            case let .loaded(status):
                if status.state == "connected" {
                    connectedSections(status)
                } else {
                    disconnectedSections(status)
                }
            }
        }
        .settingsBFormStyle()
        .task { await connection.load() }
        .refreshable {
            guard !busy else { return }
            busy = true
            await connection.load()
            busy = false
        }
        .toolbar {
            if connection.isConnected {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(String(localized: .settingsCloudConnectSyncNow), systemImage: "arrow.triangle.2.circlepath") {
                            Task { await renew() }
                        }
                        .accessibilityIdentifier("cloud-renew")
                        Button(String(localized: .settingsCloudConnectDisconnectAction), systemImage: "icloud.slash", role: .destructive) {
                            Task {
                                busy = true
                                defer { busy = false }
                                await disconnect()
                            }
                        }
                        .accessibilityIdentifier("cloud-disconnect")
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .disabled(busy)
                    .accessibilityLabel(String(localized: .settingsCloudConnectionActions))
                    .accessibilityIdentifier("cloud-actions")
                }
            }
        }
        .sheet(isPresented: $connecting, onDismiss: { connection.openApprovalPage() }) {
            CloudConnectSheet(connection: connection, serverName: connection.value?.serverName ?? "")
                .sheetFeedback()
        }
        .sheet(isPresented: $showingDetails) {
            SubsSheetScaffold(title: String(localized: .settingsCloudConnectionDetails), closeTitle: String(localized: .commonClose)) {
                if let status = connection.value {
                    SettingsFormSection {
                        SettingsBValueRow(label: String(localized: .settingsCloudServerLabel), value: status.connection?.instanceName ?? status.serverName)
                        if let account = status.connection?.accountDisplay {
                            SettingsBValueRow(label: String(localized: .settingsMembersCredentialsAccount), value: account)
                        }
                        if let date = status.connection?.connectedAt {
                            SettingsBValueRow(label: String(localized: .settingsCloudConnectedAt), value: Formatters.dateTime(date))
                        }
                        SettingsBValueRow(label: String(localized: .settingsCloudCloudUrl), value: status.cloudUrl, mono: true)
                    }
                    if let link = status.connection {
                        SettingsFormSection(String(localized: .settingsCloudGrantedPermissions)) {
                            ForEach(link.scopes, id: \.self) { scope in
                                Label(scopeTitle(scope), systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.success)
                            }
                        }
                    }
                }
            }
            .sheetFeedback()
        }
        .cloudApprovalPage(connection)
        .onChange(of: connection.value?.state) { old, new in
            if old != nil, old != "connected", new == "connected" { feedback.success(String(localized: .settingsCloudConnectedToast)) }
        }
    }

    // MARK: 未连接 / 配对中

    @ViewBuilder
    private func disconnectedSections(_ status: API.CloudStatusView) -> some View {
        SettingsFormSection {
            HStack(spacing: 14) {
                Image(systemName: "icloud")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: .settingsCloudConnectAccount)).font(.headline)
                    Text(String(localized: .settingsCloudConnectPitch))
                        .font(.subheadline).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.vertical, 8)
            if let last = status.lastDisconnect {
                SettingsBNotice(text: last.message.isEmpty ? String(localized: .settingsCloudDisconnectedNotice) : last.message, tone: .warn)
            }
        }

        if connection.pendingPairing != nil || connection.endedPairing != nil {
            SettingsFormSection {
                CloudPairingRows(connection: connection)
            } header: {
                Text(String(localized: .settingsCloudAwaitingWebsite))
            } footer: {
                Text(String(localized: .settingsCloudPendingHint))
            }
        } else {
            SettingsFormSection {
                Button { connecting = true } label: {
                    Text(String(localized: .settingsCloudConnectButton))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .settingsProminentButton()
                .accessibilityIdentifier("cloud-connect")
            } footer: {
                Text(String(localized: .settingsCloudAdminOnlyHint))
            }
        }

        SettingsFormSection {
            if let url = Self.reportsInfoURL(cloudURL: status.cloudUrl) {
                Link(destination: url) {
                    Label(String(localized: .settingsCloudPrivacyLink), systemImage: "hand.raised")
                }
            }
            if let url = Self.accountSettingsURL(cloudURL: status.cloudUrl) {
                Link(destination: url) {
                    Label(String(localized: .settingsCloudManageAccount), systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("cloud-account-settings")
            }
            if status.customCloudUrl {
                SettingsBValueRow(label: String(localized: .settingsCloudCloudUrl), value: status.cloudUrl, mono: true)
            }
            NavigationLink(value: AppRoute.settingsSection(.imPush)) {
                Label(SettingsSection.imPush.title, systemImage: SettingsSection.imPush.systemImage)
            }
        } footer: {
            Text(String(localized: .settingsCloudImHint))
        }
    }

    // MARK: 已连接

    @ViewBuilder
    private func connectedSections(_ status: API.CloudStatusView) -> some View {
        let healthy = status.health == "ok" || status.health == nil
        let account = status.connection?.accountDisplay.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SettingsFormSection {
            Button { showingDetails = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: healthy ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill")
                        .font(.largeTitle)
                        .foregroundStyle(healthy ? Theme.success : Theme.warning)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(account.isEmpty ? String(localized: .settingsCloudAccountFallback) : account)
                            .font(.headline).foregroundStyle(Theme.text)
                        Label(healthy ? String(localized: .settingsDevicesLabelsConnected) : healthLabel(status.health), systemImage: healthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(healthy ? Theme.success : Theme.warning)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
                .padding(.vertical, 6)
            }
            .disabled(busy)
            .accessibilityIdentifier("cloud-connected")
        }

        if let health = status.health, health != "ok" {
            SettingsFormSection {
                SettingsBNotice(text: status.healthMessage ?? healthLabel(health), tone: healthTone(health))
                SettingsBAsyncButton {
                    await renew()
                } label: {
                    Label(String(localized: .settingsCloudConnectSyncNow), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(busy)
                .accessibilityIdentifier("cloud-health-renew")
            }
        }

        if !status.notices.isEmpty {
            SettingsFormSection(String(localized: .settingsCloudConnectNoticeTitle)) {
                ForEach(status.notices, id: \.id) { notice in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: notice.level == "info" ? "info.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(notice.level == "info" ? Theme.info : Theme.warning)
                        Text(notice.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        SettingsBAsyncButton {
                            busy = true
                            defer { busy = false }
                            do { try await connection.dismiss(notice) } catch { feedback.error(error) }
                        } label: {
                            Image(systemName: "xmark").font(.footnote.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .accessibilityLabel(String(localized: .settingsCloudConnectDismissNotice))
                    }
                }
            }
        }

        if let link = status.connection {
            SettingsFormSection {
                ForEach(link.scopes, id: \.self) { scope in
                    LabeledContent(scopeTitle(scope)) {
                        Label(String(localized: .settingsControlsEnabled), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    }
                }
            } header: {
                Text(String(localized: .settingsCloudServices))
            } footer: {
                if link.scopes.contains("push") { Text(limitsText(link.limits)) }
            }
        }

        SettingsFormSection {
            Toggle(String(localized: .settingsCloudConnectReportStats), isOn: Binding(get: { status.reportStats }, set: { value in
                busy = true
                Task {
                    defer { busy = false }
                    do { try await connection.setReportStats(value) } catch { feedback.error(error) }
                }
            }))
            .disabled(busy)
            .accessibilityIdentifier("cloud-report-stats")
            if let url = Self.reportsInfoURL(cloudURL: status.cloudUrl) {
                Link(String(localized: .settingsCloudPrivacyLink), destination: url)
            }
            if let url = Self.accountSettingsURL(cloudURL: status.cloudUrl) {
                Link(String(localized: .settingsCloudManageAccount), destination: url)
                    .accessibilityIdentifier("cloud-account-settings")
            }
        } header: {
            Text(String(localized: .settingsCloudPrivacy))
        } footer: {
            Text(String(localized: .settingsCloudStatsOffHint))
        }
    }

    private func renew() async {
        busy = true
        defer { busy = false }
        do {
            try await connection.renew()
            if connection.value?.health == "ok" { feedback.success(String(localized: .settingsCloudConnectSynced)) }
        } catch { feedback.error(error) }
    }

    /// 断开要二次确认；云端连不上时再问一次，确认后只删这台服务器上的凭证
    private func disconnect() async {
        guard await feedback.confirm(String(localized: .settingsCloudDisconnectTitle), message: String(localized: .settingsCloudDisconnectHint),
                                     confirmTitle: String(localized: .settingsCloudConnectDisconnect), destructive: true) else { return }
        do {
            try await connection.disconnect(force: false)
            feedback.success(String(localized: .settingsCloudDisconnectedToast))
        } catch let error as APIError where error.isCloudUnreachable {
            guard await feedback.confirm(String(localized: .settingsCloudForceTitle),
                                         message: String(localized: .settingsCloudForceHint),
                                         confirmTitle: String(localized: .settingsCloudConnectForceDisconnect), destructive: true) else { return }
            do {
                try await connection.disconnect(force: true)
                feedback.success(String(localized: .settingsCloudForceToast))
            } catch {
                feedback.error(error)
            }
        } catch {
            feedback.error(error)
        }
    }

    private func healthLabel(_ health: String?) -> String {
        switch health {
        case nil, "ok": String(localized: .settingsDrivesHealthy)
        case "unreachable": String(localized: .settingsCloudHealthUnreachable)
        case "expired": String(localized: .settingsCloudHealthExpired)
        case "unsupported": String(localized: .settingsCloudHealthUnsupported)
        default: String(localized: .settingsCloudHealthError)
        }
    }

    private func healthTone(_ health: String?) -> SettingsBTone {
        switch health {
        case nil, "ok": .ok
        case "unreachable": .warn
        default: .danger
        }
    }

    private func scopeTitle(_ scope: String) -> String {
        scope == "push" ? String(localized: .settingsCloudConnectCapabilityPush) : scope
    }

    private func limitsText(_ limits: [String: Int]) -> String {
        // 负数是不限（云端协议），不写「每天最多 -1 条」
        guard let day = limits["day"], day > 0 else { return String(localized: .settingsCloudPushScope) }
        return String(localized: .settingsCloudPushScopeDaily(day))
    }

    /// 官网隐私政策里「你的服务器会发给我们什么」那一节
    static func reportsInfoURL(cloudURL: String) -> URL? {
        siteURL(cloudURL: cloudURL, path: "/zh/privacy", fragment: "server-reports")
    }

    /// 官网的账号设置页：登录方式、登录设备与删除账号都在这里。连接 Cloud 时会在官网注册账号，
    /// App 里要能直达删除账号的地方（App Store 审核条款 5.1.1(v)）
    static func accountSettingsURL(cloudURL: String) -> URL? {
        siteURL(cloudURL: cloudURL, path: "/zh/settings", fragment: nil)
    }

    /// 官网地址由云端地址去掉开头的 `api.` 得出（同网页 cloudSiteOrigin）；云端地址不可用时落到官方官网
    private static func siteURL(cloudURL: String, path: String, fragment: String?) -> URL? {
        guard var components = URLComponents(string: cloudURL), let host = components.host,
              components.scheme == "https" || components.scheme == "http"
        else {
            let anchor: String = fragment.map { "#" + $0 } ?? ""
            return URL(string: "https://movieclaw.io" + path + anchor)
        }
        components.host = host.hasPrefix("api.") ? String(host.dropFirst(4)) : host
        components.path = path
        components.query = nil
        components.fragment = fragment
        return components.url
    }
}

private struct CloudConnectSheet: View {
    let connection: CloudConnection
    let serverName: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false

    var body: some View {
        SubsSheetScaffold(title: String(localized: .settingsCloudConnectButton), onClose: {
            if name.isEmpty { dismiss() } else { discarding = true }
        }, confirm: .init(title: String(localized: .commonContinue), busy: busy, identifier: "cloud-connect-continue") {
            Task {
                busy = true
                error = nil
                defer { busy = false }
                do {
                    try await connection.connect(instanceName: name.isEmpty ? serverName : name, openApproval: false)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }) {
            SettingsFormSection {
                SettingsBTextField(label: String(localized: .settingsCloudConnectServerName), text: $name, placeholder: serverName,
                                   identifier: "cloud-instance-name")
            } footer: {
                Text(String(localized: .settingsCloudNameHint))
            }
            SettingsFormSection {
                Label(String(localized: .settingsCloudConnectCapabilityPush), systemImage: "bell.badge")
            } header: {
                Text(String(localized: .settingsCloudRequestedPermissions))
            } footer: {
                Text(String(localized: .settingsCloudContinueHint))
            }
            if let error { SettingsFormSection { SettingsBNotice(text: error, tone: .danger) } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || !name.isEmpty)
        .alert(String(localized: .settingsCloudDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsPluginPackagesDiscard), role: .destructive) { dismiss() }
        }
    }
}

/// 配对中的几行（「MovieClaw Cloud」页与「通知」页的开启卡片共用）：配对码、打开批准页、等待批准与倒计时、取消；
/// 没成的配对显示原因和「重新获取配对码」。轮询挂在页面上（见 `cloudApprovalPage`）
struct CloudPairingRows: View {
    let connection: CloudConnection
    @Environment(Feedback.self) private var feedback

    var body: some View {
        if let pairing = connection.pendingPairing {
            VStack(spacing: 4) {
                Text(String(localized: .settingsDevicesApprovalCode)).font(.caption).foregroundStyle(Theme.textMuted)
                Text(pairing.userCode)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("cloud-user-code")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            HStack {
                Spacer()
                Button {
                    connection.openApprovalPage()
                } label: {
                    Label(String(localized: .settingsCloudOpenWebsite), systemImage: "safari").font(.body.weight(.semibold))
                }
                .settingsProminentButton()
                .accessibilityIdentifier("cloud-open-approval")
                Spacer()
            }
            HStack(spacing: 10) {
                ProgressView()
                Text(String(localized: .settingsCloudWaitingEllipsis)).foregroundStyle(Theme.textMuted)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.expiry(pairing.expiresAt, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                }
            }
            SettingsBAsyncButton(String(localized: .settingsCloudCancelPairing), role: .destructive) {
                do { try await connection.cancelPairing() } catch { feedback.error(error) }
            }
            .accessibilityIdentifier("cloud-cancel-pairing")
        } else if let pairing = connection.endedPairing {
            SettingsBNotice(text: pairing.message ?? Self.endedText(pairing.status), tone: pairing.status == "denied" ? .warn : .danger)
            SettingsBAsyncButton {
                do { try await connection.connect(instanceName: pairing.instanceName) } catch { feedback.error(error) }
            } label: {
                Label(String(localized: .settingsCloudConnectGetNewCode), systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("cloud-retry-pairing")
        }
    }

    static func endedText(_ status: String) -> String {
        switch status {
        case "denied": String(localized: .settingsCloudEndedDenied)
        case "expired": String(localized: .settingsCloudConnectFailureExpired)
        default: String(localized: .settingsCloudEndedOther)
        }
    }

    /// 「配对码 9:41 后失效」
    static func expiry(_ raw: String, now: Date) -> String {
        guard let date = Formatters.date(raw) else { return "" }
        let seconds = Int(date.timeIntervalSince(now).rounded(.down))
        guard seconds > 0 else { return String(localized: .settingsCloudCodeExpired) }
        return String(localized: .settingsCloudCodeExpiresIn(String(format: "%d:%02d", seconds / 60, seconds % 60)))
    }
}

extension View {
    /// 连接 MovieClaw Cloud 要的两样东西：官网批准页的网页框；配对中每 2 秒问一次实例（网页框开着、关掉后都问），
    /// 批准了就变成「已连接」。挂在页面上而不是某一行上：列表里的行滚出屏幕会被卸载
    func cloudApprovalPage(_ connection: CloudConnection) -> some View {
        @Bindable var connection = connection
        return sheet(item: $connection.approvalPage, onDismiss: {
            Task { await connection.load() }
        }) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .background {
            if connection.pendingPairing != nil {
                Color.clear.polling(every: 2) { await connection.load() }
            }
        }
    }
}
