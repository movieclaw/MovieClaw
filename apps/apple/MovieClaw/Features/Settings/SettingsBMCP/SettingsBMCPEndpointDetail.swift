import SwiftUI

/// 端点详情：连接概览与自检；工具目录独立导航，编辑与危险操作在右上角。
struct SettingsBMCPEndpointDetail: View {
    let store: SettingsBMCPStore
    let endpointId: String

    enum Tab: String, CaseIterable, Identifiable {
        case overview, tools, settings
        var id: String { rawValue }

        /// Web 地址栏 `?tab=` 的取值（overview / tools / settings）
        init?(query: String?) {
            switch query {
            case "overview": self = .overview
            case "tools": self = .tools
            case "settings": self = .settings
            default: return nil
            }
        }
    }

    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @Environment(\.dismiss) private var dismiss
    private let initialTab: Tab
    @State private var routeConsumed = false
    @State private var showingTools = false
    @State private var editing = false
    @State private var deleting = false
    @State private var preview: API.PreviewView?
    @State private var previewError: String?
    @State private var check: API.SelfCheckView?
    @State private var checking = false
    @State private var issued: SettingsBMCPIssued?

    /// - Parameter initialTab: 深链 `?endpoint=&tab=` 直达的栏目；缺省概览
    init(store: SettingsBMCPStore, endpointId: String, initialTab: Tab = .overview) {
        self.store = store
        self.endpointId = endpointId
        self.initialTab = initialTab
    }

    var body: some View {
        Group {
            if let endpoint = store.endpoint(id: endpointId) {
                content(endpoint)
                    .task(id: PreviewKey(services: endpoint.services, expand: endpoint.expandTools)) {
                        await loadPreview(endpoint)
                    }
            } else {
                EmptyState(systemImage: "questionmark.folder", title: String(localized: .settingsMcpUiMissing), message: String(localized: .settingsMcpUiMissingHint))
            }
        }
        .navigationTitle(store.endpoint(id: endpointId)?.name ?? String(localized: .settingsMcpControlsEndpoints))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let endpoint = store.endpoint(id: endpointId) {
                    Menu {
                        Button(String(localized: .settingsMcpUiEdit), systemImage: "pencil") { editing = true }
                            .accessibilityIdentifier("mcp-detail-edit")
                        Button(String(localized: .settingsMcpUiRotate), systemImage: "key") { Task { await rotate(endpoint) } }
                            .accessibilityIdentifier("mcp-detail-rotate")
                        Button(String(localized: .settingsMcpUiDelete), systemImage: "trash", role: .destructive) { deleting = true }
                            .accessibilityIdentifier("mcp-detail-delete")
                    } label: { Label(String(localized: .settingsMcpUiActions), systemImage: "ellipsis") }
                    .disabled(store.busy)
                    .accessibilityIdentifier("mcp-detail-actions")
                }
            }
        }
        .task {
            guard !routeConsumed else { return }
            routeConsumed = true
            showingTools = initialTab == .tools
            editing = initialTab == .settings
        }
        .navigationDestination(isPresented: $showingTools) {
            Form {
                if let preview { SettingsBMCPToolCatalog(tools: preview.tools) }
                else if let previewError {
                    SettingsFormSection {
                        SettingsBNotice(text: previewError, tone: .danger).accessibilityIdentifier("mcp-tools-error")
                        Button(String(localized: .settingsMcpUiReloadTools), systemImage: "arrow.clockwise") {
                            guard let endpoint = store.endpoint(id: endpointId) else { return }
                            Task { await loadPreview(endpoint) }
                        }.accessibilityIdentifier("mcp-tools-retry")
                    }
                } else { SettingsFormSection { ProgressView(String(localized: .settingsMcpControlsLoadingCatalog)) } }
            }
            .settingsBFormStyle()
            .navigationTitle(String(localized: .settingsMcpUiTools))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if preview == nil, previewError == nil, let endpoint = store.endpoint(id: endpointId) {
                    await loadPreview(endpoint)
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let endpoint = store.endpoint(id: endpointId) {
                SettingsBMCPEditSheet(store: store, endpoint: endpoint).sheetFeedback()
            }
        }
        .sheet(isPresented: $deleting) {
            if let endpoint = store.endpoint(id: endpointId) {
                SettingsBMCPDeleteSheet(store: store, endpoint: endpoint) {
                    deleting = false
                    dismiss()
                }.sheetFeedback()
            }
        }
        .sheet(item: $issued) { item in
            SettingsBMCPTokenIssuedView(
                name: item.created.endpoint.name,
                url: store.fullURL(item.created.endpoint),
                token: item.created.token
            ) {
                issued = nil

            }
            .sheetFeedback()
        }
    }

    private struct PreviewKey: Equatable {
        var services: [String]
        var expand: Bool
    }

    // MARK: - 页面

    private func content(_ endpoint: API.EndpointView) -> some View {
        Form {
            if let error = store.error {
                SettingsFormSection {
                    SettingsBNotice(text: error, tone: .danger).accessibilityIdentifier("mcp-error")
                }
            }
            header(endpoint)
            overview(endpoint)

        }
        .settingsBFormStyle()
        .refreshable { await store.load(api) }
    }

    /// 头部：名字 + 启停开关，下一行淡色元信息（状态 / 地址 / 形态）
    private func header(_ endpoint: API.EndpointView) -> some View {
        SettingsFormSection {
            Toggle(isOn: Binding(
                get: { endpoint.enabled },
                set: { next in
                    guard !store.busy else { return }
                    Task { _ = await store.run(api) { try await api.mcpEndpointsUpdate(endpointId: endpoint.id, body: .init(enabled: next)) } }
                }
            )) {
                Label(endpoint.enabled ? String(localized: .settingsMembersUiEnabled) : String(localized: .settingsMembersUiDisabled), systemImage: endpoint.enabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(endpoint.enabled ? Color.green : Theme.textMuted)
            }
            .disabled(store.busy)
            .accessibilityLabel(String(localized: .settingsWebhookUiEnableEndpoint(endpoint.name)))
            .accessibilityIdentifier("mcp-endpoint-enabled")
        }
    }

    // MARK: - 概览

    @ViewBuilder
    private func overview(_ endpoint: API.EndpointView) -> some View {
        // 接进一个客户端要填的全部东西，就是地址 + 认证头
        SettingsFormSection {
            SettingsBMCPCopyField(value: store.fullURL(endpoint), label: String(localized: .settingsMcpControlsCopyAddress), identifier: "mcp-detail-copy-url")
                .settingsRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            if !endpoint.url.hasPrefix("http") {
                SettingsBNotice(text: String(localized: .settingsMcpControlsExternalHint), tone: .warn)
                    .settingsRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        } header: {
            Text(String(localized: .settingsMcpControlsAddress))
        }

        SettingsFormSection {
            SettingsBMCPCodeBlock(code: String(localized: .settingsMcpUiHeaderExample), lang: "http", identifier: "mcp-detail-copy-header")
                .settingsRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            DisclosureGroup(String(localized: .settingsMcpUiConnectHelp)) {
                Text(String(localized: .settingsMcpUiConnectHelpText))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: .settingsMcpControlsAuthHeader))
        }

        selfCheckSection(endpoint)

        SettingsFormSection {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: .settingsMcpControlsServices)).foregroundStyle(Theme.textMuted)
                // 详情页不设上限：这一屏就是要看全「到底开放了什么」
                SettingsBMCPServiceChips(services: endpoint.services, max: endpoint.services.count)
            }
            Button { showingTools = true } label: {
                HStack {
                    Text(String(localized: .settingsMcpUiTools)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(String(localized: .settingsMcpControlsCountUnit(endpoint.toolCount))).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }.accessibilityIdentifier("mcp-detail-tools")
            LabeledContent(String(localized: .settingsMcpUiToolDefinitions), value: preview.map { SettingsBMCPFormat.bytes($0.approxBytes) } ?? (previewError == nil ? String(localized: .settingsMcpControlsCalculating) : String(localized: .settingsPluginsLoadFailed)))
            LabeledContent(String(localized: .settingsMcpControlsMode), value: SettingsBMCPFormat.mode(endpoint.expandTools))
            LabeledContent(String(localized: .settingsMcpControlsToken), value: endpoint.tokenHint)
            LabeledContent(String(localized: .settingsMcpControlsLastCalled)) {
                Text(endpoint.lastUsedAt == nil ? String(localized: .settingsMcpControlsNeverCalled) : SettingsBMCPFormat.relative(endpoint.lastUsedAt))
                    .accessibilityIdentifier("mcp-detail-last-used")
            }
        }

        if !endpoint.missingServices.isEmpty {
            SettingsFormSection {
                SettingsBNotice(
                    text: String(localized: .settingsMcpUiMissingServices(endpoint.missingServices.count, AppFormatting.list(endpoint.missingServices))),
                    tone: .warn
                )
            }
        }
    }

    /// 连通性自检：跑一遍真实协议，只试调只读工具，就地回答「它现在能用吗」
    private func selfCheckSection(_ endpoint: API.EndpointView) -> some View {
        SettingsFormSection {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: .settingsMcpControlsCheckTitle)).font(.subheadline.weight(.medium))
                    Text(String(localized: .settingsMcpControlsCheckHint))
                        .font(.caption).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(checking ? String(localized: .settingsMcpControlsChecking) : check == nil ? String(localized: .settingsMcpControlsRunCheck) : String(localized: .settingsMcpControlsCheckAgain)) {
                    Task { await runCheck(endpoint) }
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.glass)
                .disabled(checking)
                .accessibilityIdentifier("mcp-detail-check")
            }
            if let check {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SettingsBMCPStatusDot(on: check.ok)
                        Text(check.message)
                            .font(.subheadline)
                            .foregroundStyle(check.ok ? Theme.text : Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(check.elapsedMs) ms").font(.caption.monospacedDigit()).foregroundStyle(Theme.textFaint)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text(String(localized: .settingsMcpControlsProtocol)).foregroundStyle(Theme.textFaint)
                            Text(check.protocolVersion.isEmpty ? "—" : check.protocolVersion).monospaced()
                        }
                        GridRow {
                            Text(String(localized: .settingsMcpControlsTools)).foregroundStyle(Theme.textFaint)
                            Text(String(localized: .settingsMcpControlsCountUnit(check.toolCount))).monospacedDigit()
                        }
                        if !check.probeTool.isEmpty {
                            GridRow(alignment: .firstTextBaseline) {
                                Text(String(localized: .settingsMcpControlsProbe)).foregroundStyle(Theme.textFaint)
                                Text("\(Text(check.probeTool).monospaced().foregroundStyle(Theme.accent))  \(Text(check.probeOk ? String(localized: .settingsMcpControlsSucceeded) : String(localized: .settingsMcpControlsFailed)).foregroundStyle(check.probeOk ? Theme.text : Theme.danger))  \(Text(String(check.probeMessage.prefix(60))).foregroundStyle(Theme.textFaint))")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.caption)
                    ForEach(check.warnings, id: \.self) { warning in
                        SettingsBNotice(text: warning, tone: .warn)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mcp-detail-check-result")
            }
        }
    }

    // MARK: - 动作

    private func loadPreview(_ endpoint: API.EndpointView) async {
        preview = nil
        previewError = nil
        do {
            preview = try await api.mcpEndpointsPreview(body: .init(services: endpoint.services, expandTools: endpoint.expandTools))
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }

    /// 自检请求本身失败（网络断、接口不存在）也显示成一次「未通过」——自检的意义就是给出结论
    private func runCheck(_ endpoint: API.EndpointView) async {
        checking = true
        defer { checking = false }
        do {
            check = try await api.mcpEndpointsCheck(endpointId: endpoint.id)
        } catch {
            check = API.SelfCheckView(
                ok: false, message: String(localized: .settingsMcpControlsCheckRequestFailed(error.localizedDescription)), protocolVersion: "",
                toolCount: 0, elapsedMs: 0, probeTool: "", probeOk: false, probeMessage: "", warnings: []
            )
        }
    }

    private func rotate(_ endpoint: API.EndpointView) async {
        guard await feedback.confirm(
            String(localized: .settingsMcpControlsRotateTitle),
            message: String(localized: .settingsMcpControlsRotateDescription),
            confirmTitle: String(localized: .settingsMcpControlsGenerateToken)
        ) else { return }
        if let rotated = await store.run(api, { try await api.mcpEndpointsRotateToken(endpointId: endpoint.id) }) {
            issued = SettingsBMCPIssued(created: rotated)
        }
    }


}

/// 令牌专屏的弹出参数（不给生成模型加 Identifiable 一致性，包一层）
struct SettingsBMCPIssued: Identifiable {
    let id = UUID()
    let created: API.EndpointCreatedView
}

private struct SettingsBMCPEditSheet: View {
    let store: SettingsBMCPStore
    let endpoint: API.EndpointView
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SettingsBMCPDraft
    @State private var discarding = false

    init(store: SettingsBMCPStore, endpoint: API.EndpointView) {
        self.store = store
        self.endpoint = endpoint
        _draft = State(initialValue: SettingsBMCPDraft(endpoint))
    }

    private var dirty: Bool { draft != SettingsBMCPDraft(endpoint) }

    var body: some View {
        SubsSheetScaffold(title: String(localized: .settingsMcpUiEdit), onClose: {
            if dirty { discarding = true } else { dismiss() }
        }, confirm: SubsSheetConfirm(title: String(localized: .commonSave), enabled: dirty && draft.valid,
                                     busy: store.busy, identifier: "mcp-form-submit") {
            Task {
                let body = API.EndpointUpdateRequest(name: draft.name.trimmingCharacters(in: .whitespaces),
                    services: draft.services, expandTools: draft.expandTools, timeoutSeconds: draft.timeoutSeconds)
                if await store.run(api, { try await api.mcpEndpointsUpdate(endpointId: endpoint.id, body: body) }) != nil {
                    dismiss()
                }
            }
        }) {
            if let error = store.error { SettingsFormSection { SettingsBNotice(text: error, tone: .danger) } }
            SettingsBMCPEndpointFields(draft: $draft, services: store.status?.services ?? [],
                                      baseUrl: store.status?.baseUrl ?? "", slugEditable: false)
        }
        .disabled(store.busy)
        .interactiveDismissDisabled(store.busy || dirty)
        .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
        }
    }
}

private struct SettingsBMCPDeleteSheet: View {
    let store: SettingsBMCPStore
    let endpoint: API.EndpointView
    let onDeleted: () -> Void
    @Environment(\.api) private var api
    @State private var confirmText = ""

    var body: some View {
        SubsSheetScaffold(title: String(localized: .settingsMcpUiDelete)) {
            SettingsFormSection {
                Text(String(localized: .settingsMcpUiDeleteHint(endpoint.name)))
                TextField(endpoint.slug, text: $confirmText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("mcp-delete-confirm")
            } footer: { Text(String(localized: .settingsMcpUiTypeSlug(endpoint.slug))) }
            SettingsFormSection {
                Button(String(localized: .settingsMcpUiDelete), role: .destructive) {
                    Task {
                        if await store.run(api, { try await api.mcpEndpointsDelete(endpointId: endpoint.id) }) != nil {
                            onDeleted()
                        }
                    }
                }
                .disabled(store.busy || confirmText != endpoint.slug)
                .accessibilityIdentifier("mcp-delete")
            }
            if let error = store.error { SettingsFormSection { SettingsBNotice(text: error, tone: .danger) } }
        }
        .disabled(store.busy)
        .interactiveDismissDisabled(store.busy)
    }
}
