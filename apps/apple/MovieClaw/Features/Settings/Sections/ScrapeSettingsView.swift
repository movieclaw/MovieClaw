import SwiftUI

/// 全站刮削默认值。每个设置独立编辑、保存，避免离开总览时遗失整页草稿。
struct ScrapeSettingsView: View {
    @Environment(\.api) private var api
    @State private var state: Loadable<API.ScrapeConfigView> = .loading
    @State private var sheet: SettingsBScrapeCard?
    @State private var destination: SettingsBScrapeCard?
    @State private var languages: [API.LanguageOption] = []
    @State private var countries: [API.CountryOption] = []
    @State private var overrides: [SettingsBScrapeOverride] = []
    @State private var estimate: API.ImageStorageEstimateView?

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("正在加载刮削配置…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("loading")
            case let .failed(message):
                ErrorState(message: message, retry: load)
            case let .loaded(view):
                Form {
                    SettingsFormSection {
                        row(.metaLanguage, view)
                        row(.certCountry, view)
                    } header: { Text("元数据") } footer: {
                        Text("这里的默认设置用于所有媒体库。每个库可在「编辑库 → 刮削设置」中单独覆盖。")
                    }
                    SettingsFormSection("图片") {
                        row(.sources, view)
                        row(.poster, view)
                        row(.backdrop, view)
                        row(.logo, view)
                        row(.quality, view)
                    }
                    SettingsFormSection {
                        row(.naming, view)
                        row(.mirror, view)
                    } header: { Text("整理与写入") } footer: {
                        Text("保存后对新刮削生效。已有条目可在媒体库中执行「刷新元数据」应用新配置。")
                    }
                }
                .settingsBFormStyle()
            }
        }
        .appBackground()
        .task { await load(); await loadAuxiliary() }
        .sheet(item: $sheet) { card in
            if case let .loaded(view) = state {
                editor(card, view, sheet: true).sheetFeedback()
            }
        }
        .navigationDestination(item: $destination) { card in
            if case let .loaded(view) = state {
                editor(card, view, sheet: false)
            }
        }
    }

    private func row(_ card: SettingsBScrapeCard, _ view: API.ScrapeConfigView) -> some View {
        let count = overrides.filter { !$0.keys.isDisjoint(with: card.keys) }.count
        var display = view.setting
        if display.languagePriority.isEmpty { display.languagePriority = view.effective.languagePriority }
        return Button {
            if card == .quality || card == .naming || card == .sources { destination = card } else { sheet = card }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).foregroundStyle(Theme.text)
                    Text(card.summary(display))
                        .font(.subheadline).foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                    if count > 0 {
                        Text("\(count) 个媒体库单独设置")
                            .font(.caption).foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scrape-card-\(card.rawValue)")
    }

    @ViewBuilder private func editor(_ card: SettingsBScrapeCard, _ view: API.ScrapeConfigView, sheet: Bool) -> some View {
        let overriddenBy = overrides.filter { !$0.keys.isDisjoint(with: card.keys) }.map(\.name)
        if card == .sources {
            SettingsBScrapeImageSourcesView(setting: view.setting, overriddenBy: overriddenBy) { state = .loaded($0) }
        } else {
            ScrapeSettingsEditor(card: card, config: view, languages: languages, countries: countries,
                                 overriddenBy: overriddenBy, estimate: estimate, isSheet: sheet,
                                 onSave: { await save($0, card: card) })
        }
    }

    private func load() async {
        do { state = .loaded(try await api.scrapeShow()) }
        catch is CancellationError { }
        catch { state = .failed(error.localizedDescription) }
    }

    private func loadAuxiliary() async {
        async let langs = try? api.scrapeLanguages()
        async let ctrs = try? api.scrapeCountries()
        async let libs = try? api.libraryList(scope: "all")
        async let sizes = try? api.scrapeStorageEstimate()
        languages = await langs ?? []
        countries = await ctrs ?? []
        estimate = await sizes
        overrides = (await libs ?? [])
            .map { SettingsBScrapeOverride(name: $0.name, keys: Set($0.scrapeOverrides.keys)) }
            .filter { !$0.keys.isEmpty }
    }

    private func save(_ s: API.MetadataScrapeSetting, card: SettingsBScrapeCard) async -> String? {
        do {
            let config = try await api.scrapeSet(body: card.payload(s))
            state = .loaded(config)
            estimate = (try? await api.scrapeStorageEstimate()) ?? estimate
            return nil
        } catch {
            return error.localizedDescription.isEmpty ? "保存失败，请重试" : error.localizedDescription
        }
    }
}

struct SettingsBScrapeOverride {
    let name: String
    let keys: Set<String>
}

private struct ScrapeSettingsEditor: View {
    let card: SettingsBScrapeCard
    let config: API.ScrapeConfigView
    let languages: [API.LanguageOption]
    let countries: [API.CountryOption]
    let overriddenBy: [String]
    let estimate: API.ImageStorageEstimateView?
    let isSheet: Bool
    let onSave: (API.MetadataScrapeSetting) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: API.MetadataScrapeSetting
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false
    @State private var resetting = false
    private let original: API.MetadataScrapeSetting

    init(card: SettingsBScrapeCard, config: API.ScrapeConfigView, languages: [API.LanguageOption],
         countries: [API.CountryOption], overriddenBy: [String], estimate: API.ImageStorageEstimateView?,
         isSheet: Bool, onSave: @escaping (API.MetadataScrapeSetting) async -> String?) {
        self.card = card
        self.config = config
        self.languages = languages
        self.countries = countries
        self.overriddenBy = overriddenBy
        self.estimate = estimate
        self.isSheet = isSheet
        self.onSave = onSave
        var initial = config.setting
        if card == .metaLanguage, initial.languagePriority.isEmpty {
            initial.languagePriority = config.effective.languagePriority
        }
        if card == .logo { initial.logoLanguagePriority = initial.logoLanguagePriority ?? ["meta", "en", "orig", "null"] }
        original = initial
        _draft = State(initialValue: initial)
    }

    private var dirty: Bool { draft != original }
    private var valid: Bool {
        card != .naming || SettingsBScrapeNaming.fields.allSatisfy {
            SettingsBScrapeNaming.error(for: $0, template: draft[keyPath: $0.keyPath]) == nil
        }
    }

    var body: some View {
        Group {
            if isSheet {
                SubsSheetScaffold(title: card.title, onClose: cancel,
                                  confirm: SubsSheetConfirm(title: "保存", enabled: dirty && valid,
                                                            busy: busy, identifier: "scrape-save", action: save)) {
                    content
                }
            } else {
                Form { content }
                    .settingsBFormStyle()
                    .navigationTitle(card.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消", action: cancel).accessibilityIdentifier("scrape-cancel")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            if card == .naming {
                                Menu {
                                    Button("恢复默认模板", systemImage: "arrow.counterclockwise") { resetting = true }
                                        .accessibilityIdentifier("scrape-naming-reset")
                                } label: { Image(systemName: "ellipsis") }
                                .accessibilityLabel("命名模板操作")
                                .accessibilityIdentifier("scrape-naming-actions")
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            if busy { ProgressView() } else {
                                Button("保存", action: save)
                                    .disabled(!dirty || !valid)
                                    .accessibilityIdentifier("scrape-save")
                            }
                        }
                    }
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || dirty)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { dismiss() }
        }
        .confirmationDialog("恢复全部默认命名模板？", isPresented: $resetting, titleVisibility: .visible) {
            Button("恢复默认模板") {
                for field in SettingsBScrapeNaming.fields { draft[keyPath: field.keyPath] = "" }
            }
        } message: {
            Text("当前草稿中的自定义模板会被替换，保存后才会生效。")
        }
    }

    @ViewBuilder private var content: some View {
        SettingsFormSection {
            switch card {
            case .sources: EmptyView()
            case .logo:
                SettingsBScrapeOrderChips(options: SettingsBScrapeCatalog.commonImageLangs,
                    extraOptions: SettingsBScrapeCatalog.extraImageLangs(languages), moreLabel: "语言",
                    value: Binding(get: { draft.logoLanguagePriority ?? [] }, set: { draft.logoLanguagePriority = $0 }),
                    max: 4, primaryTag: "首选", identifier: "scrape-logo-lang")
            case .metaLanguage:
                SettingsBScrapeOrderChips(options: SettingsBScrapeCatalog.commonMetaLangs,
                    extraOptions: SettingsBScrapeCatalog.extraMetaLangs(languages), moreLabel: "语言",
                    value: $draft.languagePriority, max: 3, primaryTag: "主语言", identifier: "scrape-meta-lang")
            case .certCountry:
                SettingsBScrapeOrderChips(options: SettingsBScrapeCatalog.commonCertCountries,
                    extraOptions: SettingsBScrapeCatalog.extraCountries(countries), moreLabel: "地区",
                    value: $draft.certCountryPriority, max: 6, primaryTag: "首选", identifier: "scrape-cert-country")
            case .poster:
                SettingsBScrapePosterRows(setting: $draft, extraImageLangs: SettingsBScrapeCatalog.extraImageLangs(languages))
            case .backdrop:
                SettingsBScrapeOrderChips(options: SettingsBScrapeCatalog.commonImageLangs,
                    extraOptions: SettingsBScrapeCatalog.extraImageLangs(languages), moreLabel: "语言",
                    value: $draft.backdropLanguagePriority, max: 4, primaryTag: "首选", identifier: "scrape-backdrop-lang")
            case .quality:
                SettingsBScrapeQualityRows(setting: $draft, effective: config.effective, estimate: estimate)
            case .naming:
                SettingsBScrapeNamingRows(setting: $draft)
            case .mirror:
                SettingsBScrapeMirrorRows(setting: $draft)
            }
        } footer: {
            Text(card.desc)
        }
        if !overriddenBy.isEmpty {
            SettingsFormSection {
                Text(overriddenBy.joined(separator: "、"))
                    .foregroundStyle(Theme.textMuted)
            } header: { Text("已单独设置的媒体库") } footer: {
                Text("这些媒体库使用自己的设置，不跟随这里的默认值。")
            }
        }
        if let error {
            SettingsFormSection { Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("scrape-save-error") }
        }
    }

    private func cancel() {
        if dirty { discarding = true } else { dismiss() }
    }

    private func save() {
        Task {
            busy = true
            error = await onSave(draft)
            busy = false
            if error == nil { dismiss() }
        }
    }
}
