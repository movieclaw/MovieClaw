import SwiftUI

enum MemberEditSection: String, Identifiable {
    case profile, permissions, content, libraries, sites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: "基本信息"
        case .permissions: "功能权限"
        case .content: "内容分级"
        case .libraries: "媒体库范围"
        case .sites: "可搜索站点"
        }
    }

    var compactHeight: PresentationDetent {
        switch self {
        case .profile: .height(300)
        case .permissions: .height(400)
        case .content: .height(360)
        case .libraries, .sites: .medium
        }
    }

    /// 只提交当前编辑的分区，避免覆盖其他权限或未成功加载的授权范围。
    func update(_ draft: API.MemberView, libraries: [API.LibraryView]) -> API.MemberUpdateRequest {
        var body = API.MemberUpdateRequest()
        switch self {
        case .profile: body.nickname = draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        case .permissions:
            body.allowSubscribe = draft.allowSubscribe
            body.allowSearch = draft.allowSearch
            body.allowDirectDownload = draft.allowSearch && draft.allowDirectDownload
        case .content:
            body.contentAgeLimit = draft.contentAgeLimit ?? -1
            body.allowUnrated = draft.allowUnrated
        case .libraries:
            body.allLibraries = draft.allLibraries
            body.libraryIds = draft.allLibraries ? draft.libraryIds.filter { id in
                libraries.first { $0.id == id }?.accessMode != "everyone"
            } : draft.libraryIds
        case .sites:
            body.allSites = draft.allSites
            body.siteIds = draft.allSites ? [] : draft.siteIds
        }
        return body
    }
}

struct MemberEditSheet: View {
    let member: API.MemberView
    let section: MemberEditSection
    let onSaved: (API.MemberView) -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var draft: API.MemberView
    @State private var libraries: [API.LibraryView] = []
    @State private var sites: [API.CatalogItem] = []
    @State private var loading: Bool
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var busy = false
    @State private var search = ""
    @State private var discarding = false

    init(member: API.MemberView, section: MemberEditSection, onSaved: @escaping (API.MemberView) -> Void) {
        self.member = member
        self.section = section
        self.onSaved = onSaved
        _draft = State(initialValue: member)
        _loading = State(initialValue: section == .libraries || section == .sites)
    }

    var body: some View {
        NavigationStack {
            Group {
                if section == .libraries || section == .sites {
                    form.searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                                    prompt: section == .libraries ? "搜索媒体库" : "搜索站点")
                } else { form }
            }
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if draft != member { discarding = true } else { dismiss() }
                    }.disabled(busy).accessibilityIdentifier("sheet-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() }
                    else {
                        Button("保存") { Task { await save() } }
                            .disabled(loading || loadError != nil || draft == member)
                            .accessibilityIdentifier("member-edit-save")
                    }
                }
            }
            .alert("放弃未保存的修改？", isPresented: $discarding) {
                Button("继续编辑", role: .cancel) { }
                Button("放弃修改", role: .destructive) { dismiss() }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [section.compactHeight, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .interactiveDismissDisabled(busy || draft != member)
        .task { await loadOptions() }
    }

    private var form: some View {
        Form {
            if let saveError { SettingsFormSection { Text(saveError).foregroundStyle(Theme.danger) } }
            if loading { SettingsLoadingRow() }
            else if let loadError {
                SettingsFormSection {
                    Text(loadError).foregroundStyle(.secondary)
                    Button("重试") { Task { await loadOptions() } }
                }
            } else {
                switch section {
                case .profile:
                    SettingsFormSection {
                        LabeledContent("用户名", value: member.username)
                        TextField("昵称", text: $draft.nickname)
                            .accessibilityIdentifier("member-edit-nickname")
                    } footer: { Text("用户名用于登录，创建后不能修改。昵称是其他页面显示的名称。") }
                case .permissions: permissionFields
                case .content: contentFields
                case .libraries: libraryFields
                case .sites: siteFields
                }
            }
        }
        .subsFormStyle()
        .scrollDismissesKeyboard(.interactively)
        .disabled(busy)
    }

    private var permissionFields: some View {
        Group {
            SettingsFormSection {
                Toggle("订阅追踪", isOn: $draft.allowSubscribe).accessibilityIdentifier("member-allow-subscribe")
            } footer: { Text("可以发起订阅并管理自己的订阅。") }
            SettingsFormSection {
                Toggle("资源搜索", isOn: $draft.allowSearch)
                    .onChange(of: draft.allowSearch) { _, enabled in if !enabled { draft.allowDirectDownload = false } }
                    .accessibilityIdentifier("member-allow-search")
                Toggle("一键下载", isOn: $draft.allowDirectDownload)
                    .disabled(!draft.allowSearch).accessibilityIdentifier("member-allow-download")
            } footer: {
                Text("资源搜索用于查找已授权站点的种子，不影响影视和媒体库搜索。一键下载需要开启资源搜索。")
            }
        }
    }

    private var contentFields: some View {
        Group {
            SettingsFormSection {
                Picker("年龄上限", selection: $draft.contentAgeLimit) {
                    Text("不限").tag(Int?.none)
                    ForEach([6, 12, 16, 18], id: \.self) { Text("\($0) 岁以下").tag(Optional($0)) }
                }.pickerStyle(.menu).accessibilityIdentifier("member-age-limit")
            } footer: { Text("超过所选年龄分级的作品将从浏览、搜索和播放中隐藏。") }
            if draft.contentAgeLimit != nil {
                SettingsFormSection {
                    Toggle("允许未分级作品", isOn: $draft.allowUnrated)
                        .accessibilityIdentifier("member-allow-unrated")
                } footer: { Text("部分作品没有年龄分级。关闭时，这些作品也会隐藏。") }
            }
        }
    }

    private var libraryFields: some View {
        Group {
            SettingsFormSection {
                Picker("访问范围", selection: $draft.allLibraries) {
                    Text("全部共享库").tag(true)
                    Text("指定媒体库").tag(false)
                }.pickerStyle(.menu).accessibilityIdentifier("member-library-mode")
            } footer: { Text("全部共享库包含以后新增的共享库。仅对指定成员开放的库，始终需要单独授权。") }
            let available = libraries.filter { !draft.allLibraries || $0.accessMode == "selected" }
            let matches = available.filter { matchesSearch($0.name) }
            SettingsFormSection(draft.allLibraries ? "单独授权" : "选择媒体库") {
                ForEach(matches, id: \.id) { library in
                    selectionRow(library.name, selected: draft.libraryIds.contains(library.id)) {
                        if draft.libraryIds.contains(library.id) { draft.libraryIds.removeAll { $0 == library.id } }
                        else { draft.libraryIds.append(library.id) }
                    }.accessibilityIdentifier("member-library-\(library.id)")
                }
                if matches.isEmpty { emptyOptions(available.isEmpty ? "暂无可选媒体库" : "没有匹配的媒体库") }
            }
        }
    }

    private var siteFields: some View {
        Group {
            SettingsFormSection {
                Picker("访问范围", selection: $draft.allSites) {
                    Text("全部启用站点").tag(true)
                    Text("指定站点").tag(false)
                }.pickerStyle(.menu).accessibilityIdentifier("member-site-mode")
            } footer: { Text("成员只能搜索允许访问的站点。一键下载仍由功能权限控制。") }
            if !draft.allSites {
                let matches = sites.filter { matchesSearch($0.displayName) }
                SettingsFormSection("选择站点") {
                    ForEach(matches, id: \.siteId) { site in
                        selectionRow(site.displayName, selected: draft.siteIds.contains(site.siteId)) {
                            if draft.siteIds.contains(site.siteId) { draft.siteIds.removeAll { $0 == site.siteId } }
                            else { draft.siteIds.append(site.siteId) }
                        }.accessibilityIdentifier("member-site-\(site.siteId)")
                    }
                    if matches.isEmpty { emptyOptions(sites.isEmpty ? "暂无可选站点" : "没有匹配的站点") }
                }
            }
        }
    }

    private func matchesSearch(_ name: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedStandardContains(query)
    }

    private func emptyOptions(_ title: String) -> some View {
        Text(title).foregroundStyle(.secondary)
    }

    private func selectionRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.textMuted)
            }
        }
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func loadOptions() async {
        guard section == .libraries || section == .sites else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            if section == .libraries { libraries = try await api.libraryList(scope: "all") }
            else { sites = try await api.siteCatalog() }
        } catch { loadError = error.localizedDescription }
    }

    private func save() async {
        guard !busy, !loading, loadError == nil else { return }
        busy = true
        saveError = nil
        defer { busy = false }
        do { onSaved(try await api.membersUpdate(memberId: member.id, body: section.update(draft, libraries: libraries))) }
        catch { saveError = error.localizedDescription }
    }
}
