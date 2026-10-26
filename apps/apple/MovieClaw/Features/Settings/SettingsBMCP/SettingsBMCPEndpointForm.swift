import SwiftUI

/// 端点表单草稿（新建与编辑共用；数字以字符串暂存）
struct SettingsBMCPDraft: Equatable {
    var name = ""
    var slug = ""
    var services: [String] = []
    var description: String?
    var expandTools = true
    var timeout = "300"

    init() {}

    init(_ endpoint: API.EndpointView) {
        name = endpoint.name
        slug = endpoint.slug
        services = endpoint.services
        description = endpoint.description
        expandTools = endpoint.expandTools
        timeout = String(endpoint.timeoutSeconds)
    }

    var timeoutSeconds: Int? { Int(timeout.trimmingCharacters(in: .whitespaces)) }
    var timeoutValid: Bool { timeoutSeconds.map { (5 ... 900).contains($0) } ?? false }
    var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !services.isEmpty && timeoutValid }
}

/// 新建 / 编辑端点的字段区（对应 Web `EndpointForm`），产出若干 `Section`，嵌进调用方的 `Form`。
///
/// 按「配置 ↔ 后果」重排：
/// - 名称与地址标识（新建时即时校验格式与重名，不等提交换回 409）；
/// - 工具形态使用原生菜单，工具数、体积与说明随选择更新；
/// - 服务选择器可搜索、已选置顶，每条两行（域名 + 说明），说明是判断该不该勾的唯一依据，不截断；
/// - 「客户端将看到」：实时预览这套配置真实产出的工具面（`POST /mcp/endpoints/preview`，纯内存试算）。
///   Web 桌面放右栏，手机上顺延到最后一个 Section。
struct SettingsBMCPEndpointFields: View {
    @Binding var draft: SettingsBMCPDraft
    let services: [API.ServiceView]
    let baseUrl: String
    let slugEditable: Bool
    var takenSlugs: [String] = []

    @Environment(\.api) private var api
    @State private var query = ""
    /// 预览工具面；nil = 计算中
    @State private var preview: [API.ToolPreview]?

    /// 展开模式超过这个数就建议改折叠（业界观察到的模型退化下沿）。只建议，不拦
    private static let toolHintThreshold = 30
    /// 与后端 SLUG_PATTERN 同口径：小写字母数字与连字符，首尾不为连字符
    private static let slugPattern = #"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$"#

    /// 地址标识的即时校验：空值不报错（还没开始填），有值才判
    static func slugError(_ slug: String, editable: Bool, taken: [String]) -> String? {
        let s = slug.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, editable else { return nil }
        if s.range(of: slugPattern, options: .regularExpression) == nil {
            return String(localized: .settingsMcpControlsSlugInvalid)
        }
        if taken.contains(s) { return String(localized: .settingsMcpControlsSlugTaken) }
        return nil
    }

    private var picked: Set<String> { Set(draft.services) }
    private var chosen: [API.ServiceView] { services.filter { picked.contains($0.domain) } }
    private var commandTotal: Int { chosen.reduce(0) { $0 + $1.commandCount } }
    private var expandedBytes: Int { chosen.reduce(0) { $0 + $1.expandedBytes } }
    private var collapsedBytes: Int { chosen.reduce(0) { $0 + $1.collapsedBytes } }
    private var toolCount: Int { draft.expandTools ? commandTotal : chosen.count }
    private var bytes: Int { draft.expandTools ? expandedBytes : collapsedBytes }

    /// 搜索过滤 + 已选置顶：滚到哪儿都看得见自己选了什么
    private var visible: [API.ServiceView] {
        let keyword = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = keyword.isEmpty ? services : services.filter {
            $0.domain.lowercased().contains(keyword) || $0.description.lowercased().contains(keyword)
        }
        return rows.filter { picked.contains($0.domain) } + rows.filter { !picked.contains($0.domain) }
    }

    private struct SettingsBMCPPreviewKey: Equatable {
        var services: [String]
        var expand: Bool
    }

    var body: some View {
        basicSection
        modeSection
        servicesSection
        SettingsFormSection {
            SettingsBNumberField(label: String(localized: .settingsMcpControlsTimeout), text: $draft.timeout, placeholder: "300", identifier: "mcp-form-timeout")
        } footer: { Text(draft.timeoutValid ? String(localized: .settingsMcpFormTimeoutHint) : String(localized: .settingsMcpFormTimeoutInvalid)) }
        previewSection
    }

    // MARK: 名称与地址标识

    private var basicSection: some View {
        let slugError = Self.slugError(draft.slug, editable: slugEditable, taken: takenSlugs)
        return SettingsFormSection {
            SettingsBTextField(label: String(localized: .settingsMcpControlsName), text: $draft.name, placeholder: String(localized: .settingsMcpControlsNamePlaceholder), identifier: "mcp-form-name")
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: .settingsMcpControlsSlug) + (slugEditable ? "" : String(localized: .settingsMcpControlsSlugFixed)))
                    .font(.subheadline).foregroundStyle(Theme.textMuted)
                TextField("home-assistant", text: $draft.slug)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!slugEditable)
                    .opacity(slugEditable ? 1 : 0.5)
                    .accessibilityIdentifier("mcp-form-slug")
            }
            .padding(.vertical, 2)
        } footer: {
            if let slugError {
                Text(slugError).foregroundStyle(Theme.danger).accessibilityIdentifier("mcp-form-slug-error")
            } else {
                Text("\(baseUrl)/mcp/\(draft.slug.isEmpty ? String(localized: .settingsMcpControlsSlugPlaceholder) : draft.slug)").font(.caption.monospaced())
            }
        }
    }

    // MARK: 工具形态

    private var modeSection: some View {
        SettingsFormSection {
            Picker(String(localized: .settingsMcpControlsMode), selection: $draft.expandTools) {
                Text(String(localized: .commonExpand)).tag(true)
                Text(String(localized: .settingsMcpControlsCollapsed)).tag(false)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("mcp-form-mode")
            LabeledContent(String(localized: .settingsMcpFormToolCount), value: String(localized: .settingsMcpControlsCountUnit(toolCount)))
            LabeledContent(String(localized: .settingsMcpFormDefinitionSize), value: SettingsBMCPFormat.bytes(bytes))
        } header: { Text(String(localized: .settingsMcpControlsTools)) } footer: {
            Text(draft.expandTools
                 ? String(localized: .settingsMcpFormExpandedHint)
                 : String(localized: .settingsMcpFormCollapsedHint))
        }
    }

    // MARK: 服务选择器

    private var servicesSection: some View {
        SettingsFormSection {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint)
                TextField(String(localized: .settingsMcpControlsSearchServices), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mcp-form-service-search")
                if !draft.services.isEmpty {
                    Button(String(localized: .commonClear)) { draft.services = [] }
                        .font(.caption)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("mcp-form-service-clear")
                }
            }
            ForEach(visible, id: \.domain) { service in
                let on = picked.contains(service.domain)
                Button {
                    if on {
                        draft.services.removeAll { $0 == service.domain }
                    } else {
                        draft.services.append(service.domain)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .foregroundStyle(on ? Theme.accentStrong : Theme.textFaint)
                            .padding(.top, 1)
                        // 两行：域名与说明各一行。说明是判断该不该勾的依据，不能截断
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(service.domain).font(.subheadline.monospaced()).foregroundStyle(Theme.text)
                                Text(String(localized: .settingsMcpControlsCommandsCount(service.commandCount))).font(.caption.monospacedDigit()).foregroundStyle(Theme.textFaint)
                            }
                            Text(service.description)
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .settingsRowBackground(on ? Theme.accentSoft : nil)
                .accessibilityIdentifier("mcp-form-service-\(service.domain)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        } header: {
            Text(String(localized: .settingsMcpControlsSelectedServices(String(chosen.count), String(services.count))))
        } footer: {
            Text(String(localized: .settingsMcpFormRiskHint))
        }
    }

    // MARK: 实时后果

    private var previewSection: some View {
        SettingsFormSection(String(localized: .settingsMcpControlsClientSees)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(toolCount)").font(.title.weight(.medium).monospacedDigit())
                    Text(String(localized: .settingsMcpFormToolsUnit)).foregroundStyle(Theme.textMuted)
                }
                Text(String(localized: .settingsMcpFormSummary(chosen.count, commandTotal, SettingsBMCPFormat.bytes(bytes))))
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mcp-form-totals")
            // 任务挂在具体行上而不是 Section：List 会把 Section 上的修饰符分发到每一行，变成多份任务
            .task(id: SettingsBMCPPreviewKey(services: draft.services, expand: draft.expandTools)) {
                await loadPreview()
            }

            if draft.expandTools && toolCount > Self.toolHintThreshold {
                SettingsBNotice(
                    text: String(localized: .settingsMcpFormTooMany(Self.toolHintThreshold, chosen.count, SettingsBMCPFormat.bytes(collapsedBytes))),
                    tone: .warn
                )
            }

            if let preview {
                if preview.isEmpty {
                    Text(String(localized: .settingsMcpControlsPreviewEmpty)).font(.caption).foregroundStyle(Theme.textFaint)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preview.prefix(60), id: \.name) { tool in
                            Text(tool.name)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if preview.count > 60 {
                            Text(String(localized: .settingsMcpControlsMoreTools(String(preview.count - 60)))).font(.caption).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
            } else {
                Text(String(localized: .settingsMcpControlsCalculatingNow)).font(.caption).foregroundStyle(Theme.textFaint)
            }
        }
    }

    /// 服务或模式一变就重算（请求很轻，纯内存渲染；`.task(id:)` 自动取消上一轮）
    private func loadPreview() async {
        if draft.services.isEmpty {
            preview = []
            return
        }
        preview = nil
        if let result = try? await api.mcpEndpointsPreview(body: .init(services: draft.services, expandTools: draft.expandTools)) {
            preview = result.tools
        }
    }
}

// MARK: - 新建端点弹层

/// 新建端点：原生玻璃表单，右上角确认创建。
/// 创建成功后弹层原地换成令牌专屏（令牌明文只在这一次响应里），确认保存后关闭并交给列表页推入详情。
struct SettingsBMCPCreateSheet: View {
    let store: SettingsBMCPStore
    /// 用户在令牌专屏点「我已保存」后回调端点 id，由列表页推入详情
    let onFinished: (String) -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SettingsBMCPDraft()
    @State private var issued: API.EndpointCreatedView?
    @State private var discarding = false

    private var takenSlugs: [String] { store.status?.endpoints.map(\.slug) ?? [] }

    private var canSubmit: Bool {
        !store.busy
            && draft.valid
            && !draft.slug.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.services.isEmpty
            && SettingsBMCPEndpointFields.slugError(draft.slug, editable: true, taken: takenSlugs) == nil
    }

    var body: some View {
        if let issued {
            SettingsBMCPTokenIssuedView(
                name: issued.endpoint.name,
                url: store.fullURL(issued.endpoint),
                token: issued.token
            ) {
                onFinished(issued.endpoint.id)
                dismiss()
            }
        } else {
            form
        }
    }

    private var form: some View {
        SubsSheetScaffold(title: String(localized: .settingsMcpControlsCreate), onClose: {
            if draft != SettingsBMCPDraft() { discarding = true } else { dismiss() }
        }, confirm: SubsSheetConfirm(title: String(localized: .settingsMcpControlsCreate), enabled: canSubmit,
                                     busy: store.busy, identifier: "mcp-form-submit") {
            Task { await submit() }
        }) {
            if let error = store.error {
                SettingsFormSection { SettingsBNotice(text: error, tone: .danger).accessibilityIdentifier("mcp-error") }
            }
            SettingsBMCPEndpointFields(draft: $draft, services: store.status?.services ?? [],
                                      baseUrl: store.status?.baseUrl ?? "", slugEditable: true, takenSlugs: takenSlugs)
        }
        .disabled(store.busy)
        .interactiveDismissDisabled(store.busy || draft != SettingsBMCPDraft())
        .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
        }
    }

    private func submit() async {
        let body = API.EndpointCreateRequest(
            name: draft.name.trimmingCharacters(in: .whitespaces),
            slug: draft.slug.trimmingCharacters(in: .whitespaces),
            services: draft.services,
            description: nil,
            expandTools: draft.expandTools,
            timeoutSeconds: draft.timeoutSeconds
        )
        if let created = await store.run(api, { try await api.mcpEndpointsCreate(body: body) }) {
            issued = created
        }
    }
}
