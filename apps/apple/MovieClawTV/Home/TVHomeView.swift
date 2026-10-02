import SwiftUI

/// 首页（docs/design/tvos-app.md §3.1）：顶部大图 +「接下来继续」+ 用户在网页自定义的行。
///
/// 数据与 iPhone 版、网页同一份：`LibraryHomeStore`（快照秒开、静默刷新）按 `ui.preferences.home.rows`
/// 合并出行清单（`HomeRows`），这里只是换成电视的排布——第一屏就是「接下来继续」，按确认键直接续播。
/// 「我的媒体库」这一行在电视上不画：侧边栏已经列出了每个库。
struct TVHomeView: View {
    @Environment(\.api) private var api
    @Environment(AppModel.self) private var model
    @Environment(TVRouter.self) private var router

    private var store: LibraryHomeStore { .shared }
    /// 首页第一次有内容时把焦点放到「继续播放」上（之后不再抢：用户可能正在侧边栏里）
    @FocusState private var heroPlayFocused: Bool
    @State private var focusedOnce = false

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
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: TVMetrics.rowSpacing) {
                if let hero = heroItem {
                    TVHomeHero(item: hero, playFocused: $heroPlayFocused) { resume(hero) }
                }
                ForEach(rows) { row in
                    rowView(row)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        // 顶部大图铺到屏幕上沿
        .ignoresSafeArea(edges: [.horizontal, .top])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-home")
        .task(id: heroItem?.mediaItemId) {
            guard !focusedOnce, heroItem != nil else { return }
            focusedOnce = true
            // 等这一帧布局完再挪焦点，否则按钮还没进焦点系统
            try? await Task.sleep(for: .milliseconds(150))
            heroPlayFocused = true
        }
    }

    /// 顶部大图：接下来继续的第一部（打开 App 最想做的就是接着看）
    private var heroItem: API.UpNextItemView? {
        store.upNext?.first
    }

    @ViewBuilder
    private func rowView(_ row: HomeRows.Row) -> some View {
        switch row.kind {
        case .upNext:
            if let items = store.upNext, items.count > 1 {
                TVShelf(title: row.title) {
                    // 第一部已经在顶部大图里
                    ForEach(items.dropFirst(), id: \.mediaItemId) { item in
                        upNextCard(item)
                    }
                }
            }
        case .favorites:
            if let items = store.favorites?.items, !items.isEmpty {
                TVShelf(title: row.title) {
                    ForEach(items, id: \.mediaItemId) { item in
                        TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                                     imageURL: api.image(item.posterUrl, .posterCard)) {
                            router.push(.item(libraryId: item.libraryId, itemId: item.mediaItemId))
                        }
                    }
                }
            }
        case .libraries:
            // 侧边栏已经列出了每个库，首页不再重复
            EmptyView()
        case .library, .collection:
            let items = store.itemsByKey[LibraryHomeStore.fetchKey(row)] ?? []
            if !items.isEmpty {
                TVShelf(title: row.title) {
                    ForEach(items, id: \.mediaItemId) { item in
                        TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                                     imageURL: api.image(item.posterUrl, .posterCard)) {
                            if let libraryId = item.libraryId ?? Self.libraryId(of: row) {
                                router.push(.item(libraryId: libraryId, itemId: item.mediaItemId))
                            }
                        }
                    }
                }
            }
        }
    }

    private func upNextCard(_ item: API.UpNextItemView) -> some View {
        let isEpisode = item.kind == "tv"
        let still = isEpisode ? (item.episodeStillUrl ?? item.backdropUrl) : (item.backdropUrl ?? item.posterUrl)
        return TVLandscapeCard(
            title: item.title,
            subtitle: Self.upNextSubtitle(item),
            imageURL: api.image(still, .landscapeCard),
            progress: item.progressPercent.map { Double($0) / 100 },
            badge: item.advanced ? "下一集" : nil
        ) {
            resume(item)
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
        case .library, .collection: (store.itemsByKey[LibraryHomeStore.fetchKey(row)] ?? []).isEmpty
        }
    }

    private func reload() async {
        await store.reload(api: api, owner: owner)
    }
}

/// 首页顶部大图：背景剧照铺满上半屏，左下片名 + 进度说明 +「继续播放」「详情」两个按钮
struct TVHomeHero: View {
    let item: API.UpNextItemView
    var playFocused: FocusState<Bool>.Binding
    let play: () -> Void

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: api.image(item.backdropUrl ?? item.episodeStillUrl ?? item.posterUrl))
                .frame(maxWidth: .infinity)
                .frame(height: 760)
                .clipped()
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom)
                }
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .center)
                }
            VStack(alignment: .leading, spacing: 18) {
                Text(item.advanced ? "下一集" : "继续观看")
                    .font(.caption.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(2)
                    .shadow(radius: 10)
                if let subtitle = TVHomeView.upNextSubtitle(item) {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                if let percent = item.progressPercent, percent > 0 {
                    TVProgressStrip(value: Double(percent) / 100)
                        .frame(width: 420)
                }
                HStack(spacing: 28) {
                    Button(action: play) {
                        Label(item.positionMs > 0 ? "继续播放" : "播放", systemImage: "play.fill")
                            .padding(.horizontal, 12)
                    }
                    .focused(playFocused)
                    .accessibilityIdentifier("tv-home-hero-play")
                    Button {
                        router.push(.item(libraryId: item.libraryId, itemId: item.mediaItemId))
                    } label: {
                        Label("详情", systemImage: "info.circle")
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.bottom, 40)
            .focusSection()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-home-hero")
    }
}
