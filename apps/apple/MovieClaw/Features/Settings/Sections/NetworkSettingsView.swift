import SwiftUI

/// 网络首页仅呈现配置入口；编辑使用草稿，服务开关串行保存后再测试。
struct NetworkSettingsView: View {
    @Environment(\.api) private var api
    @State private var view: Loadable<API.NetworkConfigView> = .loading
    @State private var form = API.NetworkConfigPayload()
    @State private var editor: NetworkEditorKind?
    @State private var tests: [String: NetworkTestState] = [:]
    @State private var saveChain: Task<Void, Never>?
    @State private var saving = false
    @State private var saveError: String?
    @State private var configGeneration = 0

    var body: some View {
        Group {
            switch view {
            case .loading: SettingsLoadingRow(text: String(localized: .settingsNetworkProxyLoading)).task { await reload() }
            case let .failed(message): ErrorState(title: String(localized: .settingsNetworkProxyLoadFailed), message: message, retry: reload)
            case let .loaded(current): loaded(current)
            }
        }
        .appBackground()
    }

    private func loaded(_ current: API.NetworkConfigView) -> some View {
        List {
            SettingsFormSection {
                Button { editor = .proxy } label: {
                    navigationRow(String(localized: .settingsNetworkUiProxy), value: NetworkSettingsValidation.proxyTitle(form.proxyMode))
                }.disabled(saving).accessibilityIdentifier("network-proxy-settings")
                NavigationLink {
                    serviceList(current.services.filter { !$0.id.hasPrefix("site:") }, title: String(localized: .settingsNetworkUiServices), current: current)
                } label: { Text(String(localized: .settingsNetworkUiServicesTests)) }
                .accessibilityIdentifier("network-services")
                if current.services.contains(where: { $0.id.hasPrefix("site:") }) {
                    NavigationLink {
                        serviceList(current.services.filter { $0.id.hasPrefix("site:") }, title: String(localized: .settingsNetworkProxySites), current: current)
                    } label: { Text(String(localized: .settingsNetworkProxySites)) }
                    .accessibilityIdentifier("network-sites")
                }
            } header: { Text(String(localized: .downloadConfigConnection)) } footer: {
                Text(String(localized: .settingsNetworkUiServicesHint))
            }
            SettingsFormSection {
                NavigationLink { ExternalAccessSettingsView() } label: { Text(String(localized: .settingsNetworkExternalTitle)) }
                    .accessibilityIdentifier("network-external-access")
                Button { editor = .mirrors } label: {
                    navigationRow(String(localized: .settingsNetworkUiMirrors), value: (form.tmdbApiBaseUrl ?? "").isEmpty && (form.tmdbImageBaseUrl ?? "").isEmpty ? String(localized: .settingsAppearanceDefaultBackdrop) : String(localized: .settingsScrapeCustom))
                }.disabled(saving).accessibilityIdentifier("network-mirror")
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $editor) { kind in
            NetworkConfigEditor(kind: kind, current: current, initial: form) { draft in
                await saveChain?.value
                saving = true
                invalidateTests()
                defer { saving = false }
                do {
                    // 后端为全量覆盖：只合并本抽屉负责的字段，保留最新确认过的其它配置。
                    let saved = try await api.netSet(body: kind.merging(draft, into: form))
                    accept(saved)
                    return nil
                } catch { return error.localizedDescription }
            }.sheetFeedback()
        }
    }

    private func navigationRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    private func serviceList(_ services: [API.EgressServiceOption], title: String, current: API.NetworkConfigView) -> some View {
        List {
            if let saveError { SettingsFormSection { SettingsNotice(text: saveError) } }
            ForEach(services, id: \.id) { service in
                SettingsFormSection {
                    Toggle(service.label, isOn: Binding(get: { (form.proxyServices ?? []).contains(service.id) }, set: { on in
                        var next = form
                        var ids = next.proxyServices ?? []
                        if on { if !ids.contains(service.id) { ids.append(service.id) } }
                        else { ids.removeAll { $0 == service.id } }
                        next.proxyServices = ids
                        commit(next)
                    }))
                    .disabled(!proxyActive(current) || saving)
                    .accessibilityIdentifier("network-proxy-\(service.id)")
                    Button { runTest(service.id) } label: {
                        HStack {
                            Text(String(localized: .settingsNetworkUiTest))
                            Spacer()
                            testResult(service.id)
                        }
                    }
                    .disabled(saving || tests[service.id]?.isPending == true)
                    .accessibilityIdentifier("network-test-\(service.id)")
                    if case let .done(result) = tests[service.id], !result.message.isEmpty {
                        Text(result.message).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("network-test-result-\(service.id)")
                    }
                } footer: { Text(service.description) }
            }
            SettingsFormSection { } footer: {
                Text(proxyActive(current)
                     ? String(localized: .settingsNetworkUiServicesFooter)
                     : String(localized: .settingsNetworkUiNoProxy))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func testResult(_ service: String) -> some View {
        switch tests[service] {
        case .pending: ProgressView().accessibilityLabel(String(localized: .settingsLlmUiTesting))
        case let .done(result):
            Label(result.ok ? (result.latencyMs.map { "\($0) ms" } ?? String(localized: .settingsNetworkProxyConnected)) : String(localized: .settingsNetworkProxyUnreachable),
                  systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(result.ok ? Theme.success : Theme.danger)
        case nil: EmptyView()
        }
    }

    private func proxyActive(_ current: API.NetworkConfigView) -> Bool {
        switch form.proxyMode {
        case "manual": NetworkSettingsValidation.validURL(form.proxyUrl ?? "", proxy: true)
        case "env": !current.envProxyDetected.isEmpty
        default: false
        }
    }

    private func reload() async {
        await Loadable.load(into: $view) { try await api.netShow() }
        if let current = view.value { accept(current) }
    }

    private func accept(_ current: API.NetworkConfigView) {
        view = .loaded(current)
        form = .init(proxyMode: current.proxyMode, proxyUrl: current.proxyUrl, proxyServices: current.proxyServices,
                     tmdbApiBaseUrl: current.tmdbApiBaseUrl, tmdbImageBaseUrl: current.tmdbImageBaseUrl, doubanApiBaseUrl: current.doubanApiBaseUrl)
        invalidateTests()
    }

    private func invalidateTests() {
        configGeneration += 1
        tests = [:]
    }

    private func commit(_ next: API.NetworkConfigPayload) {
        guard !saving else { return }
        let previous = form
        form = next
        saving = true
        saveError = nil
        invalidateTests()
        let pending = saveChain
        saveChain = Task {
            await pending?.value
            defer { saving = false }
            do { accept(try await api.netSet(body: next)) }
            catch { form = previous; saveError = error.localizedDescription }
        }
    }

    private func runTest(_ service: String) {
        guard !saving else { return }
        tests[service] = .pending
        let generation = configGeneration
        let pending = saveChain
        Task {
            await pending?.value
            guard generation == configGeneration else { return }
            let result: API.NetworkTestResult
            do { result = try await api.netTest(body: .init(service: service)) }
            catch { result = .init(ok: false, latencyMs: nil, message: error.localizedDescription) }
            // 旧配置的慢测试不能覆盖新配置；失败或成功均遵循同一代次。
            guard generation == configGeneration else { return }
            tests[service] = .done(result)
        }
    }
}

private enum NetworkTestState {
    case pending, done(API.NetworkTestResult)
    var isPending: Bool { if case .pending = self { true } else { false } }
}

enum NetworkEditorKind: String, Identifiable {
    case proxy, mirrors
    var id: String { rawValue }
    var title: String { self == .proxy ? String(localized: .settingsNetworkUiProxy) : String(localized: .settingsNetworkUiMirrors) }

    /// API 要求全量配置；草稿只能替换本编辑区字段，不能重放过时的服务开关。
    func merging(_ draft: API.NetworkConfigPayload, into latest: API.NetworkConfigPayload) -> API.NetworkConfigPayload {
        var next = latest
        switch self {
        case .proxy:
            next.proxyMode = draft.proxyMode
            next.proxyUrl = draft.proxyUrl
        case .mirrors:
            next.tmdbApiBaseUrl = draft.tmdbApiBaseUrl
            next.tmdbImageBaseUrl = draft.tmdbImageBaseUrl
        }
        return next
    }
}

enum NetworkSettingsValidation {
    static func validURL(_ value: String, proxy: Bool = false, allowEmpty: Bool = false) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return allowEmpty }
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        return (proxy ? ["http", "https", "socks5", "socks5h"] : ["http", "https"]).contains(scheme)
    }

    static func port(_ value: String) -> Int? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let port = Int(value), (1 ... 65535).contains(port) else { return nil }
        return port
    }

    static func proxyTitle(_ mode: String?) -> String {
        switch mode { case "manual": String(localized: .settingsNetworkProxyManual); case "env": String(localized: .settingsNetworkProxyEnv); default: String(localized: .settingsNetworkProxyOff) }
    }
}

private struct NetworkConfigEditor: View {
    let kind: NetworkEditorKind
    let current: API.NetworkConfigView
    let initial: API.NetworkConfigPayload
    let onSave: (API.NetworkConfigPayload) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: API.NetworkConfigPayload
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false

    init(kind: NetworkEditorKind, current: API.NetworkConfigView, initial: API.NetworkConfigPayload,
         onSave: @escaping (API.NetworkConfigPayload) async -> String?) {
        self.kind = kind; self.current = current; self.initial = initial; self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    private var valid: Bool {
        if kind == .proxy { return draft.proxyMode != "manual" || NetworkSettingsValidation.validURL(draft.proxyUrl ?? "", proxy: true) }
        return NetworkSettingsValidation.validURL(draft.tmdbApiBaseUrl ?? "", allowEmpty: true)
            && NetworkSettingsValidation.validURL(draft.tmdbImageBaseUrl ?? "", allowEmpty: true)
    }

    var body: some View {
        SubsSheetScaffold(title: kind.title, onClose: {
            if draft != initial { discarding = true } else { dismiss() }
        }, confirm: .init(title: String(localized: .commonSave), enabled: draft != initial && valid, busy: busy, identifier: "network-editor-save") {
            Task {
                busy = true
                draft.proxyUrl = draft.proxyUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.tmdbApiBaseUrl = draft.tmdbApiBaseUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.tmdbImageBaseUrl = draft.tmdbImageBaseUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                error = await onSave(draft)
                busy = false
                if error == nil { dismiss() }
            }
        }) {
            if kind == .proxy {
                SettingsFormSection {
                    Picker(String(localized: .settingsNetworkProxyMode), selection: Binding(get: { draft.proxyMode ?? "off" }, set: { draft.proxyMode = $0 })) {
                        Text(String(localized: .settingsNetworkProxyOff)).tag("off")
                        Text(String(localized: .settingsNetworkProxyEnv)).tag("env")
                        Text(String(localized: .settingsNetworkProxyManual)).tag("manual")
                    }.pickerStyle(.menu).accessibilityIdentifier("network-proxy-mode")
                    if draft.proxyMode == "manual" {
                        urlField(String(localized: .settingsNetworkProxyAddress), placeholder: "socks5://192.168.1.2:7891", value: $draft.proxyUrl, id: "network-proxy-url")
                    }
                    if draft.proxyMode == "env" {
                        LabeledContent(String(localized: .settingsNetworkProxyEnv), value: current.envProxyDetected.isEmpty ? String(localized: .settingsNetworkUiNoEnvProxy) : current.envProxyDetected)
                    }
                } footer: {
                    Text(draft.proxyMode == "manual" ? String(localized: .settingsNetworkUiManualHint) : String(localized: .settingsNetworkUiEnvHint))
                }
            } else {
                SettingsFormSection {
                    urlField(String(localized: .settingsNetworkProxyApiAddress), placeholder: current.mirrorDefaults["tmdb_api_base_url"] ?? "https://api.themoviedb.org", value: $draft.tmdbApiBaseUrl, id: "network-mirror-api")
                    urlField(String(localized: .settingsNetworkProxyImageAddress), placeholder: current.mirrorDefaults["tmdb_image_base_url"] ?? "https://image.tmdb.org", value: $draft.tmdbImageBaseUrl, id: "network-mirror-image")
                } footer: {
                    Text(String(localized: .settingsNetworkUiMirrorHint))
                }
            }
            if !valid { SettingsFormSection { Text(String(localized: .settingsNetworkUiAddressInvalid)).foregroundStyle(Theme.warning) } }
            if let error { SettingsFormSection { SettingsNotice(text: error) } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || draft != initial)
        .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
        }
    }

    private func urlField(_ title: String, placeholder: String, value: Binding<String?>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(placeholder, text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 }))
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier(id)
        }
    }
}

private struct ExternalAccessSettingsView: View {
    @Environment(\.api) private var api
    @State private var config: Loadable<API.AppConfigView> = .loading
    @State private var editor: ExternalAccessEditor.Kind?
    @State private var newPort: Int?

    var body: some View {
        List {
            switch config {
            case .loading: SettingsLoadingRow()
            case let .failed(error):
                SettingsNotice(text: error)
                Button(String(localized: .commonRetry)) { Task { await load() } }
            case let .loaded(value):
                if let newPort {
                    SettingsFormSection {
                        Text(String(localized: .settingsNetworkUiPortChanged(String(newPort))))
                        Text(portURL(newPort)).textSelection(.enabled)
                    } header: { Text(String(localized: .settingsNetworkUiRestartingNewPort)) } footer: {
                        Text(String(localized: .settingsNetworkUiRestartHint(String(newPort))))
                    }
                } else {
                    SettingsFormSection {
                        Button { editor = .url } label: {
                            row(String(localized: .settingsNetworkExternalAddress), value: value.externalUrl.isEmpty ? String(localized: .settingsScheduledTasksScheduleUnset) : value.externalUrl)
                        }.accessibilityIdentifier("network-external-url-settings")
                    } footer: { Text(String(localized: .settingsNetworkUiExternalHint)) }
                    SettingsFormSection {
                        Button { editor = .port } label: { row(String(localized: .settingsNetworkExternalPort), value: String(value.webPort)) }
                            .disabled(!value.webPortConfigurable).accessibilityIdentifier("network-port-settings")
                    } footer: {
                        Text(value.webPortConfigurable ? String(localized: .settingsNetworkUiPortHint) : String(localized: .settingsNetworkUiPortExternal))
                    }
                    if let rejected = value.webPortRejected {
                        SettingsFormSection { SettingsNotice(text: String(localized: .settingsNetworkUiPortFallback(String(rejected), String(value.webPort))), tone: .warn) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: .settingsNetworkExternalTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $editor) { kind in
            if let value = config.value {
                ExternalAccessEditor(kind: kind, config: value, origin: api.server.origin) { updated, changedPort in
                    config = .loaded(updated)
                    newPort = changedPort
                }.sheetFeedback()
            }
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    private func portURL(_ port: Int) -> String {
        var components = URLComponents(url: api.server.origin, resolvingAgainstBaseURL: false)
        components?.port = port
        return components?.url?.absoluteString ?? String(localized: .settingsNetworkUiPortLabel(String(port)))
    }

    private func load() async { await Loadable.load(into: $config) { try await api.appShow() } }
}

private struct ExternalAccessEditor: View {
    enum Kind: String, Identifiable {
        case url, port
        var id: String { rawValue }
        var title: String { self == .url ? String(localized: .settingsNetworkExternalAddress) : String(localized: .settingsNetworkExternalPort) }
    }
    let kind: Kind
    let config: API.AppConfigView
    let origin: URL
    let onSaved: (API.AppConfigView, Int?) -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var restoring = false
    @State private var confirming = false
    @State private var discarding = false
    @State private var busy = false
    @State private var error: String?

    init(kind: Kind, config: API.AppConfigView, origin: URL, onSaved: @escaping (API.AppConfigView, Int?) -> Void) {
        self.kind = kind; self.config = config; self.origin = origin; self.onSaved = onSaved
        _draft = State(initialValue: kind == .url ? config.externalUrl : String(config.webPort))
    }

    private var dirty: Bool { draft != (kind == .url ? config.externalUrl : String(config.webPort)) }
    private var valid: Bool { kind == .url ? NetworkSettingsValidation.validURL(draft, allowEmpty: true) : NetworkSettingsValidation.port(draft) != nil }
    private var resetTarget: Int { config.webPortResetTarget ?? config.webPortDefault }
    private var target: Int { restoring ? resetTarget : NetworkSettingsValidation.port(draft) ?? config.webPort }
    private var confirmationMessage: String {
        let seenPort = origin.port ?? (origin.scheme == "https" ? 443 : 80)
        let mapping = seenPort != config.webPort ? String(localized: .settingsNetworkUiMappingNote(String(seenPort), String(config.webPort))) : ""
        return String(localized: .settingsNetworkUiRestartConfirm(String(target), mapping))
    }

    var body: some View {
        SubsSheetScaffold(title: kind.title, onClose: {
            if dirty { discarding = true } else { dismiss() }
        }, confirm: .init(title: kind == .url ? String(localized: .commonSave) : String(localized: .commonContinue), enabled: dirty && valid, busy: busy,
                         identifier: kind == .url ? "network-external-save" : "network-port-review") {
            if kind == .url { Task { await saveURL() } }
            else { restoring = false; confirming = true }
        }) {
            SettingsFormSection {
                TextField(kind == .url ? origin.absoluteString : String(localized: .settingsNetworkUiPortField), text: $draft)
                    .keyboardType(kind == .url ? .URL : .numberPad)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier(kind == .url ? "network-external-url" : "network-port")
                if kind == .url {
                    Button(String(localized: .settingsNetworkUiUseCurrent)) { draft = origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                } else {
                    LabeledContent(String(localized: .settingsNetworkUiCurrentPort), value: String(config.webPort))
                    LabeledContent(String(localized: .settingsDevicesApprovalSource), value: config.webPortSource == "setting" ? String(localized: .settingsNetworkExternalSettingSource) : config.webPortSource == "env" ? String(localized: .settingsNetworkProxyEnv) : String(localized: .settingsAppearanceDefaultBackdrop))
                    if config.webPortSource == "setting" {
                        Button(String(localized: .settingsNetworkUiRestoreDefaultPort(String(resetTarget)))) { restoring = true; confirming = true }
                    }
                }
            } footer: {
                Text(kind == .url ? String(localized: .settingsNetworkUiUrlHint)
                     : String(localized: .settingsNetworkUiPortRangeHint))
            }
            if !valid { SettingsFormSection { Text(kind == .url ? String(localized: .settingsNetworkUiUrlInvalid) : String(localized: .settingsNetworkUiPortInvalid)).foregroundStyle(Theme.warning) } }
            if let error { SettingsFormSection { SettingsNotice(text: error) } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || dirty)
        .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
        }
        .alert(String(localized: .settingsNetworkUiConfirmPortTitle), isPresented: $confirming) {
            Button(String(localized: .commonCancel), role: .cancel) { }.accessibilityIdentifier("network-port-cancel")
            Button(String(localized: .settingsNetworkUiChangeRestart), role: .destructive) { Task { await savePort() } }
                .accessibilityIdentifier("network-port-confirm")
        } message: { Text(confirmationMessage) }
    }

    private func saveURL() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let saved = try await api.appSet(body: .init(externalUrl: draft.trimmingCharacters(in: .whitespacesAndNewlines)))
            onSaved(saved, nil); dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func savePort() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let saved = try await api.appPortSet(body: .init(port: restoring ? 0 : target))
            onSaved(saved, saved.webPort == config.webPort ? nil : saved.webPort)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
