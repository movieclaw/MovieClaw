import SwiftUI

/// 各类图片使用同一套固定来源，但保留各自的默认优先级。
enum SettingsBScrapeImageKind: String, CaseIterable, Identifiable {
    case poster, backdrop, logo, seasonPoster
    var id: String { rawValue }
    var title: String {
        switch self {
        case .poster: "海报"
        case .backdrop: "背景图"
        case .logo: "片名 Logo"
        case .seasonPoster: "季海报"
        }
    }
    var defaultOrder: [String] {
        self == .logo || self == .seasonPoster ? ["fanart", "tmdb"] : ["tmdb", "fanart"]
    }
    var keyPath: WritableKeyPath<API.MetadataScrapeSetting, [String]?> {
        switch self {
        case .poster: \.posterSourceOrder
        case .backdrop: \.backdropSourceOrder
        case .logo: \.logoSourceOrder
        case .seasonPoster: \.seasonPosterSourceOrder
        }
    }
    func payload(_ order: [String]) -> API.MetadataScrapeSettingInput {
        switch self {
        case .poster: .init(posterSourceOrder: order)
        case .backdrop: .init(backdropSourceOrder: order)
        case .logo: .init(logoSourceOrder: order)
        case .seasonPoster: .init(seasonPosterSourceOrder: order)
        }
    }

}

struct SettingsBScrapeImageSourcesView: View {
    @State private var setting: API.MetadataScrapeSetting
    let overriddenBy: [String]
    let onUpdate: (API.ScrapeConfigView) -> Void
    @State private var busy = false
    @State private var error: String?
    @Environment(\.api) private var api
    @State private var status: Loadable<API.FanartStatusView> = .loading
    @State private var keyOpen = false
    @State private var source: SettingsBScrapeImageKind?

    init(setting: API.MetadataScrapeSetting, overriddenBy: [String], onUpdate: @escaping (API.ScrapeConfigView) -> Void) {
        _setting = State(initialValue: setting)
        self.overriddenBy = overriddenBy
        self.onUpdate = onUpdate
    }

    var body: some View {
        Form {
            sections
            if !overriddenBy.isEmpty {
                SettingsFormSection {
                    Text(overriddenBy.joined(separator: "、")).foregroundStyle(Theme.textMuted)
                } header: { Text("已单独设置的媒体库") } footer: {
                    Text("这些媒体库使用自己的设置，不跟随这里的默认值。")
                }
            }
        }
        .settingsBFormStyle()
        .navigationTitle("图片来源")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            if busy { ToolbarItem(placement: .topBarTrailing) { ProgressView("正在保存…") } }
        }
        .disabled(busy)
        .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { }
        } message: { Text(error ?? "") }
    }

    private var usable: Bool {
        if case let .loaded(value) = status { return value.configured && !value.keyInvalid }
        return false
    }

    @ViewBuilder private var sections: some View {
        SettingsFormSection {
            LabeledContent("TMDB", value: "始终开启")
            Toggle("Fanart.tv", isOn: Binding(
                get: { setting.fanartEnabled == true },
                set: { enabled in
                    if enabled && !usable { keyOpen = true } else { setEnabled(enabled) }
                }
            ))
            .disabled(!statusLoaded && setting.fanartEnabled != true)
            .accessibilityIdentifier("scrape-fanart-enabled")
            switch status {
            case .loading:
                ProgressView("正在检查 API Key…")
            case let .failed(message):
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("scrape-fanart-status-error")
                Button("重新加载", systemImage: "arrow.clockwise") { Task { await load() } }
                    .accessibilityIdentifier("scrape-fanart-retry")
            case let .loaded(value):
                Button { keyOpen = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(value.keyInvalid ? "重新验证 API Key" : value.configured ? "更换 API Key" : "配置 API Key")
                            Text(value.keyInvalid ? "密钥已失效，Fanart 选图已暂停" : value.configured ? "已配置 · ••••\(value.keyHint)" : "验证后即可启用 Fanart")
                                .font(.footnote).foregroundStyle(value.keyInvalid ? Theme.danger : Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: value.keyInvalid ? "exclamationmark.triangle" : "key")
                            .foregroundStyle(value.keyInvalid ? Theme.danger : Theme.textMuted)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("scrape-fanart-key")
            }
        } header: { Text("图片服务") } footer: {
            Text("Fanart.tv 补充高清图片与片名 Logo。API Key 保存在当前服务器，所有媒体库共用。")
        }
        SettingsFormSection {
            ForEach(SettingsBScrapeImageKind.allCases) { kind in
                Button { source = kind } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.title).foregroundStyle(Theme.text)
                            Text((setting[keyPath: kind.keyPath] ?? kind.defaultOrder)
                                .map { $0 == "fanart" ? "Fanart.tv" : "TMDB" }.joined(separator: " → "))
                                .font(.subheadline).foregroundStyle(Theme.textMuted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("scrape-source-\(kind.rawValue)")
            }
            .disabled(setting.fanartEnabled != true)
        } header: { Text("来源优先级") } footer: {
            Text("先匹配语言，同一语言有多个来源时才按这里的顺序选择。季海报仅用于剧集，语言跟随海报设置。\(setting.fanartEnabled == true ? "" : "启用 Fanart 后可调整来源顺序。")")
        }
        SettingsFormSection {
            Text("更改自动保存，对新刮削生效。已有条目需执行「刷新元数据」；手动选定的图片始终优先。")
                .font(.footnote).foregroundStyle(Theme.textMuted)
        }
        .task { await load() }
        .sheet(isPresented: $keyOpen) {
            if case let .loaded(current) = status {
                SettingsBScrapeFanartKeySheet(status: current) { value in
                    status = .loaded(value)
                    return await persist(.init(fanartEnabled: true))
                }
                .sheetFeedback()
            }
        }
        .sheet(item: $source) { kind in
            SettingsBScrapeSourceOrderSheet(kind: kind, value: setting[keyPath: kind.keyPath] ?? kind.defaultOrder) {
                await persist(kind.payload($0))
            }
            .sheetFeedback()
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !busy else { return }
        let previous = setting.fanartEnabled
        setting.fanartEnabled = enabled
        busy = true
        error = nil
        Task {
            if let message = await persist(.init(fanartEnabled: enabled)) {
                setting.fanartEnabled = previous
                error = "\(enabled ? "启用" : "关闭") Fanart 失败：\(message)"
            }
        }
    }

    private func persist(_ payload: API.MetadataScrapeSettingInput) async -> String? {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let updated = try await api.scrapeSet(body: payload)
            setting = updated.setting
            onUpdate(updated)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var statusLoaded: Bool {
        if case .loaded = status { return true }
        return false
    }

    private func load() async {
        status = .loading
        do { status = .loaded(try await api.scrapeFanartShow()) }
        catch is CancellationError { }
        catch { status = .failed(error.localizedDescription) }
    }
}

private struct SettingsBScrapeSourceOrderSheet: View {
    let kind: SettingsBScrapeImageKind
    let onApply: ([String]) async -> String?
    @State private var draft: [String]
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false
    private let original: [String]
    @Environment(\.dismiss) private var dismiss

    init(kind: SettingsBScrapeImageKind, value: [String], onApply: @escaping ([String]) async -> String?) {
        self.kind = kind
        self.onApply = onApply
        original = value
        _draft = State(initialValue: value)
    }

    var body: some View {
        SubsSheetScaffold(title: "\(kind.title)来源", onClose: {
            if draft != original { discarding = true } else { dismiss() }
        }, confirm: SubsSheetConfirm(title: "保存", busy: busy, identifier: "scrape-source-done") {
            guard draft != original else { dismiss(); return }
            Task {
                busy = true
                error = await onApply(draft)
                busy = false
                if error == nil { dismiss() }
            }
        }) {
            SettingsFormSection {
                SettingsBScrapeImageSourceOrder(value: $draft)
            } footer: { Text("点右上角对勾即保存并生效。") }
            if let error {
                SettingsFormSection { Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("scrape-source-save-error") }
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || draft != original)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { dismiss() }
        }
    }
}

private struct SettingsBScrapeFanartKeySheet: View {
    let status: API.FanartStatusView
    let onVerified: (API.FanartStatusView) async -> String?
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var verified: API.FanartStatusView?
    @State private var discarding = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SubsSheetScaffold(title: status.configured ? "更换 Fanart API Key" : "Fanart API Key", onClose: {
            if !key.isEmpty { discarding = true } else { dismiss() }
        }, confirm: SubsSheetConfirm(title: "验证", enabled: !trimmedKey.isEmpty,
            busy: busy, identifier: "scrape-fanart-verify", action: verify)) {
            if status.configured {
                SettingsFormSection {
                    LabeledContent("当前密钥") {
                        Text("••••\(status.keyHint)")
                            .font(.body.monospaced())
                            .accessibilityIdentifier("scrape-fanart-current-key")
                    }
                    Label(status.keyInvalid ? "密钥已失效，需要重新配置" : "已配置，保存在当前服务器",
                          systemImage: status.keyInvalid ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(status.keyInvalid ? Theme.danger : Theme.textMuted)
                } footer: {
                    Text("已保存的密钥只显示末四位。不输入新密钥或取消，都会保留原有配置。")
                }
            }
            SettingsFormSection {
                SecureField(status.configured ? "输入新的 API Key" : "输入 API Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("scrape-fanart-key-input")
                Link("获取免费 API Key", destination: URL(string: "https://fanart.tv/get-an-api-key/")!)
            } footer: {
                Text("验证成功后立即将密钥保存到当前服务器，并启用 Fanart 选图。验证失败不会替换原密钥。")
            }
            if let error {
                SettingsFormSection { Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("scrape-fanart-key-error") }
            }
        }
        .disabled(busy)
        .onChange(of: key) { _, _ in verified = nil }
        .interactiveDismissDisabled(busy || !key.isEmpty)
        .alert("放弃输入的密钥？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃输入", role: .destructive) { dismiss() }
        }
    }

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func verify() {
        Task {
            busy = true
            error = nil
            do {
                let value: API.FanartStatusView
                if let verified { value = verified } else {
                    value = try await api.scrapeFanartSetKey(body: .init(apiKey: trimmedKey))
                    verified = value
                }
                if let message = await onVerified(value) {
                    error = "密钥已保存，但启用 Fanart 失败：\(message)。请重试。"
                } else {
                    key = ""
                    dismiss()
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
