import NukeUI
import SwiftUI

/// 媒体库首页（Web `library-view.tsx`，路由 `/library`）。
///
/// 页面 = 标题统计 + 按 `ui.preferences.home.rows` 合并出的行清单：
/// 接下来继续 / 我的收藏 / 我的媒体库（真实库 + 首页合集虚拟库卡片）/ 每库一行 / 合集行。
/// 只负责「看」，排序与行的增删改全部收进自定义页。
///
/// 刷新策略同 Web：有库在扫描/整理时 3 秒一轮（结束后再保持 12 秒快轮询，接住监控去抖触发的连环扫描），
/// 元数据刷新 5 秒，有文件写入中等待入账 10 秒，完全空闲 30 秒；
/// 库状态、要取的行、合集都没变时不重拉各行条目（空闲时每 30 秒不必打 1+N 个请求）。
/// 瞬时失败不清已有数据，只挂提示条；一次都没成功过才整页报错。
struct LibraryHomeView: View {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model
    @Environment(\.pageWarmup) private var warmup
    @State private var prefs = LibraryHomePrefs.shared
    /// 整页数据在跟着账号走的共享对象里（快照秒开、外壳预取，见 LibraryHomeStore）
    private var store: LibraryHomeStore { .shared }
    private var libraries: [API.LibraryView]? { store.libraries }
    private var collections: [API.CollectionView] { store.collections }
    private var upNext: [API.UpNextItemView]? { store.upNext }
    private var favorites: API.FavoritesView? { store.favorites }
    private var itemsByKey: [String: [API.LibraryItemView]] { store.itemsByKey }
    private var genresByKind: [String: [API.LibraryKindGenreView]] { store.genresByKind }
    private var failed: Bool { store.failed }
    /// 扫描/整理结束后的 12 秒快轮询窗口还没过（同 Web recentlyBusy）。必须是状态而不是在 body 里
    /// 现算 `Date.now < busyUntil`：数据不变时 body 不会重算，间隔就会一直停在 3 秒
    @State private var recentlyBusy = false
    @State private var clearingLibrary = false
    /// 片段（docs/design/reels.md）：蜂窝网络下进入前的确认
    @State private var confirmingReelsOnCellular = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(.bottom, 32)
        }
        .appBackground()
        .navigationTitle("媒体库")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            // 页面级动作都是低频的配置入口，收进一个 ⋯ 菜单：顶栏与发现、订阅页一致，
            // 只有「一个页面按钮 + 最右的搜索圆钮」。原先平铺的 list.bullet / 齿轮图标
            // 在 iOS 里分别像「切列表视图」「App 设置」，含义对不上（2026-09-26 用户要求整理）
            // 「片段」是 2026-09-29 用户要求放在媒体库顶部试验的入口（docs/design/reels.md），图标用圆圈播放
            // （不和底部「媒体库」页签的 play.square.stack 撞）。不常用：只留图标、排在最左，
            // 与 ⋯ 合成一个玻璃胶囊，顶栏只剩「▶ ⋯ · 搜索」两组（2026-10-05 用户要求，原先三颗圆钮又多又乱）
            ToolbarItem(placement: .topBarTrailing) {
                Button { openReels() } label: {
                    Image(systemName: "play.circle")
                }
                .accessibilityLabel("片段")
                .accessibilityIdentifier("library-reels")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("自定义首页", systemImage: "slider.horizontal.3") { router.push(.libraryCustomize) }
                        .accessibilityIdentifier("library-customize")
                    Button("全部合集", systemImage: "rectangle.stack") { router.push(.allCollections) }
                    if permissions.canManageLibraries {
                        Button("管理媒体库", systemImage: "externaldrive") { router.push(.libraryManage()) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多操作")
                .accessibilityIdentifier("library-more")
            }
        }
        .refreshable { await reload() }
        .onAppear {
            guard !warmup else { return }
            PerfTrace.pageAppeared("library")
            if dataComplete { PerfTrace.pageDataReady("library") }
            Task { await reload() }
            // 「继续观看」多半从这里点：先把起播要用的连接连好（见 PlaybackPreconnect）
            PlaybackPreconnect.warm(api: api)
        }
        // 自定义首页是盖在上面的弹出表单，关掉时这里不会再触发 onAppear：行清单一变就刷新
        // （store 按指纹只重拉变了的行；表单开着时首页在下面跟着变）
        .onChange(of: prefs.rows) { old, _ in
            if old != nil, !warmup { Task { await reload() } }
        }
        .onChange(of: dataComplete) { _, complete in
            if complete, !warmup { PerfTrace.pageDataReady("library") }
        }
        .polling(every: pollInterval) { await reload() }
        .task(id: store.busyUntil) {
            // 窗口到期把 recentlyBusy 落回 false，轮询间隔随之回到慢档
            let remaining = store.busyUntil.timeIntervalSinceNow
            recentlyBusy = remaining > 0
            guard remaining > 0 else { return }
            try? await Task.sleep(for: .seconds(remaining))
            if !Task.isCancelled { recentlyBusy = false }
        }
        .sheet(isPresented: $clearingLibrary) {
            ClearLibraryHistorySheet(libraries: visibleLibraries) { Task { await reload() } }
        }
        .alert("正在使用移动网络", isPresented: $confirmingReelsOnCellular) {
            Button("进入") { router.push(.reels) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("片段直接播放原片，可能很耗流量：4K 影片看完一段约 300MB。确定进入吗？")
        }
    }

    /// 片段在媒体库的导航栈里压栈打开（底部标签栏保留）；蜂窝 / 计费网络先确认一次（一期不限网络，只提醒）
    private func openReels() {
        let network = NetworkCost.shared
        if network.interface == "cellular" || network.isMetered {
            confirmingReelsOnCellular = true
        } else {
            router.push(.reels)
        }
    }

    // MARK: 派生状态

    private var visibleLibraries: [API.LibraryView] { (libraries ?? []).filter(\.viewerAccess) }

    /// 整页数据都到了（打点用，见 PerfTrace）：库、接下来继续、收藏、各行条目
    private var dataComplete: Bool {
        guard let libraries else { return false }
        return libraries.isEmpty || (upNext != nil && favorites != nil && store.rowsLoaded)
    }

    private var rows: [HomeRows.Row] {
        HomeRows.build(prefs: prefs.rows ?? store.snapshotRows ?? [], libraries: libraries ?? [], collections: collections)
    }

    private var homeCollections: [API.CollectionView] { HomeRows.pinnedCollections(rows) }

    private var pollInterval: Double {
        let libs = libraries ?? []
        if libs.contains(where: { $0.scanning || $0.organizing }) || recentlyBusy { return 3 }
        if libs.contains(where: { $0.metadataRefresh?.refreshing == true }) { return 5 }
        if libs.contains(where: { !$0.scanning && !$0.organizing && ($0.lastScan?.deferred ?? 0) > 0 }) { return 10 }
        return 30
    }

    // MARK: 页头

    /// 统计行。「全部合集」的固定入口在右上角 ⋯ 菜单里（「我的媒体库」行标题右侧另有一个顺手入口），
    /// 那一行被隐藏时不必再往页头挪
    private var header: some View {
        Text(failed && libraries == nil ? "暂时无法获取媒体库统计，正在自动重试" : libraryStatsSummary(libraries == nil ? nil : visibleLibraries))
            .font(.subheadline)
            .foregroundStyle(Theme.textMuted)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("library-stats")
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
        if libraries == nil, !failed {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在加载媒体库…")
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 64)
        } else if libraries == nil, failed {
            VStack(spacing: 12) {
                Text("媒体库加载失败").font(.subheadline).foregroundStyle(Theme.textMuted)
                Button("重试") { Task { await reload() } }.buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 64)
        } else if let libraries {
            if failed {
                Text("与后端通信失败，正在自动重试；下方显示的是最近一次成功加载的数据")
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.99, green: 0.9, blue: 0.54))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warning.opacity(0.1), in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.warning.opacity(0.25)))
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 16)
            }
            if libraries.isEmpty {
                EmptyState(
                    systemImage: "film.stack",
                    title: permissions.canManageLibraries ? "为收藏准备一个家" : "还没有可浏览的媒体库",
                    message: permissions.canManageLibraries
                        ? "创建电影库或剧集库，选好根目录后，订阅完成的内容会自动整理到这里。"
                        : "当前账号暂时没有可浏览的媒体库，请联系管理员分配媒体库权限。",
                    actionTitle: permissions.canManageLibraries ? "创建第一个媒体库" : nil,
                    action: permissions.canManageLibraries ? { router.push(.libraryManage(create: true)) } : nil
                )
                .padding(.top, 40)
            } else {
                let visibleRows = rows.filter { !$0.hidden }
                if visibleRows.isEmpty {
                    VStack(spacing: 6) {
                        Text("首页空空如也").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("所有行都被隐藏了。到「自定义首页」挑几行回来，或恢复默认。")
                            .font(.footnote).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
                        Button("自定义首页") { router.push(.libraryCustomize) }
                            .buttonStyle(.glass)
                            .padding(.top, 10)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.white.opacity(0.15)))
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 64)
                    .accessibilityIdentifier("home-all-hidden")
                }
                ForEach(visibleRows) { row in
                    rowView(row)
                }
            }
        }
    }

    // MARK: 行

    @ViewBuilder
    private func rowView(_ row: HomeRows.Row) -> some View {
        switch row.kind {
        case .upNext:
            if let upNext, !upNext.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    LibrarySectionHeader(title: row.title) {
                        WatchHistoryMenu(onCleared: { Task { await reload() } }, pickLibrary: { clearingLibrary = true })
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(upNext, id: \.mediaItemId) { UpNextCard(item: $0) }
                        }
                        .padding(.horizontal, Theme.pagePadding)
                    }
                    .scrollClipDisabled()
                }
                .padding(.top, 24)
                .accessibilityIdentifier("up-next-row")
            }
        case .favorites:
            if let favorites, !favorites.items.isEmpty {
                posterRow(
                    title: row.title,
                    moreTitle: "查看全部 \(favorites.total) 部",
                    more: .favorites,
                    items: favorites.items.map { item in
                        PosterRowItem(
                            id: item.mediaItemId, libraryId: item.libraryId, title: item.title, year: item.year,
                            posterUrl: item.posterUrl, aspect: item.primaryAspect,
                            info: favoriteLevelLabel(kind: item.kind, season: item.favoriteSeasonNumber, episode: item.favoriteEpisodeNumber).map { [$0] } ?? []
                        )
                    }
                )
                .accessibilityIdentifier("favorites-row")
            }
        case .libraries:
            if !visibleLibraries.isEmpty || !homeCollections.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    LibrarySectionHeader(title: row.title) {
                        if !collections.isEmpty {
                            NavigationLink(value: AppRoute.allCollections) { Text("全部合集 ›") }
                                .accessibilityIdentifier("all-collections-link")
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(visibleLibraries, id: \.id) { library in
                                NavigationLink(value: AppRoute.library(id: library.id)) {
                                    LibraryHomeCard(library: library, hasPosters: !(itemsByKey[LibraryHomeStore.coverKey(library.id)] ?? []).isEmpty)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-card-\(library.id)")
                            }
                            // 与真实库同排，合集之间沿用首页海报行的顺序；点卡片进原合集。
                            ForEach(homeCollections, id: \.id) { collection in
                                NavigationLink(value: AppRoute.collection(libraryId: collection.libraryId, collectionId: collection.id)) {
                                    CollectionLibraryHomeCard(collection: collection)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("合集「\(collection.name)」，\(collection.itemCount) 部")
                                .accessibilityIdentifier("collection-library-card-\(collection.id)")
                            }
                        }
                        .padding(.horizontal, Theme.pagePadding)
                    }
                    .scrollClipDisabled()
                }
                .padding(.top, 24)
            }
        case let .genres(kind, _):
            // 每个有片的类型一格，按部数倒序（服务端排好）；一格都没有时整段隐藏
            if let genres = genresByKind[kind], !genres.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    LibrarySectionHeader(title: row.title)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(genres, id: \.value) { genre in
                                if let id = Int(genre.value) {
                                    NavigationLink(value: AppRoute.libraryKind(kind: kind, genre: id)) {
                                        GenreCardFace(
                                            label: genre.label, count: genre.count, mediaKind: kind,
                                            coverURL: api.image(genre.coverUrl, width: ImageWidth.points(PhoneCardWidth.genreTile)),
                                            width: PhoneCardWidth.genreTile
                                        )
                                    }
                                    .buttonStyle(GenreTileButtonStyle())
                                    .accessibilityIdentifier("genre-tile-\(kind)-\(id)")
                                }
                            }
                        }
                        .padding(.horizontal, Theme.pagePadding)
                    }
                    .scrollClipDisabled()
                }
                .padding(.top, 24)
                .accessibilityIdentifier("home-row-\(row.id)")
            }
        case let .library(library, _, _, _, _, _):
            let items = itemsByKey[LibraryHomeStore.fetchKey(row)] ?? []
            if !items.isEmpty {
                posterRow(title: row.title, moreTitle: "查看全部", more: .library(id: library.id), items: items.map { PosterRowItem($0, fallbackLibrary: library.id) })
                    .accessibilityIdentifier("home-row-\(row.id)")
            }
        case let .mediaKind(kind, _, _, _, _, _, _):
            // 「全部电影」：同类型的库合成一面墙，查看全部进跨库墙页；每格落回服务端给的落点库
            let items = itemsByKey[LibraryHomeStore.fetchKey(row)] ?? []
            if !items.isEmpty {
                posterRow(title: row.title, moreTitle: "查看全部", more: .libraryKind(kind: kind), items: items.map { PosterRowItem($0, fallbackLibrary: 0) })
                    .accessibilityIdentifier("home-row-\(row.id)")
            }
        case let .collection(collection, _, _, _):
            let items = itemsByKey[LibraryHomeStore.fetchKey(row)] ?? []
            if !items.isEmpty {
                posterRow(title: row.title, moreTitle: "查看全部", more: .collection(libraryId: collection.libraryId, collectionId: collection.id),
                          items: items.map { PosterRowItem($0, fallbackLibrary: collection.libraryId ?? 0) })
                    .accessibilityIdentifier("home-row-\(row.id)")
            }
        }
    }

    private func posterRow(title: String, moreTitle: String, more: AppRoute, items: [PosterRowItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LibrarySectionHeader(title: title) {
                NavigationLink(value: more) { Text(moreTitle) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId, itemId: item.id)) {
                            LibraryPosterCell(title: item.title, year: item.year,
                                              url: api.image(item.posterUrl, width: ImageWidth.points(PhoneCardWidth.homePoster)),
                                              imageAspect: item.aspect)
                                .frame(width: PhoneCardWidth.homePoster)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            ForEach(item.info, id: \.self) { Text($0) }
                        }
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }
            .scrollClipDisabled()
        }
        .padding(.top, 24)
    }

    // MARK: 加载

    private func reload() async {
        await store.reload(api: api, owner: LibraryHomePrefs.ownerKey(api: api, username: model.session?.username))
    }
}

/// 类型剧照卡的按压反馈：轻微缩小（同系统卡片的按下手感），不叠系统的高亮蒙层
private struct GenreTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// 横滚海报行里的一格（库行 / 合集行 / 收藏行统一形态）
private struct PosterRowItem: Identifiable {
    var id: Int
    var libraryId: Int
    var title: String
    var year: Int?
    var posterUrl: String?
    var aspect: Double
    /// 长按信息（最近添加的季集范围、入库时间、收藏层级）
    var info: [String]

    init(id: Int, libraryId: Int, title: String, year: Int?, posterUrl: String?, aspect: Double, info: [String]) {
        self.id = id
        self.libraryId = libraryId
        self.title = title
        self.year = year
        self.posterUrl = posterUrl
        self.aspect = aspect
        self.info = info
    }

    init(_ item: API.LibraryItemView, fallbackLibrary: Int) {
        var info: [String] = []
        if item.kind == "tv", let addition = item.recentAddition, let label = formatRecentAddition(addition) { info.append(label) }
        if let added = item.addedAt { info.append("\(libraryFromNow(added))入库") }
        self.init(id: item.mediaItemId, libraryId: item.libraryId ?? fallbackLibrary, title: item.title, year: item.year,
                  posterUrl: item.posterUrl, aspect: item.primaryAspect, info: info)
    }
}

// MARK: - 库卡片

/// 库卡片（Web `LibraryCard`）：服务端拼好的「氛围光货架」封面 + 库名（`ShelfCardCaption`）；
/// 扫描 / 整理 / 元数据刷新进行中时封面归进度环并写出阶段，其余时间有待入账文件就挂「N 个新文件入库中」。
private struct LibraryHomeCard: View {
    let library: API.LibraryView
    /// 库里有没有海报素材（没有且没自定义封面时直接画类型占位，不请求拼贴）
    let hasPosters: Bool
    @Environment(\.api) private var api

    var body: some View {
        let refreshing = library.metadataRefresh?.refreshing == true
        let busy = library.scanning || library.organizing || refreshing
        let importing = busy ? 0 : (library.lastScan?.deferred ?? 0)
        VStack(spacing: 10) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.11, green: 0.13, blue: 0.19), Color(red: 0.06, green: 0.07, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: LibraryKindMeta.symbol(library.kind))
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.13))
                if hasPosters || library.customCover {
                    RemoteImage(url: api.image("/libraries/\(library.id)/cover", width: ImageWidth.points(PhoneCardWidth.libraryCover)),
                                placeholderSymbol: LibraryKindMeta.symbol(library.kind))
                }
                if busy {
                    ZStack {
                        Color.black.opacity(0.55)
                        VStack(spacing: 4) {
                            let progress = library.scanning ? library.scanProgress : library.organizing ? library.organizeProgress : nil
                            LibraryProgressRing(
                                processed: progress?.processed ?? (refreshing ? library.metadataRefresh?.processed : nil),
                                total: progress?.total ?? (refreshing ? library.metadataRefresh?.total : nil),
                                size: 62
                            )
                            Text(library.scanning ? ScanPhase.label(library.scanProgress?.phase) : library.organizing ? "整理中" : "刷新元数据")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                            if refreshing, let active = library.metadataRefresh?.active.first {
                                Text("\(active.title) · \(active.phase)")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                } else if importing > 0 {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(Theme.info).frame(width: 6, height: 6)
                            Text("\(importing) 个新文件入库中")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.info)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: .capsule)
                        .overlay(Capsule().strokeBorder(Theme.info.opacity(0.35)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            .aspectRatio(21 / 10, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
            ShelfCardCaption(name: library.name)
        }
        .frame(width: PhoneCardWidth.libraryCover)
        .contentShape(.rect)
    }
}

// MARK: - 合集虚拟库卡片

/// 首页合集的虚拟库卡片：复用真实媒体库的服务端货架封面，也不计入真实库统计。
/// 卡片规格沿用 LibraryHomeCard（名称同为 `ShelfCardCaption`，封面左下挂「合集」标签），名字用合集原名，与可单独改名的海报行分开。
private struct CollectionLibraryHomeCard: View {
    let collection: API.CollectionView
    @Environment(\.api) private var api

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.11, green: 0.13, blue: 0.19), Color(red: 0.06, green: 0.07, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.13))
                if !collection.covers.isEmpty {
                    RemoteImage(url: api.image("/collections/\(collection.id)/cover", width: ImageWidth.points(PhoneCardWidth.libraryCover)),
                                placeholderSymbol: "rectangle.stack")
                }
            }
            .aspectRatio(21 / 10, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
            .overlay(alignment: .bottomLeading) { CollectionCoverTag() }
            ShelfCardCaption(name: collection.name)
        }
        .frame(width: PhoneCardWidth.libraryCover)
        .contentShape(.rect)
    }
}

// MARK: - 接下来继续

/// 「接下来继续」横卡（Web `UpNextCard`）：分集剧照或背景图、续播进度、「还有 N 集」，
/// 中央常驻空心播放键直接进播放器（触摸屏没有悬停，藏起来等于不存在）；点卡片进条目详情。
private struct UpNextCard: View {
    let item: API.UpNextItemView
    @Environment(\.api) private var api
    @Environment(Router.self) private var router

    private var isEpisode: Bool { item.kind == "tv" }
    private var code: String? { isEpisode ? episodeCode(season: item.seasonNumber, episode: item.episodeNumber) : nil }
    private var context: String {
        if isEpisode { return [code, item.episodeTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
        return item.year.map(String.init) ?? ""
    }

    private var route: AppRoute {
        .libraryItem(libraryId: item.libraryId, itemId: item.mediaItemId,
                     season: isEpisode ? item.seasonNumber : nil, episode: isEpisode ? item.episodeNumber : nil)
    }

    /// 「已播 / 总时长」：只在看了一半时出现
    private var clockText: String? {
        guard item.positionMs > 0, let duration = item.durationMs, duration > 0 else { return nil }
        // 四舍五入到秒（同 Web up-next-row Math.round(ms/1000)）；播放器里的时钟仍向下取整
        return "\(Formatters.clock((Double(item.positionMs) / 1000).rounded())) / \(Formatters.clock((Double(duration) / 1000).rounded()))"
    }

    /// 第三行：为什么它在这儿
    private var stateLabel: String {
        let ago = libraryFromNow(item.lastPlayedAt)
        if item.advanced { return "\(ago)看完上一集" }
        if item.positionMs > 0, let percent = item.progressPercent, clockText == nil { return "\(ago)看到 \(percent)%" }
        if item.positionMs > 0 { return "\(ago)看过一段" }
        return "\(ago)打开过"
    }

    private var playVerb: String {
        if item.positionMs > 0 { return "继续播放" }
        return item.advanced ? "播放下一集" : "播放"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                NavigationLink(value: route) { artwork }
                    .buttonStyle(.plain)
                Button {
                    router.play(PlayRequest(
                        mediaItemId: item.mediaItemId,
                        season: isEpisode ? item.seasonNumber : nil,
                        episode: isEpisode ? item.episodeNumber : nil
                    ))
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                        .frame(width: 42, height: 42)
                        .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.45), radius: 5)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(playVerb)《\(item.title)》\(context.isEmpty ? "" : " \(context)")")
                .accessibilityIdentifier("up-next-play-\(item.mediaItemId)")
            }
            NavigationLink(value: route) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if !context.isEmpty {
                        Text(context).font(.footnote).monospacedDigit().foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Text(stateLabel).font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(width: PhoneCardWidth.upNext)
    }

    /// 剧照加载失败时的兜底（与「没有剧照」同一套画法）
    @ViewBuilder
    private var artworkFallback: some View {
        if isEpisode {
            LibraryArtwork(url: nil, frameAspect: 16 / 9, fallbackText: code)
        } else {
            LibraryArtwork(url: api.image(item.posterUrl, width: ImageWidth.points(PhoneCardWidth.upNext)), imageAspect: item.posterAspect,
                           frameAspect: 16 / 9, fallbackText: item.posterUrl == nil ? item.title : nil)
        }
    }

    private var artwork: some View {
        let url = isEpisode ? item.episodeStillUrl : item.backdropUrl
        return ZStack(alignment: .bottom) {
            if let url {
                // 剧照地址在、但图加载失败：剧集印集号、电影退回海报模糊铺底（同 Web up-next-row 的 fallback）
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        LazyImage(url: api.image(url, width: ImageWidth.points(PhoneCardWidth.upNext))) { state in
                            Group {
                                if let image = state.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else if state.error != nil {
                                    artworkFallback
                                } else {
                                    Theme.surfaceRaised
                                }
                            }
                            .perfImage(api.image(url, width: ImageWidth.points(PhoneCardWidth.upNext)), state)
                        }
                    }
                    .clipped()
            } else if isEpisode {
                LibraryArtwork(url: nil, frameAspect: 16 / 9, fallbackText: code)
            } else {
                // 缺横向剧照：用海报按真实比例模糊铺底兜底
                LibraryArtwork(url: api.image(item.posterUrl, width: ImageWidth.points(PhoneCardWidth.upNext)), imageAspect: item.posterAspect,
                               frameAspect: 16 / 9, fallbackText: item.posterUrl == nil ? item.title : nil)
            }
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .top).frame(height: 56)
            VStack(alignment: .leading, spacing: 4) {
                if let clockText {
                    Text(clockText).font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                }
                if let percent = item.progressPercent {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(Theme.accent2).frame(width: proxy.size.width * CGFloat(percent) / 100)
                        }
                    }
                    .frame(height: 3)
                } else if item.positionMs > 0 {
                    Capsule().fill(Theme.accent2.opacity(0.6)).frame(height: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            if isEpisode, item.unwatchedAheadCount > 0 {
                Text("还有 \(item.unwatchedAheadCount) 集")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(red: 0.82, green: 0.98, blue: 0.9))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(red: 5 / 255, green: 46 / 255, blue: 34 / 255).opacity(0.76), in: .capsule)
                    .overlay(Capsule().strokeBorder(Color(red: 0.65, green: 0.95, blue: 0.82).opacity(0.25)))
                    .padding(8)
            }
        }
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.38), radius: 14, y: 10)
    }
}

// MARK: - 清空观看记录

/// 「接下来继续」标题右侧的 ⋯（Web `WatchHistoryMenu`）：今天 / 最近一周 / 全部 / 某个媒体库
private struct WatchHistoryMenu: View {
    var onCleared: () -> Void
    var pickLibrary: () -> Void
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback

    var body: some View {
        Menu {
            Button("清空今天的观看记录…") {
                clear("今天的观看记录", since: Calendar.current.startOfDay(for: .now),
                      "今天播放过的作品，续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录。")
            }
            Button("清空最近一周的观看记录…") {
                clear("最近一周的观看记录", since: .now.addingTimeInterval(-7 * 86400),
                      "最近 7 天播放过的作品，续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录。")
            }
            Button("清空全部观看记录…") {
                clear("全部观看记录", since: nil,
                      "所有作品的续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录；应用更新前的自动备份仍包含历史记录。")
            }
            Divider()
            Button("清空某个媒体库的观看记录…", action: pickLibrary)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .accessibilityLabel("清空观看记录")
        .accessibilityIdentifier("watch-history-menu")
    }

    private func clear(_ label: String, since: Date?, _ description: String) {
        Task {
            guard await feedback.confirm("清空\(label)？", message: description, confirmTitle: "清空", destructive: true) else { return }
            do {
                let (result, message) = try await api.libraryClearHistory(scope: "all", since: since)
                if since != nil {
                    feedback.success(result.deletedStates > 0 ? "已清空\(label)" : "\(label)里没有可清除的记录")
                } else {
                    feedback.success(message)
                }
                onCleared()
            } catch {
                feedback.error(error)
            }
        }
    }
}

/// 「清空某个媒体库的观看记录」选择框（Web `ClearLibraryHistoryDialog`）
private struct ClearLibraryHistorySheet: View {
    let libraries: [API.LibraryView]
    var onCleared: () -> Void
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @Environment(\.dismiss) private var dismiss
    @State private var libraryId: Int?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("媒体库", selection: $libraryId) {
                        if libraries.isEmpty { Text("没有可浏览的媒体库").tag(Int?.none) }
                        ForEach(libraries, id: \.id) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                } footer: {
                    Text("选中库里所有作品的续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录。")
                }
                Section {
                    Button(role: .destructive) {
                        submit()
                    } label: {
                        let selected = libraries.first { $0.id == libraryId }
                        Text(busy ? "清空中…" : selected.map { "清空「\($0.name)」" } ?? "清空")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(libraryId == nil || busy)
                }
            }
            .navigationTitle("清空某个媒体库的观看记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .onAppear { libraryId = libraryId ?? libraries.first?.id }
    }

    private func submit() {
        guard let libraryId, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let (_, message) = try await api.libraryClearHistory(scope: "library", libraryId: libraryId)
                feedback.success(message)
                onCleared()
                dismiss()
            } catch {
                feedback.error(error)
            }
        }
    }
}

// MARK: - 库卡 / 合集卡共用的名称与合集标签

/// 「我的媒体库」行的卡片名：库卡与合集卡共用，封面下方居中、只占一行（Web `ShelfCardCaption`，
/// Emby / Jellyfin「我的媒体」同款）。不写部数（页头已有总数，入口卡只负责认出是哪个）；
/// 「默认」是订阅 / 下载的落库设置，只在库管理页标注；合集的区分是封面左下的 `CollectionCoverTag`，不占名称行
private struct ShelfCardCaption: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
    }
}

/// 合集卡封面左下的「合集」玻璃标签：落在货架封面的倒影暗区（本就没信息、压得住字），
/// 与库卡「N 个新文件入库中」同位置、同一套胶囊——合集没有扫描状态，两者不会撞车
private struct CollectionCoverTag: View {
    var body: some View {
        Label("合集", systemImage: "rectangle.stack")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.5), in: .capsule)
            .background(.ultraThinMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
            .fixedSize()
            .padding(8)
    }
}
