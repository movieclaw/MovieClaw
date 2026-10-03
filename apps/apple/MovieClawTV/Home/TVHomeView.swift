import Nuke
import SwiftUI

/// 首页（docs/design/tvos-app.md §3.1）：首屏是「接下来继续」的大图区，下面接用户在网页自定义的行。
///
/// 大图区是**焦点驱动**的（2026-10-02 用户选定，同 Netflix 新版电视首页、Infuse）：
/// - 首屏底部一行「接下来继续」小卡；整页背景剧照、片名、简介永远讲焦点所在的那一部，左右移动时交叉淡入；
/// - 不自动轮播：画面只在用户移动焦点时才换，按确认键播放的一定是眼前这部（「继续观看」是要挑着看的，
///   自己会转的轮播一次只露一部，还会在焦点底下换片）；
/// - 确认键直接续播（播放第一）；长按确认键弹菜单，可以进详情；
/// - 焦点离开这一行（往下看别的行、上到标签栏）时，大图停在最后看的那一部；
/// - 剧照按 16:9 完整显示在右上，左边和下边取剧照边缘色铺底，卡片行落在这个颜色上，不再压着剧照（§3.4）。
///
/// 数据与 iPhone 版、网页同一份：`LibraryHomeStore`（快照秒开、静默刷新）按 `ui.preferences.home.rows`
/// 合并出行清单（`HomeRows`）。「接下来继续」这一行在电视上就是首屏大图区（用户在网页隐藏了这一行就不画），
/// 其余行按顺序接在下面。「我的媒体库」是电视上进各个库的唯一入口（标签栏不再逐个列库），
/// 所以网页上隐藏了这一行，电视上也照样画。
struct TVHomeView: View {
    @Environment(\.api) private var api
    @Environment(AppModel.self) private var model
    @Environment(TVRouter.self) private var router
    @Environment(TVLibraryDirectory.self) private var directory

    private var store: LibraryHomeStore { .shared }
    /// 首屏的焦点：大图区的「继续播放」「详情」，或「接下来继续」里的某张卡
    @FocusState private var focus: TVHomeFocus?
    /// 大图区正在讲的那一部（条目 id）：焦点停稳后才跟过去，按住方向键一路划过时不逐张闪
    @State private var stageId: Int?
    /// 剧照边缘色（首屏底色）
    @State private var tint: Color?
    /// 列表滚动距离：只给背景层读，滚动时不重算整页
    @State private var scroll = TVStageScroll()
    /// 列表的滚动位置：焦点从卡片行回到按钮时滚回顶部，恢复首屏的样子
    @State private var position = ScrollPosition(edge: .top)
    /// 列表内容的上沿离屏幕顶多远（系统标签栏下方，实测 157）：首屏上半块按它定高（`TVStageBlock`）
    @State private var topInset: CGFloat = 157

    /// 预载焦点左右两部的剧照：原图约 1MB，等焦点移过去才下载会闪一下空底
    private static let prefetcher = ImagePrefetcher()

    private var owner: String {
        PageSnapshots.owner(server: api.server, username: model.session?.username ?? "")
    }

    /// 「我的媒体库」里接在库后面的合集：首页显示中的合集行，同一合集只放一张（与网页、iPhone 同一套判定）
    private var homeCollections: [API.CollectionView] { HomeRows.pinnedCollections(rows) }

    private var rows: [HomeRows.Row] {
        guard let libraries = store.libraries else { return [] }
        return HomeRows.build(prefs: LibraryHomePrefs.shared.rows ?? store.snapshotRows ?? [], libraries: libraries, collections: store.collections)
            .filter { !$0.hidden || $0.kind == .libraries }
    }

    var body: some View {
        Group {
            if store.libraries == nil {
                if store.failed {
                    TVStateView(symbol: "wifi.exclamationmark", title: "连不上服务器", message: "首页加载失败，请检查网络后重试。",
                                actionTitle: "重试") { Task { await reload() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if rows.allSatisfy(isEmpty) {
                TVStateView(symbol: "film.stack", title: "媒体库里还没有内容",
                            message: "在网页或手机上添加媒体库并扫描后，影片会出现在这里。")
            } else {
                content
            }
        }
        .task { await reload() }
        .polling(every: 60) { await reload() }
        // 接下来继续变了就同步到 Top Shelf（主屏选中 MovieClaw 图标时上方那一行）
        .task(id: store.upNext?.map(\.mediaItemId)) {
            if let items = store.upNext { await TVTopShelfPublisher.publish(items, api: api) }
        }
    }

    private var content: some View {
        let visibleRows = rows
        let upNext = visibleRows.contains { $0.kind == .upNext } ? (store.upNext ?? []) : []
        let stage = upNext.first { $0.mediaItemId == stageId } ?? upNext.first
        let backdrop = stage.flatMap(stageImageURL)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: TVMetrics.rowSpacing) {
                if let stage {
                    stageSection(stage, items: upNext)
                } else {
                    // 没有大图区时第一行别和标签栏贴在一起
                    Color.clear.frame(height: 30)
                }
                ForEach(visibleRows) { row in
                    rowView(row)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scroll.offset = offset
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in
            topInset = inset
        }
        // 只横向铺满（横滑行自己补左边距）。顶部保留安全区：列表静止时内容从标签栏的下方排起，
        // 首屏不必自己留白避让；大图背景在 background 里自己铺满全屏，不受影响
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        .background {
            TVStageBackdrop(url: backdrop, tint: stage == nil ? nil : tint, scroll: scroll)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-home")
        // 开机落在首页：第一次有内容就把焦点放到「继续播放」上（播放第一：开机按确认就续播）。只这一次——
        // 之后用户在标签栏上左右移动、经过首页时不把焦点拽下来（见 TVRouter.consumeLaunchFocus）
        .task(id: upNext.first?.mediaItemId) {
            guard upNext.first != nil, router.consumeLaunchFocus() else { return }
            // 等这一帧布局完再挪焦点，否则按钮还没进焦点系统
            try? await Task.sleep(for: .milliseconds(150))
            // 开机直接起播（Top Shelf 的「播放」、调试参数 -mcRoute）时播放器盖在上面：不去抢焦点，
            // 否则会和播放器里「跳过片头」「下一集」自动拿焦点撞上（UI 测试偶发失败）
            guard router.player == nil else { return }
            focus = .play
        }
        .onChange(of: focus) { old, new in
            switch (old, new) {
            case (.card, .card):
                break
            case (_, .card):
                // 进「接下来继续」这一行：从按钮往下、从下面的行（收藏等）往上，都滚到同一个位置。
                // 系统自己滚的量跟来路有关——从下面上来时按「上一行刚好露全」滚，比从按钮下来多滚 400 多点，
                // 大图跟着上移、下沿整个露出来（2026-10-03 真机实测）
                withAnimation(.easeInOut(duration: 0.35)) { position.scrollTo(y: Self.rowScrollOffset) }
            case (.card, .play), (.card, .details):
                // 从卡片行按「上」回到按钮区：列表滚回顶部恢复首屏——系统只滚到按钮刚好露出为止，大图会被文字压着半截
                withAnimation(.easeInOut(duration: 0.35)) { position.scrollTo(edge: .top) }
            default:
                break
            }
        }
        // 焦点停稳 0.16 秒再换大图：按住方向键一路划过去时，中间那些不逐张加载、逐张闪。
        // 焦点回到「继续播放」「详情」上时大图不变，按下去就是刚才看的那一部
        .task(id: focus) {
            guard case let .card(id) = focus, id != stageId else { return }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { stageId = id }
        }
        // 换了一部：取剧照边缘色铺底；预载左右两部的剧照，焦点移过去时直接从内存出图
        .task(id: backdrop) {
            if let stage, let index = upNext.firstIndex(where: { $0.mediaItemId == stage.mediaItemId }) {
                let neighbours = [index - 1, index + 1].filter { upNext.indices.contains($0) }
                Self.prefetcher.startPrefetching(with: neighbours.compactMap { stageImageURL(upNext[$0]) })
            }
            guard let backdrop, let color = await TVStageEdgeColor.color(for: backdrop), !Task.isCancelled else { return }
            tint = color
        }
    }

    /// 焦点在「接下来继续」那一行时列表的滚动量：取从按钮往下进这一行时系统自己滚到的位置（实测 415.5），
    /// 这条最常走的路上不再多出一段校正动画
    private static let rowScrollOffset: CGFloat = 415.5

    /// 首屏：上半块讲当前这部（文字 + 「继续播放」「详情」，与详情页同一套 `TVStageBlock`），底部露出一截「接下来继续」。
    /// - 默认焦点在「继续播放」，按确认直接续播；往下进卡片行，系统把列表滚上来，大图跟着焦点所在的卡走；
    /// - 换一部时新旧两段文字在同一个框里叠着交叉淡入——不能让它们在 VStack 里上下并排，
    ///   否则过渡那一下会被撑高、整块往上跳；按钮不跟着重建，焦点在按钮上时不会丢
    private func stageSection(_ stage: API.UpNextItemView, items: [API.UpNextItemView]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            TVStageBlock(topInset: topInset) {
                ZStack(alignment: .bottomLeading) {
                    TVStageInfo(
                        title: stage.title,
                        logoURL: api.image(stage.logoUrl),
                        headline: stage.kind == "tv"
                            ? TVStageInfo.episodeLine(season: stage.seasonNumber, episode: stage.episodeNumber, name: stage.episodeTitle)
                            : nil,
                        meta: Self.stageMeta(stage),
                        overview: stage.overview
                    )
                    .accessibilityIdentifier("tv-home-stage")
                    .id(stage.mediaItemId)
                    .transition(.opacity)
                }
            } actions: {
                stageActions(stage)
            }
            TVShelf(title: "接下来继续") {
                ForEach(Array(items.enumerated()), id: \.element.mediaItemId) { index, item in
                    upNextCard(item)
                        .focused($focus, equals: .card(item.mediaItemId))
                        .accessibilityIdentifier("tv-home-continue-\(index)")
                }
            }
            // 从按钮往下回到这一行：落在大图正讲的那张卡上，而不是按位置挑按钮正下方的第一张——
            // 否则看到第五部、上去看一眼按钮再下来，大图就跳回第一部了
            .defaultFocus($focus, .card(stage.mediaItemId), priority: .userInitiated)
        }
    }

    /// 「继续播放」「详情」两个按钮。进度、剩多久不在这里重复：下面那张剧照卡的暗带里已经写着（2026-10-03 用户要求去掉）
    private func stageActions(_ stage: API.UpNextItemView) -> some View {
        HStack(spacing: 24) {
            Button { resume(stage) } label: {
                Label(stage.positionMs > 0 ? "继续播放" : "播放", systemImage: "play.fill")
                    .padding(.horizontal, 8)
            }
            .focused($focus, equals: .play)
            .accessibilityIdentifier("tv-home-hero-play")
            Button {
                router.push(.item(libraryId: stage.libraryId, itemId: stage.mediaItemId))
            } label: {
                Label("详情", systemImage: "info.circle")
                    .padding(.horizontal, 8)
            }
            .focused($focus, equals: .details)
            .accessibilityIdentifier("tv-home-hero-details")
        }
        // 按钮这一行横贯整屏做成焦点区：标签栏上任何一项往下、卡片行任何一张往上都先落到这里——
        // 两个按钮只占左边一小截，不在这一行的话系统会越过按钮直接跳到卡片行 / 按「上」没反应。
        // 进来时落在「继续播放」上（播放第一），不按位置挑最近的「详情」
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocus($focus, .play, priority: .userInitiated)
    }

    /// 「2023 · 古装 · 喜剧」，电影再加片长（同详情页的第一行，2026-10-03 用户定）；类型只取前两个，再多就挤了。
    /// 剧集是哪一集写在下一行「第 2 季 第 6 集」，用不着再写「剧集」两个字
    private static func stageMeta(_ item: API.UpNextItemView) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        parts += (item.genres ?? []).prefix(2)
        if item.kind != "tv", let durationMs = item.durationMs, durationMs >= 60_000 {
            parts.append(TVItemDetailView.runtimeText(Int((Double(durationMs) / 60_000).rounded())))
        }
        return parts.joined(separator: " · ")
    }

    /// 大图区的整页背景：条目的背景图原图（按 Plex / Emby 的规范应是无字高清图，取决于刮削的选图偏好）。
    /// 剧集用整部剧的而不是这一集的剧照（后者最多 1080p，也容易剧透）；没有背景图退回分集剧照原图，再没有用海报
    private func stageImageURL(_ item: API.UpNextItemView) -> URL? {
        api.image(item.backdropUrl ?? item.episodeStillOriginalUrl ?? item.episodeStillUrl ?? item.posterUrl)
    }

    @ViewBuilder
    private func rowView(_ row: HomeRows.Row) -> some View {
        switch row.kind {
        case .upNext:
            // 已经是首屏的大图区
            EmptyView()
        case .favorites:
            if let items = store.favorites?.items, !items.isEmpty {
                TVShelf(title: row.title) {
                    ForEach(items, id: \.mediaItemId) { item in
                        TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                                     imageURL: api.image(item.posterUrl, .tvPoster)) {
                            router.push(.item(libraryId: item.libraryId, itemId: item.mediaItemId))
                        }
                    }
                    seeAll(row, total: store.favorites?.total)
                }
            }
        case .libraries:
            // 各个库的入口：标签栏只放固定的几项，库从这里进各自的海报墙。
            // 库后面接「显示在首页」的合集（虚拟库卡片，同网页与 iPhone，docs/design/library-collections.md）：
            // 封面是服务端用同一套货架样式拼好的图（`/collections/{id}/cover`），点进合集的海报墙
            let collections = homeCollections
            if !directory.browsable.isEmpty || !collections.isEmpty {
                TVShelf(title: row.title) {
                    ForEach(directory.browsable, id: \.id) { library in
                        TVLandscapeCard(title: library.name, subtitle: "\(library.stats.itemCount) 部",
                                        imageURL: api.image("/libraries/\(library.id)/cover"), width: 360) {
                            router.push(.library(library.id))
                        }
                    }
                    ForEach(collections, id: \.id) { collection in
                        TVLandscapeCard(title: collection.name, subtitle: "合集 · \(collection.itemCount) 部",
                                        imageURL: collection.covers.isEmpty ? nil : api.image("/collections/\(collection.id)/cover"),
                                        width: 360) {
                            router.push(.collection(id: collection.id, name: collection.name))
                        }
                    }
                }
            }
        case .library, .mediaKind, .collection:
            // 类型行（「全部电影」）是跨库的：每部片自带详情落点库（服务端给的 library_id）
            let items = store.itemsByKey[LibraryHomeStore.fetchKey(row)] ?? []
            if !items.isEmpty {
                TVShelf(title: row.title) {
                    ForEach(items, id: \.mediaItemId) { item in
                        TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                                     imageURL: api.image(item.posterUrl, .tvPoster)) {
                            if let libraryId = item.libraryId ?? Self.libraryId(of: row) {
                                router.push(.item(libraryId: libraryId, itemId: item.mediaItemId))
                            }
                        }
                    }
                    seeAll(row, total: Self.rowTotal(row))
                }
            }
        }
    }

    /// 行末尾的「查看全部」：进与这一行同一套取数参数的完整海报墙（每行只取前 20 部）
    @ViewBuilder
    private func seeAll(_ row: HomeRows.Row, total: Int?) -> some View {
        if let source = TVWallSource(row.kind) {
            TVSeeAllCard(total: total) {
                router.push(.rowWall(title: row.title, source: source))
            }
            .accessibilityIdentifier("tv-see-all-\(row.id)")
        }
    }

    /// 「查看全部」上写的总数：只在确切知道时写——媒体库没加筛选时用库的统计（「最近观看」「只看未看」的量不知道）
    static func rowTotal(_ row: HomeRows.Row) -> Int? {
        if case let .library(library, sort, _, unwatched, _, _) = row.kind, !unwatched, sort != "last_played" {
            return library.stats.itemCount
        }
        return nil
    }

    /// 「接下来继续」的一张卡：剧集用这一集的剧照（TMDB 原图压成电视横卡，本地只有 300 宽的小图），
    /// 电影用剧照。确认键续播；长按确认键出菜单（续播 / 详情）
    private func upNextCard(_ item: API.UpNextItemView) -> some View {
        let isEpisode = item.kind == "tv"
        let still = isEpisode
            ? (item.episodeStillOriginalUrl ?? item.episodeStillUrl ?? item.backdropUrl)
            : (item.backdropUrl ?? item.posterUrl)
        return TVLandscapeCard(
            title: item.title,
            subtitle: nil,
            imageURL: api.image(still, .tvLandscape),
            progress: item.progressPercent.map { Double($0) / 100 },
            badge: item.advanced ? "下一集" : nil,
            // 第几集、剩多久压在图片底部；片名一直写在剧照下面——剧照上认不出是哪部
            detail: Self.upNextBand(item),
            caption: .always
        ) {
            resume(item)
        }
        .contextMenu {
            Button(item.positionMs > 0 ? "继续播放" : "播放", systemImage: "play.fill") { resume(item) }
            Button("查看详情", systemImage: "info.circle") {
                router.push(.item(libraryId: item.libraryId, itemId: item.mediaItemId))
            }
        }
    }

    /// 卡片底部暗带里的紧凑写法（卡片 400 点宽，放不下「第 2 季 第 6 集 · 剩 18 分钟」）：
    /// 「S2 E6 · 剩 18 分钟」「剩 1 小时 5 分」；还没开始看的写全长：「S1 E2 · 41 分钟」「1 小时 58 分」
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

    /// 「第 1 季 第 3 集 · 剩 23 分钟」「剩 1 小时 5 分」
    static func upNextSubtitle(_ item: API.UpNextItemView) -> String? {
        var parts: [String] = []
        if item.kind == "tv" { parts.append("第 \(item.seasonNumber) 季 第 \(item.episodeNumber) 集") }
        if item.positionMs > 0, let remaining = Formatters.remaining(positionMs: item.positionMs, durationMs: item.durationMs) {
            parts.append(remaining)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 按确认键直接续播（续播点由服务端按这一集 / 这部片的进度给）
    private func resume(_ item: API.UpNextItemView) {
        let isEpisode = item.kind == "tv"
        router.play(PlayRequest(
            mediaItemId: item.mediaItemId,
            season: isEpisode ? item.seasonNumber : nil,
            episode: isEpisode ? item.episodeNumber : nil
        ))
    }

    /// 库行的条目里没带库 id 时，用行本身的库
    static func libraryId(of row: HomeRows.Row) -> Int? {
        if case let .library(library, _, _, _, _, _) = row.kind { return library.id }
        return nil
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

/// 首页首屏的焦点位置
enum TVHomeFocus: Hashable {
    case play
    case details
    case card(Int)
}
