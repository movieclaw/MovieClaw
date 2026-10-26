import SwiftUI

// IM 推送页（对应 Web `ImPushSection` + `AddChannelMenu` + `ChannelAccountRowView`）。
//
// 「推什么」不在这里：IM 只是通知的一个渠道，和手机 App 一样按「设置 → 通知」的开关推
// （docs/design/cloud-push.md §5）。这里只管接了哪些账号，外加一键测试推送。
//
// 通道来自通道插件（docs/design/plugin-channels.md）：列表、新增菜单、绑定弹层都按 `GET /channels`
// 返回的通道渲染，不认识具体平台。提供某个通道的插件关掉 / 卸载了，它的账号照常列出、标「插件未启用」。

/// IM 推送页的全部 Section
struct SettingsBPushChannelsSections: View {
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @Environment(Router.self) private var router

    @State private var channels: [API.ChannelView] = []
    @State private var rows: [API.ChannelAccountView]?
    @State private var error: String?
    @State private var busy = false
    @State private var pushBusy = false
    /// 正在绑定的通道（nil = 没开弹层）
    @State private var binding: API.ChannelView?
    private var probe: LLMCapabilityProbe { .shared }

    var body: some View {
        SettingsFormSection {
            // 生命周期修饰符挂在常驻的说明行上：挂在 Section 上会被 List 分发到每一行，
            // 变成多份任务 / 多个 sheet 呈现者
            intro
                .task {
                    async let probing: Void = probe.ensure(api: api)
                    await load()
                    await probing
                }
                .sheet(item: $binding) { channel in
                    SettingsBPushBindSheet(channel: channel) {
                        binding = nil
                        feedback.success(
                            channel.receive
                                ? String(localized: .settingsImChannelsBoundChat(channel.title))
                                : String(localized: .settingsImChannelsBoundPush(channel.title))
                        )
                        Task { await load() }
                    }
                    .sheetFeedback()
                }
            // 前置门禁：对话完全由模型驱动，未接入模型时隐藏新增入口并引导
            if probe.state == .missing {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: .settingsPushChannelsNeedModel))
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(String(localized: .settingsLlmConnectModel)) { router.push(.settingsSection(.llm)) }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("push-llm-setup")
                }
            }
            NavigationLink(value: AppRoute.settingsSection(.notifications)) {
                Label(String(localized: .settingsPushChannelsWhich), systemImage: SettingsSection.notifications.systemImage)
            }
            .accessibilityIdentifier("push-notifications-link")
            if let error {
                SettingsBNotice(text: error, tone: .danger)
                    .accessibilityIdentifier("push-channels-error")
            }
        }

        SettingsFormSection {
            if let rows {
                if rows.isEmpty {
                    emptyState
                } else {
                    ForEach(rows) { row in
                        accountRow(row)
                    }
                }
            } else {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 48)
                }
            }
        } header: {
            HStack {
                Text(rows == nil ? String(localized: .commonLoadingProgress) : rows!.isEmpty ? String(localized: .settingsPushChannelsNone) : String(localized: .settingsPushChannelsAccounts(rows!.count)))
                    .accessibilityIdentifier("push-channels-count")
                Spacer()
                if !addable.isEmpty {
                    addMenu
                }
            }
            .textCase(nil)
        }

        // 测试推送：验证已接入通道确实能收到消息
        if let rows, !rows.isEmpty {
            SettingsFormSection {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: .settingsImChannelsTestLabel)).font(.body.weight(.medium))
                        Text(String(localized: .settingsImChannelsTestDescription)).font(.caption).foregroundStyle(Theme.textFaint)
                    }
                    Spacer(minLength: 8)
                    SettingsBAsyncButton(String(localized: .settingsWebhookUiSendTest)) { await testPush() }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.glass)
                        .disabled(pushBusy)
                        .accessibilityIdentifier("push-test")
                }
            }
        }
    }

    /// 能对话的通道完全由模型驱动：没接模型时菜单里只留只推送的通道
    private var addable: [API.ChannelView] {
        channels.filter { probe.state != .missing || !$0.receive }
    }

    private var intro: some View {
        let code: (String) -> Text = { Text(" \($0) ").font(.caption.monospaced()).foregroundStyle(Theme.text) }
        let lead: Text = Text(String(localized: .settingsPushChannelsIntroLead)) + code("/reset")
        let rest: Text = Text(String(localized: .settingsPushChannelsIntroMiddle)) + code("/stop")
        return (lead + rest + Text(String(localized: .settingsPushChannelsIntroTail)))
            .font(.footnote)
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「新增通道」菜单：平台名 + 一句话说明，点选即开绑定弹层
    private var addMenu: some View {
        Menu {
            ForEach(addable) { channel in
                Button {
                    binding = channel
                } label: {
                    Text(String(localized: .settingsImChannelsAddNamed(channel.title)))
                    if !channel.description.isEmpty {
                        Text(channel.description)
                    }
                }
                .accessibilityIdentifier("push-add-\(channel.id)")
            }
        } label: {
            Label(String(localized: .settingsImChannelsAdd), systemImage: "plus")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.glass)
        .disabled(rows == nil)
        .accessibilityIdentifier("push-add-channel")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.title2)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 14))
            Text(String(localized: .settingsImChannelsEmpty)).font(.body.weight(.medium))
            Text(channels.isEmpty
                 ? String(localized: .settingsPushChannelsNoneAvailable)
                 : String(localized: .settingsPushChannelsAddHint(AppFormatting.list(channels.map(\.title)))))
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("push-channels-empty")
    }

    /// 一行已接入账号：平台名 + 运行状态 + 绑定人 / 失效原因 + 解绑
    private func title(of row: API.ChannelAccountView) -> String {
        channels.first { $0.id == row.channelId }?.title ?? row.channelId
    }

    private func accountRow(_ row: API.ChannelAccountView) -> some View {
        let badge: (text: String, tone: SettingsBTone) = !row.channelAvailable
            ? (String(localized: .settingsImChannelsPluginDisabled), .neutral)
            : row.status == "stale"
                ? (String(localized: .settingsImChannelsStale), .danger)
                : row.running ? (String(localized: .settingsMcpControlsRunning), .ok) : (String(localized: .settingsImChannelsStopped), .neutral)
        let detail: String = !row.channelAvailable
            ? String(localized: .settingsImChannelsDisabledDescription)
            : row.status == "stale"
                ? (row.lastError ?? String(localized: .settingsImChannelsStaleDescription))
                : String(localized: .settingsImChannelsBoundAt(row.boundUserId ?? row.displayName, SettingsBFormat.relative(row.boundAt)))
        return HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.body)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title(of: row)).font(.body.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        SettingsBDot(tone: badge.tone, size: 6)
                        Text(badge.text)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(badge.tone == .neutral ? Theme.text.opacity(0.75) : badge.tone.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((badge.tone == .neutral ? Color.white : badge.tone.color).opacity(0.12), in: .capsule)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(String(localized: .settingsImChannelsUnbind)) {
                Task { await unbind(row) }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.danger)
            .buttonStyle(.glass)
            .disabled(busy)
            .accessibilityIdentifier("push-unbind-\(row.channelId)-\(row.accountId)")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("push-account-\(row.channelId)-\(row.accountId)")
    }

    // MARK: 数据

    private func load() async {
        do {
            let data = try await api.channelsList()
            error = nil
            channels = data.channels
            rows = data.accounts
        } catch is CancellationError {
        } catch let failure as APIError where failure.status == 404 {
            // 服务器还没有通用的通道接口（插件化之前的版本）
            error = String(localized: .settingsPushChannelsServerOld)
            rows = []
        } catch {
            self.error = error.localizedDescription
            rows = []
        }
    }

    private func testPush() async {
        pushBusy = true
        defer { pushBusy = false }
        do {
            let result = try await api.channelsImPushTest(body: .init(text: ""))
            feedback.success(String(localized: .settingsPushChannelsTestSent(result["sent"]?.intValue ?? 0)))
        } catch {
            feedback.error(error.localizedDescription)
        }
    }

    private func unbind(_ row: API.ChannelAccountView) async {
        guard await feedback.confirm(
            String(localized: .settingsImChannelsUnbindTitle(title(of: row))),
            message: String(localized: .settingsImChannelsUnbindDescription),
            confirmTitle: String(localized: .settingsImChannelsUnbind),
            destructive: true
        ) else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            _ = try await api.channelsAccountsUnbind(channelId: row.channelId, accountId: row.accountId)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
