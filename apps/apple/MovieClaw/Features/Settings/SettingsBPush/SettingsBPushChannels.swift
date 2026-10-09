import SwiftUI

// IM 推送 →「接入通道」标签（对应 Web `ChannelsTab` + `AddChannelMenu` + `ChannelAccountRowView`）。
//
// 通道来自通道插件（docs/design/plugin-channels.md）：列表、新增菜单、绑定弹层都按 `GET /channels`
// 返回的通道渲染，不认识具体平台。提供某个通道的插件关掉 / 卸载了，它的账号照常列出、标「插件未启用」。

/// 「接入通道」的全部 Section
struct SettingsBPushChannelsSections: View {
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @Environment(Router.self) private var router

    @State private var channels: [API.ChannelView] = []
    @State private var rows: [API.ChannelAccountView]?
    @State private var error: String?
    @State private var busy = false
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
                                ? "\(channel.title) 已接入，现在就可以给它发消息试试"
                                : "\(channel.title) 已接入，推送会发到那里"
                        )
                        Task { await load() }
                    }
                    .sheetFeedback()
                }
            // 前置门禁：对话完全由模型驱动，未接入模型时隐藏新增入口并引导
            if probe.state == .missing {
                HStack(alignment: .firstTextBaseline) {
                    Text("接入 AI 模型后即可解锁通道中的 AI 对话能力。")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("去接入") { router.push(.settingsSection(.llm)) }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("push-llm-setup")
                }
            }
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
                Text(rows == nil ? "加载中…" : rows!.isEmpty ? "还没有接入任何通道。" : "已接入 \(rows!.count) 个账号。")
                    .accessibilityIdentifier("push-channels-count")
                Spacer()
                if !addable.isEmpty {
                    addMenu
                }
            }
            .textCase(nil)
        }
    }

    /// 能对话的通道完全由模型驱动：没接模型时菜单里只留只推送的通道
    private var addable: [API.ChannelView] {
        channels.filter { probe.state != .missing || !$0.receive }
    }

    private var intro: some View {
        let code: (String) -> Text = { Text(" \($0) ").font(.caption.monospaced()).foregroundStyle(Theme.text) }
        return Text("接入的通道都是推送目标；能对话的通道里还能直接和 AI 助手聊：发消息即可搜片、订阅、查进度。发送\(code("/reset"))重置会话，\(code("/stop"))取消正在进行的处理。通道由插件提供，可以在网页的「设置 → 插件」里安装更多通道。")
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
                    Text("新增 \(channel.title) 通道")
                    if !channel.description.isEmpty {
                        Text(channel.description)
                    }
                }
                .accessibilityIdentifier("push-add-\(channel.id)")
            }
        } label: {
            Label("新增通道", systemImage: "plus")
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
            Text("还没有接入任何通道").font(.body.weight(.medium))
            Text(channels.isEmpty
                 ? "没有可用的通道：到网页的「设置 → 插件」看看通道插件是否都关掉了。"
                 : "点击右上角「新增通道」，支持\(channels.map(\.title).joined(separator: "、"))。")
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
            ? ("插件未启用", .neutral)
            : row.status == "stale"
                ? ("需重新绑定", .danger)
                : row.running ? ("运行中", .ok) : ("未运行", .neutral)
        let detail: String = !row.channelAvailable
            ? "提供这个通道的插件已关闭或卸载，账号保留，重新启用后自动恢复"
            : row.status == "stale"
                ? (row.lastError ?? "凭据已失效，请重新绑定")
                : "\(row.boundUserId ?? row.displayName) · 绑定于 \(SettingsBFormat.relative(row.boundAt))"
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
            Button("解绑") {
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
            error = "服务器版本较旧，升级 MovieClaw 后即可在这里管理通道。"
            rows = []
        } catch {
            self.error = error.localizedDescription
            rows = []
        }
    }

    private func unbind(_ row: API.ChannelAccountView) async {
        guard await feedback.confirm(
            "解绑该 \(title(of: row)) 账号？",
            message: "解绑后停止收发、删除凭据，需要重新绑定才能使用；历史对话保留。",
            confirmTitle: "解绑",
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
