import SwiftUI

/// 发现（docs/design/tvos-app.md §3.1，侧边栏「更多」里的二级入口）：用电视的方式浏览——顶部大图（本周精选），
/// 下面是服务端给的榜单横排（今日热榜、正在热映、高分……），选中进作品详情，在那里播放或一键订阅。
///
/// 数据与 iPhone 版同一份：`DiscoverFeed`（版面 + Hero + 各行，快照秒开）。电视上只看 TMDB 视角
/// （豆瓣没有 Hero，榜单也只适合手机上细翻），电影 / 剧集在页面顶部切换。
struct TVDiscoverView: View {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(AppModel.self) private var model
    @Environment(TVRouter.self) private var router
    @State private var store = DiscoverFeedStore()
    @State private var mediaType = "movie"

    private var feed: DiscoverFeed { store.feed(mediaType: mediaType, provider: "tmdb") }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: TVMetrics.rowSpacing) {
                if let hero = feed.hero?.first {
                    TVDiscoverHero(item: hero, mediaType: $mediaType)
                } else {
                    TVDiscoverTypePicker(mediaType: $mediaType)
                        .padding(.horizontal, TVMetrics.edge)
                        .padding(.top, 40)
                }
                if let failure = feed.failure, feed.allRowsFailed || feed.layout == nil {
                    TVStateView(symbol: failure.unreachable ? "wifi.exclamationmark" : "exclamationmark.triangle",
                                title: failure.message, message: failure.hint, actionTitle: "重试") {
                        Task { await feed.reload(api: api) }
                    }
                    .frame(height: 520)
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
struct TVDiscoverTypePicker: View {
    @Binding var mediaType: String

    var body: some View {
        Picker("类型", selection: $mediaType) {
            Text("电影").tag("movie")
            Text("剧集").tag("tv")
        }
        .pickerStyle(.segmented)
        .frame(width: 420)
        .accessibilityIdentifier("tv-discover-type")
    }
}

/// 发现页顶部大图：本周精选的第一部，剧照铺满上半屏，左下片名、简介与「详情」
struct TVDiscoverHero: View {
    let item: DiscoverPosterItem
    @Binding var mediaType: String

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router

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
                TVDiscoverTypePicker(mediaType: $mediaType)
                    .padding(.bottom, 30)
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
                Button {
                    DiscoverMediaSeed.remember(item)
                    router.push(.discoverTitle(item.resolvedTitleRef))
                } label: {
                    Label("详情", systemImage: "info.circle")
                        .padding(.horizontal, 12)
                }
                .padding(.top, 8)
                .accessibilityIdentifier("tv-discover-hero-detail")
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.bottom, 40)
            .focusSection()
        }
    }
}
