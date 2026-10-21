import SwiftUI

/// 一个媒体库的海报墙（docs/design/tvos-app.md §3.1）：库名 + 条件摘要与部数 + 「排序与筛选」+ 海报墙（`TVPosterWall`）。
///
/// 电视上的筛选只留四样，都收在标题行右边那一枚按钮里：排序（最近添加 / 最近上映 / 评分 / 片名）、「只看没看过的」、
/// 类型 / 年代 / 画质三个二级菜单（每项写部数、0 部置灰，口径与墙同一套参数）。排序与「只看没看过的」按库记在本机，
/// 类型 / 年代 / 画质是这一次的意图，离开页面就清空（理由见 `LibraryFilter` 的注释）。筛空时给出放宽建议，不留空墙。
struct TVLibraryView: View {
    let libraryId: Int

    @Environment(\.api) private var api
    @Environment(TVLibraryDirectory.self) private var directory
    @State private var pager = LibraryWallPager<API.LibraryItemView>(pageSize: TVWallLayout.pageSize)
    @State private var sort: WallSortState
    @State private var unwatched: Bool
    @State private var picks = TVWallPicks()
    @State private var facets: API.LibraryFacetsView?
    @State private var index: [TVWallIndexEntry] = []
    @State private var relax: [API.RelaxSuggestionView] = []

    /// 电视上提供的排序档
    private static let sorts = ["added_at", "release_date", "rating", "title"]

    init(libraryId: Int) {
        self.libraryId = libraryId
        let key = Self.sortKey(libraryId)
        _sort = State(initialValue: WallSortState.load(key, default: WallSortState(sort: "added_at"), allowed: Self.sorts))
        _unwatched = State(initialValue: UserDefaults.standard.bool(forKey: key + ".unwatched"))
    }

    private static func sortKey(_ id: Int) -> String { "movieclaw.tv.wall-sort.\(id)" }
    private var library: API.LibraryView? { directory.library(libraryId) }

    var body: some View {
        TVPosterWall(title: library?.name ?? "媒体库", subtitle: summary,
                     pager: pager, fallbackLibrary: libraryId, total: total, index: index,
                     positionTitle: positionTitle, emptyTitle: emptyTitle, emptyMessage: emptyMessage,
                     emptyActions: relaxActions, retry: { await reload() }) {
            sortMenu
        }
        .task(id: "\(sort.sort)-\(sort.reversed)-\(filter.key)") { await reload() }
        .task(id: filter.key) {
            // 计数只跟条件走、与排序无关；二级维度（画质）的计数要 tier=all 才有
            facets = nil
            facets = try? await api.libraryFacetsFiltered(libraryId: libraryId, filter: filter, allTiers: true)
        }
        .onChange(of: sort) { _, value in value.save(Self.sortKey(libraryId)) }
        .onChange(of: unwatched) { _, value in UserDefaults.standard.set(value, forKey: Self.sortKey(libraryId) + ".unwatched") }
        .accessibilityIdentifier("tv-library-\(libraryId)")
    }

    private var emptyTitle: String {
        filter.isEmpty ? "这个库里还没有内容" : "没有符合条件的影片"
    }

    private var emptyMessage: String? {
        if filter.isEmpty { return nil }
        return "「" + conditions.joined(separator: " · ") + "」下没有影片，换一个条件试试"
    }

    /// 按添加时间排序没有索引条，位置提示写添加的年月
    private var positionTitle: ((API.LibraryItemView) -> String?)? {
        if sort.sort == "added_at" { return Self.addedMonth }
        return nil
    }

    // MARK: 条件

    /// 当前条件（与 iPhone / 网页同一个模型，墙、计数、索引、放宽建议四个接口共用这一份展开）
    private var filter: LibraryFilter {
        var filter = LibraryFilter()
        if let genre = picks.genre { filter.genres = [genre] }
        if let decade = picks.decade { filter.decades = [decade] }
        if picks.quality == TVWallPicks.hdr {
            filter.hdr = true
        } else if let resolution = picks.quality {
            filter.resolutions = [resolution]
        }
        if unwatched { filter.watch = "unwatched" }
        return filter
    }

    /// 标题旁的条件摘要（「科幻 · 2010 年代 · 未看」），名字取服务端 facet 的展示名
    private var conditions: [String] {
        var parts: [String] = []
        if let genre = picks.genre {
            parts.append(facets?.genres.first { $0.value == String(genre) }?.label ?? "类型")
        }
        if let decade = picks.decade { parts.append(Self.decadeLabel(decade, facets?.decades)) }
        if let quality = picks.quality { parts.append(qualityLabel(quality)) }
        if unwatched { parts.append("未看") }
        return parts
    }

    /// 当前条件下共几部：用 facet 的命中数（与墙同一套参数）；还没回来时，没加条件先用库的统计顶上
    private var total: Int? {
        facets?.total ?? (filter.isEmpty ? library?.stats.itemCount : nil)
    }

    private var summary: String? {
        let parts = conditions + [total.map { "\($0) 部" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 年代档在电视上写成「2010 年代」（服务端的展示名是「2010s」）
    private static func decadeLabel(_ value: String, _ options: [API.FacetValueView]?) -> String {
        if value.count == 5, value.hasSuffix("s"), Int(value.prefix(4)) != nil { return "\(value.prefix(4)) 年代" }
        return options?.first { $0.value == value }?.label ?? value
    }

    private var decadeOptions: [API.FacetValueView]? {
        facets?.decades.map { API.FacetValueView(value: $0.value, label: Self.decadeLabel($0.value, nil), count: $0.count) }
    }

    /// 分辨率在电视上按习惯叫法：2160p 写「4K」
    private static func resolutionLabel(_ option: API.FacetValueView) -> String {
        option.value == "2160p" ? "4K" : option.label
    }

    private var qualityOptions: [API.FacetValueView] {
        let resolutions = (facets?.resolutions ?? [])
            .map { API.FacetValueView(value: $0.value, label: Self.resolutionLabel($0), count: $0.count) }
        let hdr = (facets?.hdr ?? []).filter { $0.value == "1" }
            .map { API.FacetValueView(value: TVWallPicks.hdr, label: $0.label, count: $0.count) }
        return resolutions + hdr
    }

    private func qualityLabel(_ value: String) -> String {
        if value == TVWallPicks.hdr { return "HDR" }
        return qualityOptions.first { $0.value == value }?.label ?? value
    }

    // MARK: 排序与筛选菜单

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sort.sort) {
                ForEach(Self.sorts, id: \.self) { key in
                    Text(HomeRows.preset(key).short(false)).tag(key)
                }
            }
            Toggle("只看没看过的", isOn: $unwatched)
            Section("筛选") {
                facetMenu("类型", options: facets?.genres, selected: picks.genre.map(String.init)) { value in
                    picks.genre = value.flatMap { Int($0) }
                }
                facetMenu("年代", options: decadeOptions, selected: picks.decade) { picks.decade = $0 }
                facetMenu("画质", options: facets == nil ? nil : qualityOptions, selected: picks.quality,
                          selectedLabel: picks.quality.map(qualityLabel)) { picks.quality = $0 }
                if !picks.isEmpty {
                    Button("清除筛选", systemImage: "xmark.circle") { picks = TVWallPicks() }
                }
            }
        } label: {
            Label("排序与筛选 · \(HomeRows.preset(sort.sort).short(false))", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("tv-library-sort")
    }

    /// 一个筛选维度的二级菜单：每项写部数（在其他条件不变时选它还剩几部），0 部的置灰但照样列出来
    private func facetMenu(_ title: String, options: [API.FacetValueView]?, selected: String?,
                           selectedLabel: String? = nil, pick: @escaping (String?) -> Void) -> some View {
        Menu {
            Button {
                pick(nil)
            } label: {
                if selected == nil { Label("全部", systemImage: "checkmark") } else { Text("全部") }
            }
            if let options {
                ForEach(options, id: \.value) { option in
                    Button {
                        pick(option.value)
                    } label: {
                        if selected == option.value { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                        Text("\(option.count) 部")
                    }
                    .disabled(option.count == 0 && selected != option.value)
                }
            } else {
                Text("正在统计…")
            }
        } label: {
            Text(title)
            Text(selectedLabel ?? selected.flatMap { value in options?.first { $0.value == value }?.label } ?? "全部")
        }
    }

    // MARK: 筛空

    /// 筛空时的出路：服务端只给救得回内容的条件（最多三条），再加一个「清除全部条件」
    private var relaxActions: [TVWallAction] {
        guard !filter.isEmpty, pager.items?.isEmpty == true else { return [] }
        var actions = relax.map { suggestion in
            TVWallAction(id: "\(suggestion.dim):\(suggestion.value)",
                         title: "去掉“\(relaxLabel(suggestion))”可看 \(suggestion.count) 部") {
                remove(suggestion.dim)
            }
        }
        actions.append(TVWallAction(id: "clear", title: "清除全部条件") {
            picks = TVWallPicks()
            unwatched = false
        })
        return actions
    }

    /// 放宽建议里的条件名与标题旁的摘要同一种叫法（「4K」「2010 年代」「未看」）
    private func relaxLabel(_ suggestion: API.RelaxSuggestionView) -> String {
        switch suggestion.dim {
        case "resolutions": suggestion.value == "2160p" ? "4K" : suggestion.label
        case "decades": Self.decadeLabel(suggestion.value, nil)
        default: suggestion.label
        }
    }

    private func remove(_ dim: String) {
        switch dim {
        case "genres": picks.genre = nil
        case "decades": picks.decade = nil
        case "resolutions", "hdr": picks.quality = nil
        case "watch": unwatched = false
        default: break
        }
    }

    // MARK: 取数

    private func reload() async {
        let id = libraryId
        let filter = filter
        let sortValue = sort.sort
        let order = WallSortDirections.of(sortValue)?.orderParam(reversed: sort.reversed)
        let reversed = sort.reversed
        let api = api
        index = []
        relax = []
        // 索引与第一页一起取：按上映排序要按年分档（旧服务端不认这个参数，回月份档，下面照样按年并起来）
        async let rawIndex: [API.LibraryIndexEntryView] = TVWallIndex.supports(sortValue)
            ? (try? await api.libraryIndexFiltered(libraryId: id, filter: filter, sort: sortValue, order: order,
                                                   granularity: sortValue == "release_date" ? "year" : nil)) ?? []
            : []
        await pager.reset { offset, limit in
            try await api.libraryItemsFiltered(libraryId: id, filter: filter, sort: sortValue, order: order,
                                               limit: limit, offset: offset)
        }
        index = TVWallIndex.entries(sort: sortValue, reversed: reversed, raw: await rawIndex)
        if pager.items?.isEmpty == true, !filter.isEmpty {
            relax = (try? await api.libraryRelaxFiltered(libraryId: id, filter: filter))?.suggestions ?? []
        }
    }

    /// 按添加时间排序时的位置提示：「2026 年 8 月」（added_at 是 ISO 时间，只取年月）
    private static func addedMonth(_ item: API.LibraryItemView) -> String? {
        guard let added = item.addedAt, added.count >= 7,
              let year = Int(added.prefix(4)), let month = Int(added.dropFirst(5).prefix(2)) else { return nil }
        return "\(year) 年 \(month) 月"
    }
}

/// 媒体库墙上选的类型 / 年代 / 画质（各单选：电视上一维选一个就够，多选的组合交给网页和 iPhone）
struct TVWallPicks: Hashable {
    /// 画质里「HDR」的取值（其余取值是分辨率，如 2160p）
    static let hdr = "hdr"

    var genre: Int?
    var decade: String?
    var quality: String?

    var isEmpty: Bool { genre == nil && decade == nil && quality == nil }
}

/// 合集：同一套海报墙，条目来自合集接口；排序按合集记在本机，默认是合集自己的顺序
struct TVCollectionView: View {
    let collectionId: Int
    let name: String

    @Environment(\.api) private var api
    @State private var pager = LibraryWallPager<API.LibraryItemView>(pageSize: TVWallLayout.pageSize)
    @State private var sort: WallSortState

    /// 「合集顺序」= 不传排序，由服务端按合集的自定顺序 / 默认序给
    private static let ownOrder = "collection"
    private static let sorts = [ownOrder, "added_at", "release_date", "rating", "title"]

    init(collectionId: Int, name: String) {
        self.collectionId = collectionId
        self.name = name
        _sort = State(initialValue: WallSortState.load("movieclaw.tv.collection-sort.\(collectionId)",
                                                       default: WallSortState(sort: Self.ownOrder), allowed: Self.sorts))
    }

    var body: some View {
        TVPosterWall(title: name, pager: pager, emptyTitle: "合集里还没有内容", retry: { await reload() }) {
            Menu {
                Picker("排序", selection: $sort.sort) {
                    ForEach(Self.sorts, id: \.self) { key in
                        Text(Self.label(key)).tag(key)
                    }
                }
            } label: {
                Label("排序 · \(Self.label(sort.sort))", systemImage: "line.3.horizontal.decrease")
            }
            .accessibilityIdentifier("tv-collection-sort")
        }
        .task(id: sort) { await reload() }
        .onChange(of: sort) { _, value in value.save("movieclaw.tv.collection-sort.\(collectionId)") }
    }

    private static func label(_ key: String) -> String {
        key == ownOrder ? "合集顺序" : HomeRows.preset(key).short(false)
    }

    private func reload() async {
        let id = collectionId
        let sortValue = sort.sort == Self.ownOrder ? nil : sort.sort
        let order = sortValue.flatMap { WallSortDirections.of($0)?.orderParam(reversed: sort.reversed) }
        let api = api
        await pager.reset { offset, limit in
            try await api.collectionItemsList(collectionId: id, limit: limit, offset: offset, sort: sortValue, order: order)
        }
    }
}

/// 筛空页上的一个按钮（「去掉“西部”可看 516 部」）
struct TVWallAction: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
}

/// 海报墙的焦点：海报 / 索引条的一档 / 筛空页的按钮
enum TVWallFocus: Hashable {
    case item(Int)
    case rail(String)
    /// 索引条的接应区：从任意一排往右进来先落在这里，再转交给当前所在的那一档
    case railEntry
    case action(String)
}

/// 海报墙（媒体库、合集、首页一行的「查看全部」共用，docs/design/tvos-app.md §3.4；影人页用同一套版式 `TVWallLayout`）。
///
/// 照 Disney+ / Netflix 电视版的海报墙（2026-10-03 用户嫌原来的不够精致）：
/// - 海报放大到一屏 5 列（333 宽，原来 6 列 266），间距收紧（左右 24、上下 40，原来 32 / 52）；
/// - 海报下面不挂片名：挂字一行行参差不齐、行距也被撑大（同 Disney+）；焦点所在那张的底部浮出「片名 · 年份」暗带——
///   很多海报只印英文、艺术字甚至没字，大库里光看海报认不出是哪部（#942）；
/// - 背景是焦点所在那一部的剧照，压暗、模糊、交叉淡入；按住方向键一路滚的时候不换（同 Apple TV App 的影库）；
/// - 标题行：大标题 + 灰色的条件摘要与部数，右边放这一页自己的按钮（媒体库的「排序与筛选」）。
///
/// 大库（几千部）的翻找（§3.1）：
/// - 窗口式分页（`LibraryWallPager`）：一页 60 部，离窗口底还有三排就取下一页、并把接下来的海报先下好；
/// - 按标题 / 上映 / 评分排序时右侧有索引条（A–Z、年份、分数档）：最右一列再按右键进去，上下选、确认跳过去，左键退出；
///   跳转把窗口换成从那一档开始的一页，往上走再把前面一页页补回来；
/// - 按住方向键快速滚动时，屏幕中央浮出当前所在的档（「S」「2015」）和第几部。
/// 选中一部进条目详情，落点库优先用服务端给的 `library_id`；从详情返回，窗口与焦点都还在原处。
struct TVPosterWall<Accessory: View>: View {
    let title: String
    var subtitle: String?
    let pager: LibraryWallPager<API.LibraryItemView>
    /// 条目里没带库 id 时的详情落点
    var fallbackLibrary: Int?
    /// 整份结果共几部（位置提示「第 1204 部 / 共 3000 部」）；不知道就只写第几部
    var total: Int?
    /// 右侧索引条；空 = 这种排序没有索引条
    var index: [TVWallIndexEntry] = []
    /// 没有索引条时，位置提示的大字写什么（按添加时间排序写「2026 年 8 月」）；nil = 不提示
    var positionTitle: ((API.LibraryItemView) -> String?)?
    var emptyTitle = "这里还没有内容"
    var emptyMessage: String?
    /// 筛空时的出路（放宽建议、清除条件）；空 = 普通的空态
    var emptyActions: [TVWallAction] = []
    let retry: () async -> Void
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var wallScope
    @FocusState private var focus: TVWallFocus?
    /// 最近一次获得焦点的海报：从索引条按左键回到它、索引条亮出它所在的档
    @State private var lastItem: Int?
    /// 跳转之后要把焦点交给的那一张（程序赋焦点在视图刚出现的那一帧会被忽略，见 `jump`）
    @State private var preferredItem: Int?
    /// 背景跟着的那一部：焦点停稳再换，按住方向键一路划过去时不逐张闪
    @State private var backdropItem: API.LibraryItemView?
    @State private var lastMoveAt = Date.distantPast
    @State private var quickSteps = 0
    @State private var hud: TVWallHud?

    private let cols = TVWallLayout.columnCount
    /// 滚动位置：跳转与往上补页都按几何偏移定位（每排一样高，偏移算得出来）
    @State private var position = ScrollPosition(edge: .top)
    /// 当前滚动偏移与标题行高度（普通类：滚动时改它不触发重绘）
    @State private var geometry = TVWallGeometry()

    var body: some View {
        Group {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 36) {
                    header
                    grid
                    // 网格横贯整屏做成焦点区：上面的按钮往下、往左都先进网格、落到最近的那张。
                    // 库里只有一两部、海报都挤在左边时，右上角按钮的正下方是空的，焦点会卡在它上面下不来（实测）
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                    states
                }
                .padding(.horizontal, TVMetrics.edge)
                .padding(.top, 20)
                .padding(.bottom, 80)
                // 快速滚动时屏幕右缘那串点是 UIScrollView 的「索引显示」，不归 scrollIndicators 管；
                // 探针要放在滚动内容里，往上才找得到承载它的 UIScrollView
                .background { TVScrollIndexHider() }
            }
            // 定位一律按偏移：按条目 id 定位（scrollTo / scrollPosition(id:)）要等目标在懒加载网格里生成出来，
            // 换窗口、补页之后时灵时不灵，画面常停回页首（模拟器实测）；每排高度固定，偏移直接算得出来
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                geometry.offset = offset
            }
            .scrollClipDisabled()
            // 系统的快速滚动指示器画在屏幕右缘，正好压在索引条上；位置交给索引条与中央的位置提示。
            // tvOS 上 .hidden 只是「由系统决定」，按住方向键快速滚动时它照样出来，要 .never
            .scrollIndicators(.never)
            .ignoresSafeArea(edges: .horizontal)
            .background { backdrop }
            .overlay(alignment: .trailing) {
                if !index.isEmpty, pager.items?.isEmpty == false {
                    rail
                }
            }
            .overlay {
                if let hud {
                    hudView(hud)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: hud)
            .focusScope(wallScope)
            .onChange(of: focus) { old, new in focusMoved(from: old, to: new) }
            .task(id: focus) { await settle() }
            .task(id: hud) {
                guard hud != nil else { return }
                try? await Task.sleep(for: .milliseconds(1200))
                if !Task.isCancelled { hud = nil }
            }
            .onChange(of: pager.items?.count) { prefetchPages() }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title)
                .font(.system(size: 52, weight: .bold))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .accessibilityIdentifier("tv-wall-subtitle")
            }
            Spacer(minLength: 40)
            accessory()
                // 跳到库中间时，窗口前面的条目还没取回来：此时网格第一排往上应当原地不动、等前一页补上，
                // 不能一下子落到页首的按钮上（按钮离真正的「上一部」还隔着几千部）
                .disabled(pager.start > 0)
        }
        // 标题行横贯整屏做成焦点区：从第一排任何一张往上都能到右边的按钮（它只占右上角一小块，
        // 正上方不是它的海报往上会没有去处）
        .focusSection()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { geometry.header = $0 }
    }

    private var grid: some View {
        let items = pager.items ?? []
        return LazyVGrid(columns: TVWallLayout.columns, alignment: .leading, spacing: TVWallLayout.rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.mediaItemId) { position, item in
                TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                             imageURL: posterURL(item),
                             width: TVWallLayout.posterWidth,
                             caption: .band) {
                    if let libraryId = item.libraryId ?? fallbackLibrary {
                        router.push(.item(libraryId: libraryId, itemId: item.mediaItemId))
                    }
                }
                .focused($focus, equals: .item(item.mediaItemId))
                .prefersDefaultFocus(item.mediaItemId == preferredItem, in: wallScope)
                .accessibilityIdentifier("tv-poster-\(item.mediaItemId)")
                .onAppear {
                    // 离窗口底还有三排就取下一页：按住方向键滚下去时，下一页已经在路上
                    if position >= items.count - cols * 3 { Task { await pager.loadMore() } }
                }
            }
        }
    }

    @ViewBuilder
    private var states: some View {
        if pager.items == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if let error = pager.failed {
            TVStateView(symbol: "wifi.exclamationmark", title: "加载失败", message: error, actionTitle: "重试") {
                Task { await retry() }
            }
            .frame(height: 500)
        } else if pager.items?.isEmpty == true {
            if emptyActions.isEmpty {
                TVStateView(symbol: "film", title: emptyTitle, message: emptyMessage)
                    .frame(height: 500)
            } else {
                emptyState
            }
        }
    }

    /// 筛空：不留空墙，给出「去掉哪一条能找回多少部」
    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.title2.weight(.semibold))
            if let emptyMessage {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 32) {
                ForEach(emptyActions) { action in
                    Button(action.title, action: action.action)
                        .focused($focus, equals: .action(action.id))
                }
            }
            .padding(.top, 12)
            .focusSection()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
        // 容器直接挂标识会盖住里面每个按钮的标识（UI 测试按档找不到）
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-wall-empty")
    }

    /// 焦点那一部的剧照（按模糊垫底的小图取，够用且轻）：放大模糊、压暗，交叉淡入
    private var backdrop: some View {
        TVBlurredBackdrop(url: backdropItem.flatMap {
            api.image($0.backdropUrl ?? $0.posterUrl, width: ImageWidth.points(TVMetrics.blurredBackdropWidth))
        })
            .ignoresSafeArea()
    }

    private func posterURL(_ item: API.LibraryItemView) -> URL? {
        api.image(item.posterUrl, width: ImageWidth.tvCard(TVWallLayout.posterWidth))
    }

    // MARK: 索引条

    /// 当前所在的档：最近获得焦点的那张海报落在哪一档
    private var currentKey: String? {
        guard let id = lastItem, let offset = pager.offset(of: id) else { return nil }
        return TVWallIndex.entry(at: offset, in: index)?.key
    }

    /// 焦点在索引条的某一档上
    private var railFocused: Bool {
        if case .rail = focus { return true }
        return false
    }

    /// 索引条正在被使用（焦点在某一档上，或刚落进接应区、正要转交）：这时各档才可选
    private var railActive: Bool {
        railFocused || focus == .railEntry
    }

    /// 右侧索引条：一档一行，库里没有的档压暗、跳不过去。
    /// 进条的落点要是「当前所在的那一档」：任由系统按位置挑，落点就成了随缘的某个字母；只留当前那一档可选也不行——
    /// 焦点在屏幕中间那排、当前档在条的顶上时，两者上下不重叠，系统往右根本找不到它（模拟器实测按右键原地不动）。
    /// 所以焦点不在条上时，各档都不可选，整条盖一块透明的接应区：任何一排往右都落进来，再把焦点转交给当前那一档
    private var rail: some View {
        let height = min(30, (820 / CGFloat(max(index.count, 1))).rounded(.down))
        let current = currentKey ?? index.first { $0.count > 0 }?.key
        let narrow = index.contains { $0.label.count > 2 }
        return VStack(spacing: 0) {
            ForEach(index) { entry in
                Button {
                    jump(to: entry)
                } label: {
                    Text(entry.label)
                }
                .buttonStyle(TVRailButtonStyle(empty: entry.count == 0, current: entry.key == current,
                                               height: height, small: narrow))
                .focused($focus, equals: .rail(entry.key))
                .disabled(entry.count == 0 || !railActive)
                .overlay(alignment: upperHalf(entry) ? .topTrailing : .bottomTrailing) {
                    // 上半截的档往下展开、下半截的往上展开：贴着条顶的几档往上伸会盖住标题行的按钮
                    if focus == .rail(entry.key) {
                        railBubble(entry)
                            .offset(x: -92, y: upperHalf(entry) ? -12 : 12)
                    }
                }
                .accessibilityIdentifier("tv-rail-\(entry.key)")
            }
        }
        .padding(.vertical, 12)
        .frame(width: 64)
        .overlay {
            if !railFocused {
                Color.clear
                    .contentShape(.rect)
                    .focusable()
                    .focused($focus, equals: .railEntry)
                    .accessibilityHidden(true)
            }
        }
        .background {
            if railFocused {
                Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
            }
        }
        .focusSection()
        .onMoveCommand { direction in
            // 接了移动命令，系统就不再替这一条挪焦点：上下自己挪（顺手跳过空档），
            // 左键回到刚才那张海报（而不是按位置挑旁边的某一张）
            switch direction {
            case .up: railStep(-1)
            case .down: railStep(1)
            case .left: if let lastItem { focus = .item(lastItem) }
            default: break
            }
        }
        .padding(.trailing, 12)
        .padding(.top, 120)
        .animation(.easeOut(duration: 0.2), value: railFocused)
        // 容器直接挂标识会盖住里面每个按钮的标识（UI 测试按档找不到）
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-wall-rail")
    }

    /// 索引条上下挪一档，跳过空档；到头就停
    private func railStep(_ delta: Int) {
        guard case let .rail(key) = focus, var position = index.firstIndex(where: { $0.key == key }) else { return }
        repeat { position += delta } while index.indices.contains(position) && index[position].count == 0
        if index.indices.contains(position) { focus = .rail(index[position].key) }
    }

    /// 焦点落进接应区：转交给当前所在的那一档。各档刚变成可选的那一帧，焦点赋值会被系统忽略，没接住就稍等再交
    private func enterRail() {
        let target = currentKey ?? index.first { $0.count > 0 }?.key
        guard let target else { return }
        Task {
            for _ in 0 ..< 4 {
                try? await Task.sleep(for: .milliseconds(40))
                guard focus == .railEntry else { return }
                focus = .rail(target)
            }
        }
    }

    private func upperHalf(_ entry: TVWallIndexEntry) -> Bool {
        (index.firstIndex(of: entry) ?? 0) < index.count / 2
    }

    /// 索引条左边的预览气泡：档名大字 + 这一档有几部
    private func railBubble(_ entry: TVWallIndexEntry) -> some View {
        VStack(spacing: 10) {
            Text(entry.title)
                .font(.system(size: entry.title.count > 2 ? 52 : 88, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(entry.count) 部")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
        .frame(width: 220, height: 180)
        .glassEffect(.regular, in: .rect(cornerRadius: 36))
        .fixedSize()
        .allowsHitTesting(false)
    }

    /// 跳到某一档：窗口换成从这一档开始的一页（起点按整排对齐，列位置与从头翻下来时一样），先把前面一页也补上，
    /// 再把锚点和焦点交给这一档的第一张。
    /// 先补前一页是为了让目标上面有内容：窗口第一排就在页首时，滚动位置停在最顶上，系统让内容贴着顶部、不保持锚点，
    /// 之后往上补页会把整屏顶下去、焦点那一排被挤出屏幕（模拟器实测）
    private func jump(to entry: TVWallIndexEntry) {
        guard let offset = entry.offset else { return }
        let aligned = offset - offset % cols
        Task {
            await pager.jump(to: aligned)
            await pager.loadPrevious()
            guard let items = pager.items, !items.isEmpty else { return }
            let position = min(offset - pager.start, items.count - 1)
            let target = items[position].mediaItemId
            // 等网格按新窗口排好版再滚（同一帧里滚，内容高度还是旧的）
            try? await Task.sleep(for: .milliseconds(50))
            preferredItem = target
            lastItem = target
            hud = TVWallHud(title: entry.title, detail: positionDetail(offset))
            // 滚到目标那一排：标题行下面第几排 × 每排高度，上面留一点边
            self.position.scrollTo(y: max(0, rowTop(position / cols) - 60))
            // 焦点赋值在目标视图刚出现的那一帧会被系统忽略：标成默认焦点再重置焦点区，没接住就稍等再交（docs：tvOS 焦点实测坑）
            for _ in 0 ..< 5 {
                try? await Task.sleep(for: .milliseconds(60))
                if focus == .item(target) { break }
                focus = .item(target)
                resetFocus(in: wallScope)
            }
        }
    }

    // MARK: 快速滚动

    private func focusMoved(from old: TVWallFocus?, to new: TVWallFocus?) {
        if new == .railEntry {
            enterRail()
            return
        }
        guard case let .item(id) = new else {
            quickSteps = 0
            return
        }
        lastItem = id
        let now = Date.now
        // 连续几次焦点移动都挨得很近，就是在按住方向键快速滚动。连发是先慢后快的
        //（模拟器量：按住后各次间隔约 1.4 / 1.1 / 0.5 / 0.25 / 0.18 秒），门槛取 0.55 秒、连着两次，按住一秒多就出提示
        if case .item = old, now.timeIntervalSince(lastMoveAt) < 0.55 {
            quickSteps += 1
        } else {
            quickSteps = 0
        }
        lastMoveAt = now
        guard let items = pager.items, let position = items.firstIndex(where: { $0.mediaItemId == id }) else { return }
        if quickSteps >= 2, let label = positionLabel(items[position], offset: pager.start + position) {
            hud = TVWallHud(title: label, detail: positionDetail(pager.start + position))
        }
        if position >= items.count - cols * 3 { Task { await pager.loadMore() } }
        if position < cols * 3, pager.start > 0 { Task { await loadPrevious() } }
        // 接下来三排的海报先解码进内存：滚到屏幕上时已经是现成的，不闪占位底
        let ahead = items[min(position + cols, items.count)..<min(position + cols * 4, items.count)]
        TVWallPrefetch.ahead(ahead.compactMap(posterURL))
    }

    /// 往上补一页：补进来几排，偏移就加几排的高度，原来那几排在屏幕上纹丝不动（与数据变化同一次更新，不闪）
    private func loadPrevious() async {
        guard pager.start > 0 else { return }
        let before = pager.start
        await pager.loadPrevious()
        let added = (before - pager.start) / cols
        if added > 0 { position.scrollTo(y: geometry.offset + CGFloat(added) * TVWallLayout.rowStride) }
    }

    /// 网格第几排的顶在滚动内容里的位置（内容上边距 20 + 标题行 + 标题行与网格的间距 36）
    private func rowTop(_ row: Int) -> CGFloat {
        20 + geometry.header + 36 + CGFloat(row) * TVWallLayout.rowStride
    }

    /// 焦点停稳：换背景（快速滚动时多等一会儿，按住方向键一路滚过去不逐张换）
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(quickSteps >= 2 ? 450 : 200))
        guard !Task.isCancelled, case let .item(id) = focus, id != backdropItem?.mediaItemId else { return }
        backdropItem = pager.items?.first { $0.mediaItemId == id }
    }

    private func positionLabel(_ item: API.LibraryItemView, offset: Int) -> String? {
        if !index.isEmpty { return TVWallIndex.entry(at: offset, in: index)?.title }
        return positionTitle?(item)
    }

    private func positionDetail(_ offset: Int) -> String {
        if let total { return "第 \(offset + 1) 部 / 共 \(total) 部" }
        return "第 \(offset + 1) 部"
    }

    private func hudView(_ hud: TVWallHud) -> some View {
        VStack(spacing: 14) {
            Text(hud.title)
                .font(.system(size: hud.title.count > 3 ? 64 : 120, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(hud.detail)
                .font(.system(size: 24))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
        .frame(minWidth: 300, minHeight: 260)
        .glassEffect(.regular, in: .rect(cornerRadius: 48))
        .allowsHitTesting(false)
        .accessibilityIdentifier("tv-wall-hud")
    }

    /// 新到的一页先把海报下到磁盘缓存（不解码：一页 60 张都解码进内存太占）
    private func prefetchPages() {
        TVWallPrefetch.page((pager.items ?? []).compactMap(posterURL))
    }
}

extension TVPosterWall where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, pager: LibraryWallPager<API.LibraryItemView>, fallbackLibrary: Int? = nil,
         total: Int? = nil, emptyTitle: String = "这里还没有内容", retry: @escaping () async -> Void) {
        self.init(title: title, subtitle: subtitle, pager: pager, fallbackLibrary: fallbackLibrary, total: total,
                  emptyTitle: emptyTitle, retry: retry, accessory: { EmptyView() })
    }
}

/// 关掉 tvOS 滚动视图在快速滚动时自动出现的「索引显示」（右缘一串点 + 一个圆点，`indexDisplayMode` 默认 automatic）：
/// 它正好压在索引条上，位置已经交给索引条与中央的位置提示。SwiftUI 没有对应的修饰符，从挂在滚动视图背景里的这个视图往上找到
/// 承载它的 UIScrollView 设掉
private struct TVScrollIndexHider: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView {
                    scroll.indexDisplayMode = .alwaysHidden
                    return
                }
                view = current.superview
            }
        }
    }
}

/// 海报墙的滚动几何（普通类，改了不触发重绘）
final class TVWallGeometry {
    var offset: CGFloat = 0
    var header: CGFloat = 70
}

/// 屏幕中央的位置提示
struct TVWallHud: Equatable {
    let title: String
    let detail: String
}

/// 索引条的一格：平时灰字（当前所在的档白字、空档几乎看不见），获得焦点时白底黑字放大
private struct TVRailButtonStyle: ButtonStyle {
    let empty: Bool
    let current: Bool
    let height: CGFloat
    /// 年份这种四位数的档用小一号的字
    let small: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, empty: empty, current: current, height: height, small: small)
    }

    private struct Face<Label: View>: View {
        let label: Label
        let empty: Bool
        let current: Bool
        let height: CGFloat
        let small: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            label
                .font(.system(size: small ? 16 : 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isFocused ? Color.black : .white.opacity(empty ? 0.16 : current ? 1 : 0.5))
                .frame(width: small ? 58 : 44, height: height)
                .background {
                    Capsule().fill(.white).opacity(isFocused ? 1 : 0)
                }
                .scaleEffect(isFocused ? 1.2 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// 海报墙的版式：媒体库、合集、「查看全部」与影人页（`TVPersonView`）同一套，换页面时海报的大小、位置、
/// 焦点移动的手感都不变。一屏 5 列，左右间距 24、上下 40，5 张加 4 个间距铺满安全区内的 1760 点
enum TVWallLayout {
    static let columnCount = 5
    static let columnSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 40
    static let posterWidth: CGFloat = (1920 - TVMetrics.edge * 2 - CGFloat(columnCount - 1) * columnSpacing) / CGFloat(columnCount)
    static let columns = Array(repeating: GridItem(.fixed(posterWidth), spacing: columnSpacing), count: columnCount)
    /// 一排占的高度（海报 2:3 + 行距）：跳转与补页按它算偏移
    static let rowStride: CGFloat = posterWidth * 1.5 + rowSpacing
    /// 一页 60 部（12 排）：整排的倍数，往上补页时列位置不错开
    static let pageSize = 60
}
