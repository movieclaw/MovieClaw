import SwiftUI

/// 各类图片使用同一套固定来源，但保留各自的默认优先级。
enum SettingsBScrapeImageKind: String, CaseIterable, Identifiable {
    case poster, backdrop, logo, seasonPoster
    var id: String { rawValue }
    var title: String {
        switch self {
        case .poster: String(localized: .settingsScrapePoster)
        case .backdrop: String(localized: .settingsAppearanceBackdropTab)
        case .logo: String(localized: .settingsScrapeTitleLogo)
        case .seasonPoster: String(localized: .settingsScrapeSeasonPoster)
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
                } header: { Text(String(localized: .settingsImageSourcesOverriddenLibraries)) } footer: {
                    Text(String(localized: .settingsImageSourcesOverriddenHint))
                }
            }
        }
        .settingsBFormStyle()
        .navigationTitle(String(localized: .settingsScrapeImageSources))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            if busy { ToolbarItem(placement: .topBarTrailing) { ProgressView(String(localized: .settingsPlaybackControlsSaving)) } }
        }
        .disabled(busy)
        .alert(String(localized: .settingsScheduledTasksUiSaveFailed), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(String(localized: .settingsImageSourcesOk), role: .cancel) { }
        } message: { Text(error ?? "") }
    }

    private var usable: Bool {
        if case let .loaded(value) = status { return value.configured && !value.keyInvalid }
        return false
    }

    @ViewBuilder private var sections: some View {
        SettingsFormSection {
            LabeledContent("TMDB", value: String(localized: .settingsScrapeAlwaysEnabled))
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
                ProgressView(String(localized: .settingsImageSourcesCheckingKey))
            case let .failed(message):
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("scrape-fanart-status-error")
                Button(String(localized: .librarySubtitlePreviewReload), systemImage: "arrow.clockwise") { Task { await load() } }
                    .accessibilityIdentifier("scrape-fanart-retry")
            case let .loaded(value):
                Button { keyOpen = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(value.keyInvalid ? String(localized: .settingsImageSourcesReverifyKey) : value.configured ? String(localized: .settingsImageSourcesChangeKey) : String(localized: .settingsImageSourcesConfigureKey))
                            Text(value.keyInvalid ? String(localized: .settingsImageSourcesKeyInvalid) : value.configured ? String(localized: .settingsImageSourcesKeyConfigured(value.keyHint)) : String(localized: .settingsImageSourcesVerifyToEnable))
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
        } header: { Text(String(localized: .settingsImageSourcesServices)) } footer: {
            Text(String(localized: .settingsImageSourcesFanartHint))
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
        } header: { Text(String(localized: .settingsImageSourcesPriority)) } footer: {
            Text(String(localized: .settingsImageSourcesPriorityHint) + (setting.fanartEnabled == true ? "" : String(localized: .settingsImageSourcesEnableFanartForOrder)))
        }
        SettingsFormSection {
            Text(String(localized: .settingsImageSourcesAutosaveHint))
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
                error = enabled ? String(localized: .settingsImageSourcesEnableFailed(message)) : String(localized: .settingsImageSourcesDisableFailed(message))
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
        SubsSheetScaffold(title: String(localized: .settingsImageSourcesSourcesTitle(kind.title)), onClose: {
            if draft != original { discarding = true } else { dismiss() }
        }, confirm: SubsSheetConfirm(title: String(localized: .commonSave), busy: busy, identifier: "scrape-source-done") {
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
            } footer: { Text(String(localized: .settingsImageSourcesCheckToSave)) }
            if let error {
                SettingsFormSection { Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("scrape-source-save-error") }
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || draft != original)
        .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
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
        SubsSheetScaffold(title: status.configured ? String(localized: .settingsImageSourcesChangeFanartKey) : "Fanart API Key", onClose: {
            if !key.isEmpty { discarding = true } else { dismiss() }
        }, confirm: SubsSheetConfirm(title: String(localized: .settingsImageSourcesVerify), enabled: !trimmedKey.isEmpty,
            busy: busy, identifier: "scrape-fanart-verify", action: verify)) {
            if status.configured {
                SettingsFormSection {
                    LabeledContent(String(localized: .settingsImageSourcesCurrentKey)) {
                        Text("••••\(status.keyHint)")
                            .font(.body.monospaced())
                            .accessibilityIdentifier("scrape-fanart-current-key")
                    }
                    Label(status.keyInvalid ? String(localized: .settingsImageSourcesKeyInvalidRedo) : String(localized: .settingsImageSourcesKeyStored),
                          systemImage: status.keyInvalid ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(status.keyInvalid ? Theme.danger : Theme.textMuted)
                } footer: {
                    Text(String(localized: .settingsImageSourcesKeyMaskHint))
                }
            }
            SettingsFormSection {
                SecureField(status.configured ? String(localized: .settingsImageSourcesNewKey) : String(localized: .settingsImageSourcesEnterKey), text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("scrape-fanart-key-input")
                Link(String(localized: .settingsImageSourcesGetKey), destination: URL(string: "https://fanart.tv/get-an-api-key/")!)
            } footer: {
                Text(String(localized: .settingsImageSourcesVerifyHint))
            }
            if let error {
                SettingsFormSection { Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("scrape-fanart-key-error") }
            }
        }
        .disabled(busy)
        .onChange(of: key) { _, _ in verified = nil }
        .interactiveDismissDisabled(busy || !key.isEmpty)
        .alert(String(localized: .settingsImageSourcesDiscardKey), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsImageSourcesDiscard), role: .destructive) { dismiss() }
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
                    error = String(localized: .settingsImageSourcesSavedButEnableFailed(message))
                } else {
                    key = ""
                    dismiss()
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
