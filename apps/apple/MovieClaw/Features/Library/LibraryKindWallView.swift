import SwiftUI

/// 按类型的跨库海报墙（Web `kind-wall-view.tsx`，路由 `/library/kind/{movie|tv|video}`）：
/// 首页「全部电影」那一行点「查看全部」进来的地方（docs/design/library-home-perspective.md §8）。
///
/// 成员 = 当前身份可见、没被管理员排除出首页的同类型库，同一部片在 4K 库和普通库里各有一份时只出现一格；
/// 每格点进它自己的落点库（服务端给的 `library_id`）。口径全部在服务端（`/libraries/kinds/{kind}`），
/// 这里只管翻页与排序。
///
/// 刻意比单库页薄（同 Web）：没有筛选条（facet 统计按单库算，跨库版本留到下一期）、没有索引条与图床浏览，只有排序。
/// 从详情页返回只整窗对账（`refresh`），不清空窗口、不动滚动位置；换排序才回墙首。
///
/// 带 `genre`（`?g=878`）时是首页「电影类型」色块的落点：墙按这个 TMDB 类型筛好，页头换成与色块同一块网格渐变。
struct LibraryKindWallView: View {
    let kind: String
    var genre: Int?
    @Environment(\.api) private var api
    @State private var pager = LibraryWallPager<API.LibraryItemView>(pageSize: 60)
    @State private var sort: WallSortState
    @State private var libraryCount: Int?

    init(kind: String, genre: Int? = nil) {
        self.kind = kind
        self.genre = genre
        _sort = State(initialValue: WallSortState.load(
            Self.sortKey(kind), default: WallSortState(sort: "default"), allowed: Self.sortOptions(kind).map(\.value)
        ))
    }

    /// 排序记在本机，键与 Web localStorage 同名，按类型各一份
    private static func sortKey(_ kind: String) -> String { "movieclaw.library.kind-wall-sort.\(kind)" }

    /// 默认档是「最近添加」——这面墙从首页的「全部电影 · 最近添加」点进来，进来之后顺序不该变。
    /// 其余档与单库墙同一套；其他视频没有评分与上映时间，列出来只会排出一面按 id 的墙，按类型裁掉
    private static func sortOptions(_ kind: String) -> [WallSortMenu.Option] {
        let all: [WallSortMenu.Option] = [
            .init(value: "default", label: "最近添加", direction: WallSortDirections.of("added_at")),
            .init(value: "title", label: "按标题", direction: WallSortDirections.of("title")),
            .init(value: "release_date", label: "按上映时间", direction: WallSortDirections.of("release_date")),
            .init(value: "rating", label: "按评分", direction: WallSortDirections.of("rating")),
            .init(value: "runtime", label: "按片长", direction: WallSortDirections.of("runtime")),
            .init(value: "size", label: "按体积", direction: WallSortDirections.of("size")),
            .init(value: "last_played", label: "最近观看", direction: WallSortDirections.of("last_played")),
        ]
        return kind == "video" ? all.filter { $0.value != "rating" && $0.value != "release_date" } : all
    }

    private var genreName: String? { genre.map { GenrePalette.tones[$0]?.name ?? "类型 \($0)" } }
    private var label: String { genreName ?? "全部\(HomeRows.mediaKindLabel(kind))" }
    /// 筛选参数 g：只带预设的这一个类型
    private var genreQuery: String? { genre.map(String.init) }
    private var effectiveSort: String { sort.sort == "default" ? "added_at" : sort.sort }
    private var order: String? { WallSortDirections.of(effectiveSort)?.orderParam(reversed: sort.reversed) }
    private var empty: Bool { pager.items?.isEmpty == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
            }
            .padding(.bottom, 32)
        }
        .appBackground()
        .navigationTitle(label)
        // 类型页的大字写在渐变页头里，导航栏只留小标题，不叠两遍
        .navigationBarTitleDisplayMode(genre == nil ? .automatic : .inline)
        // 首载与换排序分开：`.task` 每次重新出现都会重跑，放在里面的 reset 会让从详情页返回时整面墙清空、跳回墙首
        .task {
            if pager.items == nil { await reload() }
        }
        .onChange(of: sort) {
            sort.save(Self.sortKey(kind))
            Task { await reload() }
        }
        .onAppear { if pager.items != nil { Task { await refresh() } } }
        .refreshable { await refresh() }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let genre {
                // 色块的落点：页头就是那块色块放大，进来的人一眼知道自己在哪
                GenreArtwork(genreId: genre)
                    .frame(height: 116)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label)
                                .font(.system(size: 26, weight: .semibold))
                                .tracking(1)
                            if let total = pager.total, let libraryCount {
                                Text("\(total) 部\(HomeRows.mediaKindLabel(kind)) · 来自 \(libraryCount) 个库")
                                    .font(.subheadline.monospacedDigit())
                                    .opacity(0.75)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.08)], startPoint: .top, endPoint: .center), lineWidth: 0.75)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("kind-wall-genre-header")
            }
            // 概况读失败时（libraryCount 为 nil）只说口径，不挂一句永远的「正在读取」；类型页的数量写在页头里
            if genre == nil {
                Text(pager.items == nil ? "正在读取…"
                    : libraryCount == 0 ? "还没有可浏览的\(HomeRows.mediaKindLabel(kind))库"
                    : libraryCount.map { "\(pager.total ?? 0) 部作品 · 来自 \($0) 个库，同一部片只算一次" } ?? "同一部片只算一次")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityIdentifier("kind-wall-summary")
            }
            if pager.items != nil, !empty {
                WallSortMenu(options: Self.sortOptions(kind), state: $sort)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
        if let failed = pager.failed, pager.items == nil {
            ErrorState(title: "加载失败", message: failed) { await reload() }
        } else if pager.items == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        } else if let items = pager.items, !items.isEmpty {
            // 其他视频是 16:9 抓帧，走宽列；影视按 2:3 钉死框比例——跨库的一面墙里偶有没刮到海报的本地条目，
            // 钉死后每格等高、片名落在一条线上（同 Web）
            let wide = kind == "video"
            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 200 : 140), spacing: 12, alignment: .top)], alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    LibraryInventoryCell(item: item, libraryId: item.libraryId ?? 0, frameAspect: wide ? 16 / 9 : Theme.posterAspect,
                                         showRating: effectiveSort == "rating")
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            WallLoadMoreFooter(hasMore: pager.hasMore, start: pager.start, loaded: items.count, total: pager.total) {
                await pager.loadMore()
            }
        }
    }

    /// 总数与组成库只在墙首取一次：往下翻页时数量不变，不必每页多打一个请求
    private func loadSummary() async {
        guard let summary = try? await api.uiLibraryKindSummary(kind: kind, g: genreQuery) else { return }
        pager.total = summary.itemCount
        libraryCount = summary.libraryIds.count
    }

    private func reload() async {
        let api = self.api
        let kind = self.kind
        let sort = effectiveSort
        let order = self.order
        let genre = genreQuery
        await loadSummary()
        await pager.reset({ offset, limit in
            try await api.uiLibraryKindItems(kind: kind, sort: sort, order: order, limit: limit, offset: offset, g: genre)
        })
    }

    /// 从详情页返回 / 下拉：按已加载的页数整窗重拉（在详情页删掉的片要跟着消失）
    private func refresh() async {
        await loadSummary()
        await pager.refresh()
    }
}
