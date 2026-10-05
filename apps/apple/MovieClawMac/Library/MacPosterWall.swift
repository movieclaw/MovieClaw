import SwiftUI

/// 海报墙（媒体库、合集、首页一行的「查看全部」、我的收藏共用，docs/design/macos-app.md §4.3）。
///
/// 照 Apple Music 的「资料库 › 专辑」网格：
/// - 列数跟着窗口宽度走（海报 150～200 宽自适应，拉宽窗口多放几列，不把海报拉得巨大）；
/// - 海报下面写片名与年份（鼠标没有焦点，认不出的东西不能只在悬停时出现）；
/// - 悬停：海报压暗，左下浮出播放键（电影续播 / 剧集由服务端定接着看哪一集），右下「⋯」菜单（与右键菜单同一份）；
/// - 页头：大标题 + 灰色总数，排序与筛选放在窗口工具栏里（Mac 的习惯位置）。
/// 点一部进条目详情，落点库优先用服务端给的 `library_id`；分页加载，滚到底接着取。
struct MacPosterWall<Accessory: View>: View {
    let title: String
    var subtitle: String?
    let wall: MacWallLoader
    /// 条目里没带库 id 时的详情落点
    var fallbackLibrary: Int?
    var emptyTitle = "这里还没有内容"
    var emptyMessage: String?
    let retry: () async -> Void
    /// 页头右侧的控件（媒体库的排序与筛选）
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.api) private var api
    @Environment(MacRouter.self) private var router

    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22, alignment: .top)]
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let items = wall.items, !items.isEmpty {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 26) {
                        ForEach(items, id: \.mediaItemId) { item in
                            MacWallCell(item: item, fallbackLibrary: fallbackLibrary)
                                .onAppear {
                                    if item.mediaItemId == items.last?.mediaItemId { Task { await wall.loadMore() } }
                                }
                        }
                    }
                    if wall.loadingMore {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 8)
                    }
                }
                states
            }
            .padding(.horizontal, MacMetrics.edge)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(Color.macPage)
        .navigationTitle(title)
        // 大标题已经写在内容顶上（同 Apple Music 的资料库），工具栏里不再重复
        .toolbar(removing: .title)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .lineLimit(1)
            if let subtitle, wall.items?.isEmpty != true {
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            accessory()
        }
    }

    @ViewBuilder
    private var states: some View {
        if wall.items == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if let error = wall.failed, wall.items?.isEmpty != false {
            MacStateView(symbol: "wifi.exclamationmark", title: "加载失败", message: error, actionTitle: "重试") {
                Task { await retry() }
            }
            .frame(height: 420)
        } else if wall.items?.isEmpty == true {
            MacStateView(symbol: "film", title: emptyTitle, message: emptyMessage)
                .frame(height: 420)
        }
    }
}

extension MacPosterWall where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, wall: MacWallLoader, fallbackLibrary: Int? = nil,
         emptyTitle: String = "这里还没有内容", emptyMessage: String? = nil, retry: @escaping () async -> Void) {
        self.init(title: title, subtitle: subtitle, wall: wall, fallbackLibrary: fallbackLibrary, emptyTitle: emptyTitle,
                  emptyMessage: emptyMessage, retry: retry, accessory: { EmptyView() })
    }
}

/// 海报墙的一格：海报宽度跟着网格的列宽走（`GeometryReader` 读列宽，保持 2:3）
private struct MacWallCell: View {
    let item: API.LibraryItemView
    let fallbackLibrary: Int?
    @Environment(\.api) private var api
    @Environment(MacRouter.self) private var router

    var body: some View {
        GeometryReader { proxy in
            MacPosterCard(
                title: item.title,
                subtitle: Self.subtitle(item),
                imageURL: api.image(item.posterUrl, width: ImageWidth.macCard(200)),
                width: proxy.size.width,
                play: { router.play(PlayRequest(mediaItemId: item.mediaItemId)) },
                menu: MacItemMenu.actions(item: item, libraryId: item.libraryId ?? fallbackLibrary, router: router)
            ) {
                open()
            }
        }
        // 2:3 的海报 + 两行字
        .aspectRatio(2 / 3, contentMode: .fit)
        .padding(.bottom, 38)
        .accessibilityIdentifier("mac-poster-\(item.mediaItemId)")
    }

    private func open() {
        if let libraryId = item.libraryId ?? fallbackLibrary {
            router.push(.item(libraryId: libraryId, itemId: item.mediaItemId))
        }
    }

    /// 「2010」「2019 · 3 季」
    static func subtitle(_ item: API.LibraryItemView) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if item.kind == "tv" {
            let seasons = item.seasons.filter { $0 > 0 }.count
            if seasons > 1 { parts.append("\(seasons) 季") }
        }
        return parts.joined(separator: " · ")
    }
}

/// 一部片的右键菜单 / 悬停「⋯」：播放、查看详情、收藏 / 取消收藏
enum MacItemMenu {
    static func actions(item: API.LibraryItemView, libraryId: Int?, router: MacRouter) -> [MacCardAction] {
        var actions = [MacCardAction(title: "播放", symbol: "play.fill") {
            router.play(PlayRequest(mediaItemId: item.mediaItemId))
        }]
        if let libraryId {
            actions.append(MacCardAction(title: "查看详情", symbol: "info.circle") {
                router.push(.item(libraryId: libraryId, itemId: item.mediaItemId))
            })
        }
        return actions
    }
}

/// 海报墙的分页加载：一页 60 条，滚到底接着取；换了排序 / 筛选整页重来
@Observable
final class MacWallLoader {
    typealias Fetch = (_ offset: Int, _ limit: Int) async throws -> [API.LibraryItemView]

    private(set) var items: [API.LibraryItemView]?
    private(set) var failed: String?
    private(set) var loadingMore = false
    private var hasMore = false
    private var fetch: Fetch?
    private var generation = 0
    private static let pageSize = 60

    func reset(_ fetch: @escaping Fetch) async {
        generation += 1
        let request = generation
        self.fetch = fetch
        do {
            let page = try await fetch(0, Self.pageSize)
            guard request == generation else { return }
            items = page
            hasMore = page.count == Self.pageSize
            failed = nil
        } catch is CancellationError {
        } catch {
            guard request == generation else { return }
            if items == nil { items = [] }
            failed = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !loadingMore, let fetch, let current = items else { return }
        let request = generation
        loadingMore = true
        defer { loadingMore = false }
        if let page = try? await fetch(current.count, Self.pageSize), request == generation {
            let known = Set(current.map(\.mediaItemId))
            items = current + page.filter { !known.contains($0.mediaItemId) }
            hasMore = page.count == Self.pageSize
        }
    }
}

// MARK: - 媒体库

/// 一个媒体库的海报墙：库名 + 总数 + 排序 / 只看没看过的（按库记在本机，同 iPhone、Apple TV 版）
struct MacLibraryView: View {
    let libraryId: Int

    @Environment(\.api) private var api
    @Environment(MacLibraryDirectory.self) private var directory
    @State private var wall = MacWallLoader()
    @State private var sort = WallSortState(sort: "added_at")
    @State private var unwatched = false
    @State private var restored = false

    /// 提供的排序档（同 Apple TV 版）
    private static let sorts = ["added_at", "release_date", "rating", "title"]

    private var library: API.LibraryView? { directory.library(libraryId) }
    private var sortKey: String { "movieclaw.mac.wall-sort.\(libraryId)" }

    var body: some View {
        MacPosterWall(title: library?.name ?? "媒体库", subtitle: library.map { "\($0.stats.itemCount) 部" },
                      wall: wall, fallbackLibrary: libraryId,
                      emptyTitle: unwatched ? "没有没看过的了" : "这个库里还没有内容",
                      emptyMessage: unwatched ? nil : "在网页上扫描媒体库后，影片会出现在这里。",
                      retry: { await reload() }) {
            sortMenu
        }
        .task(id: restored ? "\(sort.sort)-\(sort.reversed)-\(unwatched)" : nil) {
            guard restored else { return }
            await reload()
        }
        .onAppear {
            sort = WallSortState.load(sortKey, default: WallSortState(sort: "added_at"), allowed: Self.sorts)
            unwatched = UserDefaults.standard.bool(forKey: sortKey + ".unwatched")
            restored = true
        }
        .onChange(of: sort) { _, value in value.save(sortKey) }
        .onChange(of: unwatched) { _, value in UserDefaults.standard.set(value, forKey: sortKey + ".unwatched") }
        .accessibilityIdentifier("mac-library-\(libraryId)")
    }

    /// 排序与「只看没看过的」：一枚玻璃下拉，标题行最右（同 Apple Music 资料库右上的排序）
    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sort.sort) {
                ForEach(Self.sorts, id: \.self) { key in
                    Text(HomeRows.preset(key).short(false)).tag(key)
                }
            }
            .pickerStyle(.inline)
            if let direction = WallSortDirections.of(sort.sort) {
                Picker("方向", selection: $sort.reversed) {
                    Text(direction.label(reversed: false)).tag(false)
                    Text(direction.label(reversed: true)).tag(true)
                }
                .pickerStyle(.inline)
            }
            Divider()
            Toggle("只看没看过的", isOn: $unwatched)
        } label: {
            Label(sortLabel, systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .accessibilityIdentifier("mac-library-sort")
    }

    private var sortLabel: String {
        HomeRows.preset(sort.sort).short(sort.reversed) + (unwatched ? " · 未看" : "")
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

/// 合集：同一套海报墙，条目来自合集接口（排序跟着合集自己的设定）
struct MacCollectionView: View {
    let collectionId: Int
    let name: String

    @Environment(\.api) private var api
    @State private var wall = MacWallLoader()

    var body: some View {
        MacPosterWall(title: name, wall: wall, emptyTitle: "合集里还没有内容", retry: { await reload() })
            .task(id: collectionId) { await reload() }
    }

    private func reload() async {
        let id = collectionId
        await wall.reset { [api] offset, limit in
            try await api.collectionItemsList(collectionId: id, limit: limit, offset: offset)
        }
    }
}

// MARK: - 「查看全部」

/// 首页一行的「查看全部」从哪取数：与这一行同一套参数（排序、正倒序、只看未看），进来看到的顺序和行里一致
enum MacWallSource: Hashable {
    case library(id: Int, sort: String, reversed: Bool, unwatched: Bool)
    case mediaKind(kind: String, sort: String, reversed: Bool, unwatched: Bool)
    case collection(id: Int, sort: String, reversed: Bool)
    case favorites(sort: String, reversed: Bool)

    /// 首页这一行对应的来源；「接下来继续」「我的媒体库」两行没有「查看全部」
    init?(_ kind: HomeRows.Kind) {
        switch kind {
        case let .library(library, sort, reversed, unwatched, _, _):
            self = .library(id: library.id, sort: sort, reversed: reversed, unwatched: unwatched)
        case let .mediaKind(kind, _, sort, reversed, unwatched, _, _):
            self = .mediaKind(kind: kind, sort: sort, reversed: reversed, unwatched: unwatched)
        case let .collection(collection, sort, reversed, _):
            self = .collection(id: collection.id, sort: sort, reversed: reversed)
        case let .favorites(sort, reversed):
            self = .favorites(sort: sort, reversed: reversed)
        case .upNext, .libraries, .genres:
            return nil
        }
    }
}

/// 首页一行的「查看全部」与侧边栏的「我的收藏」：行标题 + 海报墙，取数参数与行完全一样
struct MacRowWallView: View {
    let title: String
    let source: MacWallSource

    @Environment(\.api) private var api
    @Environment(MacLibraryDirectory.self) private var directory
    @State private var wall = MacWallLoader()

    var body: some View {
        MacPosterWall(title: title, subtitle: total.map { "\($0) 部" }, wall: wall, fallbackLibrary: fallbackLibrary,
                      emptyTitle: isFavorites ? "还没有收藏" : "这里还没有内容",
                      emptyMessage: isFavorites ? "在条目详情里点 ♡ 收藏，想看的片都会聚到这里。" : nil,
                      retry: { await reload() })
            .task(id: source) { await reload() }
            .accessibilityIdentifier(isFavorites ? "mac-favorites" : "mac-row-wall")
    }

    private var isFavorites: Bool {
        if case .favorites = source { return true }
        return false
    }

    /// 标题旁的总数：只在确切知道时写
    private var total: Int? {
        switch source {
        case let .library(id, sort, _, unwatched):
            return unwatched || sort == "last_played" ? nil : directory.library(id)?.stats.itemCount
        case .favorites:
            return favoritesTotal
        case .mediaKind, .collection:
            return nil
        }
    }

    @State private var favoritesTotal: Int?

    private var fallbackLibrary: Int? {
        if case let .library(id, _, _, _) = source { return id }
        return nil
    }

    private func reload() async {
        let api = api
        switch source {
        case let .library(id, sort, reversed, unwatched):
            // 「最近观看」行只要播过的（w=seen），同首页取数
            let watch: String? = sort == "last_played" ? "seen" : unwatched ? "unwatched" : nil
            let order = HomeRows.preset(sort).direction?.orderParam(reversed: reversed)
            await wall.reset { offset, limit in
                try await api.libraryItemsList(libraryId: id, sort: sort, order: order, limit: limit, offset: offset, w: watch)
            }
        case let .mediaKind(kind, sort, reversed, unwatched):
            let watch: String? = sort == "last_played" ? "seen" : unwatched ? "unwatched" : nil
            let order = HomeRows.preset(sort).direction?.orderParam(reversed: reversed)
            await wall.reset { offset, limit in
                try await api.uiLibraryKindItems(kind: kind, sort: sort, order: order, limit: limit, offset: offset, w: watch)
            }
        case let .collection(id, sort, reversed):
            let order = HomeRows.preset(sort).direction?.orderParam(reversed: reversed)
            await wall.reset { offset, limit in
                try await api.collectionItemsList(collectionId: id, limit: limit, offset: offset, sort: sort, order: order)
            }
        case let .favorites(sort, reversed):
            let unwatchedFirst = sort == "unwatched_first"
            let order = HomeRows.favoritesPreset(sort).direction?.orderParam(reversed: reversed)
            let totalBox = TotalBox()
            await wall.reset { offset, limit in
                let page = try await api.playbackFavorites(limit: limit, offset: offset, unwatchedFirst: unwatchedFirst,
                                                           sort: unwatchedFirst ? "favorited_at" : sort, order: order)
                totalBox.value = page.total
                return page.items.map(\.asLibraryItem)
            }
            favoritesTotal = totalBox.value
        }
    }

    /// 取数闭包里顺手记下收藏总数
    private final class TotalBox: @unchecked Sendable {
        var value: Int?
    }
}
