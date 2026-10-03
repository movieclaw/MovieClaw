import SwiftUI

/// 我的订阅（docs/design/tvos-app.md §3.1，标签栏的一项，没有订阅权限时不出现）：以看为主——
/// 顶部「下一部到手的」、刚刚入库（按确认键直接播）、本周日程、在追的剧集与电影。
///
/// 判定口径与 iPhone 版、网页完全一致（`SubscriptionsHome`：Hero 的挑选与排序、刚刚入库的播放入口、日程、
/// 海报行里谁排前面），数据也是同一份（`SubscriptionIndex` + `SubscriptionsHomeFeed`，快照秒开）。
/// 电视上不做编辑规则、暂停、取消、整理、体检——这些在手机和网页上做。选中一部订阅进它的作品详情。
struct TVSubscriptionsView: View {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(AppModel.self) private var model
    @Environment(TVRouter.self) private var router

    /// 列表的滚动位置：焦点从下面的行回到大图的按钮时滚回顶部
    @State private var position = ScrollPosition(edge: .top)

    private var index: SubscriptionIndex { .shared }
    private var feed: SubscriptionsHomeFeed { .shared }

    var body: some View {
        Group {
            if let subscriptions = index.subscriptions {
                if subscriptions.isEmpty {
                    TVStateView(symbol: "bookmark", title: "还没有订阅",
                                message: "在「发现」里选一部作品按「订阅」，有新资源时会自动下载入库。",
                                actionTitle: "去发现") { router.selectedTab = .discoverMovies }
                } else {
                    content(feed.state(for: subscriptions))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await reload() }
        .polling(every: 30) { await reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-subscriptions")
    }

    private func content(_ state: SubsHomeState) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: TVMetrics.rowSpacing) {
                if let slide = state.slides.first {
                    TVSubscriptionHero(slide: slide) {
                        withAnimation(.easeInOut(duration: 0.35)) { position.scrollTo(edge: .top) }
                    }
                } else {
                    Text("我的订阅")
                        .font(.title.weight(.bold))
                        .padding(.horizontal, TVMetrics.edge)
                        .padding(.top, 40)
                }
                if !feed.recent.isEmpty {
                    TVShelf(title: "刚刚入库") {
                        ForEach(feed.recent, id: \.self) { card in
                            TVLandscapeCard(
                                title: card.media.title,
                                subtitle: SubscriptionsHome.recentDetail(card),
                                imageURL: api.image(card.stillUrl ?? card.media.backdropUrl ?? card.media.posterUrl, .tvLandscape),
                                progress: card.progressPercent.map { Double($0) / 100 },
                                badge: "新"
                            ) {
                                router.play(SubscriptionsHome.playRequest(card))
                            }
                        }
                    }
                }
                if !state.days.isEmpty, state.days.contains(where: { !$0.entries.isEmpty }) {
                    TVShelf(title: "本周日程") {
                        ForEach(state.days) { day in
                            TVScheduleDayCard(day: day)
                        }
                    }
                }
                shelf("剧集", state.tv)
                shelf("电影", state.movie)
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .scrollPosition($position)
        .ignoresSafeArea(edges: [.horizontal, .top])
    }

    @ViewBuilder
    private func shelf(_ title: String, _ shelf: SubsHomeShelf) -> some View {
        if !shelf.isEmpty {
            TVShelf(title: title, detail: "\(shelf.all.count) 部") {
                ForEach(shelf.all) { entry in
                    TVPosterCard(title: entry.sub.media.title, subtitle: entry.chip?.text ?? entry.meta,
                                 imageURL: api.image(entry.sub.media.posterUrl, .tvPoster),
                                 progress: entry.progress,
                                 badge: entry.resting ? SubscriptionStatusMeta.label(entry.sub.status) : nil) {
                        router.push(.discoverTitle("tmdb:\(entry.sub.media.kind):\(entry.sub.media.tmdbId)"))
                    }
                    .opacity(entry.resting ? 0.6 : 1)
                }
            }
        }
    }

    private func reload() async {
        let username = model.session?.username
        await index.ensureLoaded(api: api, owner: username, maxAge: 20)
        await feed.refreshIfStale(api: api, isAdmin: permissions.isAdmin, maxAge: 20)
    }
}

/// 顶部「下一部到手的」：剧照铺满上半屏，眉标（下载中 / 刚刚入库 / 今天……）、片名、时间与进度；
/// 已经入库的给「播放」
struct TVSubscriptionHero: View {
    let slide: SubsHomeHeroSlide
    /// 焦点进了按钮行：页面滚回顶部。从下面的行往上回来时系统只滚到按钮刚好露出为止，
    /// 标签栏还在屏幕外，再按「上」就上不去了（tvOS 26 原生标签栏，2026-10-03 实测）
    var onFocus: () -> Void = {}

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @FocusState private var focused: HeroButton?

    private enum HeroButton { case play, details }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: api.server.originalTMDBImageURL(slide.media.backdropUrl) ?? api.image(slide.media.posterUrl))
                .frame(maxWidth: .infinity)
                .frame(height: 760)
                .clipped()
                .overlay { LinearGradient(colors: [.clear, .black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom) }
                .overlay { LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .center) }
            VStack(alignment: .leading, spacing: 18) {
                Text(slide.eyebrow.text)
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(slide.eyebrow.tone.color.opacity(0.25), in: .capsule)
                    .foregroundStyle(slide.eyebrow.tone.color)
                Text(slide.media.title)
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(2)
                    .shadow(radius: 10)
                if let clock = slide.clock {
                    Text([slide.clockLabel, clock].compactMap { $0 }.joined(separator: " "))
                        .font(.title3.monospacedDigit())
                }
                if let detail = slide.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                if let progress = slide.progress {
                    TVProgressStrip(value: progress).frame(width: 420)
                }
                HStack(spacing: 28) {
                    if let play = slide.play {
                        Button { router.play(play) } label: {
                            Label("播放", systemImage: "play.fill").padding(.horizontal, 12)
                        }
                        .focused($focused, equals: .play)
                        .accessibilityIdentifier("tv-subscriptions-hero-play")
                    }
                    Button {
                        router.push(.discoverTitle("tmdb:\(slide.media.kind):\(slide.media.tmdbId)"))
                    } label: {
                        Label("详情", systemImage: "info.circle")
                    }
                    .focused($focused, equals: .details)
                }
                .padding(.top, 8)
                // 按钮这一行横贯整屏做成焦点区：标签栏上「我的订阅」往下会先落到这里，不会越过大图直接进下面的行；
                // 进来时落在第一个按钮上，不按位置挑最近的
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                .defaultFocus($focused, slide.play == nil ? .details : .play, priority: .userInitiated)
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.bottom, 40)
            .focusSection()
        }
        .onChange(of: focused) { old, new in
            if old == nil, new != nil { onFocus() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-subscriptions-hero")
    }
}

/// 日程里的一天：日期 + 当天要到的集（只看，按确认键没有动作；用卡片样式是为了能用遥控器滑过去看）
private struct TVScheduleDayCard: View {
    let day: SubsHomeScheduleDay

    var body: some View {
        Button {} label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(day.dayNumber).font(.title2.weight(.bold).monospacedDigit())
                    Text(day.dateLabel).font(.callout)
                    Text(day.weekday).font(.caption).foregroundStyle(.secondary)
                }
                if day.entries.isEmpty {
                    Text("没有要到的").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(day.entries.prefix(4)) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text([entry.episodeLabel, entry.time, entry.status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(entry.tone.color)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(width: 360, height: 300, alignment: .topLeading)
        }
        .buttonStyle(.card)
    }
}
