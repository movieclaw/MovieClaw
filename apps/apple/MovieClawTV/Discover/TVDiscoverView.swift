import SwiftUI

/// 发现（docs/design/tvos-app.md §3.1，标签栏的一项）：用电视的方式浏览——顶部大图（本周精选），
/// 下面是服务端给的榜单横排（今日热榜、正在热映、高分……），选中进作品详情，在那里播放或一键订阅。
///
/// 数据与 iPhone 版同一份：`DiscoverFeed`（版面 + Hero + 各行，快照秒开）。电视上只看 TMDB 视角
/// （豆瓣没有 Hero，榜单也只适合手机上细翻）。电影、剧集是标签栏上的两个页签（「发现电影」「发现剧集」），
/// 各自固定一种，页面顶部只留「片段」的入口。
struct TVDiscoverView: View {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(AppModel.self) private var model
    @Environment(TVRouter.self) private var router
    @State private var store = DiscoverFeedStore()
    /// 列表的滚动位置：焦点从下面的行回到大图的按钮时滚回顶部
    @State private var position = ScrollPosition(edge: .top)
    /// "movie" / "tv"：由标签栏的页签决定
    let mediaType: String

    private var feed: DiscoverFeed { store.feed(mediaType: mediaType, provider: "tmdb") }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: TVMetrics.rowSpacing) {
                if let hero = feed.hero?.first {
                    TVDiscoverHero(item: hero) {
                        withAnimation(.easeInOut(duration: 0.35)) { position.scrollTo(edge: .top) }
                    }
                } else {
                    // 没有大图（加载中 / 失败）时顶上什么都不放：贴着标签栏的按钮会在切页签时把焦点抢走
                    Color.clear.frame(height: 40)
                }
                if let failure = feed.failure, feed.allRowsFailed || feed.layout == nil {
                    TVStateView(symbol: failure.unreachable ? "wifi.exclamationmark" : "exclamationmark.triangle",
                                title: failure.message, message: failure.hint, actionTitle: "重试") {
                        Task { await feed.reload(api: api) }
                    }
                    .frame(height: 520)
                    // 发现数据取不到时「片段」照样能用（它放的是自己片库里的片段）
                    TVDiscoverReelsEntry()
                        .frame(maxWidth: .infinity)
                }
                if let hero = feed.hero, hero.count > 1 {
                    shelf(title: "本周精选", items: Array(hero.dropFirst()))
                }
                ForEach(feed.rowSections, id: \.collectionRef) { section in
                    if case let .loaded(items) = feed.rows[section.collectionRef], !items.isEmpty {
                        shelf(title: section.title, items: items)
                    }
                }
                if feed.layout == nil, feed.failure == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .scrollPosition($position)
        .ignoresSafeArea(edges: [.horizontal, .top])
        .task(id: mediaType) {
            await feed.loadIfNeeded(api: api)
            if permissions.canSubscribe {
                await SubscriptionIndex.shared.ensureLoaded(api: api, owner: model.session?.username)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-discover")
    }

    private func shelf(title: String, items: [DiscoverPosterItem]) -> some View {
        TVShelf(title: title) {
            ForEach(items) { item in
                TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                             imageURL: api.image(item.posterUrl, .tvPoster), badge: badge(for: item)) {
                    DiscoverMediaSeed.remember(item)
                    router.push(.discoverTitle(item.resolvedTitleRef))
                }
            }
        }
    }

    /// 角标：已入库优先（能直接看），其次已订阅
    private func badge(for item: DiscoverPosterItem) -> String? {
        if item.libraryStatus != nil { return "已入库" }
        if permissions.canSubscribe, let sub = SubscriptionIndex.shared.subscription(for: item) {
            return SubscriptionStatusMeta.label(sub.status)
        }
        return nil
    }
}

/// 电影 / 剧集切换
/// 片段（自己片库里的随机片段连播）是低频入口，标签栏不单独占一格，放在发现页顶部
struct TVDiscoverReelsEntry: View {
    @Environment(TVRouter.self) private var router

    var body: some View {
        Button { router.push(.reels) } label: {
            Label("片段", systemImage: "film.stack")
        }
        .accessibilityIdentifier("tv-discover-reels")
    }
}

/// 发现页顶部大图：本周精选的第一部，剧照铺满上半屏，左下片名、简介与「详情」
struct TVDiscoverHero: View {
    let item: DiscoverPosterItem
    /// 焦点进了按钮行：页面滚回顶部。从下面的行往上回来时系统只滚到按钮刚好露出为止，
    /// 标签栏还在屏幕外，再按「上」就上不去了（tvOS 26 原生标签栏，2026-10-03 实测）
    var onFocus: () -> Void = {}

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @FocusState private var focused: HeroButton?

    private enum HeroButton { case details, reels }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: DiscoverHeroImage.url(item, api: api))
                .frame(maxWidth: .infinity)
                .frame(height: 780)
                .clipped()
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom)
                }
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .center)
                }
            VStack(alignment: .leading, spacing: 18) {
                Text("本周精选")
                    .font(.caption.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(2)
                    .shadow(radius: 10)
                Text([item.year.map(String.init), item.rating > 0 ? "★ " + String(format: "%.1f", item.rating) : nil,
                      item.genres.prefix(3).joined(separator: " · ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                // 「片段」放在「详情」旁边而不是大图顶上：贴着标签栏的按钮会在切页签、页面重建时把焦点从标签栏抢走（实测）
                HStack(spacing: 28) {
                    Button {
                        DiscoverMediaSeed.remember(item)
                        router.push(.discoverTitle(item.resolvedTitleRef))
                    } label: {
                        Label("详情", systemImage: "info.circle")
                            .padding(.horizontal, 12)
                    }
                    .focused($focused, equals: .details)
                    .accessibilityIdentifier("tv-discover-hero-detail")
                    TVDiscoverReelsEntry()
                        .focused($focused, equals: .reels)
                }
                .padding(.top, 8)
                // 按钮这一行横贯整屏做成焦点区：往下按会先落到这里，不会越过大图直接进下面的海报行；
                // 进来时落在「详情」上——标签栏右边几项往下，按位置最近的是「片段」
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                .defaultFocus($focused, .details, priority: .userInitiated)
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.bottom, 40)
            .focusSection()
        }
        .onChange(of: focused) { old, new in
            if old == nil, new != nil { onFocus() }
        }
    }
}
