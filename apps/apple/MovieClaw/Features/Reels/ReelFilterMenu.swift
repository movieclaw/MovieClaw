import SwiftUI

/// 刷片右上角的筛选键：形态照发现页的 `DiscoverFilterMenu`——按钮只写一个短摘要，点开是
/// 每个维度一个二级菜单（标题下是当前值），有条件时末尾给「清空条件」；选一项菜单即收起，
/// 选中立刻生效（整个信息流按新条件重来）。
///
/// 维度与取值沿用**媒体库筛选**（`LibraryFilter`，年代、片长按档）：刷片刷的是自己的片库，
/// 与媒体库墙是同一批片子、同一套口径；发现页那种单个年份的取值放到几百部的库里一选就空。
/// 另加刷片特有的两维：电影 / 剧集（刷片是混着抽的），和「只看没看过的」（刷片是帮人决定
/// 今晚看什么，最常用的就是排除看过的）。
///
/// 每个取值后面写着当前条件下还剩几部（服务端 `/reels/facets` 按「排除本维自身条件」算），
/// 为 0 的置灰不可点——不让人点出一个空的信息流。
struct ReelFilterMenu: View {
    let store: ReelsStore?

    /// 菜单里的维度（键是 `LibraryFilter` 的维度名，toggle / values(of:) 直接认）
    private static let dimensions: [(key: String, title: String, systemImage: String)] = [
        ("genres", String(localized: .mediaDiscoveryType), "theatermasks"),
        ("decades", String(localized: .libraryFiltersDecades), "calendar"),
        ("countries", String(localized: .mediaFiltersCountry), "globe.asia.australia"),
        ("rating_gte", String(localized: .mediaFiltersRating), "star"),
        ("runtimes", String(localized: .libraryFiltersRuntime), "clock"),
    ]

    var body: some View {
        let filter = store?.filter ?? LibraryFilter()
        let kind = store?.kind
        let title = buttonTitle(filter: filter, kind: kind)
        // 库里只有「其他」视频时服务端不给类型列表：没有可切换的，整行不画。加载中（facets 还
        // 没回来）先画着，与以前一样显示「加载中」
        let showKinds = !(store?.facets?.kinds.isEmpty ?? false)
        // 「其他」没有 TMDB 档案：类型 / 年代 / 地区 / 评分 / 片长对它无意义，只剩观看状态。
        // 选了「其他」，或库里只有「其他」（服务端回落，filterable = false）时收起这几个菜单
        let filterable = kind != "video" && (store?.facets?.filterable ?? true)
        Menu {
            if showKinds {
                Menu {
                    option(String(localized: .mediaFiltersAll), count: nil, selected: kind == nil) { apply(filter, kind: nil) }
                    ForEach(facetValues("kinds"), id: \.value) { value in
                        option(value.label, count: value.count, selected: kind == value.value) {
                            let next = kind == value.value ? nil : value.value
                            // 切到「其他」时清掉不适用的条件，只留观看状态
                            apply(next == "video" ? watchOnly(filter) : filter, kind: next)
                        }
                    }
                } label: {
                    Label(kindsTitle, systemImage: "film.stack")
                    Text(kind.flatMap { label("kinds", $0) } ?? String(localized: .mediaFiltersUnlimited))
                }
            }
            ForEach(filterable ? Self.dimensions : [], id: \.key) { dim in
                Menu {
                    let values = facetValues(dim.key)
                    if values.isEmpty {
                        Button(store?.facets == nil ? String(localized: .commonLoadingProgress) : String(localized: .reelsFilterNothing)) {}
                            .disabled(true)
                    }
                    ForEach(values, id: \.value) { value in
                        option(value.label, count: value.count,
                               selected: filter.values(of: dim.key).contains(value.value)) {
                            var next = filter
                            next.toggle(dim.key, value.value)
                            apply(next, kind: kind)
                        }
                    }
                } label: {
                    Label(dim.title, systemImage: dim.systemImage)
                    Text(summary(dim.key, filter: filter) ?? String(localized: .mediaFiltersUnlimited))
                }
            }
            Section {
                let unwatched = facetValues("watch").first
                option(String(localized: .libraryRowsOnlyUnwatched), count: unwatched?.count, selected: filter.watch == "unwatched") {
                    var next = filter
                    next.toggle("watch", "unwatched")
                    apply(next, kind: kind)
                }
            }
            if !filter.isEmpty || kind != nil {
                Section {
                    Button(String(localized: .mediaDiscoveryClearFilters), systemImage: "xmark.circle", role: .destructive) {
                        apply(LibraryFilter(), kind: nil)
                    }
                }
            }
        } label: {
            // 右上角的工具栏位由系统画液态玻璃底，这里只给内容
            HStack(spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
        }
        .accessibilityLabel(String(localized: .mediaFiltersButtonLabel(title)))
        .accessibilityIdentifier("reels-filter")
    }

    /// 一个可勾选的取值：后面带剩余部数；为 0 且没勾着的置灰（勾着的得能取消）
    private func option(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { selected }, set: { _ in action() })) {
            Text(title)
            if let count { Text(String(localized: .libraryStatusTitleCount(count))) }
        }
        .disabled(count == 0 && !selected)
    }

    /// 菜单里这一行的名字：有几类写几类（「电影 / 剧集」或「电影 / 剧集 / 其他」）
    private var kindsTitle: String {
        let labels = facetValues("kinds").map(\.label)
        return labels.isEmpty ? String(localized: .reelsFilterMoviesSeries) : labels.joined(separator: " / ")
    }

    /// 只留观看状态：「其他」没有 TMDB 档案，别的维度带过去只会把它筛空
    private func watchOnly(_ filter: LibraryFilter) -> LibraryFilter {
        var only = LibraryFilter()
        only.watch = filter.watch
        return only
    }

    private func apply(_ filter: LibraryFilter, kind: String?) {
        store?.applyFilter(filter, kind: kind)
    }

    private func facetValues(_ key: String) -> [API.FacetValueView] {
        guard let facets = store?.facets else { return [] }
        switch key {
        case "kinds": return facets.kinds
        case "genres": return facets.genres
        case "decades": return facets.decades
        case "countries": return facets.countries
        case "rating_gte": return facets.ratings
        case "runtimes": return facets.runtimes
        case "watch": return facets.watch
        default: return []
        }
    }

    private func label(_ key: String, _ value: String) -> String? {
        facetValues(key).first { $0.value == value }?.label
    }

    /// 某一维的当前值；多选写第一个再带个数（「剧情等 2 个」），未启用返回 nil
    private func summary(_ key: String, filter: LibraryFilter) -> String? {
        let values = filter.values(of: key)
        guard let first = values.first else { return nil }
        let name = label(key, first) ?? first
        return values.count == 1 ? name : String(localized: .mediaFiltersGenreSummary(name, values.count))
    }

    /// 顶栏寸土寸金：没条件写「全部」，只有一个条件写它的值，多个条件写「已筛选 N 项」
    private func buttonTitle(filter: LibraryFilter, kind: String?) -> String {
        let active = Self.dimensions.map(\.key).filter { !filter.values(of: $0).isEmpty }
        let count = filter.count + (kind == nil ? 0 : 1)
        switch count {
        case 0: return String(localized: .mediaFiltersAll)
        case 1:
            if let kind { return label("kinds", kind) ?? (kind == "tv" ? String(localized: .mediaKindTv) : String(localized: .mediaKindMovie)) }
            if filter.watch == "unwatched" { return String(localized: .reelsNotWatched) }
            return active.first.flatMap { summary($0, filter: filter) } ?? String(localized: .reelsFilterActiveCount(1))
        default: return String(localized: .reelsFilterActiveCount(count))
        }
    }
}
