import Nuke
import SwiftUI

/// 媒体库首页的数据（Web `library-view.tsx` 的取数部分）：原来是页面自己的 @State，搬成跟着账号走的共享对象。
///
/// 搬出来是为了「秒开」：
/// - **快照**：上次加载成功的整页数据存在本机（`PageSnapshots`），登录恢复的那一刻就在后台读出来（`adopt`），
///   冷启动落在媒体库、或第一次切过来时，第一帧就是完整页面，随后静默刷新；
/// - **预取**：落地页不是媒体库时，外壳在空闲时把它刷新好、首屏海报解码进内存（`prefetch`），切过来就是最新的。
///
/// 刷新口径同原页面（同 Web）：库状态、要取的行、合集都没变时不重拉各行条目；瞬时失败不清已有数据，
/// 只让页面挂提示条，一次都没成功过（连快照都没有）才整页报错。
@Observable
final class LibraryHomeStore {
    static let shared = LibraryHomeStore()

    private(set) var libraries: [API.LibraryView]?
    private(set) var collections: [API.CollectionView] = []
    private(set) var upNext: [API.UpNextItemView]?
    private(set) var favorites: API.FavoritesView?
    private(set) var itemsByKey: [String: [API.LibraryItemView]] = [:]
    /// 「电影类型 / 剧集类型」色块：每种类型（movie / tv）的 TMDB 类型分布，与各行条目同一轮取、同一个指纹闸
    private(set) var genresByKind: [String: [API.FacetValueView]] = [:]
    /// 各行条目至少到过一次（或来自快照）
    private(set) var rowsLoaded = false
    /// 最近一次刷新失败（页面据此挂提示条 / 整页报错）
    private(set) var failed = false
    /// 有库在扫描 / 整理时往后 12 秒保持快轮询（同 Web recentlyBusy）
    private(set) var busyUntil: Date = .distantPast
    /// 快照里的首页行清单：偏好还没从服务器拉到时先按它排版。不写回 `LibraryHomePrefs`——
    /// 合集页「显示在首页」以那份清单为底整份保存，不能拿可能过期的快照当底
    private(set) var snapshotRows: [API.HomeRowPref]?

    @ObservationIgnored private var owner: String?
    /// 各行条目上次拉取时的输入指纹（库状态、要取的行、合集），没变就不重拉
    @ObservationIgnored private var rowsFingerprint: Int?
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// 上次写盘的快照指纹：没变就不重写（扫描中 3 秒一轮的轮询，数据多半没变）
    @ObservationIgnored private var savedFingerprint: Int?

    nonisolated static let rowCount = 20
    private nonisolated static let snapshotName = "library-home"

    // MARK: 账号与快照

    /// 以这个账号的身份使用：换了账号就清空旧账号的数据，并读出这个账号的快照。
    /// `synchronously`：冷启动就落在媒体库时当场读完（约 150KB，几毫秒），保证第一帧就是完整页面；
    /// 其余情况在后台线程读，读完再交给主线程
    /// 返回值：后台读快照的任务（同步读、没换账号时为 nil），调用方可以等它读完再做首屏图片预热
    @discardableResult
    func adopt(owner key: String, synchronously: Bool = false) -> Task<Void, Never>? {
        guard key != owner else { return nil }
        owner = key
        libraries = nil
        collections = []
        upNext = nil
        favorites = nil
        itemsByKey = [:]
        genresByKind = [:]
        rowsLoaded = false
        failed = false
        snapshotRows = nil
        rowsFingerprint = nil
        savedFingerprint = nil
        refreshedAt = nil
        inFlight = nil
        if synchronously {
            if let snapshot = PageSnapshots.read(LibraryHomeSnapshot.self, Self.snapshotName, owner: key) { apply(snapshot, owner: key) }
            return nil
        }
        // 读盘立刻在后台线程开始（不等主线程空下来）；读完交回主线程
        let read = Task.detached(priority: .userInitiated) {
            PageSnapshots.read(LibraryHomeSnapshot.self, Self.snapshotName, owner: key)
        }
        return Task {
            if let snapshot = await read.value { apply(snapshot, owner: key) }
        }
    }

    private func apply(_ snapshot: LibraryHomeSnapshot, owner key: String) {
        // 读盘期间换了账号，或网络已经先一步拿到了新数据：快照作废
        guard owner == key, libraries == nil else { return }
        libraries = snapshot.libraries
        collections = snapshot.collections
        upNext = snapshot.upNext
        favorites = snapshot.favorites
        itemsByKey = snapshot.itemsByKey
        genresByKind = snapshot.genresByKind ?? [:]
        snapshotRows = snapshot.rows
        rowsLoaded = true
        PerfTrace.record("snapshot.applied", ["page": "library"])
    }

    // MARK: 刷新

    /// 页面不在屏幕上时的预取：刚刷过就不再打接口
    func prefetch(api: APIClient, owner key: String, maxAge: TimeInterval = 30) async {
        if let refreshedAt, owner == key, Date.now.timeIntervalSince(refreshedAt) < maxAge { return }
        await reload(api: api, owner: key)
    }

    /// 刷新整页；并发调用合并为同一次
    func reload(api: APIClient, owner key: String) async {
        adopt(owner: key)
        if let inFlight { return await inFlight.value }
        let task = Task { await load(api: api, owner: key) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func load(api: APIClient, owner key: String) async {
        let prefs = LibraryHomePrefs.shared
        do {
            // 偏好：拉到为止（之后由自定义页写回共享副本）。失败保持 nil、下一轮轮询再拉——
            // 写成 [] 会让合集页「显示在首页」以空清单为底整份保存，把用户自定义的行覆盖掉。
            // 行清单决定要取哪些数据，所以只有全新安装第一次打开（本次运行没拉到过、也没有快照）才先等它
            if prefs.rows == nil, snapshotRows == nil { await prefs.ensureLoaded(api: api, owner: key) }
            // 接下来继续、收藏两行只看行清单（要不要这两行、收藏按什么排），和偏好、库、合集五个请求同时发——
            // 原先是「偏好 → 库与合集 → 接下来继续与收藏 → 各行」四跳串行
            let planned = Self.plan(prefs.rows ?? snapshotRows ?? [])
            let wantsUpNext = planned.upNext, favoritesQuery = planned.favorites
            async let prefsTask: Void = prefs.ensureLoaded(api: api, owner: key)
            async let libsTask = api.libraryList(scope: "all")
            async let colsTask = try? api.collectionList()
            async let upNextTask = Self.fetchUpNext(api, wantsUpNext)
            async let favoritesTask = Self.fetchFavorites(api, favoritesQuery)
            let libs = try await libsTask
            let cols = await colsTask ?? collections
            await prefsTask
            guard owner == key else { return }
            failed = false
            if libs != libraries { libraries = libs }
            if cols != collections { collections = cols }
            if libs.contains(where: { $0.scanning || $0.organizing }) { busyUntil = .now.addingTimeInterval(12) }
            PerfTrace.pageStage("library", "libraries")

            // 各行条目：库与合集一到就发（不再等接下来继续、收藏）；库状态、要取的行、合集都没变时跳过
            let rowPrefs = prefs.rows ?? snapshotRows ?? []
            let visibleRows = HomeRows.build(prefs: rowPrefs, libraries: libs, collections: cols).filter { !$0.hidden }
            let fetches = Self.rowFetches(visibleRows, libs, api: api)
            let genreKinds = visibleRows.compactMap { row -> String? in
                if case let .genres(kind, _) = row.kind { kind } else { nil }
            }
            var hasher = Hasher()
            hasher.combine(libs)
            hasher.combine(fetches.keys.sorted())
            // 库状态（含作品数）没变，类型分布也不会变：与条目共用同一个指纹闸
            hasher.combine(genreKinds)
            hasher.combine(cols)
            let fingerprint = hasher.finalize()
            let rowsUnchanged = fingerprint == rowsFingerprint
            async let rowsTask = rowsUnchanged ? nil : Self.fetchRows(fetches)
            async let genresTask = rowsUnchanged ? nil : Self.fetchGenres(api, genreKinds)

            // 刷新到的偏好若改了这两行的取法（极少见：别处刚改过自定义首页），按新的再取一次
            let actual = Self.plan(rowPrefs)
            var (latestUpNext, latestFavorites) = await (upNextTask, favoritesTask)
            if actual.upNext != planned.upNext { latestUpNext = await Self.fetchUpNext(api, actual.upNext) }
            if actual.favorites != planned.favorites { latestFavorites = await Self.fetchFavorites(api, actual.favorites) }
            guard owner == key else { return }
            if let latestUpNext { upNext = latestUpNext } else if upNext == nil { upNext = [] }
            if let latestFavorites { favorites = latestFavorites } else if favorites == nil { favorites = API.FavoritesView(items: [], total: 0) }
            PerfTrace.pageStage("library", "upNext+favorites")

            if let next = await rowsTask {
                let genres = await genresTask ?? [:]
                guard owner == key else { return }
                rowsFingerprint = fingerprint
                itemsByKey = next
                genresByKind = genres
                rowsLoaded = true
            }
            refreshedAt = .now
            saveSnapshot(owner: key, rows: prefs.rows)
        } catch is CancellationError {
        } catch {
            if owner == key { failed = true }
        }
    }

    private func saveSnapshot(owner key: String, rows: [API.HomeRowPref]?) {
        guard let libraries, let upNext, let favorites else { return }
        let snapshot = LibraryHomeSnapshot(
            rows: rows ?? snapshotRows, libraries: libraries, collections: collections,
            upNext: upNext, favorites: favorites, itemsByKey: itemsByKey, genresByKind: genresByKind
        )
        let fingerprint = snapshot.hashValue
        guard fingerprint != savedFingerprint else { return }
        savedFingerprint = fingerprint
        PageSnapshots.write(snapshot, Self.snapshotName, owner: key)
    }

    // MARK: 首屏图片

    /// 首屏会显示的图（与 LibraryHomeView 的排版同一口径，交给 `FirstScreenImages` 提前解码进内存）：
    /// 前四行里，接下来继续前 3 张、收藏前 4 张、库卡片封面前 2 张、库 / 类型 / 合集行各前 4 张
    func firstScreenImageURLs(api: APIClient) -> [URL] {
        guard let libraries else { return [] }
        let rows = HomeRows.build(prefs: LibraryHomePrefs.shared.rows ?? snapshotRows ?? [], libraries: libraries, collections: collections)
            .filter { !$0.hidden }
            .prefix(4)
        var urls: [URL?] = []
        for row in rows {
            switch row.kind {
            case .upNext:
                for item in (upNext ?? []).prefix(3) {
                    // 同 UpNextCard.artwork：剧集用分集剧照、电影用背景图；电影缺背景图退回海报
                    let isEpisode = item.kind == "tv"
                    let width = ImageWidth.points(PhoneCardWidth.upNext)
                    if let still = isEpisode ? item.episodeStillUrl : item.backdropUrl {
                        urls.append(api.image(still, width: width))
                    } else if !isEpisode {
                        urls.append(api.image(item.posterUrl, width: width))
                    }
                }
            case .favorites:
                urls += (favorites?.items ?? []).prefix(4).map { api.image($0.posterUrl, width: ImageWidth.points(PhoneCardWidth.homePoster)) }
            case .libraries:
                for library in libraries.filter(\.viewerAccess).prefix(2)
                where library.customCover || !(itemsByKey[Self.coverKey(library.id)] ?? []).isEmpty {
                    urls.append(api.image("/libraries/\(library.id)/cover", width: ImageWidth.points(PhoneCardWidth.libraryCover)))
                }
            case .genres:
                // 色块是本地画的渐变，没有图
                break
            case .library, .mediaKind, .collection:
                urls += (itemsByKey[Self.fetchKey(row)] ?? []).prefix(4).map {
                    api.image($0.posterUrl, width: ImageWidth.points(PhoneCardWidth.homePoster))
                }
            }
        }
        return urls.compactMap { $0 }
    }

    // MARK: 取数

    /// 一行取数的缓存键：同一个库同一种排序同一方向（同一个未看开关）只请求一次
    static func fetchKey(_ row: HomeRows.Row) -> String {
        switch row.kind {
        case let .library(library, sort, reversed, unwatched, _, _): "lib:\(library.id):\(sort):\(reversed):\(unwatched)"
        case let .mediaKind(kind, _, sort, reversed, unwatched, _, _): "kind:\(kind):\(sort):\(reversed):\(unwatched)"
        case let .collection(collection, sort, reversed, _): "col:\(collection.id):\(sort):\(reversed)"
        default: row.id
        }
    }

    /// 库卡片封面用的那批条目，与默认的「最近添加」行共用一份
    static func coverKey(_ libraryId: Int) -> String { "lib:\(libraryId):added_at:false:false" }

    /// 收藏行的查询参数
    private struct FavoritesQuery: Equatable, Sendable {
        var unwatchedFirst: Bool
        var sort: String
        var order: String?
    }

    /// 行清单里「接下来继续」「收藏」两行怎么取：要不要取、收藏按什么排（与库、合集无关，行清单一定就能定）
    private struct Plan: Equatable {
        var upNext: Bool
        var favorites: FavoritesQuery?
    }

    private static func plan(_ rowPrefs: [API.HomeRowPref]) -> Plan {
        let rows = HomeRows.build(prefs: rowPrefs, libraries: [], collections: []).filter { !$0.hidden }
        var favorites: FavoritesQuery?
        if let row = rows.first(where: { if case .favorites = $0.kind { true } else { false } }), case let .favorites(sort, reversed) = row.kind {
            // 「未看优先」是首页这一行的默认（全量页不传，保持收藏时间序）
            favorites = FavoritesQuery(
                unwatchedFirst: sort == "unwatched_first",
                sort: sort == "unwatched_first" ? "favorited_at" : sort,
                order: HomeRows.favoritesPreset(sort).direction?.orderParam(reversed: reversed)
            )
        }
        return Plan(upNext: rows.contains { $0.kind == .upNext }, favorites: favorites)
    }

    private nonisolated static func fetchUpNext(_ api: APIClient, _ wanted: Bool) async -> [API.UpNextItemView]? {
        guard wanted else { return nil }
        return (try? await api.playbackUpNext(limit: rowCount))?.items
    }

    private nonisolated static func fetchFavorites(_ api: APIClient, _ query: FavoritesQuery?) async -> API.FavoritesView? {
        guard let query else { return nil }
        return try? await api.playbackFavorites(limit: rowCount, offset: 0, unwatchedFirst: query.unwatchedFirst, sort: query.sort, order: query.order)
    }

    /// 各行条目并发取回；单行失败按空行处理（同原来）
    private nonisolated static func fetchRows(_ fetches: [String: @Sendable () async throws -> [API.LibraryItemView]]) async -> [String: [API.LibraryItemView]] {
        await withTaskGroup(of: (String, [API.LibraryItemView]).self) { group in
            for (key, fetch) in fetches {
                group.addTask { (key, (try? await fetch()) ?? []) }
            }
            var next: [String: [API.LibraryItemView]] = [:]
            for await (key, items) in group { next[key] = items }
            return next
        }
    }

    /// 类型色块：每种类型的 TMDB 类型分布并发取回；单种失败按空处理（那一区不画）
    private nonisolated static func fetchGenres(_ api: APIClient, _ kinds: [String]) async -> [String: [API.FacetValueView]] {
        await withTaskGroup(of: (String, [API.FacetValueView]).self) { group in
            for kind in kinds {
                group.addTask { (kind, (try? await api.uiLibraryKindGenres(kind: kind)) ?? []) }
            }
            var next: [String: [API.FacetValueView]] = [:]
            for await (kind, genres) in group { next[kind] = genres }
            return next
        }
    }

    /// 显示中的行各自要打的请求，按缓存键去重；排序与截断交给服务端
    private static func rowFetches(_ rows: [HomeRows.Row], _ libs: [API.LibraryView], api: APIClient) -> [String: @Sendable () async throws -> [API.LibraryItemView]] {
        var fetches: [String: @Sendable () async throws -> [API.LibraryItemView]] = [:]
        let limit = rowCount
        for row in rows {
            switch row.kind {
            case let .library(library, sort, reversed, unwatched, _, _):
                // 「最近观看」行只要播过的（w=seen）
                let watch: String? = sort == "last_played" ? "seen" : unwatched ? "unwatched" : nil
                let order = HomeRows.preset(sort).direction?.orderParam(reversed: reversed)
                let id = library.id
                fetches[fetchKey(row)] = { try await api.libraryItemsList(libraryId: id, sort: sort, order: order, limit: limit, w: watch) }
            case let .mediaKind(kind, _, sort, reversed, unwatched, _, _):
                // 与库行同一套取数规则，只是来源换成按类型的跨库墙（同一部片跨库只出现一次）
                let watch: String? = sort == "last_played" ? "seen" : unwatched ? "unwatched" : nil
                let order = HomeRows.preset(sort).direction?.orderParam(reversed: reversed)
                fetches[fetchKey(row)] = { try await api.uiLibraryKindItems(kind: kind, sort: sort, order: order, limit: limit, w: watch) }
            case let .collection(collection, sort, reversed, _):
                let order = HomeRows.preset(sort).direction?.orderParam(reversed: reversed)
                let id = collection.id
                fetches[fetchKey(row)] = { try await api.collectionItemsList(collectionId: id, limit: limit, sort: sort, order: order) }
            case .libraries:
                for library in libs where library.viewerAccess {
                    let key = coverKey(library.id)
                    let id = library.id
                    if fetches[key] == nil {
                        fetches[key] = { try await api.libraryItemsList(libraryId: id, sort: "added_at", limit: limit) }
                    }
                }
            default: break
            }
        }
        return fetches
    }
}

/// 媒体库首页的快照（`PageSnapshots`）：整页渲染要的全部数据
nonisolated struct LibraryHomeSnapshot: Codable, Hashable, Sendable {
    var rows: [API.HomeRowPref]?
    var libraries: [API.LibraryView]
    var collections: [API.CollectionView]
    var upNext: [API.UpNextItemView]
    var favorites: API.FavoritesView
    var itemsByKey: [String: [API.LibraryItemView]]
    /// 可空：升级前写下的快照没有这一项，照常能读
    var genresByKind: [String: [API.FacetValueView]]?
}
