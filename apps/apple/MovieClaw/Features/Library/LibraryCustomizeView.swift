import SwiftUI

/// 自定义首页（Web `library-customize-view.tsx`，路由 `/library/customize`）。
///
/// 功能与 Web 一致，交互按 iOS 的编辑列表重新组织（不照搬 Web 的原地展开）：
/// - **整页是一张弹出表单**（`AppSheet.customizeHome`，由 Router 把 `/library/customize` 改成弹出）：
///   编辑布局是一件「进去改完就走」的事，表单盖在首页上，关掉就看到效果，也不会被悬浮标签栏挡住；
/// - **主清单只做两件事**：行首圆圈显隐、行尾把手拖动排序（同系统「音乐 › 资料库 › 编辑」）；
///   每行下面一行小字说清来源与排序，能设置的行带 ›，点进单行设置页；
/// - **单行设置页**（`RowSettingsView`）是标准表单：名字、排序依据 + 方向、只看没看过的、来源、删除（仅自加行）。
///   哪种行支持哪些设置就只出哪几组，不出现灰掉的控件；
/// - **添加一行**：左上角 ＋ 打开来源选择（按类型 / 媒体库 / 合集三组），选中即加到末尾并直接进它的设置页；
/// - **恢复默认**：红字放在清单最底部，二次确认；不占右上角——那里是 ✓ 完成。
///
/// 保存：每次改动先落本地草稿，400ms 防抖后整份 PUT `/ui/preferences`（后端是整体覆盖，
/// 所以要带上主题、侧栏等其余偏好原值）。保存成功写回 `LibraryHomePrefs.shared`，关掉表单首页立即生效。
struct LibraryCustomizeView: View {
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(Feedback.self) private var feedback
    @Environment(AppModel.self) private var model
    @State private var prefs = LibraryHomePrefs.shared

    @State private var libraries: [API.LibraryView]?
    @State private var collections: [API.CollectionView] = []
    @State private var fullPrefs: API.UiPreferencesSetting?
    @State private var loadFailed = false
    @State private var saveError: String?
    @State private var draft: [HomeRows.Row]?
    @State private var saveTask: Task<Void, Never>?
    /// 表单内的导航栈：压的是行 id（单行设置页）
    @State private var path: [String] = []
    @State private var adding = false

    private var savedRows: [HomeRows.Row] {
        HomeRows.build(prefs: prefs.rows ?? [], libraries: libraries ?? [], collections: collections)
    }

    private var rows: [HomeRows.Row] { draft ?? savedRows }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    if libraries != nil {
                        ForEach(rows) { row in
                            RowLine(
                                row: row,
                                onToggle: { update(row.id) { $0.hidden.toggle() } },
                                onOpen: { path.append(row.id) }
                            )
                        }
                        .onMove { from, to in
                            var next = rows
                            next.move(fromOffsets: from, toOffset: to)
                            commit(next)
                        }
                    } else if !loadFailed {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 6) {
                        if loadFailed {
                            // 读取失败时整张清单不画——残缺清单上点一下圆圈就会整份保存，把认不出的库行/合集行永久丢掉
                            Text("读取媒体库与合集失败，行清单可能不完整；下拉刷新重试。")
                                .foregroundStyle(Theme.warning)
                                .accessibilityIdentifier("customize-load-failed")
                        }
                        if let saveError {
                            Text(saveError).foregroundStyle(Theme.danger)
                        }
                        Text("首页的行")
                    }
                } footer: {
                    if libraries != nil {
                        Text("\(rows.filter { !$0.hidden }.count) 行显示、\(rows.filter(\.hidden).count) 行隐藏。轻点圆圈显示或隐藏，按住右侧把手拖动排序。改动只影响你自己的首页。")
                            .accessibilityIdentifier("customize-summary")
                    }
                }

                if libraries != nil {
                    Section {
                        Button("恢复默认布局", role: .destructive) { Task { await restoreDefaults() } }
                            .accessibilityIdentifier("restore-defaults")
                    }
                }
            }
            // 常驻编辑态：拖动把手一直在。不给 onDelete，行首就不会冒出红色减号（与显隐圆圈打架）；删除在单行设置页里
            .environment(\.editMode, .constant(.active))
            .navigationTitle("自定义首页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("添加一行", systemImage: "plus") { adding = true }
                        .disabled(libraries == nil)
                        .accessibilityIdentifier("add-row")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark", role: .confirm) { dismiss() }
                        .accessibilityIdentifier("customize-done")
                }
            }
            .navigationDestination(for: String.self) { id in
                if let row = rows.first(where: { $0.id == id }) {
                    RowSettingsView(
                        row: row,
                        onChange: { update(id, $0) },
                        onRemove: {
                            path.removeAll { $0 == id }
                            remove(id)
                        }
                    )
                }
            }
            .sheet(isPresented: $adding) {
                AddRowSheet(
                    // 按类型的来源与首页同一口径：可见、没被排除首页的同类型库
                    kinds: HomeRows.mediaKindGroups((libraries ?? []).filter(\.viewerAccess)),
                    libraries: (libraries ?? []).filter(\.viewerAccess),
                    // 内置的「我的收藏」等自动合集不进候选（首页已有「我的收藏」这一行）
                    collections: collections.filter { $0.kind == "user" },
                    onHome: Set(rows.compactMap { if case let .collection(c, _, _, _) = $0.kind { c.id } else { nil } }),
                    add: add
                )
                .sheetFeedback()
            }
            .task { await load() }
            .refreshable { await load() }
        }
        .onDisappear { flushSave() }
    }

    // MARK: 数据

    private func load() async {
        do {
            async let libs = api.libraryList(scope: "all")
            async let cols = api.collectionList()
            async let ui = api.uiPrefsShow()
            let (l, c, u) = try await (libs, cols, ui)
            collections = c
            fullPrefs = u
            // 副本记在当前账号名下（换过账号时旧账号的清单随之作废）
            prefs.adopt(owner: LibraryHomePrefs.ownerKey(api: api, username: model.session?.username))
            prefs.rows = u.home.rows
            libraries = l
            loadFailed = false
        } catch is CancellationError {
        } catch {
            // 保持 libraries 为 nil（首次读取失败时不渲染可编辑清单），只挂提示
            loadFailed = true
        }
    }

    private func update(_ id: String, _ patch: (inout HomeRows.Row) -> Void) {
        commit(rows.map { row in
            guard row.id == id else { return row }
            var next = row
            patch(&next)
            return next
        })
    }

    private func remove(_ id: String) {
        commit(rows.filter { $0.id != id })
    }

    /// 加到末尾，并直接进它的设置页（新行多半要马上改排序或名字）
    private func add(_ row: HomeRows.Row) {
        commit(rows + [row])
        adding = false
        path.append(row.id)
    }

    /// 改动落草稿，400ms 防抖后保存
    private func commit(_ next: [HomeRows.Row]) {
        draft = next
        saveError = nil
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await save(next)
        }
    }

    /// 关掉表单时把还在防抖窗口里的改动立即存掉
    private func flushSave() {
        guard let draft, saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        let rows = draft
        Task { await save(rows) }
    }

    private func save(_ rows: [HomeRows.Row]) async {
        do {
            let saved = try await savePrefs(HomeRows.toPrefs(rows))
            prefs.rows = saved.home.rows
            fullPrefs = saved
            if draft == rows { draft = nil }
            saveTask = nil
        } catch is CancellationError {
        } catch {
            saveError = error.localizedDescription.isEmpty ? "保存失败，请稍后再试" : error.localizedDescription
        }
    }

    /// 后端整体覆盖：以当前完整偏好为底，只替换 home.rows
    private func savePrefs(_ rows: [API.HomeRowPrefInput]) async throws -> API.UiPreferencesSetting {
        let base: API.UiPreferencesSetting
        if let fullPrefs { base = fullPrefs } else { base = try await api.uiPrefsShow() }
        var input = try JSONDecoder().decode(API.UiPreferencesSettingInput.self, from: JSONEncoder().encode(base))
        input.home = API.HomeUiPrefsInput(rows: rows)
        return try await api.uiPrefsUpdate(body: input)
    }

    private func restoreDefaults() async {
        guard await feedback.confirm("恢复默认布局？", message: "你自己加的行会被移除，排序和名字回到默认。", confirmTitle: "恢复默认", destructive: true) else { return }
        saveTask?.cancel()
        saveTask = nil
        draft = nil
        do {
            let saved = try await savePrefs([])
            prefs.rows = saved.home.rows
            fullPrefs = saved
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - 主清单的一行

/// 行首圆圈（显隐）+ 名字与小字 + ›（能设置的行）。拖动把手由编辑态的 List 自己画在行尾
private struct RowLine: View {
    let row: HomeRows.Row
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: row.hidden ? "circle" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(row.hidden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.hidden ? "显示「\(row.title)」" : "隐藏「\(row.title)」")
            .accessibilityIdentifier("row-visibility-\(row.id)")

            // 不能设置的行（接下来继续、我的媒体库）不包按钮：包了再 disabled 会连文字一起置灰，看着像被隐藏了
            if row.configurable {
                Button(action: onOpen) { label }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("row-title-\(row.id)")
            } else {
                label.accessibilityIdentifier("row-title-\(row.id)")
            }
        }
        .padding(.vertical, 2)
    }

    private var label: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .foregroundStyle(row.hidden ? Theme.textFaint : Theme.text)
                    .lineLimit(1)
                Text(row.meta)
                    .font(.footnote)
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if row.configurable {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }
}

private extension HomeRows.Row {
    /// 有可设项（排序 / 名字 / 删除）的行才点得进设置页；接下来继续、我的媒体库只能显隐和换位
    var configurable: Bool { sort != nil }
}

// MARK: - 单行设置页

/// 一行的设置（标准表单）：名字 → 排序依据 + 方向 → 只看没看过的 → 来源 → 删除（仅自加行）
private struct RowSettingsView: View {
    let row: HomeRows.Row
    var onChange: ((inout HomeRows.Row) -> Void) -> Void
    var onRemove: () -> Void

    @FocusState private var nameFocused: Bool

    /// 排序依据的候选（不分方向，方向单独一个分段控件）
    private var sortKeys: [String] {
        switch row.kind {
        case .favorites: HomeRows.favoritesSorts
        case let .library(library, _, _, _, _, _): HomeRows.sorts(for: library.kind)
        case let .mediaKind(kind, _, _, _, _, _, _): HomeRows.sorts(for: kind)
        case .collection: HomeRows.allSorts
        default: []
        }
    }

    private var isFavorites: Bool { if case .favorites = row.kind { true } else { false } }

    private var direction: WallSortDirection? {
        guard let sort = row.sort else { return nil }
        return isFavorites ? HomeRows.favoritesPreset(sort).direction : HomeRows.preset(sort).direction
    }

    /// 「只显示我没看过的」：只对库行与类型行有意义，且与「最近观看」互斥（那一行只要播过的）
    private var unwatched: Bool? {
        switch row.kind {
        case let .library(_, sort, _, unwatched, _, _), let .mediaKind(_, _, sort, _, unwatched, _, _):
            sort == "last_played" ? nil : unwatched
        default: nil
        }
    }

    private var nameEditable: Bool {
        switch row.kind {
        case .library, .mediaKind, .collection: true
        default: false
        }
    }

    /// 这一行从哪来：名字改掉之后，靠它认出这一行指向哪个库 / 哪些库 / 哪个合集
    private var source: String? {
        switch row.kind {
        case let .library(library, _, _, _, _, _): "\(library.name)库"
        case let .mediaKind(_, libraries, _, _, _, _, _): libraries.map(\.name).joined(separator: "、")
        case let .collection(collection, _, _, _): "合集「\(collection.name)」"
        default: nil
        }
    }

    var body: some View {
        Form {
            if nameEditable {
                Section {
                    TextField(row.defaultTitle, text: Binding(
                        get: { row.customName },
                        set: { value in setName(String(value.prefix(40))) }
                    ))
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onChange(of: nameFocused) { _, focused in
                        // 失焦时去掉首尾空白（同 Web onBlur trim）；输入途中不 trim，免得吃掉词间的空格
                        let trimmed = row.customName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !focused, trimmed != row.customName { setName(trimmed) }
                    }
                    .accessibilityIdentifier("row-name")
                } header: {
                    Text("名字")
                } footer: {
                    Text("留空就跟随排序自动取名。")
                }
            }

            Section("排序") {
                ForEach(sortKeys, id: \.self) { key in
                    Button {
                        // 换依据时回到该档的自然方向
                        setSort(key, reversed: false)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.sortLabel(key)).foregroundStyle(Theme.text)
                                if let hint = Self.sortHint(key) {
                                    Text(hint).font(.footnote).foregroundStyle(Theme.textFaint)
                                }
                            }
                            Spacer()
                            if row.sort == key {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("row-sort-\(key)")
                }
                if let direction, let sort = row.sort {
                    // 自然方向在前：「新→旧」「高→低」「A→Z」
                    Picker("顺序", selection: Binding(
                        get: { row.reversed },
                        set: { setSort(sort, reversed: $0) }
                    )) {
                        Text(direction.label(reversed: false)).tag(false)
                        Text(direction.label(reversed: true)).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("row-order")
                }
            }

            if let unwatched {
                Section {
                    Toggle("只显示我没看过的", isOn: Binding(get: { unwatched }, set: setUnwatched))
                        .accessibilityIdentifier("row-unwatched")
                }
            }

            if let source {
                Section {
                    LabeledContent("来源", value: source)
                } footer: {
                    if case .mediaKind = row.kind {
                        Text("同一部片在几个库里都有时只出现一次；从首页排除的库不算在内。")
                    }
                }
            }

            if row.removable {
                Section {
                    Button("删除这一行", role: .destructive, action: onRemove)
                        .accessibilityIdentifier("row-remove")
                }
            }
        }
        .navigationTitle(row.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 改动（按行的种类改对应字段；「最近观看」与「只看没看过的」互斥）

    private func setSort(_ key: String, reversed: Bool) {
        onChange { r in
            switch r.kind {
            case .favorites: r.kind = .favorites(sort: key, reversed: reversed)
            case let .library(library, _, _, unwatched, name, builtin):
                r.kind = .library(library: library, sort: key, reversed: reversed,
                                  unwatched: key == "last_played" ? false : unwatched, name: name, builtin: builtin)
            case let .mediaKind(kind, libraries, _, _, unwatched, name, builtin):
                r.kind = .mediaKind(kind: kind, libraries: libraries, sort: key, reversed: reversed,
                                    unwatched: key == "last_played" ? false : unwatched, name: name, builtin: builtin)
            case let .collection(collection, _, _, name):
                r.kind = .collection(collection: collection, sort: key, reversed: reversed, name: name)
            default: break
            }
        }
    }

    private func setUnwatched(_ value: Bool) {
        onChange { r in
            switch r.kind {
            case let .library(library, sort, reversed, _, name, builtin):
                r.kind = .library(library: library, sort: sort, reversed: reversed, unwatched: value, name: name, builtin: builtin)
            case let .mediaKind(kind, libraries, sort, reversed, _, name, builtin):
                r.kind = .mediaKind(kind: kind, libraries: libraries, sort: sort, reversed: reversed, unwatched: value, name: name, builtin: builtin)
            default: break
            }
        }
    }

    private func setName(_ name: String) {
        onChange { r in
            switch r.kind {
            case let .library(library, sort, reversed, unwatched, _, builtin):
                r.kind = .library(library: library, sort: sort, reversed: reversed, unwatched: unwatched, name: name, builtin: builtin)
            case let .mediaKind(kind, libraries, sort, reversed, unwatched, _, builtin):
                r.kind = .mediaKind(kind: kind, libraries: libraries, sort: sort, reversed: reversed, unwatched: unwatched, name: name, builtin: builtin)
            case let .collection(collection, sort, reversed, _):
                r.kind = .collection(collection: collection, sort: sort, reversed: reversed, name: name)
            default: break
            }
        }
    }

    // MARK: 排序依据的叫法（不带方向；方向在分段控件里）

    static func sortLabel(_ key: String) -> String {
        switch key {
        case "unwatched_first": "未看优先"
        case "favorited_at": "收藏时间"
        case "release_date": "上映时间"
        case "last_played": "上次观看"
        case "rating": "评分"
        case "random": "随便看看"
        case "title": "片名"
        default: "添加时间"
        }
    }

    static func sortHint(_ key: String) -> String? {
        switch key {
        case "unwatched_first": "没看完的在前，再按收藏时间"
        case "last_played": "只列我播放过的"
        case "random": "每天换一批"
        default: nil
        }
    }
}

// MARK: - 添加一行

/// 「添加一行」的来源选择：按类型（「全部电影」，跨库合并）/ 媒体库 / 合集；已在首页的合集置灰打勾
private struct AddRowSheet: View {
    let kinds: [(kind: String, libraries: [API.LibraryView])]
    let libraries: [API.LibraryView]
    let collections: [API.CollectionView]
    let onHome: Set<Int>
    var add: (HomeRows.Row) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !kinds.isEmpty {
                    Section {
                        // 类型排最前：「全部电影」是比单个库更大的来源
                        ForEach(kinds, id: \.kind) { group in
                            choice(
                                title: "全部\(HomeRows.mediaKindLabel(group.kind))",
                                icon: Self.kindIcon(group.kind),
                                detail: "\(group.libraries.count) 个库"
                            ) { add(HomeRows.newMediaKindRow(group.kind, libraries: group.libraries)) }
                            .accessibilityIdentifier("add-row-kind-\(group.kind)")
                        }
                    } header: {
                        Text("按类型")
                    } footer: {
                        Text("同类型的库合成一行，同一部片只出现一次。")
                    }
                }
                if !libraries.isEmpty {
                    Section("媒体库") {
                        ForEach(libraries, id: \.id) { library in
                            choice(title: library.name, icon: Self.kindIcon(library.kind), detail: nil) {
                                add(HomeRows.newLibraryRow(library))
                            }
                            .accessibilityIdentifier("add-row-library-\(library.id)")
                        }
                    }
                }
                if !collections.isEmpty {
                    Section("合集") {
                        ForEach(collections, id: \.id) { collection in
                            let onHome = onHome.contains(collection.id)
                            choice(title: collection.name, icon: "square.stack", detail: onHome ? nil : "\(collection.itemCount) 部", done: onHome) {
                                add(HomeRows.newCollectionRow(collection))
                            }
                            .disabled(onHome)
                        }
                    }
                }
            }
            .navigationTitle("添加一行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func choice(title: String, icon: String, detail: String?, done: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(title).foregroundStyle(done ? Theme.textFaint : Theme.text)
                Spacer()
                if let detail { Text(detail).font(.subheadline).foregroundStyle(Theme.textFaint) }
                if done { Image(systemName: "checkmark").foregroundStyle(Theme.textFaint) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private static func kindIcon(_ kind: String) -> String {
        switch kind {
        case "tv": "tv"
        case "video": "video"
        case "photo": "photo"
        default: "film"
        }
    }
}
