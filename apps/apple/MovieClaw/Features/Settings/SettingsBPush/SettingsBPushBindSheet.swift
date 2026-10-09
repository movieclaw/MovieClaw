import CoreImage.CIFilterBuiltins
import SwiftUI

/// 「接入通道」绑定弹层（对应 Web `channel-bind-dialog.tsx`）——所有通道共用一层壳。
///
/// 通道是插件（docs/design/plugin-channels.md §5.2），弹层不认识任何具体平台：按通道声明的
/// 绑定方式通用渲染。
/// - 交互式（flow，如微信扫码）：进弹层即发起 → 二维码与状态 → 需要时填输入框（微信手机上显示的
///   配对数字）→ 完成；
/// - 表单（form）：按字段渲染输入框 → 提交。带配对码的（Telegram / Discord）显示 6 位码，用户私聊
///   bot 发码后完成；不带配对的（飞书 Webhook）提交即完成。
/// 未完成的状态靠 2 秒一次的轮询推进（后端只读内存快照，毫秒级返回），与 Web 同一间隔。
/// 轮询 / 自动发起这类副作用只挂在一个常驻行上——列表会把修饰符分发给每一行，挂在整段上会变成多份。
struct SettingsBPushBindSheet: View {
    let channel: API.ChannelView
    /// 绑定完成：由调用方负责关闭弹层并刷新通道列表
    let onBound: () -> Void

    var body: some View {
        SubsSheetScaffold(
            title: "接入 \(channel.title)",
            subtitle: channel.binding.hint.isEmpty ? channel.description : channel.binding.hint,
            closeTitle: "关闭"
        ) {
            if channel.binding.kind == "flow" {
                SettingsBPushFlowBody(channel: channel, onBound: onBound)
            } else {
                SettingsBPushFormBody(channel: channel, onBound: onBound)
            }
        }
    }
}

/// 绑定已完成（交给调用方关弹层）/ 失败需重来
private let doneStatuses: Set<String> = ["confirmed", "already_bound"]
private let failedStatuses: Set<String> = ["expired", "failed"]

// MARK: - 共用小件

/// 弹层里的状态行（居中排版，行底由表单提供）
private struct SettingsBPushStatusCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 14) { content() }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

/// 单行输入（表单行里的原生输入框）
private struct SettingsBPushInput: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var mono = false
    let identifier: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: $text)
            .font(mono ? .body.monospaced() : .body)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(onSubmit)
            .accessibilityIdentifier(identifier)
    }
}

/// 本地生成二维码。
///
/// Web 直接显示服务端渲染好的 SVG data URL（`qr_image`），iOS 没有现成的 SVG 渲染，
/// 于是用 CoreImage 把二维码内容（`qr`，即 SVG 编码的同一串）本地画出来，
/// 最近邻放大保证边缘锐利。
enum SettingsBPushQRCode {
    static func image(for content: String) -> UIImage? {
        guard !content.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 交互式：二维码 + 可选输入

private struct SettingsBPushFlowBody: View {
    let channel: API.ChannelView
    let onBound: () -> Void

    @Environment(\.api) private var api
    @State private var binding: API.ChannelBindingView?
    @State private var qrImage: UIImage?
    @State private var value = ""
    @State private var error: String?
    @State private var busy = false
    /// 进弹层即发起只自动一次；失败 / 过期后由用户点按钮重来，不无限重试
    @State private var autoStarted = false
    @FocusState private var inputFocused: Bool

    private var failed: Bool { binding.map { failedStatuses.contains($0.status) } ?? false }
    private var polling: Bool {
        guard let status = binding?.status else { return false }
        return !doneStatuses.contains(status) && !failedStatuses.contains(status)
    }

    var body: some View {
        if let error {
            SettingsFormSection {
                SubsNoticeRow(text: error, tone: .error).accessibilityIdentifier("push-bind-error")
            }
        }
        SettingsFormSection {
            statusRow
                .task {
                    guard !autoStarted else { return }
                    autoStarted = true
                    await begin()
                }
                .polling(every: 2) { await poll() }
        }
        if binding?.status == "need_input" {
            SettingsFormSection {
                HStack(spacing: 8) {
                    SettingsBPushInput(
                        placeholder: binding?.inputLabel ?? "请输入",
                        text: $value,
                        keyboard: .numberPad,
                        identifier: "push-flow-input",
                        onSubmit: { Task { await submit() } }
                    )
                    .focused($inputFocused)
                    Button("确认") { Task { await submit() } }
                        .font(.subheadline.weight(.semibold))
                        .discoverProminentButton()
                        .disabled(busy || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("push-flow-submit")
                }
                .onAppear { inputFocused = true }
            } header: {
                Text("还差一步")
            }
        }
    }

    /// 二维码 / 状态常驻一行（副作用挂在这里，行身份不随分支变化）
    private var statusRow: some View {
        VStack(spacing: 0) {
            if let binding {
                SettingsBPushStatusCard {
                    if !failed, !binding.qr.isEmpty {
                        Group {
                            if let qrImage {
                                Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                ProgressView().tint(.black)
                            }
                        }
                        .frame(width: 176, height: 176)
                        .padding(12)
                        .background(.white, in: .rect(cornerRadius: 16))
                        .accessibilityLabel("\(channel.title)绑定二维码")
                        .accessibilityIdentifier("push-flow-qrcode")
                    }
                    VStack(spacing: 4) {
                        Text(failed ? "绑定未完成"
                             : binding.status == "pending" ? "等待扫码"
                             : binding.status == "need_input" ? "还差一步" : "已扫码")
                            .font(.body.weight(.medium))
                            .accessibilityIdentifier("push-flow-status")
                        Text(binding.message).font(.subheadline).foregroundStyle(Theme.textMuted)
                    }
                    if failed {
                        Button("重新发起") { Task { await begin() } }
                            .font(.subheadline.weight(.semibold))
                            .discoverProminentButton()
                            .disabled(busy)
                            .accessibilityIdentifier("push-flow-restart")
                    }
                }
            } else if busy {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else {
                // 发起失败（网关不可达等）：留一个手动重试入口
                SettingsBPushStatusCard {
                    Text("没能发起绑定").font(.body.weight(.medium))
                    Button("重试") { Task { await begin() } }
                        .font(.subheadline.weight(.semibold))
                        .discoverProminentButton()
                        .accessibilityIdentifier("push-flow-retry")
                }
            }
        }
    }

    private func show(_ next: API.ChannelBindingView) {
        // 二维码会中途刷新：内容变了才重画
        if next.qr != binding?.qr {
            qrImage = SettingsBPushQRCode.image(for: next.qr)
        }
        binding = next
    }

    private func begin() async {
        error = nil
        value = ""
        busy = true
        defer { busy = false }
        do {
            let started = try await api.channelsBindingsStart(body: .init(channelId: channel.id, fields: [:]))
            if doneStatuses.contains(started.status) { onBound(); return }
            show(started)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func poll() async {
        guard polling, let current = binding else { return }
        // 轮询失败静默重试（过期由状态自己表达）
        guard let snap = try? await api.channelsBindingsStatus(bindingId: current.bindingId) else { return }
        if doneStatuses.contains(snap.status) { onBound(); return }
        show(snap)
    }

    private func submit() async {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = binding, !text.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let next = try await api.channelsBindingsInput(bindingId: current.bindingId, body: .init(value: text))
            value = ""
            if doneStatuses.contains(next.status) { onBound(); return }
            show(next)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 表单：字段 +（可选）配对码

private struct SettingsBPushFormBody: View {
    let channel: API.ChannelView
    let onBound: () -> Void

    @Environment(\.api) private var api
    @State private var values: [String: String] = [:]
    @State private var binding: API.ChannelBindingView?
    @State private var error: String?
    @State private var busy = false

    private var fields: [API.ChannelFieldView] { channel.binding.fields }
    private var pairing: Bool { channel.binding.pairing == "code" }
    private var ready: Bool {
        !busy && fields.allSatisfy { field in
            !field.required || !(values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        if let error {
            SettingsFormSection {
                SubsNoticeRow(text: error, tone: .error).accessibilityIdentifier("push-bind-error")
            }
        }
        if let binding {
            SettingsFormSection {
                pairingRow(binding).polling(every: 2) { await poll() }
            }
        } else {
            ForEach(Array(fields.enumerated()), id: \.element.key) { index, field in
                SettingsFormSection {
                    fieldRow(field, first: index == 0)
                } header: {
                    Text(field.required ? field.label : "\(field.label)（选填）")
                } footer: {
                    if !field.help.isEmpty { Text(field.help) }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: API.ChannelFieldView, first: Bool) -> some View {
        let text = Binding(
            mcGet: { values[field.key] ?? "" },
            set: { values[field.key] = $0 }
        )
        Group {
            if field.secret {
                SecureField(field.placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await start() } }
            } else {
                SettingsBPushInput(
                    placeholder: field.placeholder,
                    text: text,
                    identifier: "push-field-\(field.key)",
                    onSubmit: { Task { await start() } }
                )
            }
        }
        .accessibilityIdentifier("push-field-\(field.key)")
        .toolbar {
            // 确认键挂在导航栏右上角（与其它表单弹层一致）；只挂在第一行上，避免分发成多份
            if first, binding == nil {
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView().accessibilityLabel("校验中")
                    } else {
                        Button(pairing ? "获取配对码" : "完成接入", systemImage: "checkmark", role: .confirm) {
                            Task { await start() }
                        }
                        .discoverProminentButton()
                        .disabled(!ready)
                        .accessibilityIdentifier("push-form-submit")
                    }
                }
            }
        }
    }

    private func pairingRow(_ binding: API.ChannelBindingView) -> some View {
        SettingsBPushStatusCard {
            if binding.status == "pending" {
                Text(binding.message).font(.body.weight(.medium))
                Text(binding.pairCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .tracking(9)
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("push-pair-code")
                Text("10 分钟内有效 · 发码人将成为唯一可对话的用户与推送目标")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            } else {
                Text("绑定未完成").font(.body.weight(.medium))
                Text(binding.message).font(.subheadline).foregroundStyle(Theme.textMuted)
                Button("重新发起") { self.binding = nil }
                    .font(.subheadline.weight(.semibold))
                    .discoverProminentButton()
                    .accessibilityIdentifier("push-form-restart")
            }
        }
    }

    private func start() async {
        guard ready else { return }
        busy = true
        error = nil
        defer { busy = false }
        let trimmed = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        do {
            let next = try await api.channelsBindingsStart(body: .init(channelId: channel.id, fields: trimmed))
            if doneStatuses.contains(next.status) { onBound(); return }
            binding = next
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func poll() async {
        guard let current = binding, current.status == "pending" else { return }
        // 轮询失败静默重试（过期由状态自己表达）
        guard let snap = try? await api.channelsBindingsStatus(bindingId: current.bindingId) else { return }
        if doneStatuses.contains(snap.status) { onBound(); return }
        binding = snap
    }
}
