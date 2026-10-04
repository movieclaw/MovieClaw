import SwiftUI

/// 一个媒体库的海报墙（docs/design/tvos-app.md §3.1）：库名 + 排序 / 只看未看 + 海报墙（`TVPosterWall`）。
///
/// 筛选只保留电视上用得着的两样：排序（最近添加 / 最近上映 / 评分 / 片名）与「只看未看」，
/// 按库记在本机（同 iPhone 版海报墙的排序记忆）。条目分页加载，滚到底自动接着取。
struct TVLibraryView: View {
    let libraryId: Int

    @Environment(\.api) private var api
    @Environment(TVLibraryDirectory.self) private var directory
    @State private var wall = TVWallLoader()
    @State private var sort = WallSortState(sort: "added_at")
    @State private var unwatched = false

    /// 电视上提供的排序档
    private static let sorts = ["added_at", "release_date", "rating", "title"]

    private var library: API.LibraryView? { directory.library(libraryId) }
    private var sortKey: String { "movieclaw.tv.wall-sort.\(libraryId)" }

    var body: some View {
        TVPosterWall(title: library?.name ?? "媒体库", subtitle: library.map { "\($0.stats.itemCount) 部" },
                     wall: wall, fallbackLibrary: libraryId,
                     emptyTitle: unwatched ? "没有没看过的了" : "这个库里还没有内容",
                     retry: { await reload() }) {
            sortMenu
        }
        .task(id: "\(sort.sort)-\(sort.reversed)-\(unwatched)") { await reload() }
        .onAppear {
            sort = WallSortState.load(sortKey, default: WallSortState(sort: "added_at"), allowed: Self.sorts)
            unwatched = UserDefaults.standard.bool(forKey: sortKey + ".unwatched")
        }
        .onChange(of: sort) { _, value in value.save(sortKey) }
        .onChange(of: unwatched) { _, value in UserDefaults.standard.set(value, forKey: sortKey + ".unwatched") }
        .accessibilityIdentifier("tv-library-\(libraryId)")
    }

    /// 排序与「只看未看」：标题行最右边一枚按钮
    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sort.sort) {
                ForEach(Self.sorts, id: \.self) { key in
                    Text(HomeRows.preset(key).short(false)).tag(key)
                }
            }
            Toggle("只看没看过的", isOn: $unwatched)
        } label: {
            Label(sortLabel, systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("tv-library-sort")
    }

    private var sortLabel: String {
        HomeRows.preset(sort.sort).short(false) + (unwatched ? " · 未看" : "")
    }

    private func reload() async {
        let id = libraryId
        let sortValue = sort.sort
        let order = WallSortDirections.of(sortValue)?.orderParam(reversed: sort.reversed)
        let watch = unwatched ? "unwatched" : nil
        await wall.reset { [api] offset, limit in
            try await api.libraryItemsList(libraryId: id, sort: sortValue, order: order, limit: limit, offset: offset, w: watch)
        }
    }
}

/// 合集：同一套海报墙，条目来自合集接口
struct TVCollectionView: View {
    let collectionId: Int
    let name: String

    @Environment(\.api) private var api
    @State private var wall = TVWallLoader()

    var body: some View {
        TVPosterWall(title: name, wall: wall, emptyTitle: "合集里还没有内容", retry: { await reload() })
            .task { await reload() }
    }

    private func reload() async {
        let id = collectionId
        await wall.reset { [api] offset, limit in
            try await api.collectionItemsList(collectionId: id, limit: limit, offset: offset)
        }
    }
}

/// 海报墙（媒体库、合集、首页一行的「查看全部」共用，docs/design/tvos-app.md §3.4；影人页用同一套版式 `TVWallLayout`）。
///
/// 照 Disney+ / Netflix 电视版的海报墙（2026-10-03 用户嫌原来的不够精致）：
/// - 海报放大到一屏 5 列（333 宽，原来 6 列 266），间距收紧（左右 24、上下 40，原来 32 / 52）；
/// - 海报下面不挂片名：海报自带片名，挂字一行行参差不齐、行距也被撑大（同 Disney+）；片名写进无障碍标签；
/// - 背景是焦点所在那一部的剧照，压暗、模糊、交叉淡入：整页跟着焦点有了颜色，不是一片死黑（同 Apple TV App 的影库）；
/// - 标题行：大标题 + 灰色的总数，右边放这一页自己的按钮（媒体库的排序）。
/// 选中一部进条目详情，落点库优先用服务端给的 `library_id`；分页加载，滚到底接着取。
struct TVPosterWall<Accessory: View>: View {
    let title: String
    var subtitle: String?
    let wall: TVWallLoader
    /// 条目里没带库 id 时的详情落点
    var fallbackLibrary: Int?
    var emptyTitle = "这里还没有内容"
    let retry: () async -> Void
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @FocusState private var focused: Int?
    /// 背景跟着的那一部：焦点停稳 0.2 秒再换，按住方向键一路划过去时不逐张闪
    @State private var backdropItem: API.LibraryItemView?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 36) {
                header
                LazyVGrid(columns: TVWallLayout.columns, alignment: .leading, spacing: TVWallLayout.rowSpacing) {
                    ForEach(wall.items ?? [], id: \.mediaItemId) { item in
                        TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                                     imageURL: api.image(item.posterUrl, width: ImageWidth.tvCard(TVWallLayout.posterWidth)),
                                     width: TVWallLayout.posterWidth,
                                     caption: .hidden) {
                            if let libraryId = item.libraryId ?? fallbackLibrary {
                                router.push(.item(libraryId: libraryId, itemId: item.mediaItemId))
                            }
                        }
                        .focused($focused, equals: item.mediaItemId)
                        .accessibilityIdentifier("tv-poster-\(item.mediaItemId)")
                        .onAppear {
                            if item.mediaItemId == wall.items?.last?.mediaItemId { Task { await wall.loadMore() } }
                        }
                    }
                }
                // 网格横贯整屏做成焦点区：上面的按钮往下、往左都先进网格、落到最近的那张。
                // 库里只有一两部、海报都挤在左边时，右上角按钮的正下方是空的，焦点会卡在它上面下不来（实测）
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                states
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.top, 20)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background { backdrop }
        .task(id: focused) {
            guard let id = focused, id != backdropItem?.mediaItemId else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            backdropItem = wall.items?.first { $0.mediaItemId == id }
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
            }
            Spacer(minLength: 40)
            accessory()
        }
        // 标题行横贯整屏做成焦点区：从第一排任何一张往上都能到右边的排序按钮（它只占右上角一小块，
        // 正上方不是它的海报往上会没有去处）
        .focusSection()
    }

    @ViewBuilder
    private var states: some View {
        if wall.items == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if let error = wall.failed {
            TVStateView(symbol: "wifi.exclamationmark", title: "加载失败", message: error, actionTitle: "重试") {
                Task { await retry() }
            }
            .frame(height: 500)
        } else if wall.items?.isEmpty == true {
            TVStateView(symbol: "film", title: emptyTitle)
                .frame(height: 500)
        }
    }

    /// 焦点那一部的剧照（按模糊垫底的小图取，够用且轻）：放大模糊、压暗，交叉淡入
    private var backdrop: some View {
        TVBlurredBackdrop(url: backdropItem.flatMap {
            api.image($0.backdropUrl ?? $0.posterUrl, width: ImageWidth.points(TVMetrics.blurredBackdropWidth))
        })
            .ignoresSafeArea()
    }
}

extension TVPosterWall where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, wall: TVWallLoader, fallbackLibrary: Int? = nil,
         emptyTitle: String = "这里还没有内容", retry: @escaping () async -> Void) {
        self.init(title: title, subtitle: subtitle, wall: wall, fallbackLibrary: fallbackLibrary,
                  emptyTitle: emptyTitle, retry: retry, accessory: { EmptyView() })
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
}

/// 海报墙的分页加载：一页 60 条，滚到底接着取；换了排序 / 筛选整页重来
@Observable
final class TVWallLoader {
    typealias Fetch = (_ offset: Int, _ limit: Int) async throws -> [API.LibraryItemView]

    private(set) var items: [API.LibraryItemView]?
    private(set) var failed: String?
    private var hasMore = false
    private var loading = false
    private var fetch: Fetch?
    private static let pageSize = 60

    func reset(_ fetch: @escaping Fetch) async {
        self.fetch = fetch
        do {
            let page = try await fetch(0, Self.pageSize)
            items = page
            hasMore = page.count == Self.pageSize
            failed = nil
        } catch is CancellationError {
        } catch {
            if items == nil { items = [] }
            failed = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !loading, let fetch, let current = items else { return }
        loading = true
        defer { loading = false }
        if let page = try? await fetch(current.count, Self.pageSize) {
            let known = Set(current.map(\.mediaItemId))
            items = current + page.filter { !known.contains($0.mediaItemId) }
            hasMore = page.count == Self.pageSize
        }
    }
}
