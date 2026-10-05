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
    @State private var instanceName = ""
    @State private var nameEdited = false

    var body: some View {
        Form {
            switch connection.status {
            case .loading:
                Section { SettingsLoadingRow() }
            case let .failed(message):
                Section {
                    SettingsBNotice(text: message, tone: .danger)
                    SettingsBAsyncButton("重试") { await connection.load() }
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
        .refreshable { await connection.load() }
        .cloudApprovalPage(connection)
        .onChange(of: connection.value?.state) { old, new in
            // 在官网批准了（配对中 → 已连接）：提示一次
            if old != nil, old != "connected", new == "connected" { feedback.success("已连接到 MovieClaw 账号") }
        }
        .onChange(of: connection.value?.serverName, initial: true) { _, name in
            if !nameEdited, let name { instanceName = name }
        }
    }

    // MARK: 未连接 / 配对中

    @ViewBuilder
    private func disconnectedSections(_ status: API.CloudStatusView) -> some View {
        Section {
            SettingsBIntro(text: "把这台服务器连到你的 MovieClaw 账号，家人手机上的 MovieClaw App 就能收到通知。")
            if let last = status.lastDisconnect {
                SettingsBNotice(text: last.message.isEmpty ? "这台服务器已和 MovieClaw Cloud 断开" : last.message, tone: .warn)
            }
        }

        if connection.pendingPairing != nil || connection.endedPairing != nil {
            Section {
                CloudPairingRows(connection: connection)
            } header: {
                Text("在 MovieClaw 官网批准这次连接")
            } footer: {
                Text("这台服务器申请的权限：使用官方推送。关掉网页不会取消配对，在官网批准后这里会自动变成「已连接」。")
            }
        } else {
            Section {
                Text("连接需要一个 MovieClaw 账号，用 Apple、Google 或邮箱登录都可以。只有你（管理员）需要账号，家人不用。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsBTextField(label: "服务器名称", text: Binding(get: { instanceName }, set: {
                    instanceName = $0
                    nameEdited = true
                }), placeholder: status.serverName, hint: "官网上显示的名字，以后在官网也能改", identifier: "cloud-instance-name")
                HStack {
                    Spacer()
                    SettingsBAsyncButton {
                        await connect()
                    } label: {
                        Text("连接到 MovieClaw 账号").font(.body.weight(.semibold))
                    }
                    .settingsProminentButton()
                    .accessibilityIdentifier("cloud-connect")
                    Spacer()
                }
            } header: {
                Text("还没有连接")
            }
        }

        Section {
            if let url = Self.reportsInfoURL(cloudURL: status.cloudUrl) {
                Link("会向 MovieClaw Cloud 上报哪些信息？", destination: url)
                    .font(.subheadline)
            }
            if status.customCloudUrl {
                SettingsBValueRow(label: "云端地址", value: status.cloudUrl, mono: true)
            }
        } footer: {
            Text("只想用微信、Telegram 收通知？不用连接，用「IM 推送」就行。自己打包了 App？在网页端「设置 → App 推送」里添加自建推送中继。")
        }
        Section {
            NavigationLink(value: AppRoute.settingsSection(.imPush)) {
                Label(SettingsSection.imPush.title, systemImage: SettingsSection.imPush.systemImage)
            }
        }
    }

    private func connect() async {
        do {
            try await connection.connect(instanceName: instanceName)
        } catch {
            feedback.error(error)
        }
    }

    // MARK: 已连接

    @ViewBuilder
    private func connectedSections(_ status: API.CloudStatusView) -> some View {
        let link = status.connection
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.icloud")
                    .font(.title2)
                    .foregroundStyle(status.health == "ok" || status.health == nil ? Theme.success : Theme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.connectedTitle(link?.accountDisplay))
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(link?.instanceName ?? status.serverName)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 8)
                SettingsBBadge(text: healthLabel(status.health), tone: healthTone(status.health))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cloud-connected")
            if let link {
                if let connectedAt = link.connectedAt {
                    SettingsBValueRow(label: "连接于", value: Formatters.dateTime(connectedAt))
                }
            }
            if status.customCloudUrl {
                SettingsBValueRow(label: "云端地址", value: status.cloudUrl, mono: true)
            }
        }

        if let health = status.health, health != "ok" {
            Section {
                SettingsBNotice(text: status.healthMessage ?? healthLabel(health), tone: healthTone(health))
                SettingsBAsyncButton {
                    do {
                        try await connection.renew()
                        if connection.value?.health == "ok" { feedback.success("已和 MovieClaw Cloud 同步") }
                    } catch {
                        feedback.error(error)
                    }
                } label: {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("cloud-renew")
            }
        }

        if !status.notices.isEmpty {
            Section {
                ForEach(status.notices, id: \.id) { notice in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: notice.level == "info" ? "info.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(notice.level == "info" ? Theme.info : Theme.warning)
                        Text(notice.message)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        SettingsBAsyncButton {
                            do { try await connection.dismiss(notice) } catch { feedback.error(error) }
                        } label: {
                            Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("关闭这条通知")
                    }
                }
            } header: {
                Text("来自 MovieClaw 的通知")
            }
        }

        if let link {
            Section {
                ForEach(link.scopes, id: \.self) { scope in
                    HStack {
                        SettingsRowText(title: scopeTitle(scope), detail: scope == "push" ? limitsText(link.limits) : nil)
                        Spacer()
                        SettingsBBadge(text: "已授予", tone: .ok)
                    }
                }
            } header: {
                Text("这台服务器能用的")
            }
        }

        Section {
            Toggle(isOn: Binding(get: { status.reportStats }, set: { value in
                Task {
                    do { try await connection.setReportStats(value) } catch { feedback.error(error) }
                }
            })) {
                SettingsRowText(title: "上报统计信息", detail: "关掉后只上报版本信息，推送不受影响，只是官网上少一些展示")
            }
            .accessibilityIdentifier("cloud-report-stats")
            if let url = Self.reportsInfoURL(cloudURL: status.cloudUrl) {
                Link("连接后会向 MovieClaw Cloud 上报哪些信息？", destination: url)
                    .font(.subheadline)
            }
        } header: {
            Text("上报")
        }

        Section {
            SettingsBAsyncButton(role: .destructive) {
                await disconnect()
            } label: {
                Text("断开连接")
            }
            .accessibilityIdentifier("cloud-disconnect")
        } footer: {
            Text("家人手机上的官方推送会立即停止。自建推送中继不受影响。")
        }
    }

    /// 断开要二次确认；云端连不上时再问一次，确认后只删这台服务器上的凭证
    private func disconnect() async {
        guard await feedback.confirm("断开 MovieClaw Cloud？", message: "家人手机上的官方推送会立即停止。自建推送中继不受影响。",
                                     confirmTitle: "断开", destructive: true) else { return }
        do {
            try await connection.disconnect(force: false)
            feedback.success("已断开 MovieClaw Cloud")
        } catch let error as APIError where error.isCloudUnreachable {
            guard await feedback.confirm("连不上 MovieClaw Cloud，仍要断开吗？",
                                         message: "只会删掉这台服务器上的连接凭证。断开后请到 movieclaw.io 把这台服务器也删掉。",
                                         confirmTitle: "仍要断开", destructive: true) else { return }
            do {
                try await connection.disconnect(force: true)
                feedback.success("已断开。记得到 movieclaw.io 把这台服务器也删掉")
            } catch {
                feedback.error(error)
            }
        } catch {
            feedback.error(error)
        }
    }

    /// 「已连接到 y•••@gmail.com 的 MovieClaw 账号」
    static func connectedTitle(_ account: String?) -> String {
        guard let account, !account.isEmpty else { return "已连接到 MovieClaw 账号" }
        return "已连接到 \(account) 的 MovieClaw 账号"
    }

    private func healthLabel(_ health: String?) -> String {
        switch health {
        case nil, "ok": "正常"
        case "unreachable": "连不上云端"
        case "expired": "凭证已过期"
        case "unsupported": "版本不受支持"
        default: "异常"
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
        scope == "push" ? "官方推送" : scope
    }

    private func limitsText(_ limits: [String: Int]) -> String {
        // 负数是不限（云端协议），不写「每天最多 -1 条」
        guard let day = limits["day"], day > 0 else { return "给登录了这台服务器的手机发通知" }
        return "给登录了这台服务器的手机发通知，每天最多 \(day) 条"
    }

    /// 官网隐私政策里「你的服务器会发给我们什么」那一节：官网地址由云端地址去掉开头的 `api.` 得出（同网页 cloudSiteOrigin）
    static func reportsInfoURL(cloudURL: String) -> URL? {
        guard var components = URLComponents(string: cloudURL), let host = components.host,
              components.scheme == "https" || components.scheme == "http"
        else { return URL(string: "https://movieclaw.io/zh/privacy#server-reports") }
        components.host = host.hasPrefix("api.") ? String(host.dropFirst(4)) : host
        components.path = "/zh/privacy"
        components.query = nil
        components.fragment = "server-reports"
        return components.url
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
                Text("配对码").font(.caption).foregroundStyle(Theme.textMuted)
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
                    Label("打开 movieclaw.io 批准", systemImage: "safari").font(.body.weight(.semibold))
                }
                .settingsProminentButton()
                .accessibilityIdentifier("cloud-open-approval")
                Spacer()
            }
            HStack(spacing: 10) {
                ProgressView()
                Text("等待批准…").foregroundStyle(Theme.textMuted)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.expiry(pairing.expiresAt, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                }
            }
            SettingsBAsyncButton("取消配对", role: .destructive) {
                do { try await connection.cancelPairing() } catch { feedback.error(error) }
            }
            .accessibilityIdentifier("cloud-cancel-pairing")
        } else if let pairing = connection.endedPairing {
            SettingsBNotice(text: pairing.message ?? Self.endedText(pairing.status), tone: pairing.status == "denied" ? .warn : .danger)
            SettingsBAsyncButton {
                do { try await connection.connect(instanceName: pairing.instanceName) } catch { feedback.error(error) }
            } label: {
                Label("重新获取配对码", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("cloud-retry-pairing")
        }
    }

    static func endedText(_ status: String) -> String {
        switch status {
        case "denied": "在官网上拒绝了这次连接。"
        case "expired": "配对码已过期。"
        default: "连接没有完成，请重试。"
        }
    }

    /// 「配对码 9:41 后失效」
    static func expiry(_ raw: String, now: Date) -> String {
        guard let date = Formatters.date(raw) else { return "" }
        let seconds = Int(date.timeIntervalSince(now).rounded(.down))
        guard seconds > 0 else { return "配对码已过期" }
        return String(format: "配对码 %d:%02d 后失效", seconds / 60, seconds % 60)
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
