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
            case .loading: SettingsLoadingRow(text: "正在加载网络配置…").task { await reload() }
            case let .failed(message): ErrorState(title: "网络配置加载失败", message: message, retry: reload)
            case let .loaded(current): loaded(current)
            }
        }
        .appBackground()
    }

    private func loaded(_ current: API.NetworkConfigView) -> some View {
        List {
            SettingsFormSection {
                Button { editor = .proxy } label: {
                    navigationRow("代理配置", value: NetworkSettingsValidation.proxyTitle(form.proxyMode))
                }.disabled(saving).accessibilityIdentifier("network-proxy-settings")
                NavigationLink {
                    serviceList(current.services.filter { !$0.id.hasPrefix("site:") }, title: "服务代理", current: current)
                } label: { Text("服务代理与测试") }
                .accessibilityIdentifier("network-services")
                if current.services.contains(where: { $0.id.hasPrefix("site:") }) {
                    NavigationLink {
                        serviceList(current.services.filter { $0.id.hasPrefix("site:") }, title: "PT 站点", current: current)
                    } label: { Text("PT 站点") }
                    .accessibilityIdentifier("network-sites")
                }
            } header: { Text("连接") } footer: {
                Text("按服务选择代理。内网下载器和媒体服务器始终直连。")
            }
            SettingsFormSection {
                NavigationLink { ExternalAccessSettingsView() } label: { Text("外部访问") }
                    .accessibilityIdentifier("network-external-access")
                Button { editor = .mirrors } label: {
                    navigationRow("TMDB 镜像", value: (form.tmdbApiBaseUrl ?? "").isEmpty && (form.tmdbImageBaseUrl ?? "").isEmpty ? "默认" : "自定义")
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
                            Text("测试连接")
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
                     ? "开关决定此服务是否走代理，改动立即生效。测试会按已保存的配置发起真实请求。"
                     : "当前没有可用代理。测试仍可检查直连或镜像的连通性。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func testResult(_ service: String) -> some View {
        switch tests[service] {
        case .pending: ProgressView().accessibilityLabel("测试中")
        case let .done(result):
            Label(result.ok ? (result.latencyMs.map { "\($0) ms" } ?? "连通") : "不通",
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
    var title: String { self == .proxy ? "代理配置" : "TMDB 镜像" }

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
        switch mode { case "manual": "手动"; case "env": "环境变量"; default: "不使用" }
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
        }, confirm: .init(title: "保存", enabled: draft != initial && valid, busy: busy, identifier: "network-editor-save") {
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
                    Picker("代理方式", selection: Binding(get: { draft.proxyMode ?? "off" }, set: { draft.proxyMode = $0 })) {
                        Text("不使用").tag("off")
                        Text("环境变量").tag("env")
                        Text("手动").tag("manual")
                    }.pickerStyle(.menu).accessibilityIdentifier("network-proxy-mode")
                    if draft.proxyMode == "manual" {
                        urlField("代理地址", placeholder: "socks5://192.168.1.2:7891", value: $draft.proxyUrl, id: "network-proxy-url")
                    }
                    if draft.proxyMode == "env" {
                        LabeledContent("环境变量", value: current.envProxyDetected.isEmpty ? "未检测到代理" : current.envProxyDetected)
                    }
                } footer: {
                    Text(draft.proxyMode == "manual" ? "支持 HTTP、HTTPS、SOCKS5 和 SOCKS5H。地址必须能由服务器访问，保存后立即生效。" : "环境变量使用服务器的 HTTPS_PROXY、HTTP_PROXY 或 ALL_PROXY；不使用时全部服务直连。")
                }
            } else {
                SettingsFormSection {
                    urlField("接口地址", placeholder: current.mirrorDefaults["tmdb_api_base_url"] ?? "https://api.themoviedb.org", value: $draft.tmdbApiBaseUrl, id: "network-mirror-api")
                    urlField("图床地址", placeholder: current.mirrorDefaults["tmdb_image_base_url"] ?? "https://image.tmdb.org", value: $draft.tmdbImageBaseUrl, id: "network-mirror-image")
                } footer: {
                    Text("留空使用默认地址。只填域名时会自动补全接口 /3 和图床 /t/p 路径。镜像可作为代理的替代方案；同时配置时会经代理访问镜像。公共镜像会接触你的 API Key，请选可信服务。")
                }
            }
            if !valid { SettingsFormSection { Text("请输入包含域名或 IP 的完整地址，并检查协议。代理支持 http(s) / socks5(h)，镜像支持 http(s)。").foregroundStyle(Theme.warning) } }
            if let error { SettingsFormSection { SettingsNotice(text: error) } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || draft != initial)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { dismiss() }
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
                Button("重试") { Task { await load() } }
            case let .loaded(value):
                if let newPort {
                    SettingsFormSection {
                        Text("对外端口已改为 \(newPort)")
                        Text(portURL(newPort)).textSelection(.enabled)
                    } header: { Text("正在新端口重启") } footer: {
                        Text("当前连接地址可能已失效。Docker bridge 部署需将端口映射的容器侧端口改为 \(newPort) 并重建容器。重启后请在登录页的「更换服务器」中填写新地址。")
                    }
                } else {
                    SettingsFormSection {
                        Button { editor = .url } label: {
                            row("外部访问地址", value: value.externalUrl.isEmpty ? "未设置" : value.externalUrl)
                        }.accessibilityIdentifier("network-external-url-settings")
                    } footer: { Text("用于通知跳转、AI 回复链接与对外回调。保存后立即生效。") }
                    SettingsFormSection {
                        Button { editor = .port } label: { row("对外端口", value: String(value.webPort)) }
                            .disabled(!value.webPortConfigurable).accessibilityIdentifier("network-port-settings")
                    } footer: {
                        Text(value.webPortConfigurable ? "修改监听端口会重启服务器。反向代理和 Docker 端口映射也需要同步调整。" : "当前部署由外部进程提供入口，请在启动命令或反向代理中修改端口。")
                    }
                    if let rejected = value.webPortRejected {
                        SettingsFormSection { SettingsNotice(text: "端口 \(rejected) 无法绑定，已回落到 \(value.webPort)。", tone: .warn) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("外部访问")
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
        return components?.url?.absoluteString ?? "端口 \(port)"
    }

    private func load() async { await Loadable.load(into: $config) { try await api.appShow() } }
}

private struct ExternalAccessEditor: View {
    enum Kind: String, Identifiable {
        case url, port
        var id: String { rawValue }
        var title: String { self == .url ? "外部访问地址" : "对外端口" }
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
    private var target: Int { restoring ? config.webPortDefault : NetworkSettingsValidation.port(draft) ?? config.webPort }
    private var confirmationMessage: String {
        let seenPort = origin.port ?? (origin.scheme == "https" ? 443 : 80)
        let mapping = seenPort != config.webPort ? "当前通过端口 \(seenPort) 访问，服务器监听 \(config.webPort)，中间存在端口映射或反向代理。" : ""
        return "服务器将重启并监听端口 \(target)，当前地址可能失效。\(mapping)Docker bridge 部署必须同步修改 compose 中 ports 的容器侧端口并重建容器；反向代理必须调整目标端口。只想改变访问端口时，可直接调整映射或反向代理。"
    }

    var body: some View {
        SubsSheetScaffold(title: kind.title, onClose: {
            if dirty { discarding = true } else { dismiss() }
        }, confirm: .init(title: kind == .url ? "保存" : "继续", enabled: dirty && valid, busy: busy,
                         identifier: kind == .url ? "network-external-save" : "network-port-review") {
            if kind == .url { Task { await saveURL() } }
            else { restoring = false; confirming = true }
        }) {
            SettingsFormSection {
                TextField(kind == .url ? origin.absoluteString : "端口", text: $draft)
                    .keyboardType(kind == .url ? .URL : .numberPad)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier(kind == .url ? "network-external-url" : "network-port")
                if kind == .url {
                    Button("使用当前服务器地址") { draft = origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                } else {
                    LabeledContent("当前端口", value: String(config.webPort))
                    LabeledContent("来源", value: config.webPortSource == "setting" ? "应用内设置" : config.webPortSource == "env" ? "环境变量" : "默认")
                    if config.webPortSource == "setting" {
                        Button("恢复默认端口（\(config.webPortDefault)）") { restoring = true; confirming = true }
                    }
                }
            } footer: {
                Text(kind == .url ? "填写可从外部访问的完整 http(s) 地址；经反向代理访问时填写代理后的地址。留空可清除设置。"
                     : "有效范围 1–65535。修改后服务器将全量重启；如果使用 Docker bridge，通常只需调整宿主侧端口映射。")
            }
            if !valid { SettingsFormSection { Text(kind == .url ? "请输入完整的 http(s) 地址。" : "请输入 1–65535 的整数。").foregroundStyle(Theme.warning) } }
            if let error { SettingsFormSection { SettingsNotice(text: error) } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || dirty)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { dismiss() }
        }
        .alert("确认修改端口并重启？", isPresented: $confirming) {
            Button("取消", role: .cancel) { }.accessibilityIdentifier("network-port-cancel")
            Button("修改并重启", role: .destructive) { Task { await savePort() } }
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
