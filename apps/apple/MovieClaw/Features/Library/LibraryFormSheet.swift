import SwiftUI

/// 媒体库表单（Web `library-form-dialog.tsx` 的 LibraryFormDialog）：`libraryId` 为 nil 走新建向导，否则编辑该库。以 .sheet 呈现。
///
/// 新建极简（向导）：只问必答题——① 选类型 → ② 名称、根目录、可见范围 → ③（影视库）收藏范围；
/// 扫描开关全按推荐值、刮削偏好覆盖是少数人的精调，都放到编辑里。最后一步「创建并开始扫描」。
///
/// 编辑分层：按用途分区折叠（基本信息 / 封面 / 扫描与监控 / 收藏范围 / 刮削设置 / 可见范围），默认全收起、
/// 同时只开一个；折叠态的摘要行先回答「这个库配成了什么样」，改哪项点哪项。封面上传即生效，不进保存的 payload。
/// 类型创建后不可改，只读展示。
struct LibraryFormSheet: View {
    var libraryId: Int?
    /// 保存成功回调，带上服务端返回的库
    var onSaved: (API.LibraryView) -> Void = { _ in }

    var body: some View {
        if let libraryId {
            ManageEditLibraryForm(libraryId: libraryId, onSaved: onSaved)
        } else {
            ManageCreateLibraryForm(onSaved: onSaved)
        }
    }
}

/// 类型卡片的文案：讲清后果，不提识别用的是哪个数据源（同 Web `KIND_CARDS`）
enum ManageKindCard {
    static func symbol(_ kind: String) -> String { LibraryKindMeta.symbol(kind) }

    static func blurb(_ kind: String) -> String {
        switch kind {
        case "movie": String(localized: .libraryFormMovieBlurb)
        case "tv": String(localized: .libraryFormTvBlurb)
        case "video": String(localized: .libraryFormVideoBlurb)
        default: String(localized: .libraryFormPhotoBlurb)
        }
    }

    static func traits(_ kind: String) -> String {
        switch kind {
        case "movie", "tv": String(localized: .libraryFormMovieTraits)
        case "video": String(localized: .libraryFormVideoTraits)
        default: String(localized: .libraryFormPhotoTraits)
        }
    }

    static func chosen(_ kind: String) -> String {
        switch kind {
        case "movie": String(localized: .libraryFormMovieChosen)
        case "tv": String(localized: .libraryFormTvChosen)
        case "video": String(localized: .libraryFormVideoChosen)
        default: String(localized: .libraryFormPhotoChosen)
        }
    }

    static func defaultName(_ kind: String) -> String {
        switch kind {
        case "movie": String(localized: .libraryFormMovieDefaultName)
        case "tv": String(localized: .libraryFormTvDefaultName)
        case "video": String(localized: .libraryKindOther)
        default: String(localized: .libraryFormPhotoDefaultName)
        }
    }

    static func defaults(_ kind: String) -> String {
        switch kind {
        case "movie":
            String(localized: .libraryFormMovieDefaults)
        case "tv":
            String(localized: .libraryFormTvDefaults)
        case "video":
            String(localized: .libraryFormVideoDefaults)
        default:
            String(localized: .libraryFormPhotoDefaults)
        }
    }

    /// 新建时的类型是否带识别链（决定有没有收藏范围这一步）
    static func isScraped(_ kind: String) -> Bool { kind != "video" && kind != "photo" }
}

// MARK: - 新建向导

struct ManageCreateLibraryForm: View {
    let onSaved: (API.LibraryView) -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1
    @State private var kind: String?
    @State private var name = ""
    @State private var roots: [String] = []
    @State private var regions: [String] = []
    @State private var genres: [Int] = []
    @State private var accessMode = "everyone"
    @State private var adminVisible = true
    @State private var memberIds: [Int] = []
    @State private var busy = false
    @State private var error: String?
    @State private var options: ManageRoutingOptions?

    private var hasScope: Bool { kind.map(ManageKindCard.isScraped) ?? false }
    private var totalSteps: Int { hasScope ? 3 : 2 }
    private var ready: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !roots.isEmpty }
    private var scope: (declared: Bool, text: String)? {
        kind.map { ManageMatchRules.summary(kind: $0, regions: regions, genres: genres, options: options) }
    }

    var body: some View {
        NavigationStack {
            Form {
                stepHeader
                switch step {
                case 1: kindStep
                case 2: basicsStep
                default: scopeStep
                }
                if let error {
                    Section {
                        Text(error).font(.subheadline).foregroundStyle(Theme.danger)
                    }
                }
                Section {
                    // 主按钮随步骤变化：第 2 步对影视库是「下一步」，最后一步保存即扫描
                    Button {
                        primaryAction()
                    } label: {
                        Text(primaryLabel)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .discoverProminentButton()
                    .disabled(primaryDisabled)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("form-primary")
                } footer: {
                    Text(String(localized: .libraryFormStepProgress(step, totalSteps)) + (step == totalSteps ? String(localized: .libraryFormScanOnSaveSuffix) : ""))
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(String(localized: .libraryFormAddTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == 1 {
                        Button(String(localized: .commonCancel)) { dismiss() }.accessibilityIdentifier("form-cancel")
                    } else {
                        Button(String(localized: .libraryFormPreviousStep)) { step = step == 3 ? 2 : 1 }.accessibilityIdentifier("form-back")
                    }
                }
            }
        }
        .presentationBackground(.regularMaterial)
        .task { options = await ManageRoutingOptions.load(api) }
    }

    /// 步骤条：影视库三步，其他 / 图片库两步
    private var stepHeader: some View {
        Section {
            HStack(spacing: 18) {
                ForEach([(1, String(localized: .libraryFormStepType)), (2, String(localized: .libraryFormStepFolders)), (3, String(localized: .libraryFormStepScope))].filter { $0.0 != 3 || hasScope }, id: \.0) { n, label in
                    VStack(spacing: 6) {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(step == n ? .white : Theme.textFaint)
                        Capsule().fill(step == n ? Theme.accent : .clear).frame(height: 2)
                    }
                    .fixedSize()
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: 步骤

    @ViewBuilder
    private var kindStep: some View {
        Section {
            ForEach(ManageKind.all, id: \.self) { k in
                Button {
                    choose(k)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: ManageKindCard.symbol(k)).foregroundStyle(Theme.accent)
                            Text(ManageKind.label(k)).font(.body.weight(.semibold)).foregroundStyle(.white)
                            Spacer()
                            if kind == k { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                        Text(ManageKindCard.blurb(k)).font(.caption).foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(ManageKindCard.traits(k)).font(.caption2).foregroundStyle(Theme.textFaint)
                    }
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("form-kind-\(k)")
            }
        } footer: {
            Text(String(localized: .libraryFormTypeHint))
        }
    }

    @ViewBuilder
    private var basicsStep: some View {
        if let kind {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: ManageKindCard.symbol(kind)).foregroundStyle(Theme.accent)
                    Text(ManageKind.label(kind)).font(.body.weight(.semibold))
                    Text(ManageKindCard.chosen(kind)).font(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(String(localized: .libraryFormChangeType)) { step = 1 }.font(.caption).buttonStyle(.borderless)
                }
            }
            Section(String(localized: .libraryFormName)) {
                TextField(String(localized: .libraryFormNamePlaceholder), text: $name)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    // 回车执行主按钮（同 Web；输入法选词的回车由系统消化，不会走到 onSubmit）
                    .onSubmit { if !primaryDisabled { primaryAction() } }
                    .accessibilityIdentifier("form-name")
            }
            Section {
                ManageRootsEditor(roots: $roots)
            } header: {
                Text(String(localized: .libraryFormRoots))
            } footer: {
                Text(String(localized: .libraryFormPrimaryRootNote))
            }
            Section(String(localized: .libraryFormAccessScope)) {
                ManageAccessEditor(mode: $accessMode, adminVisible: $adminVisible, memberIds: $memberIds)
            }
            Section {
                Label {
                    (Text(String(localized: .libraryFormDefaultsIntro)).foregroundStyle(Theme.text).fontWeight(.medium) + Text(ManageKindCard.defaults(kind)))
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(Theme.info)
                }
            }
        }
    }

    @ViewBuilder
    private var scopeStep: some View {
        if let kind {
            Section {
                (Text(String(localized: .libraryFormScopeLead)) + Text(String(localized: .libraryFormScopeEmphasis)).foregroundStyle(Theme.text).fontWeight(.medium)
                + Text(String(localized: .libraryFormScopeTail)))
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                ManageScopeEditor(kind: kind, regions: $regions, genres: $genres, options: options)
            } footer: {
                if let scope {
                    Text(scope.declared ? String(localized: .libraryFormScopeCurrent(scope.text)) : String(localized: .libraryFormScopeFallback))
                }
            }
        }
    }

    // MARK: 动作

    /// 名称按类型预填；用户已经改过的名字不动
    private func choose(_ next: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let untouched = trimmed.isEmpty || (kind.map { name == ManageKindCard.defaultName($0) } ?? false)
        kind = next
        if untouched { name = ManageKindCard.defaultName(next) }
        if !ManageKindCard.isScraped(next) {
            regions = []
            genres = []
        }
        step = 2
    }

    private var primaryLabel: String {
        if step == 1 { return String(localized: .libraryFormCreateAndScan) }
        if step == 2, hasScope { return String(localized: .libraryFormNextScope) }
        if busy { return String(localized: .libraryFormCreating) }
        if step == 3, let scope, !scope.declared { return String(localized: .libraryFormSkipAndCreate) }
        return String(localized: .libraryFormCreateAndScan)
    }

    private var primaryDisabled: Bool {
        if step == 1 { return true }
        if step == 2, hasScope { return !ready }
        return !ready || busy
    }

    private func primaryAction() {
        if step == 2, hasScope {
            step = 3
        } else {
            Task { await submit() }
        }
    }

    private func submit() async {
        guard let kind, ready, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        // 开关全按推荐值：监控开、自动清理关、封面开、章节开、首页展示（图片库默认不上首页）；建好后在编辑里调
        let payload = API.LibraryPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            generateThumbnails: true,
            extractChapterImages: true,
            excludeFromHome: kind == "photo",
            accessMode: accessMode,
            adminVisible: adminVisible,
            memberIds: accessMode == "selected" ? memberIds : [],
            rootPaths: roots,
            matchRules: hasScope ? ManageMatchRules.build(
                genres: ManageMatchRules.validGenres(kind: kind, genres: genres, options: options), regions: regions
            ) : [],
            autoClearMissing: false,
            scrapeOverrides: [:],
            realtimeWatch: true
        )
        do {
            let saved = try await api.libraryCreate(body: payload)
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 编辑

struct ManageEditLibraryForm: View {
    let libraryId: Int
    let onSaved: (API.LibraryView) -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var state: Loadable<API.LibraryView> = .loading

    var body: some View {
        NavigationStack {
            AsyncContent(state, retry: load) { library in
                ManageEditLibraryBody(library: library, onSaved: onSaved)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if state.value == nil {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: .commonCancel)) { dismiss() } }
                }
            }
        }
        .presentationBackground(.regularMaterial)
        .task { await load() }
    }

    private func load() async {
        await Loadable.load(into: $state) { try await api.libraryGet(libraryId: libraryId) }
    }
}

/// 编辑表单本体：草稿以库的当前配置起步
private struct ManageEditLibraryBody: View {
    let library: API.LibraryView
    let onSaved: (API.LibraryView) -> Void

    enum SectionId: String { case basic, cover, scan, scope, scrape, access }

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var roots: [String]
    @State private var realtimeWatch: Bool
    @State private var autoClearMissing: Bool
    @State private var generateThumbnails: Bool
    @State private var extractChapterImages: Bool
    @State private var excludeFromHome: Bool
    @State private var autoSeriesCollections: Bool
    @State private var accessMode: String
    @State private var adminVisible: Bool
    @State private var memberIds: [Int]
    @State private var regions: [String]
    @State private var genres: [Int]
    @State private var scrapeOverrides: [String: API.JSONValue]
    @State private var customCover: Bool
    /// 展开的分区（同时只开一个）；默认全收起——摘要行已经把现状说清
    @State private var open: SectionId?
    @State private var busy = false
    @State private var error: String?
    @State private var options: ManageRoutingOptions?

    init(library: API.LibraryView, onSaved: @escaping (API.LibraryView) -> Void) {
        self.library = library
        self.onSaved = onSaved
        let parsed = ManageMatchRules.parse(library.matchRules)
        _name = State(initialValue: library.name)
        _roots = State(initialValue: library.rootPaths)
        _realtimeWatch = State(initialValue: library.realtimeWatch)
        _autoClearMissing = State(initialValue: library.autoClearMissing)
        _generateThumbnails = State(initialValue: library.generateThumbnails)
        _extractChapterImages = State(initialValue: library.extractChapterImages)
        _excludeFromHome = State(initialValue: library.excludeFromHome)
        _autoSeriesCollections = State(initialValue: library.autoSeriesCollections)
        _accessMode = State(initialValue: library.accessMode)
        _adminVisible = State(initialValue: library.adminVisible)
        _memberIds = State(initialValue: library.memberIds)
        _regions = State(initialValue: parsed.regions)
        _genres = State(initialValue: parsed.genres)
        _scrapeOverrides = State(initialValue: library.scrapeOverrides)
        _customCover = State(initialValue: library.customCover)
    }

    private var scraped: Bool { library.capabilities.scraped }
    /// 图片库：条目只看不播，缩略图从原图缩放而来（不是抓帧），开关文案随之换
    private var playable: Bool { library.capabilities.playable }
    private var ready: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !roots.isEmpty }
    private var missingFields: [String] {
        [name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: .libraryFormName) : nil, roots.isEmpty ? String(localized: .libraryFormRoots) : nil].compactMap { $0 }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Image(systemName: ManageKindCard.symbol(library.kind)).foregroundStyle(Theme.accent)
                    Text(ManageKind.label(library.kind))
                }
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.white.opacity(0.04), in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.line))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
            }

            section(.basic, title: String(localized: .libraryFormBasic)) {
                HStack(spacing: 8) {
                    Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: .libraryFormUnnamed) : name).foregroundStyle(Theme.text)
                    Text(roots.first ?? String(localized: .libraryFormNoRoot)).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                    if roots.count > 1 { Text(String(localized: .libraryFormRootCount(roots.count))).fixedSize() }
                }
            } content: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: .libraryFormName)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textMuted)
                    TextField(String(localized: .libraryFormName), text: $name).autocorrectionDisabled().accessibilityIdentifier("form-name")
                }
                Text(String(localized: .libraryFormRootsTitle)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textMuted)
                ManageRootsEditor(roots: $roots)
            }

            section(.cover, title: String(localized: .libraryFormCover)) {
                Text(customCover ? String(localized: .libraryFormCustomCover) : String(localized: .libraryFormAutoCover))
            } content: {
                ManageCoverEditor(libraryId: library.id, custom: $customCover)
            }

            section(.scan, title: String(localized: .libraryFormScanning)) {
                ManageFlow(spacing: 10, lineSpacing: 4) {
                    dot(realtimeWatch, String(localized: .libraryFormMonitoring))
                    dot(autoClearMissing, String(localized: .libraryFormAutoClearMissing))
                    dot(generateThumbnails, scraped ? String(localized: .libraryFormFillMissingImages) : playable ? String(localized: .libraryFormFrameCovers) : String(localized: .libraryFormThumbnails))
                    if playable { dot(extractChapterImages, String(localized: .libraryFormChapters)) }
                    dot(!excludeFromHome, String(localized: .libraryFormHomeDisplay))
                    if library.kind != "photo" { dot(autoSeriesCollections, String(localized: .libraryFormSeriesCollections)) }
                }
            } content: {
                scanSwitches
            }

            if scraped {
                section(.scope, title: String(localized: .libraryFormScope)) {
                    let scope = ManageMatchRules.summary(kind: library.kind, regions: regions, genres: genres, options: options)
                    Text(scope.declared ? scope.text : String(localized: .libraryFormUnsetScopeHint))
                        .foregroundStyle(scope.declared ? Theme.text : Theme.textFaint)
                } content: {
                    Text(String(localized: .libraryFormScopeEditHint))
                        .font(.caption).foregroundStyle(Theme.textFaint)
                    ManageScopeEditor(kind: library.kind, regions: $regions, genres: $genres, options: options)
                }

                section(.scrape, title: String(localized: .libraryFormMetadataSettings)) {
                    if let text = scrapeSummary {
                        Text(text).foregroundStyle(Theme.text)
                    } else {
                        Text(String(localized: .libraryFormFollowGlobal)).foregroundStyle(Theme.textFaint)
                    }
                } content: {
                    ManageScrapeOverrides(overrides: $scrapeOverrides)
                }
            }

            // 可见范围放最后：它决定的是「谁能看」，与库怎么扫、收什么无关
            section(.access, title: String(localized: .libraryFormAccessScope)) {
                Text(ManageAccessEditor.summary(mode: accessMode, adminVisible: adminVisible, memberCount: memberIds.count))
                    .foregroundStyle(accessMode == "everyone" ? Theme.text : Theme.warning)
            } content: {
                ManageAccessEditor(mode: $accessMode, adminVisible: $adminVisible, memberIds: $memberIds)
            }

            if let error {
                Section {
                    Text(error).font(.subheadline).foregroundStyle(Theme.danger)
                }
            }
            Section {
            } footer: {
                Text(missingFields.isEmpty ? String(localized: .libraryFormTypeFixed) : String(localized: .libraryFormStillMissing(AppFormatting.list(missingFields))))
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(String(localized: .libraryFormEditTitle(library.name)))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: .commonCancel)) { dismiss() }.accessibilityIdentifier("form-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? String(localized: .libraryCollectionsSaving) : String(localized: .commonSave)) { Task { await submit() } }
                    .disabled(!ready || busy)
                    .accessibilityIdentifier("form-save")
            }
        }
        .task { options = await ManageRoutingOptions.load(api) }
    }

    // MARK: 分区

    /// 一个折叠分区：头行是「标题 + 摘要 + 箭头」，展开后内容行接在同一个 Section 里
    @ViewBuilder
    private func section<Summary: View, Content: View>(
        _ id: SectionId, title: String,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = open == id
        Section {
            Button {
                withAnimation(.snappy) { open = expanded ? nil : id }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 76, alignment: .leading)
                    summary()
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("form-section-\(id.rawValue)")
            .accessibilityAddTraits(expanded ? .isSelected : [])
            if expanded {
                content()
            }
        }
    }

    private func dot(_ on: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Theme.success : Color.white.opacity(0.25)).frame(width: 6, height: 6)
            Text(text)
        }
    }

    @ViewBuilder
    private var scanSwitches: some View {
        ManageSwitchRow(
            title: String(localized: .libraryFormWatchChanges),
            detail: library.networkMount
                ? String(localized: .libraryFormNetworkWatchHint)
                : String(localized: .libraryFormWatchHint),
            isOn: $realtimeWatch, identifier: "form-switch-watch"
        )
        ManageSwitchRow(
            title: String(localized: .libraryFormClearMissingAfterScan),
            detail: String(localized: .libraryFormClearMissingHint),
            isOn: $autoClearMissing, identifier: "form-switch-clear-missing"
        )
        ManageSwitchRow(
            title: scraped ? String(localized: .libraryFormFrameFallback) : playable ? String(localized: .libraryFormGenerateCovers) : String(localized: .libraryFormGenerateThumbs),
            detail: scraped
                ? String(localized: .libraryFormScrapedFrameHint)
                : playable
                ? String(localized: .libraryFormLocalFrameHint)
                : String(localized: .libraryFormThumbnailHint),
            isOn: $generateThumbnails, identifier: "form-switch-thumbnails"
        )
        // 章节是视频的事：图片库（不可播）没有这一项
        if playable {
            ManageSwitchRow(
                title: String(localized: .libraryStatusGenerateChapters),
                detail: String(localized: .libraryFormChaptersDetail),
                isOn: $extractChapterImages, identifier: "form-switch-chapters"
            )
        }
        ManageSwitchRow(
            title: String(localized: .libraryActionsShowHome),
            detail: String(localized: .libraryFormHomeDisplayHint),
            isOn: Binding(mcGet: { !excludeFromHome }, set: { excludeFromHome = !$0 }), identifier: "form-switch-home"
        )
        // 系列是「作品的属性」：影视库来自 TMDB，其他库来自视频旁 NFO 的 <set>；照片没有系列
        if library.kind != "photo" {
            ManageSwitchRow(
                title: String(localized: .libraryFormAutoCollections),
                detail: scraped
                    ? String(localized: .libraryFormTmdbCollectionsDetail)
                    : String(localized: .libraryFormLocalCollectionsDetail),
                isOn: $autoSeriesCollections, identifier: "form-switch-series"
            )
        }
    }

    /// 刮削覆盖的摘要：「已覆盖 3 项 · 元数据 · 命名与整理」；键按前缀归到设置页的四个分区
    private var scrapeSummary: String? {
        let keys = scrapeOverrides.keys.sorted()
        guard !keys.isEmpty else { return nil }
        var groups: [String] = []
        for key in keys {
            let group = key.hasPrefix("naming_") ? String(localized: .libraryFormNaming)
                : key.hasPrefix("mirror_") ? String(localized: .libraryFormFolderWrites)
                : (key.hasPrefix("poster_") || key.hasPrefix("backdrop_") || key.hasPrefix("still_")) ? String(localized: .libraryFormImages) : String(localized: .libraryFormMetadata)
            if !groups.contains(group) { groups.append(group) }
        }
        return String(localized: .libraryFormOverridesSummary(keys.count, groups.joined(separator: " · ")))
    }

    private func submit() async {
        guard ready, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        let payload = API.LibraryPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            kind: library.kind,
            generateThumbnails: generateThumbnails,
            extractChapterImages: extractChapterImages,
            excludeFromHome: excludeFromHome,
            autoSeriesCollections: autoSeriesCollections,
            accessMode: accessMode,
            adminVisible: adminVisible,
            memberIds: memberIds,
            rootPaths: roots,
            matchRules: scraped ? ManageMatchRules.build(
                genres: ManageMatchRules.validGenres(kind: library.kind, genres: genres, options: options), regions: regions
            ) : [],
            autoClearMissing: autoClearMissing,
            scrapeOverrides: scraped ? scrapeOverrides : [:],
            realtimeWatch: realtimeWatch
        )
        do {
            let saved = try await api.libraryUpdate(libraryId: library.id, body: payload)
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
