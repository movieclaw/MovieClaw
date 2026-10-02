import Nuke
import SwiftUI

/// 首页（docs/design/tvos-app.md §3.1）：首屏是「接下来继续」的大图区，下面接用户在网页自定义的行。
///
/// 大图区是**焦点驱动**的（2026-10-02 用户选定，同 Netflix 新版电视首页、Infuse）：
/// - 首屏底部一行「接下来继续」小卡；整页背景剧照、片名、简介永远讲焦点所在的那一部，左右移动时交叉淡入；
/// - 不自动轮播：画面只在用户移动焦点时才换，按确认键播放的一定是眼前这部（「继续观看」是要挑着看的，
///   自己会转的轮播一次只露一部，还会在焦点底下换片）；
/// - 确认键直接续播（播放第一）；长按确认键弹菜单，可以进详情；
/// - 焦点离开这一行（往下看别的行、展开侧边栏）时，大图停在最后看的那一部；
/// - 页面底色取大图主色（与 iPhone 订阅首页 / 发现页同一套取色），往下滚时剧照淡出、颜色退淡。
///
/// 数据与 iPhone 版、网页同一份：`LibraryHomeStore`（快照秒开、静默刷新）按 `ui.preferences.home.rows`
/// 合并出行清单（`HomeRows`）。「接下来继续」这一行在电视上就是首屏大图区（用户在网页隐藏了这一行就不画），
/// 其余行按顺序接在下面；「我的媒体库」这一行不画：侧边栏已经列出了每个库。
struct TVHomeView: View {
    @Environment(\.api) private var api
    @Environment(AppModel.self) private var model
    @Environment(TVRouter.self) private var router

    private var store: LibraryHomeStore { .shared }
    /// 焦点所在的「接下来继续」卡（条目 id）；焦点不在这一行时为 nil
    @FocusState private var focusedCard: Int?
    /// 大图区正在讲的那一部（条目 id）：焦点停稳后才跟过去，按住方向键一路划过时不逐张闪
    @State private var stageId: Int?
    /// 大图剧照的主色（页面氛围底色）
    @State private var tint: Color?
    /// 列表滚动距离：只给背景层读，滚动时不重算整页
    @State private var scroll = TVHomeScroll()
    /// 首页第一次有内容时把焦点放到第一张卡上（播放第一：开机按确认就续播）；之后不再抢，用户可能正在侧边栏里
    @State private var focusedOnce = false

    /// 预载焦点左右两部的剧照：原图约 1MB，等焦点移过去才下载会闪一下空底
    private static let prefetcher = ImagePrefetcher()

    private var owner: String {
        PageSnapshots.owner(server: api.server, username: model.session?.username ?? "")
    }

    private var rows: [HomeRows.Row] {
        guard let libraries = store.libraries else { return [] }
        return HomeRows.build(prefs: LibraryHomePrefs.shared.rows ?? store.snapshotRows ?? [], libraries: libraries, collections: store.collections)
            .filter { !$0.hidden }
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
                    // 没有大图区时第一行别和左上角侧边栏收起后的按钮挤在一起
                    Color.clear.frame(height: 30)
                }
                ForEach(visibleRows) { row in
                    rowView(row)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scroll.offset = offset
        }
        // 只横向铺满（横滑行自己补左边距）。顶部保留安全区：列表静止时内容从左上角侧边栏按钮的下沿排起，
        // 首屏不必自己留白避让；大图背景在 background 里自己铺满全屏，不受影响
        .ignoresSafeArea(edges: .horizontal)
        .background {
            TVHomeBackdrop(url: backdrop, tint: stage == nil ? nil : tint, scroll: scroll)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-home")
        .task(id: upNext.first?.mediaItemId) {
            guard !focusedOnce, let first = upNext.first else { return }
            focusedOnce = true
            // 等这一帧布局完再挪焦点，否则卡片还没进焦点系统
            try? await Task.sleep(for: .milliseconds(150))
            focusedCard = first.mediaItemId
        }
        // 焦点停稳 0.16 秒再换大图：按住方向键一路划过去时，中间那些不逐张加载、逐张闪
        .task(id: focusedCard) {
            guard let id = focusedCard, id != stageId else { return }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { stageId = id }
        }
        // 换了一部：取主色铺底；预载左右两部的剧照，焦点移过去时直接从内存出图
        .task(id: backdrop) {
            if let stage, let index = upNext.firstIndex(where: { $0.mediaItemId == stage.mediaItemId }) {
                let neighbours = [index - 1, index + 1].filter { upNext.indices.contains($0) }
                Self.prefetcher.startPrefetching(with: neighbours.compactMap { stageImageURL(upNext[$0]) })
            }
            guard let backdrop, let color = await ImmersiveHeroAmbientColor.color(for: backdrop), !Task.isCancelled else { return }
            tint = color
        }
    }

    /// 首屏文字区的高度。整个首屏的竖向尺寸是按 tvOS 的焦点滚动规则倒推的：列表静止在顶部时
    /// （内容从侧边栏按钮下沿排起），获得焦点的卡片连同下面两行字要离屏幕底边一百来点，否则系统会
    /// 自己把列表往上滚一截让出余量——启动时滚了、从下面的行回来时又滚回顶部，首屏就上下跳。
    /// 文字区 368 + 卡片行刚好满足（实测 378 时启动会被系统滚动 7 点）；下一行的标题从屏幕底边露出来，暗示下面还有
    private static let stageInfoHeight: CGFloat = 368

    /// 首屏：上面讲焦点那一部，底部一行「接下来继续」。
    /// - 文字区高度固定、文字贴底排：有没有 Logo、简介几行都只影响文字往上长多少，卡片行纹丝不动；
    /// - 换一部时新旧两段文字在同一个框里叠着交叉淡入——不能让它们在 VStack 里上下并排，
    ///   否则过渡那一下首屏会被撑高、整块往上跳
    private func stageSection(_ stage: API.UpNextItemView, items: [API.UpNextItemView]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack(alignment: .bottomLeading) {
                TVHomeStageInfo(item: stage)
                    .id(stage.mediaItemId)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .frame(height: Self.stageInfoHeight, alignment: .bottomLeading)
            .padding(.horizontal, TVMetrics.edge)
            TVShelf(title: "接下来继续") {
                ForEach(Array(items.enumerated()), id: \.element.mediaItemId) { index, item in
                    upNextCard(item)
                        .focused($focusedCard, equals: item.mediaItemId)
                        .accessibilityIdentifier("tv-home-continue-\(index)")
                }
            }
        }
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
                }
            }
        case .libraries:
            // 侧边栏已经列出了每个库，首页不再重复
            EmptyView()
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
                }
            }
        }
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
            subtitle: Self.upNextSubtitle(item),
            imageURL: api.image(still, .tvLandscape),
            width: 360,
            progress: item.progressPercent.map { Double($0) / 100 },
            badge: item.advanced ? "下一集" : nil
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
        case .libraries: true
        case .library, .mediaKind, .collection: (store.itemsByKey[LibraryHomeStore.fetchKey(row)] ?? []).isEmpty
        }
    }

    private func reload() async {
        await store.reload(api: api, owner: owner)
    }
}
