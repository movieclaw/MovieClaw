import SwiftUI

/// 「AI 设定」里的网页搜索：一节状态行，接入 / 更换在弹层里做（对应 Web `web-search-settings.tsx`）。
///
/// 已接入时下面跟「重新测试连接」和「关闭网页搜索」；没接入只有一行入口。
/// 弹层右上角 ✓ 是「验证并保存」：服务端先用这把 Key 搜索一次，通过才落库，失败不动已保存的配置。
struct WebSearchSettingsSection: View {
    var reloadID: Int = 0

    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback

    @State private var config: API.WebSearchConfigView?
    @State private var error: String?
    @State private var editing = false
    /// 服务器早于 0.39.0、没有网页搜索接口：整节不显示，免得给一个点了也没用的「重试」
    @State private var unsupported = false

    var body: some View {
        Group {
            if unsupported {
                EmptyView()
            } else if let config {
                statusSection(config)
            } else if let error {
                SettingsFormSection {
                    SettingsNotice(text: error)
                    Button("重试") { Task { await load() } }
                        .accessibilityIdentifier("web-search-retry")
                } header: {
                    Text("网页搜索")
                }
            } else {
                SettingsFormSection { SettingsLoadingRow() } header: { Text("网页搜索") }
            }
        }
        .task(id: reloadID) { await load() }
    }

    private func statusSection(_ config: API.WebSearchConfigView) -> some View {
        let current = config.configured ? config.providers.first { $0.id == config.provider } : nil
        return SettingsFormSection {
            Button { editing = true } label: {
                HStack(spacing: 12) {
                    if let current {
                        SettingsBDot(tone: .ok, size: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(current.label).foregroundStyle(Theme.text)
                            Text(config.keyHint.isEmpty ? "已接入" : "已接入 · 密钥末四位 \(config.keyHint)")
                                .font(.caption).foregroundStyle(Theme.textMuted)
                        }
                    } else {
                        Text("接入网页搜索").foregroundStyle(Theme.text)
                    }
                    Spacer()
                    if current == nil {
                        Text("未接入").foregroundStyle(Theme.textMuted)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .accessibilityIdentifier("web-search-row")
            // 弹层挂在行上：挂在 Form 里的 Section 上不会弹出
            .sheet(isPresented: $editing) {
                WebSearchSettingsSheet(config: config) { next in
                    self.config = next
                    let label = next.providers.first { $0.id == next.provider }?.label
                    feedback.success(label.map { "网页搜索已接入 \($0)" } ?? "网页搜索已接入")
                }
                .sheetFeedback()
            }
            if current != nil {
                SettingsBAsyncButton(action: retest) {
                    Label("重新测试连接", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("web-search-retest")
                SettingsBAsyncButton(role: .destructive, action: clear) {
                    Label("关闭网页搜索", systemImage: "xmark.circle")
                }
                .foregroundStyle(Theme.danger)
                .accessibilityIdentifier("web-search-clear")
            }
        } header: {
            Text("网页搜索")
        } footer: {
            Text(current == nil
                 ? "接入 Tavily、Exa 或 Brave Search 后，智能体能上网查最新信息。不接入就没有这个工具。"
                 : "智能体需要最新信息时会自己上网搜索。")
        }
    }

    private func load() async {
        do {
            config = try await api.llmWebSearchShow()
            error = nil
            unsupported = false
        } catch is CancellationError {
        } catch let failure as APIError where failure.status == 404 {
            unsupported = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func retest() async {
        do {
            let result = try await api.llmWebSearchTest(body: .init(provider: config?.provider, apiKey: nil))
            feedback.success(result.message)
        } catch {
            feedback.error(error)
        }
    }

    private func clear() async {
        guard await feedback.confirm(
            "关闭网页搜索？",
            message: "已保存的 API Key 会从这台服务器删除。智能体将不再上网搜索，直到你重新接入。",
            confirmTitle: "关闭",
            destructive: true
        ) else { return }
        do {
            config = try await api.llmWebSearchClear()
            feedback.success("已关闭网页搜索")
        } catch {
            feedback.error(error)
        }
    }
}

/// 接入 / 更换网页搜索：选服务、填 Key，右上角 ✓ 验证并保存。
struct WebSearchSettingsSheet: View {
    let config: API.WebSearchConfigView
    let onSaved: (API.WebSearchConfigView) -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var provider: String
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false

    init(config: API.WebSearchConfigView, onSaved: @escaping (API.WebSearchConfigView) -> Void) {
        self.config = config
        self.onSaved = onSaved
        _provider = State(initialValue: config.provider ?? config.providers.first?.id ?? "")
    }

    private var initialProvider: String { config.provider ?? config.providers.first?.id ?? "" }
    private var selected: API.WebSearchProviderOption? { config.providers.first { $0.id == provider } }
    private var keepsSaved: Bool { config.configured && provider == config.provider }
    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 不论换不换服务都要一把 Key：同一家不填新 Key 等于什么都没改
    private var canSubmit: Bool { !provider.isEmpty && !trimmedKey.isEmpty }
    private var dirty: Bool { !apiKey.isEmpty || provider != initialProvider }

    var body: some View {
        SubsSheetScaffold(
            title: config.configured ? "更换网页搜索" : "接入网页搜索",
            onClose: { if dirty { discarding = true } else { dismiss() } },
            confirm: SubsSheetConfirm(title: "验证并保存", enabled: canSubmit, busy: busy, identifier: "web-search-save") {
                Task { await submit() }
            }
        ) {
            if let error {
                SettingsFormSection {
                    SettingsBNotice(text: error, tone: .danger)
                        .accessibilityIdentifier("web-search-error")
                }
            }
            SettingsFormSection {
                ForEach(config.providers, id: \.id) { item in
                    Button {
                        provider = item.id
                        error = nil
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.label).foregroundStyle(Theme.text)
                                Text(item.note).font(.caption).foregroundStyle(Theme.textFaint)
                            }
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .opacity(provider == item.id ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(provider == item.id ? .isSelected : [])
                    .accessibilityIdentifier("web-search-provider-\(item.id)")
                }
            } header: {
                Text("搜索服务")
            }
            SettingsFormSection {
                HStack {
                    Group {
                        if showKey {
                            TextField(keyPlaceholder, text: $apiKey)
                        } else {
                            SecureField(keyPlaceholder, text: $apiKey)
                        }
                    }
                    .font(.body.monospaced())
                    .textContentType(nil)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { if canSubmit { Task { await submit() } } }
                    .accessibilityIdentifier("web-search-key")
                    Button(showKey ? "隐藏" : "显示") { showKey.toggle() }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showKey ? "隐藏 API Key" : "显示 API Key")
                }
                if let selected, let url = URL(string: selected.signupUrl) {
                    Link(destination: url) {
                        Label("申请 \(selected.label) API Key", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityIdentifier("web-search-signup")
                }
            } header: {
                Text("API Key")
            } footer: {
                Text(keyFooter)
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || dirty)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改", role: .destructive) { dismiss() }
        }
    }

    private var keyPlaceholder: String {
        keepsSaved && !config.keyHint.isEmpty ? "当前末四位 \(config.keyHint)" : "粘贴 API Key"
    }

    private var keyFooter: String {
        let rule = "保存前会先用这把 Key 搜索一次，通过才保存。"
        if keepsSaved { return "已保存的密钥不会回显，填入新的 Key 才会更换。" + rule }
        if config.configured { return "更换搜索服务需要它自己的 Key。" + rule }
        return rule + "密钥只存在服务器上。"
    }

    private func submit() async {
        guard canSubmit, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let next = try await api.llmWebSearchUpdate(body: .init(provider: provider, apiKey: trimmedKey))
            onSaved(next)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
