import SwiftUI

/// 一个媒体库的海报墙（docs/design/tvos-app.md §3.1）：库名 + 排序 / 只看未看 + 一屏 6 列的海报。
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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                header
                TVPosterGrid(items: wall.items ?? []) { item in
                    TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                                 imageURL: api.image(item.posterUrl, .posterCard)) {
                        router.push(.item(libraryId: item.libraryId ?? libraryId, itemId: item.mediaItemId))
                    }
                    .onAppear {
                        if item.mediaItemId == wall.items?.last?.mediaItemId { Task { await wall.loadMore() } }
                    }
                }
                if wall.items == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                } else if wall.items?.isEmpty == true {
                    TVStateView(symbol: "film", title: unwatched ? "没有没看过的了" : "这个库里还没有内容")
                        .frame(height: 500)
                } else if let error = wall.failed {
                    TVStateView(symbol: "wifi.exclamationmark", title: "加载失败", message: error, actionTitle: "重试") {
                        Task { await reload() }
                    }
                    .frame(height: 500)
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .task(id: "\(sort.sort)-\(sort.reversed)-\(unwatched)") { await reload() }
        .onAppear {
            sort = WallSortState.load(sortKey, default: WallSortState(sort: "added_at"), allowed: Self.sorts)
            unwatched = UserDefaults.standard.bool(forKey: sortKey + ".unwatched")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-library-\(libraryId)")
    }

    @Environment(TVRouter.self) private var router

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            Text(library?.name ?? "媒体库")
                .font(.title.weight(.bold))
            if let total = library?.stats.itemCount {
                Text("\(total) 部")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
        .onChange(of: sort) { _, value in value.save(sortKey) }
        .onChange(of: unwatched) { _, value in UserDefaults.standard.set(value, forKey: sortKey + ".unwatched") }
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
    @Environment(TVRouter.self) private var router
    @State private var wall = TVWallLoader()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                Text(name)
                    .font(.title.weight(.bold))
                TVPosterGrid(items: wall.items ?? []) { item in
                    TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                                 imageURL: api.image(item.posterUrl, .posterCard)) {
                        if let libraryId = item.libraryId {
                            router.push(.item(libraryId: libraryId, itemId: item.mediaItemId))
                        }
                    }
                    .onAppear {
                        if item.mediaItemId == wall.items?.last?.mediaItemId { Task { await wall.loadMore() } }
                    }
                }
                if wall.items == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .task {
            let id = collectionId
            await wall.reset { [api] offset, limit in
                try await api.collectionItemsList(collectionId: id, limit: limit, offset: offset)
            }
        }
    }
}

/// 「全部媒体库」：侧边栏放不下时，所有库的卡片
struct TVAllLibrariesView: View {
    @Environment(TVLibraryDirectory.self) private var directory
    @Environment(TVRouter.self) private var router
    @Environment(\.api) private var api

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                Text("全部媒体库")
                    .font(.title.weight(.bold))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.landscapeWidth), spacing: TVMetrics.cardSpacing), count: 3),
                          alignment: .leading, spacing: 60) {
                    ForEach(directory.browsable, id: \.id) { library in
                        TVLandscapeCard(title: library.name, subtitle: "\(library.stats.itemCount) 部",
                                        imageURL: api.image("/libraries/\(library.id)/cover")) {
                            router.push(.library(library.id))
                        }
                    }
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
    }
}

/// 一屏 6 列的海报网格
struct TVPosterGrid<Cell: View>: View {
    let items: [API.LibraryItemView]
    @ViewBuilder let cell: (API.LibraryItemView) -> Cell

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.posterWidth), spacing: TVMetrics.cardSpacing), count: 6),
                  alignment: .leading, spacing: 56) {
            ForEach(items, id: \.mediaItemId) { item in
                cell(item)
            }
        }
    }
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
