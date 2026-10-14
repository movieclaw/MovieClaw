import SwiftUI

/// 「AI 设定」里的搜索能力接入，交互与 Web `web-search-settings.tsx` 一致。
///
/// 选一家供应商、粘贴 Key、测试连接，通过之后才能保存。服务端也会再测一次，
/// 没通过的密钥不会写入服务器，已经保存的密钥不会被一次失败的尝试换掉。
struct WebSearchSettingsSection: View {
    var reloadID: Int = 0

    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback

    @State private var config: API.WebSearchConfigView?
    @State private var provider = ""
    @State private var apiKey = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var verifiedToken: String?
    @State private var busy: Busy?
    @State private var confirmingClear = false

    private enum Busy { case test, save, clear }

    var body: some View {
        Group {
            if let config {
                form(config)
                    .disabled(busy != nil)
            } else if let error {
                SettingsFormSection {
                    SettingsNotice(text: error)
                    Button("重试") { Task { await load() } }
                        .accessibilityIdentifier("web-search-retry")
                } header: {
                    Text("搜索能力接入")
                }
            } else {
                SettingsFormSection { SettingsLoadingRow() } header: { Text("搜索能力接入") }
            }
        }
        .task(id: reloadID) { await load() }
        .confirmationDialog("关闭网页搜索？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { Task { await clear() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已保存的 API Key 会从这台服务器删除。智能体将不再上网搜索，直到你重新接入。")
        }
    }

    private func form(_ config: API.WebSearchConfigView) -> some View {
        let selected = config.providers.first { $0.id == provider }
        // 表单就是已保存的样子（同一家、没填新 Key）时没有要保存的东西，不提示先测试
        let unchanged = probeToken == "\(config.provider ?? "")\nsaved"
        let hint = probeToken != nil && !canSave && !unchanged ? " 请先测试连接，通过后才能保存。" : ""
        return SettingsFormSection {
            Picker("供应商", selection: $provider) {
                Text("请选择…").tag("")
                ForEach(config.providers, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("web-search-provider")
            if let selected {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.note)
                    if let url = URL(string: selected.signupUrl) {
                        Link("申请 \(selected.label) API Key", destination: url)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
            }
            SecureField(placeholder(config), text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("web-search-key")
            Text(statusLine(config, selected) + hint)
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .accessibilityIdentifier("web-search-status")
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(Theme.success)
                    .accessibilityIdentifier("web-search-notice")
            }
            if let error { SettingsNotice(text: error) }
            // 同一行两个按钮必须 borderless：默认样式下点这一行会把两个按钮都触发
            HStack(spacing: 12) {
                Button(busy == .test ? "测试中…" : "测试连接") { Task { await test() } }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("web-search-test")
                Button(busy == .save ? "保存中…" : "保存") { Task { await save() } }
                    .buttonStyle(.borderless)
                    .disabled(!canSave)
                    .accessibilityIdentifier("web-search-save")
            }
            if config.configured {
                Button(busy == .clear ? "清除中…" : "清除", role: .destructive) {
                    confirmingClear = true
                }
                .accessibilityIdentifier("web-search-clear")
            }
        } header: {
            Text("搜索能力接入")
        } footer: {
            Text("选一家搜索服务并填入 API Key。先测试连接，通过后才能保存；没通过的密钥不会写入服务器。不配置就不会提供这个工具。")
        }
        .onChange(of: provider) { _, _ in
            notice = nil
            error = nil
        }
        .onChange(of: apiKey) { _, _ in
            notice = nil
            error = nil
        }
    }

    private var switching: Bool {
        config?.configured == true && provider != (config?.provider ?? "")
    }

    /// 一次成功的测试只对这一组供应商和密钥有效。空密钥且供应商未变时，测的是已保存的那把。
    private var probeToken: String? {
        guard !provider.isEmpty else { return nil }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return "\(provider)\n\(trimmed)" }
        if config?.configured == true, provider == (config?.provider ?? "") { return "\(provider)\nsaved" }
        return nil
    }

    private var canSave: Bool { probeToken != nil && probeToken == verifiedToken }

    private func placeholder(_ config: API.WebSearchConfigView) -> String {
        if switching { return "更换供应商时请粘贴新的 API Key" }
        if config.configured, !config.keyHint.isEmpty { return "已保存，留空表示不修改（末四位 \(config.keyHint)）" }
        if config.configured { return "已保存，留空表示不修改" }
        return "粘贴 API Key"
    }

    private func statusLine(_ config: API.WebSearchConfigView, _ selected: API.WebSearchProviderOption?) -> String {
        guard config.configured, let selected, selected.id == config.provider else {
            return "密钥只存在这台服务器上，保存之后界面不再显示完整密钥。"
        }
        if !config.keyHint.isEmpty { return "已接入 \(selected.label)，密钥末四位 \(config.keyHint)。" }
        return "已接入 \(selected.label)。"
    }

    private func load() async {
        do {
            let next = try await api.llmWebSearchShow()
            let first = config == nil
            config = next
            if first { provider = next.provider ?? "" }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func test() async {
        guard !provider.isEmpty else {
            error = "请先选择搜索供应商"
            return
        }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, switching || config?.configured != true {
            error = "请先粘贴 API Key"
            return
        }
        busy = .test
        error = nil
        notice = nil
        defer { busy = nil }
        do {
            let tested = probeToken
            let result = try await api.llmWebSearchTest(body: .init(
                provider: provider,
                apiKey: trimmed.isEmpty ? nil : trimmed
            ))
            notice = result.message
            verifiedToken = tested
        } catch {
            verifiedToken = nil
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard canSave else { return }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = .save
        error = nil
        notice = nil
        defer { busy = nil }
        do {
            let next = try await api.llmWebSearchUpdate(body: .init(
                provider: provider,
                apiKey: trimmed.isEmpty ? nil : trimmed
            ))
            config = next
            provider = next.provider ?? ""
            apiKey = ""
            verifiedToken = nil
            feedback.success("网页搜索已验证并保存")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clear() async {
        busy = .clear
        error = nil
        notice = nil
        defer { busy = nil }
        do {
            config = try await api.llmWebSearchClear()
            provider = ""
            apiKey = ""
            verifiedToken = nil
            feedback.success("已关闭网页搜索")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
