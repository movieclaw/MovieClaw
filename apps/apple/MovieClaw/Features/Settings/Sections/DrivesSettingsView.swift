import SwiftUI

/// 「设置 → 网盘」（docs/design/cloud-storage.md §2、§11.7；网页 components/drives-section.tsx）。
///
/// 只回答「接了哪些网盘账号、它们好不好」：账号列表 + 扫码添加。网盘来自存储插件，卡片与登录按服务端给的声明
/// 渲染，不认识具体网盘。常用的只有「同时播放数」放在账号上；限速、每日预算只在网页「高级」里调。
/// 只有装了存储插件、或已有网盘账号时设置首页才列出这个分区（`DrivesAvailability`）。
struct DrivesSettingsView: View {
    @Environment(\.api) private var api
    @State private var accounts: Loadable<[API.DriveAccountView]> = .loading
    @State private var backends: [API.DriveBackendView] = []
    @State private var settings: API.DriveSettingsView?
    @State private var login: API.DriveBackendView?
    @State private var removing: API.DriveAccountView?
    @State private var actionError: String?

    var body: some View {
        List {
            SettingsFormSection {
                Text("媒体库可以放在网盘上：网盘里已有的片子直接看，新片下载后自动上传、本地自动腾空。网盘由插件提供，在网页「设置 → 插件」里安装。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
            if let actionError {
                SettingsFormSection { SettingsNotice(text: actionError) }
            }
            accountSection
            if let settings, !(accounts.value ?? []).isEmpty {
                SettingsFormSection {
                    Toggle("本地腾空后删除下载任务", isOn: Binding(mcGet: { settings.removeDownloadTasks }, set: { value in
                        Task { await saveSettings(value) }
                    }))
                    .accessibilityIdentifier("drives-remove-download-tasks")
                } header: { Text("上传到网盘之后") } footer: {
                    Text("主根在网盘的库，文件传上去、本地腾空后，把下载器里对应的任务连同下载目录里的数据一起删掉，空间才真正回来。有 H&R 考核的、不是 MovieClaw 投递的、还供着库里别的本地文件的种子都保留。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .appBackground()
        .task { await load() }
        .sheet(item: $login) { backend in
            DriveLoginSheet(backend: backend) { _ in
                login = nil
                Task { await load() }
            }
            .sheetFeedback()
        }
        .confirmationDialog(
            "移除网盘账号「\(removing?.name ?? "")」？",
            isPresented: Binding(mcGet: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { account in
            Button("移除", role: .destructive) { Task { await remove(account) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("只删除 MovieClaw 里的账号记录，不会动网盘上的任何文件。")
        }
    }

    @ViewBuilder private var accountSection: some View {
        switch accounts {
        case .loading:
            SettingsFormSection("账号") { SettingsLoadingRow() }
        case let .failed(message):
            SettingsFormSection("账号") {
                SettingsNotice(text: message)
                Button("重试") { Task { await load() } }
            }
        case let .loaded(rows):
            SettingsFormSection {
                if rows.isEmpty {
                    Text(backends.isEmpty
                         ? "没有可用的网盘：先在网页「设置 → 插件」安装网盘存储插件。"
                         : "还没有网盘账号，点下面添加，支持\(backends.map(\.title).joined(separator: "、"))。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                }
                ForEach(rows, id: \.id) { account in
                    DriveAccountRow(
                        account: account,
                        onSlots: { value in Task { await update(account, slots: value) } },
                        onRefresh: { Task { await refresh(account) } },
                        onRelogin: backends.first(where: { $0.type == account.backend }).map { backend in
                            { login = backend }
                        },
                        onRemove: { removing = account }
                    )
                }
                addButton
            } header: { Text("账号") }
        }
    }

    @ViewBuilder private var addButton: some View {
        let scannable = backends.filter(\.login.scan)
        if scannable.count == 1, let only = scannable.first {
            Button { login = only } label: { Label("添加\(only.title)账号", systemImage: "plus") }
                .accessibilityIdentifier("drives-add")
        } else if scannable.count > 1 {
            Menu {
                ForEach(scannable, id: \.type) { backend in
                    Button(backend.title) { login = backend }
                }
            } label: { Label("添加网盘账号", systemImage: "plus") }
                .accessibilityIdentifier("drives-add")
        }
    }

    private func load() async {
        do {
            async let rows = api.drivesAccountsList()
            async let available = api.drivesBackendsList()
            let (loaded, list) = try await (rows, available)
            accounts = .loaded(loaded)
            backends = list
            settings = try? await api.drivesSettingsGet()
        } catch {
            accounts = .failed(error.localizedDescription)
        }
    }

    private func replace(_ next: API.DriveAccountView) {
        guard var rows = accounts.value, let index = rows.firstIndex(where: { $0.id == next.id }) else { return }
        rows[index] = next
        accounts = .loaded(rows)
    }

    private func update(_ account: API.DriveAccountView, slots: Int) async {
        actionError = nil
        do {
            replace(try await api.drivesAccountsUpdate(
                accountId: account.id, body: API.DriveAccountUpdatePayload(readSlots: slots)))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func refresh(_ account: API.DriveAccountView) async {
        actionError = nil
        do {
            replace(try await api.drivesAccountsRefresh(accountId: account.id))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func remove(_ account: API.DriveAccountView) async {
        actionError = nil
        do {
            _ = try await api.drivesAccountsDelete(accountId: account.id)
            if let rows = accounts.value { accounts = .loaded(rows.filter { $0.id != account.id }) }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func saveSettings(_ value: Bool) async {
        let previous = settings
        settings?.removeDownloadTasks = value
        do {
            settings = try await api.drivesSettingsUpdate(body: API.DriveSettingsPayload(removeDownloadTasks: value))
        } catch {
            settings = previous
            actionError = error.localizedDescription
        }
    }
}

/// 一个网盘账号：名字、状态、容量、同时播放数。
private struct DriveAccountRow: View {
    let account: API.DriveAccountView
    let onSlots: (Int) -> Void
    let onRefresh: () -> Void
    let onRelogin: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Menu {
                    Button("刷新容量", systemImage: "arrow.clockwise", action: onRefresh)
                    if let onRelogin { Button("重新登录", systemImage: "qrcode", action: onRelogin) }
                    Button("移除账号", systemImage: "trash", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityIdentifier("drive-account-menu-\(account.id)")
            }
            if let status = statusText {
                Label(status, systemImage: account.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(account.status == "ok" ? Theme.success : Theme.warning)
            }
            Stepper(value: Binding(mcGet: { account.readSlots }, set: onSlots), in: 1...10) {
                Text("同时播放数 \(account.readSlots)")
            }
            .accessibilityIdentifier("drive-account-slots-\(account.id)")
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [account.backendTitle]
        if let used = account.quotaUsed, let total = account.quotaTotal, total > 0 {
            parts.append("已用 \(Formatters.bytes(used)) / \(Formatters.bytes(total))")
        }
        if !account.backendAvailable { parts.append("插件未安装") }
        return parts.joined(separator: " · ")
    }

    private var statusText: String? {
        switch account.status {
        case "ok": return nil
        case "auth_expired": return account.statusMessage ?? "登录已失效，需要重新登录"
        default: return account.statusMessage ?? "暂时不可用"
        }
    }
}

/// 扫码添加 / 重新登录一个网盘账号：选好登录选项（默认已选好）→ 二维码 → 手机上确认，服务端建好账号。
struct DriveLoginSheet: View {
    let backend: API.DriveBackendView
    let onDone: (API.DriveAccountView) -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var options: [String: String] = [:]
    @State private var flow: API.DriveLoginView?
    @State private var qrImage: UIImage?
    @State private var error: String?
    @State private var busy = false

    private var failed: Bool { ["expired", "failed"].contains(flow?.status ?? "") }

    var body: some View {
        SubsSheetScaffold(title: "添加\(backend.title)账号", closeTitle: "关闭") {
            if !backend.login.hint.isEmpty {
                SettingsFormSection { Text(backend.login.hint).font(.subheadline).foregroundStyle(Theme.textMuted) }
            }
            ForEach(backend.login.options, id: \.key) { option in
                SettingsFormSection {
                    Picker(option.label, selection: Binding(mcGet: { options[option.key] ?? option.default }, set: { value in
                        options[option.key] = value
                        Task { await begin() }
                    })) {
                        ForEach(option.choices, id: \.value) { choice in
                            Text(choice.value == option.default ? "\(choice.label)（推荐）" : choice.label).tag(choice.value)
                        }
                    }
                } footer: {
                    let chosen = option.choices.first { $0.value == (options[option.key] ?? option.default) }
                    if let help = chosen?.help.nonEmpty ?? option.help.nonEmpty { Text(help) }
                }
            }
            SettingsFormSection {
                VStack(spacing: 14) {
                    if let qrImage, !failed {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("drive-login-qr")
                    } else if busy {
                        ProgressView().frame(width: 200, height: 200)
                    }
                    Text(failed ? "登录未完成" : flow?.status == "scanned" ? "已扫描" : "用\(backend.title) App 扫码")
                        .font(.headline)
                    if let message = flow?.message.nonEmpty ?? (flow?.status == "pending" ? "扫码后在手机上确认登录" : nil) {
                        Text(message).font(.subheadline).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
                    }
                    if failed || (flow == nil && !busy) {
                        Button("重新扫码") { Task { await begin() } }.buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            if let error { SettingsFormSection { SettingsNotice(text: error) } }
        }
        .task { await begin() }
        .polling(every: 1.5) { await poll() }
        .onDisappear {
            if let flow, !failed, flow.status != "confirmed" {
                let api = api
                Task { _ = try? await api.drivesLoginsCancel(loginId: flow.loginId) }
            }
        }
    }

    private func begin() async {
        if let previous = flow, previous.status != "confirmed", !failed {
            _ = try? await api.drivesLoginsCancel(loginId: previous.loginId)
        }
        busy = true
        error = nil
        defer { busy = false }
        var picked: [String: String] = [:]
        for option in backend.login.options { picked[option.key] = options[option.key] ?? option.default }
        do {
            let started = try await api.drivesLoginsStart(body: API.DriveLoginPayload(backend: backend.type, options: picked))
            flow = started
            qrImage = SettingsBPushQRCode.image(for: started.qrText)
        } catch {
            flow = nil
            self.error = error.localizedDescription
        }
    }

    private func poll() async {
        guard let current = flow, !failed, current.status != "confirmed" else { return }
        guard let next = try? await api.drivesLoginsStatus(loginId: current.loginId) else { return }
        if next.status == "confirmed", let account = next.account {
            flow = next
            onDone(account)
            dismiss()
            return
        }
        flow = next
        if next.qrText != current.qrText { qrImage = SettingsBPushQRCode.image(for: next.qrText) }
    }
}

/// 设置首页要不要列出「网盘」：装了存储插件、或已经有网盘账号（插件卸载后仍要看得到账号）。
enum DrivesAvailability {
    static func check(_ api: APIClient) async -> Bool {
        async let backends = try? api.drivesBackendsList()
        async let accounts = try? api.drivesAccountsList()
        let (b, a) = await (backends, accounts)
        return !(b ?? []).isEmpty || !(a ?? []).isEmpty
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
