import SwiftUI

enum MemberEditSection: String, Identifiable {
    case profile, permissions, content, libraries, sites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: String(localized: .settingsMembersUiBasic)
        case .permissions: String(localized: .settingsMembersUiPermissions)
        case .content: String(localized: .settingsMembersAccessContentRating)
        case .libraries: String(localized: .settingsMembersUiLibraries)
        case .sites: String(localized: .settingsMembersAccessSearchableSites)
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
                                    prompt: section == .libraries ? String(localized: .libraryManageSearch) : String(localized: .searchPreferencesSites))
                } else { form }
            }
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: .commonCancel)) {
                        if draft != member { discarding = true } else { dismiss() }
                    }.disabled(busy).accessibilityIdentifier("sheet-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() }
                    else {
                        Button(String(localized: .commonSave)) { Task { await save() } }
                            .disabled(loading || loadError != nil || draft == member)
                            .accessibilityIdentifier("member-edit-save")
                    }
                }
            }
            .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
                Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
                Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
            }
        }
        .adaptiveDetents(typeSize.isAccessibilitySize ? [.large] : [section.compactHeight, .large])
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
                    Button(String(localized: .commonRetry)) { Task { await loadOptions() } }
                }
            } else {
                switch section {
                case .profile:
                    SettingsFormSection {
                        LabeledContent(String(localized: .settingsMembersCredentialsUsername), value: member.username)
                        TextField(String(localized: .settingsProfileNickname), text: $draft.nickname)
                            .accessibilityIdentifier("member-edit-nickname")
                    } footer: { Text(String(localized: .settingsMemberEditNameHint)) }
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
                Toggle(String(localized: .settingsMembersAccessSubscribe), isOn: $draft.allowSubscribe).accessibilityIdentifier("member-allow-subscribe")
            } footer: { Text(String(localized: .settingsMemberEditSubscribeHint)) }
            SettingsFormSection {
                Toggle(String(localized: .settingsMembersUiSearch), isOn: $draft.allowSearch)
                    .onChange(of: draft.allowSearch) { _, enabled in if !enabled { draft.allowDirectDownload = false } }
                    .accessibilityIdentifier("member-allow-search")
                Toggle(String(localized: .settingsMembersAccessDirectDownload), isOn: $draft.allowDirectDownload)
                    .disabled(!draft.allowSearch).accessibilityIdentifier("member-allow-download")
            } footer: {
                Text(String(localized: .settingsMemberEditSearchHint))
            }
        }
    }

    private var contentFields: some View {
        Group {
            SettingsFormSection {
                Picker(String(localized: .settingsMemberEditAgeLimit), selection: $draft.contentAgeLimit) {
                    Text(String(localized: .settingsMembersAccessUnlimited)).tag(Int?.none)
                    ForEach([6, 12, 16, 18], id: \.self) { Text(String(localized: .settingsMembersAccessUnderAge($0))).tag(Optional($0)) }
                }.pickerStyle(.menu).accessibilityIdentifier("member-age-limit")
            } footer: { Text(String(localized: .settingsMemberEditAgeHint)) }
            if draft.contentAgeLimit != nil {
                SettingsFormSection {
                    Toggle(String(localized: .settingsMemberEditAllowUnrated), isOn: $draft.allowUnrated)
                        .accessibilityIdentifier("member-allow-unrated")
                } footer: { Text(String(localized: .settingsMemberEditUnratedHint)) }
            }
        }
    }

    private var libraryFields: some View {
        Group {
            SettingsFormSection {
                Picker(String(localized: .settingsMemberEditScope), selection: $draft.allLibraries) {
                    Text(String(localized: .settingsMembersAccessShared)).tag(true)
                    Text(String(localized: .settingsMembersAccessSelectedLibraries)).tag(false)
                }.pickerStyle(.menu).accessibilityIdentifier("member-library-mode")
            } footer: { Text(String(localized: .settingsMemberEditLibrariesHint)) }
            let available = libraries.filter { !draft.allLibraries || $0.accessMode == "selected" }
            let matches = available.filter { matchesSearch($0.name) }
            SettingsFormSection(draft.allLibraries ? String(localized: .settingsMemberEditIndividual) : String(localized: .settingsMemberEditChooseLibraries)) {
                ForEach(matches, id: \.id) { library in
                    selectionRow(library.name, selected: draft.libraryIds.contains(library.id)) {
                        if draft.libraryIds.contains(library.id) { draft.libraryIds.removeAll { $0 == library.id } }
                        else { draft.libraryIds.append(library.id) }
                    }.accessibilityIdentifier("member-library-\(library.id)")
                }
                if matches.isEmpty { emptyOptions(available.isEmpty ? String(localized: .settingsMemberEditNoLibraries) : String(localized: .settingsMemberEditNoLibraryMatches)) }
            }
        }
    }

    private var siteFields: some View {
        Group {
            SettingsFormSection {
                Picker(String(localized: .settingsMemberEditScope), selection: $draft.allSites) {
                    Text(String(localized: .settingsMembersAccessAllSites)).tag(true)
                    Text(String(localized: .settingsMembersAccessSelectedSites)).tag(false)
                }.pickerStyle(.menu).accessibilityIdentifier("member-site-mode")
            } footer: { Text(String(localized: .settingsMemberEditSitesHint)) }
            if !draft.allSites {
                let matches = sites.filter { matchesSearch($0.displayName) }
                SettingsFormSection(String(localized: .settingsMemberEditChooseSites)) {
                    ForEach(matches, id: \.siteId) { site in
                        selectionRow(site.displayName, selected: draft.siteIds.contains(site.siteId)) {
                            if draft.siteIds.contains(site.siteId) { draft.siteIds.removeAll { $0 == site.siteId } }
                            else { draft.siteIds.append(site.siteId) }
                        }.accessibilityIdentifier("member-site-\(site.siteId)")
                    }
                    if matches.isEmpty { emptyOptions(sites.isEmpty ? String(localized: .settingsMemberEditNoSites) : String(localized: .settingsMemberEditNoSiteMatches)) }
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
        .accessibilityValue(selected ? String(localized: .settingsMemberEditSelected) : String(localized: .commonNotSelected))
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
