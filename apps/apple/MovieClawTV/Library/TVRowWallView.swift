import SwiftUI

/// 首页一行的「查看全部」从哪取数：与这一行同一套参数（排序、正倒序、只看未看），进来看到的顺序和行里一致
enum TVWallSource: Hashable {
    /// 某个媒体库（「最近添加」「最近观看」……）
    case library(id: Int, sort: String, reversed: Bool, unwatched: Bool)
    /// 按类型的跨库墙（「全部电影」）：同一部片跨库只出现一次
    case mediaKind(kind: String, sort: String, reversed: Bool, unwatched: Bool)
    /// 合集
    case collection(id: Int, sort: String, reversed: Bool)
    /// 我的收藏
    case favorites(sort: String, reversed: Bool)
    /// 首页「按类型找电影 / 剧集」色块：按一个 TMDB 类型筛好的跨库墙（最近添加在前），count 是色块上的部数
    case genre(kind: String, genre: Int, count: Int)

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
            // 类型色块行没有「查看全部」：每一格自己就是一面墙的入口
            return nil
        }
    }
}

/// 首页一行的「查看全部」（docs/design/tvos-app.md §3.4）：行标题 + 海报墙（`TVPosterWall`），分页加载、滚到底接着取。
///
/// 首页每行只取前 20 部（`LibraryHomeStore.rowCount`），这一页把整行取全，取数参数与行完全一样
/// （同 iPhone 首页各行的「查看全部」）。不另给排序：排序跟着这一行走，在网页上自定义首页时设定。
/// 选中一部进条目详情，详情落点库优先用服务端给的 `library_id`（跨库墙、合集、收藏里的片来自不同的库）。
struct TVRowWallView: View {
    let title: String
    let source: TVWallSource

    @Environment(\.api) private var api
    @Environment(TVLibraryDirectory.self) private var directory
    @State private var wall = TVWallLoader()

    var body: some View {
        TVPosterWall(title: title, subtitle: total.map { "\($0) 部" }, wall: wall, fallbackLibrary: fallbackLibrary,
                     retry: { await reload() })
            .task { await reload() }
            .accessibilityIdentifier("tv-row-wall")
    }

    /// 标题旁的总数：只在确切知道时写（媒体库没加筛选时用库的统计，收藏用接口给的总数）
    private var total: Int? {
        switch source {
        case let .library(id, sort, _, unwatched):
            return unwatched || sort == "last_played" ? nil : directory.library(id)?.stats.itemCount
        case .favorites:
            return LibraryHomeStore.shared.favorites?.total
        case let .genre(_, _, count):
            return count
        case .mediaKind, .collection:
            return nil
        }
    }

    /// 条目里没带库 id 时的详情落点（单库墙里的片就在这个库）
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
        case let .genre(kind, genre, _):
            let g = String(genre)
            await wall.reset { offset, limit in
                try await api.uiLibraryKindItems(kind: kind, sort: "added_at", limit: limit, offset: offset, g: g)
            }
        case let .favorites(sort, reversed):
            // 「未看优先」是首页收藏行的一档：同首页取数，进来的顺序与行里一致
            let unwatchedFirst = sort == "unwatched_first"
            let order = HomeRows.favoritesPreset(sort).direction?.orderParam(reversed: reversed)
            await wall.reset { offset, limit in
                try await api.playbackFavorites(limit: limit, offset: offset, unwatchedFirst: unwatchedFirst,
                                                sort: unwatchedFirst ? "favorited_at" : sort, order: order)
                    .items.map(\.asLibraryItem)
            }
        }
    }
}
