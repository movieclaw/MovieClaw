import Nuke
import SwiftUI

/// 首页（docs/design/macos-app.md §4.1）：首屏是「接下来继续」的大图区，下面接用户在网页自定义的行。
///
/// 数据与 iPhone、Apple TV 版、网页同一份：`LibraryHomeStore`（快照秒开、静默刷新）按 `ui.preferences.home.rows`
/// 合并出行清单（`HomeRows`）。
/// - 大图区讲「接下来继续」里的一部：默认第一部；鼠标在下面那一行的卡片上停稳 0.3 秒，大图就换成那一部
///   （同 Apple TV 版「跟着焦点走」，Mac 上焦点就是鼠标）；右下角一排小圆点也能点着换。不自动轮播：
///   按「继续播放」播的一定是眼前这部；
/// - 剧照铺满大图区并延伸到侧边栏与工具栏底下（同 Apple Music 的专辑页头图），往下渐隐进剧照的边缘色，
///   边缘色再往下过渡到页面底色；
/// - 下面的行是 Apple Music 式的「架子」：标题可点进完整的海报墙（`MacRowWallView`），悬停两端出翻页键。
struct MacHomeView: View {
    @Environment(\.api) private var api
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @Environment(MacLibraryDirectory.self) private var directory

    private var store: LibraryHomeStore { .shared }
    /// 大图区正在讲的那一部（条目 id）
    @State private var stageId: Int?
    /// 鼠标正停在哪张「接下来继续」卡上（停稳才换大图）
    @State private var hoveredId: Int?
    /// 剧照边缘色（大图区以下的底色从它过渡到页面底色）
    @State private var tint: Color?

    /// 预载相邻两部的剧照：整张大图几百 KB 起，等鼠标移过去才下载会闪一下空底
    private static let prefetcher = ImagePrefetcher()

    private var owner: String {
        PageSnapshots.owner(server: api.server, username: model.session?.username ?? "")
    }

    private var rows: [HomeRows.Row] {
        guard let libraries = store.libraries else { return [] }
        return HomeRows.build(prefs: LibraryHomePrefs.shared.rows ?? store.snapshotRows ?? [], libraries: libraries, collections: store.collections)
            .filter { !$0.hidden }
    }

    private var homeCollections: [API.CollectionView] { HomeRows.pinnedCollections(rows) }

    var body: some View {
        Group {
            if store.libraries == nil {
                if store.failed {
                    MacStateView(symbol: "wifi.exclamationmark", title: "连不上服务器", message: "首页加载失败，请检查网络后重试。",
                                 actionTitle: "重试") { Task { await reload() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if rows.allSatisfy(isEmpty) {
                MacStateView(symbol: "film.stack", title: "媒体库里还没有内容",
                             message: "在网页上添加媒体库并扫描后，影片会出现在这里。")
            } else {
                content
            }
        }
        .background(Color.macPage)
        .navigationTitle("首页")
        .toolbar(removing: .title)
        .task { await reload() }
        .polling(every: 60) { await reload() }
        // 播放器关掉、服务端收下「停止」后刷新：「接下来继续」立刻跟上刚才看到的位置
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopReported)) { _ in
            Task { await reload() }
        }
        .accessibilityIdentifier("mac-home")
    }

    private var content: some View {
        let visibleRows = rows
        let upNext = visibleRows.contains { $0.kind == .upNext } ? (store.upNext ?? []) : []
        let stage = upNext.first { $0.mediaItemId == stageId } ?? upNext.first
        return GeometryReader { window in
            let heroHeight = MacStageLayout.height(for: window.size.width, windowHeight: window.size.height + window.safeAreaInsets.top)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: MacMetrics.rowSpacing) {
                    if let stage {
                        hero(stage, items: upNext, height: heroHeight, topInset: window.safeAreaInsets.top)
                        upNextShelf(upNext, stage: stage)
                            .padding(.top, -MacMetrics.rowSpacing * 0.4)
                    }
                    ForEach(visibleRows) { row in
                        rowView(row)
                    }
                }
                .padding(.top, stage == nil ? 16 : 0)
                .padding(.bottom, 48)
            }
            .ignoresSafeArea(edges: stage == nil ? [] : .top)
            .background(alignment: .top) {
                // 大图区以下的底色：剧照边缘色往下 520 点渐变到页面底色，行与行落在这片颜色上，不是一条硬边
                if stage != nil {
                    LinearGradient(stops: [.init(color: tint ?? .macPage, location: 0),
                                           .init(color: tint ?? .macPage, location: 0.55),
                                           .init(color: .macPage, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: heroHeight + 520)
                        .ignoresSafeArea()
                        .animation(.easeInOut(duration: 0.8), value: tint?.description)
                }
            }
        }
        // 鼠标停稳 0.3 秒才换大图：一路划过一排卡片时不逐张闪
        .task(id: hoveredId) {
            guard let id = hoveredId, id != stageId else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { stageId = id }
        }
        .task(id: stage.map { stageImageURL($0) } ?? nil) {
            guard let stage else { return }
            if let index = upNext.firstIndex(where: { $0.mediaItemId == stage.mediaItemId }) {
                let neighbours = [index - 1, index + 1].filter { upNext.indices.contains($0) }
                Self.prefetcher.startPrefetching(with: neighbours.compactMap { stageImageURL(upNext[$0]) })
            }
            guard let url = stageImageURL(stage), let color = await MacStageEdgeColor.color(for: url), !Task.isCancelled else { return }
            tint = color
        }
    }

    // MARK: 大图区

    private func hero(_ stage: API.UpNextItemView, items: [API.UpNextItemView], height: CGFloat, topInset: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            MacStageBackdrop(url: stageImageURL(stage), tint: tint, fadeFrom: 0.6)
                .frame(height: height)
                // 剧照延伸到侧边栏底下（同 Apple Music 专辑页的头图）
                .backgroundExtensionEffect()
            VStack(alignment: .leading, spacing: 20) {
                MacStageInfo(
                    title: stage.title,
                    logoURL: api.image(stage.logoUrl),
                    headline: stage.kind == "tv"
                        ? MacStageInfo.episodeLine(season: stage.seasonNumber, episode: stage.episodeNumber, name: stage.episodeTitle)
                        : nil,
                    meta: Self.stageMeta(stage),
                    overview: stage.overview,
                    overviewLines: 2
                )
                .id(stage.mediaItemId)
                .transition(.opacity)
                .accessibilityIdentifier("mac-home-stage")
                heroActions(stage)
            }
            .padding(.horizontal, MacMetrics.edge + 8)
            .padding(.bottom, 64)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            if items.count > 1 {
                stagePager(items, current: stage.mediaItemId)
                    .padding(.trailing, MacMetrics.edge + 8)
                    .padding(.bottom, 70)
            }
        }
        .clipped()
    }

    /// 「继续播放」「详情」：主按钮是醒目的玻璃（同 Apple Music 的「播放」），次按钮普通玻璃
    private func heroActions(_ stage: API.UpNextItemView) -> some View {
        HStack(spacing: 12) {
            Button { resume(stage) } label: {
                Label(stage.positionMs > 0 ? "继续播放" : "播放", systemImage: "play.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.white.opacity(0.9))
            .foregroundStyle(.black)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mac-home-hero-play")
            Button {
                router.push(.item(libraryId: stage.libraryId, itemId: stage.mediaItemId))
            } label: {
                Label("详情", systemImage: "info.circle")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
            .accessibilityIdentifier("mac-home-hero-details")
            if let remaining = Self.upNextBand(stage) {
                Text(remaining)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.leading, 6)
            }
        }
    }

    /// 右下角一排小圆点：「接下来继续」里有几部，点一下大图换过去（不自动轮播）
    private func stagePager(_ items: [API.UpNextItemView], current: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(items.prefix(12), id: \.mediaItemId) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.45)) { stageId = item.mediaItemId }
                } label: {
                    Capsule()
                        .fill(.white.opacity(item.mediaItemId == current ? 0.95 : 0.35))
                        .frame(width: item.mediaItemId == current ? 18 : 7, height: 7)
                        .contentShape(.rect.inset(by: -4))
                }
                .buttonStyle(.plain)
                .help(item.title)
                .accessibilityLabel(item.title)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .animation(.easeInOut(duration: 0.25), value: current)
    }

    /// 「接下来继续」一行：剧照卡，点一下直接续播；鼠标停在哪张，大图就讲哪一部
    private func upNextShelf(_ items: [API.UpNextItemView], stage: API.UpNextItemView) -> some View {
        MacShelf(title: "接下来继续", artHeight: MacMetrics.landscapeWidth * 9 / 16) {
            ForEach(Array(items.enumerated()), id: \.element.mediaItemId) { index, item in
                upNextCard(item)
                    .overlay {
                        // 大图正讲的这一部描一圈亮边，看得出上面讲的是哪张
                        if item.mediaItemId == stage.mediaItemId, items.count > 1 {
                            RoundedRectangle(cornerRadius: MacMetrics.cardCorner)
                                .strokeBorder(.white.opacity(0.7), lineWidth: 2)
                                .frame(height: MacMetrics.landscapeWidth * 9 / 16)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .allowsHitTesting(false)
                        }
                    }
                    .onHover { inside in
                        if inside { hoveredId = item.mediaItemId } else if hoveredId == item.mediaItemId { hoveredId = nil }
                    }
                    .accessibilityIdentifier("mac-home-continue-\(index)")
            }
        }
    }

    private func upNextCard(_ item: API.UpNextItemView) -> some View {
        let isEpisode = item.kind == "tv"
        let still = isEpisode ? (item.episodeStillUrl ?? item.backdropUrl) : (item.backdropUrl ?? item.posterUrl)
        return MacLandscapeCard(
            title: item.title,
            subtitle: isEpisode ? item.episodeTitle.flatMap { $0.isEmpty ? nil : $0 } : item.year.map(String.init),
            imageURL: api.image(still, width: ImageWidth.macCard(MacMetrics.landscapeWidth)),
            progress: item.progressPercent.map { Double($0) / 100 },
            badge: item.advanced ? "下一集" : nil,
            detail: Self.upNextBand(item),
            play: { resume(item) },
            menu: [
                MacCardAction(title: item.positionMs > 0 ? "继续播放" : "播放", symbol: "play.fill") { resume(item) },
                MacCardAction(title: "查看详情", symbol: "info.circle") {
                    router.push(.item(libraryId: item.libraryId, itemId: item.mediaItemId))
                },
            ]
        ) {
            resume(item)
        }
    }

    // MARK: 其余的行

    @ViewBuilder
    private func rowView(_ row: HomeRows.Row) -> some View {
        switch row.kind {
        case .upNext:
            EmptyView()
        case .favorites:
            if let items = store.favorites?.items, !items.isEmpty {
                posterShelf(row, items: items.map(\.asLibraryItem), total: store.favorites?.total)
            }
        case .libraries:
            let collections = homeCollections
            if !directory.browsable.isEmpty || !collections.isEmpty {
                MacShelf(title: row.title) {
                    ForEach(directory.browsable, id: \.id) { library in
                        MacLibraryCard(name: library.name, count: library.stats.itemCount,
                                       imageURL: api.image("/libraries/\(library.id)/cover", width: ImageWidth.macCard(MacMetrics.libraryWidth))) {
                            router.searchText = ""
                            router.select(.library(library.id))
                        }
                        .accessibilityIdentifier("mac-home-library-\(library.id)")
                    }
                    ForEach(collections, id: \.id) { collection in
                        MacLibraryCard(name: collection.name, count: collection.itemCount, collection: true,
                                       imageURL: collection.covers.isEmpty ? nil : api.image("/collections/\(collection.id)/cover", width: ImageWidth.macCard(MacMetrics.libraryWidth))) {
                            router.select(.collection(collection.id))
                        }
                    }
                }
            }
        case .library, .mediaKind, .collection:
            let items = store.itemsByKey[LibraryHomeStore.fetchKey(row)] ?? []
            if !items.isEmpty {
                posterShelf(row, items: items, total: Self.rowTotal(row))
            }
        }
    }

    private func posterShelf(_ row: HomeRows.Row, items: [API.LibraryItemView], total: Int?) -> some View {
        let source = MacWallSource(row.kind)
        let seeAll: (() -> Void)? = source.map { source in { router.push(.rowWall(title: row.title, source: source)) } }
        return MacShelf(title: row.title, seeAll: seeAll, artHeight: MacMetrics.posterWidth * 1.5) {
            ForEach(items, id: \.mediaItemId) { item in
                let libraryId = item.libraryId ?? Self.libraryId(of: row)
                MacPosterCard(
                    title: item.title,
                    subtitle: item.year.map(String.init),
                    imageURL: api.image(item.posterUrl, width: ImageWidth.macCard(MacMetrics.posterWidth)),
                    play: { router.play(PlayRequest(mediaItemId: item.mediaItemId)) },
                    menu: MacItemMenu.actions(item: item, libraryId: libraryId, router: router)
                ) {
                    if let libraryId { router.push(.item(libraryId: libraryId, itemId: item.mediaItemId)) }
                }
                .accessibilityIdentifier("mac-home-poster-\(item.mediaItemId)")
            }
            if let seeAll, items.count >= LibraryHomeStore.rowCount {
                MacSeeAllCard(total: total, action: seeAll)
            }
        }
        .id(row.id)
    }

    // MARK: 派生

    /// 「2023 · 古装 · 喜剧」，电影再加片长；类型只取前两个
    private static func stageMeta(_ item: API.UpNextItemView) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        parts += (item.genres ?? []).prefix(2)
        if item.kind != "tv", let durationMs = item.durationMs, durationMs >= 60_000 {
            parts.append(Formatters.runtime(Int((Double(durationMs) / 60_000).rounded())))
        }
        return parts.joined(separator: " · ")
    }

    /// 大图：条目的背景图按屏宽像素取；剧集用整部剧的背景图（单集剧照分辨率低、也容易剧透），没有再退回剧照、海报
    private func stageImageURL(_ item: API.UpNextItemView) -> URL? {
        api.image(item.backdropUrl ?? item.episodeStillUrl ?? item.posterUrl, width: ImageWidth.screen)
    }

    /// 卡片暗带里的紧凑写法：「S2 E6 · 剩 18 分钟」；还没开始看的写全长
    static func upNextBand(_ item: API.UpNextItemView) -> String? {
        var parts: [String] = []
        if item.kind == "tv" { parts.append("S\(item.seasonNumber) E\(item.episodeNumber)") }
        if item.positionMs > 0, let remaining = Formatters.remaining(positionMs: item.positionMs, durationMs: item.durationMs) {
            parts.append(remaining)
        } else if let durationMs = item.durationMs, durationMs >= 60_000 {
            parts.append(Formatters.duration(minutes: durationMs / 60_000))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 「查看全部」上写的总数：只在确切知道时写
    static func rowTotal(_ row: HomeRows.Row) -> Int? {
        if case let .library(library, sort, _, unwatched, _, _) = row.kind, !unwatched, sort != "last_played" {
            return library.stats.itemCount
        }
        return nil
    }

    static func libraryId(of row: HomeRows.Row) -> Int? {
        if case let .library(library, _, _, _, _, _) = row.kind { return library.id }
        return nil
    }

    private func resume(_ item: API.UpNextItemView) {
        let isEpisode = item.kind == "tv"
        router.play(PlayRequest(mediaItemId: item.mediaItemId,
                                season: isEpisode ? item.seasonNumber : nil,
                                episode: isEpisode ? item.episodeNumber : nil))
    }

    private func isEmpty(_ row: HomeRows.Row) -> Bool {
        switch row.kind {
        case .upNext: (store.upNext ?? []).isEmpty
        case .favorites: (store.favorites?.items ?? []).isEmpty
        case .libraries: directory.browsable.isEmpty && homeCollections.isEmpty
        case .library, .mediaKind, .collection: (store.itemsByKey[LibraryHomeStore.fetchKey(row)] ?? []).isEmpty
        }
    }

    private func reload() async {
        await store.reload(api: api, owner: owner)
    }
}
