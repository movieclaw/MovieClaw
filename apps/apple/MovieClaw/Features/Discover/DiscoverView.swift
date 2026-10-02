import Nuke
import SwiftUI

/// 发现页（发现标签根页，对应 Web `components/discover-view.tsx`）：Hero 轮播 + 分类横滚行。
///
/// 数据流：先读后端的展示清单 `GET /ui/discovery/{type}?provider=`（声明有哪些分区、每个分区画成
/// hero / ranked-row / poster-row），再把每个分区的 collectionRef 原样交给
/// `GET /discover/collections/{ref}/titles` 并发拉取——先到先渲染，失败的行整行收起；
/// 所有常规行都失败时整页进入错误态（上游不可达给「前往网络设置」）。
///
/// 顶栏：中间「电影 / 剧集」分段（Web 放在底栏附属位；原生不改 MainTabView，放顶栏）、
/// 右侧数据源（TMDB / 豆瓣）与「筛选」（仅 TMDB）。
/// 各视角（类型 × 数据源）的清单与片单结果缓存在 `DiscoverFeedStore` 里，来回切换即时恢复。
///
/// 筛选状态随视角走（同 Web：切类型、切数据源都跳到不带筛选的新地址）：电影与剧集的 TMDB
/// 类型 ID 是两套（电影 28=动作，剧集 10759=动作冒险），带着旧筛选切过去只会查出错的结果。
struct DiscoverView: View {
    let kind: String

    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @Environment(\.pageWarmup) private var warmup

    @State private var mediaType: String?
    @State private var source = "tmdb"
    @State private var filters = DiscoveryFilters.empty
    @State private var store = DiscoverFeedStore()
    /// 顶部安全区（状态栏 + 顶栏）高度：沉浸 Hero 用等量负边距顶到屏幕物理顶边
    @State private var topInset: CGFloat = 0
    /// Hero 当前那张（页面据此给氛围底取色）；切换电影 / 剧集、数据源时回到第一张
    @State private var heroIndex = 0
    /// 当前那张剧照的主色（氛围底，与订阅首页同一套取色）
    @State private var tint: Color?
    /// 滚动距离：只给 Hero（视差、淡出）与氛围底读，滚动时不重算整页
    @State private var scroll = ImmersiveHeroScroll()

    private var currentType: String { mediaType ?? (kind == "tv" ? "tv" : "movie") }
    private var feedKey: String { "\(currentType):\(source)" }
    private var filtering: Bool { source == "tmdb" && filters.activeCount > 0 }

    var body: some View {
        let feed = store.feed(mediaType: currentType, provider: source)
        Group {
            if filtering {
                DiscoverFilteredGrid(mediaType: currentType, filters: $filters)
                    .id(currentType)
            } else if let failure = feed.failure, feed.layout == nil || feed.allRowsFailed {
                DiscoverErrorView(failure: failure) {
                    await feed.reload(api: api)
                }
            } else {
                content(feed)
            }
        }
        .appBackground()
        // 站内链接 /discover/{movie|tv}[?source=&genres=…] 切到本标签时带来的视角（同 Web 地址即状态）
        .onChange(of: router.rootParameter, initial: true) { _, parameter in
            guard let parameter, parameter.tab == .discover else { return }
            let viewpoint = DiscoverViewpoint(parameter: parameter.value)
            mediaType = viewpoint.mediaType
            source = viewpoint.source
            filters = viewpoint.filters
            router.rootParameter = nil
        }
        // 左上角大字标题即当前看的类型（电影 / 剧集），后面小字是数据源；点标题弹出菜单切换两者
        // （iOS「切换当前页显示内容」的标题菜单交互，同「照片」「文件」）。系统的 toolbarTitleMenu
        // 不支持 inlineLarge 大标题（不显示箭头、点了不弹），所以用无玻璃底的前置菜单按钮画成大标题的样子。
        // 顶部不再另占一行，沉浸 Hero 完整露出；右上角只留筛选（TMDB 才有）与外壳的搜索
        .navigationTitle(currentType == "tv" ? "剧集" : "电影")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: feedKey) {
            guard !warmup else { return }
            // 冷启动落在发现页时先把第一帧（快照或骨架）送上屏，再发请求（见 FirstFrameGate）
            await FirstFrameGate.wait()
            await feed.loadIfNeeded(api: api)
        }
        .onAppear {
            guard !warmup else { return }
            PerfTrace.pageAppeared("discover")
            if feed.perfComplete, FirstFrameGate.state.opened { PerfTrace.pageDataReady("discover") }
        }
        .onChange(of: feed.perfComplete && FirstFrameGate.state.opened) { _, complete in
            if complete, !warmup { PerfTrace.pageDataReady("discover") }
        }
        .tracksSubscriptionIndex()
    }

    @ViewBuilder
    private func content(_ feed: DiscoverFeed) -> some View {
        let immersive = feed.declaresHero && feed.hero?.isEmpty != true
        // 冷启动落在这里时第一帧先画骨架（轻），开闸后下一帧再画快照 / 数据：
        // 首帧不被整页内容拖晚，完整页面紧跟着就到（见 FirstFrameGate）
        let skeleton = feed.layout == nil || !FirstFrameGate.state.opened
        ScrollView {
            // 大图不进懒加载容器（同订阅首页，用普通 VStack）：它向屏幕顶边之外伸出一截、带负的顶部留白，轮播指示器
            // 又一直在刷新；放在 LazyVStack 里，懒加载反复估算校正行位置，真机上大图会跟着上下浮动一点
            VStack(alignment: .leading, spacing: 28) {
                if skeleton {
                    DiscoverHeroSkeleton()
                } else if feed.declaresHero {
                    if let hero = feed.hero {
                        if !hero.isEmpty { DiscoverHeroHost(items: hero, scroll: scroll, index: $heroIndex) }
                    } else {
                        DiscoverHeroSkeleton()
                    }
                }
                // 懒加载：二十来行里首屏只看得见两三行，一上来就把每一行连同可见的海报卡全建出来太慢
                LazyVStack(alignment: .leading, spacing: 28) {
                    if skeleton {
                        DiscoverRowSkeleton(title: " ")
                        DiscoverRowSkeleton(title: " ")
                    } else {
                        ForEach(feed.rowSections, id: \.collectionRef) { section in
                            row(section, feed: feed)
                        }
                        if currentType == "movie", source == "tmdb" {
                            DiscoverRegionFooter {
                                // 院线地区改了：「正在热映 / 即将上映」随地区而变，清掉全部缓存重拉
                                store.invalidateAll()
                                await feed.reload(api: api)
                            }
                        }
                    }
                }
            }
            .padding(.top, immersive || skeleton ? -topInset : 8)
            .padding(.bottom, 32)
        }
        // 滚动视图铺到屏幕顶边，顶部内边距按顶栏高度手动给定，不交给系统按安全区自动让。
        // iOS 26 上自动让的内边距会跟着导航栏高度走，而导航栏会在「大标题展开 / 收起」之间无限来回
        // （约 1.8 秒一个来回，内边距在 122 与 174 之间变）：大图顶边随之在 0 与 52pt 之间跳，
        // 又被下拉拉伸放大，看起来忽高忽低一直闪。触发条件是负顶部留白 + 下面的行用 LazyVStack
        // （订阅首页没用懒加载，不受影响；iOS 27 只在启动时切一次）。内边距改成手动给定后循环断开；
        // 不能只铺满不给内边距——那样下拉刷新的转圈会跑到状态栏正中、被灵动岛挡住
        .contentMargins(.top, topInset, for: .scrollContent)
        .ignoresSafeArea(.container, edges: .top)
        // 沉浸 Hero 从状态栏与顶栏底下穿过：关掉顶部滚动边缘雾化，由 Hero 自带的顶部压暗保证控件可读
        .scrollEdgeEffectHidden(immersive, for: .top)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
            scroll.offset = offset
        }
        // 页面底色跟着当前那张剧照的主色走，剧照底部渐隐进去（与订阅首页同一套氛围底）
        .background { DiscoverAmbientHost(tint: immersive ? tint : nil, scroll: scroll) }
        .task(id: tintSource(feed)) {
            guard let url = tintSource(feed) else { return }
            if let color = await ImmersiveHeroAmbientColor.color(for: url), !Task.isCancelled { tint = color }
        }
        .onChange(of: feedKey) {
            heroIndex = 0
            // 切视角（电影 / 剧集）时这个视角的数据已经在（快照 / 缓存）：这一次打开当场就算数据就绪
            if feed.perfComplete, !warmup { PerfTrace.pageDataReady("discover") }
        }
        .refreshable { await feed.reload(api: api) }
        .accessibilityIdentifier("discover-scroll")
    }

    /// 当前那张 Hero 的剧照地址（与 Hero 显示同一个地址，取色命中图片缓存）
    private func tintSource(_ feed: DiscoverFeed) -> URL? {
        guard let hero = feed.hero, !hero.isEmpty else { return nil }
        return DiscoverHeroSlide.imageURL(hero[min(heroIndex, hero.count - 1)], api: api)
    }

    @ViewBuilder
    private func row(_ section: API.DiscoveryPageSectionView, feed: DiscoverFeed) -> some View {
        switch feed.rows[section.collectionRef] {
        case nil:
            DiscoverRowSkeleton(title: section.title)
        case let .loaded(items) where !items.isEmpty:
            let ref = section.supportsFullListing ? CollectionRef(section.collectionRef) : nil
            DiscoverPosterRow(
                title: section.title,
                items: ref == nil ? items : Array(items.prefix(10)),
                onMore: ref.map { ref in { router.push(ref.route) } }
            )
        default:
            // 失败或空行整行收起
            EmptyView()
        }
    }

    /// 标题菜单：类型与数据源两组（切类型保留数据源、切数据源保留类型，都清空筛选，同 Web）
    @ViewBuilder
    private var titleMenu: some View {
        Picker("类型", selection: Binding(mcGet: { currentType }, set: { next in
            guard next != currentType else { return }
            mediaType = next
            filters = .empty
        })) {
            Label("电影", systemImage: "film").tag("movie")
            Label("剧集", systemImage: "tv").tag("tv")
        }
        .pickerStyle(.inline)
        .accessibilityIdentifier("discover-type")
        Picker("数据源", selection: Binding(mcGet: { source }, set: { next in
            guard next != source else { return }
            source = next
            filters = .empty
        })) {
            Text("TMDB").tag("tmdb")
            Text("豆瓣").tag("douban")
        }
        .pickerStyle(.inline)
        .accessibilityIdentifier("discover-source")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } // 藏起系统的居中小标题
        ToolbarItem(placement: .topBarLeading) {
            Menu { titleMenu } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(currentType == "tv" ? "剧集" : "电影")
                        // 30pt：文字高度要落在工具栏按钮的高度（约 36pt）以内，34pt 会在菜单形变动画时被裁掉上半截
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(source == "tmdb" ? "TMDB" : "豆瓣")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.textMuted)
                }
                .fixedSize()
                .contentShape(.rect)
                // 不要用 offset 往左挪去对齐其它页的系统大标题（工具栏按钮自带约 9pt 内边距）：
                // 菜单弹出 / 收起的形变动画以按钮边界为起点，挪出边界的部分会被裁掉，切换瞬间「电」字缺一截（真机截图）。
                // 系统大标题位置（ToolbarItem .largeTitle）又不能交互，只能接受这 9pt 缩进
            }
            .accessibilityLabel("正在看\(currentType == "tv" ? "剧集" : "电影")，数据源\(source == "tmdb" ? "TMDB" : "豆瓣")")
            .accessibilityHint("切换类型或数据源")
            .accessibilityIdentifier("discover-title-menu")
        }
        .sharedBackgroundVisibility(.hidden)
        // 右上角只剩组合发现筛选（豆瓣视角没有）；整条顶栏的最右是外壳注入的搜索圆钮（MainTabView 的 AppTopBar）
        ToolbarItemGroup(placement: .topBarTrailing) {
            if source == "tmdb" {
                DiscoverFilterMenu(mediaType: currentType, filters: $filters)
            }
        }
    }
}

// MARK: - Hero

/// 发现页的沉浸 Hero：编辑推荐轮播（今日精选剧照 + 片名 + 简介 + 订阅键，左对齐）。
///
/// 轮播与图片处理和订阅首页是同一套（DesignSystem/ImmersiveHero.swift）：剧照慢速推近、上滑视差
/// 下沉与文字淡出、下半部压暗后渐隐进页面氛围色、指示器当前格按 8 秒填满、预载下一张。
/// 与订阅首页的区分在内容与版式：这里是编辑推荐（文字左对齐、指示器靠右下），订阅首页是
/// 时间驱动（片名 Logo 居中、大号时刻、指示器居中）；高度也略高（520 对 500）。
struct DiscoverHero: View {
    /// Hero 高度（pt，从屏幕物理顶边算起）：固定 520，约占 iPhone 屏高六成（用户拍板，原先 440）
    static let height: CGFloat = 520
    private static let interval: Double = 8

    let items: [DiscoverPosterItem]
    /// 列表向上滚动的距离（下拉为负）：驱动视差与淡出
    let scrollOffset: CGFloat
    @Binding var index: Int

    @Environment(\.api) private var api
    /// 指示器当前胶囊的填充进度 0...1
    @State private var fill: CGFloat = 0
    /// 左右安全区：轮播铺满整屏宽（横屏不让出灵动岛那侧），文字与指示器要自己躲开
    @State private var sideInsets = EdgeInsets()

    /// 预载下一张剧照：原图约 400KB～1MB，等轮到它才下载会闪一下空底；只预载下一张，蜂窝网络下不白烧流量
    private static let prefetcher = ImagePrefetcher()

    private var fade: Double { Double(max(0, min(1, 1 - scrollOffset / 260))) }

    var body: some View {
        TabView(selection: $index) {
            // 按条目认页（同订阅首页）：先画快照、再换成新数据时，同一下标换了一张图，
            // 按下标认会把上一张没走完的推近状态带到新图上
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                DiscoverHeroSlide(item: item, active: i == index, isFirst: i == 0, isLast: i == items.count - 1,
                                  scrollOffset: scrollOffset, fade: fade, sideInsets: sideInsets)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // 横屏时剧照也铺满整屏宽：不铺的话两侧安全区（灵动岛、圆角那一截）露出页面底色
        .ignoresSafeArea(.container, edges: .horizontal)
        .onGeometryChange(for: EdgeInsets.self, of: \.safeAreaInsets) { sideInsets = $0 }
        // 向屏幕顶边之外多占一截给下拉拉伸用（分页 TabView 会裁掉页外内容，见 ImmersiveHeroBackdrop），布局高度仍是 height
        .frame(height: DiscoverHero.height + ImmersiveHeroBackdrop.pullReserve)
        .padding(.top, -ImmersiveHeroBackdrop.pullReserve)
        .overlay(alignment: .bottomTrailing) {
            if items.count > 1 {
                ImmersiveHeroIndicator(count: items.count, index: $index, fill: fill) { "切换到《\(items[$0].title)》" }
                    .padding(.trailing, 20 + sideInsets.trailing)
                    .padding(.bottom, 16)
                    .opacity(fade)
            }
        }
        .immersiveHeroRotation(index: $index, count: items.count, fill: $fill, interval: Self.interval)
        .onChange(of: index, initial: true) { _, current in
            guard items.count > 1 else { return }
            let next = items[(current + 1) % items.count]
            if let url = DiscoverHeroSlide.imageURL(next, api: api) {
                Self.prefetcher.startPrefetching(with: [url])
            }
        }
        .accessibilityIdentifier("discover-hero")
    }
}

/// 只有它读滚动距离：滚动时只重算 Hero，不牵动整个发现页
private struct DiscoverHeroHost: View {
    let items: [DiscoverPosterItem]
    let scroll: ImmersiveHeroScroll
    @Binding var index: Int

    var body: some View {
        DiscoverHero(items: items, scrollOffset: scroll.offset, index: $index)
    }
}

private struct DiscoverAmbientHost: View {
    let tint: Color?
    let scroll: ImmersiveHeroScroll

    var body: some View {
        ImmersiveHeroAmbient(tint: tint, scrollOffset: scroll.offset)
    }
}

struct DiscoverHeroSlide: View {
    let item: DiscoverPosterItem
    let active: Bool
    let isFirst: Bool
    let isLast: Bool
    let scrollOffset: CGFloat
    let fade: Double
    /// 左右安全区（轮播铺满整屏宽，文字自己躲开）
    let sideInsets: EdgeInsets
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(Router.self) private var router

    var body: some View {
        let sub = SubscriptionIndex.shared.subscription(for: item)
        ZStack(alignment: .bottomLeading) {
            ImmersiveHeroBackdrop(url: Self.imageURL(item, api: api), active: active, scrollOffset: scrollOffset, height: DiscoverHero.height,
                                  isFirst: isFirst, isLast: isLast)

            VStack(alignment: .leading, spacing: 6) {
                Text("今日精选 · \(item.mediaType == "tv" ? "剧集" : "电影")")
                    .font(.caption.weight(.semibold))
                    .tracking(2.5)
                    .foregroundStyle(Theme.accent2)
                Text(item.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !item.originalTitle.isEmpty {
                    Text(item.originalTitle).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                meta
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
                if permissions.canSubscribe {
                    Button {
                        // 已订阅也打开订阅弹层：弹层预检发现既有订阅后进入管理态（同 Web `openSubscribe`）
                        router.present(.subscribe(SubscribeRequest(titleRef: item.resolvedTitleRef, title: item.title)))
                    } label: {
                        Label(sub == nil ? "订阅影片" : "已订阅", systemImage: sub == nil ? "plus" : "checkmark")
                            .heroActionLabel()
                    }
                    // 尺寸统一见 HeroActionButton.swift
                    .buttonStyle(HeroButtonStyle(prominent: sub == nil))
                    .controlSize(.regular)
                    .padding(.top, 6)
                    .accessibilityLabel(sub == nil ? "订阅影片《\(item.title)》" : "管理《\(item.title)》的订阅")
                    .accessibilityIdentifier("hero-subscribe")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .padding(.trailing, 60)
            .padding(.leading, sideInsets.leading)
            .padding(.trailing, sideInsets.trailing)
            .opacity(fade)
            .offset(y: max(0, scrollOffset) * 0.15)
        }
        .contentShape(.rect)
        .onTapGesture {
            DiscoverMediaSeed.remember(item)
            router.push(.mediaDetail(titleRef: item.resolvedTitleRef))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("查看《\(item.title)》详情")
    }

    /// 剧照地址见 `DiscoverHeroImage`（Apple TV 的发现页同一口径）
    static func fullResolution(_ raw: String?) -> String? { DiscoverHeroImage.fullResolution(raw) }

    static func imageURL(_ item: DiscoverPosterItem, api: APIClient) -> URL? { DiscoverHeroImage.url(item, api: api) }

    private var meta: some View {
        HStack(spacing: 10) {
            if item.rating > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.warning)
                    Text(String(format: "%.1f", item.rating)).fontWeight(.semibold).foregroundStyle(.white)
                }
            }
            if let year = item.year { Text(String(year)) }
            if !item.genres.isEmpty { Text(item.genres.joined(separator: " / ")).lineLimit(1) }
            if !item.extent.isEmpty { Text(item.extent) }
            if item.libraryStatus != nil {
                HStack(spacing: 4) {
                    Circle().fill(Theme.success).frame(width: 6, height: 6)
                    Text("在库")
                }
                .foregroundStyle(Color(red: 0.43, green: 0.91, blue: 0.72))
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.8))
    }
}

/// Hero 订阅键：未订阅用强调样式（同 Web btn-accent），已订阅用普通玻璃
private struct HeroButtonStyle: PrimitiveButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .discoverProminentButton()
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.glass)
        }
    }
}

struct DiscoverHeroSkeleton: View {
    var body: some View {
        DiscoverSkeletonBlock(cornerRadius: 0)
            .frame(height: DiscoverHero.height)
            .stretchesOnPull()
            .accessibilityLabel("发现页加载中")
    }
}

// MARK: - 错误态

/// 加载失败：后端中文原因 + 重试；上游不可达（UPSTREAM_UNREACHABLE）额外给地球图标、
/// 后端的下一步提示和「前往网络设置」（同 Web `DiscoverError`：普通失败不带图标，重试键为主按钮）
struct DiscoverErrorView: View {
    let failure: DiscoverFeed.Failure
    let retry: () async -> Void
    @Environment(Router.self) private var router
    @Environment(\.permissions) private var permissions
    @State private var retrying = false

    /// 网络设置是超管页面：成员不给跳转，重试键回到主按钮
    private var showsNetworkSettings: Bool { failure.unreachable && permissions.isAdmin }

    var body: some View {
        ContentUnavailableView {
            if failure.unreachable {
                Label("无法连接数据源", systemImage: "globe")
            } else {
                Text("发现页加载失败")
            }
        } description: {
            VStack(spacing: 8) {
                Text(failure.message)
                if failure.unreachable, let hint = failure.hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(Theme.textFaint)
                        .accessibilityIdentifier("discover-error-hint")
                }
            }
        } actions: {
            if showsNetworkSettings {
                Button("前往网络设置") { router.push(.settingsSection(.network)) }
                    .discoverProminentButton()
                    .accessibilityIdentifier("discover-network-settings")
            }
            if showsNetworkSettings {
                retryButton.buttonStyle(.glass)
            } else {
                retryButton.discoverProminentButton()
            }
        }
        .accessibilityIdentifier("error-state")
    }

    private var retryButton: some View {
        Button {
            retrying = true
            Task { await retry(); retrying = false }
        } label: {
            if retrying { ProgressView() } else { Text("重试") }
        }
        .disabled(retrying)
    }
}

// MARK: - 院线地区

/// 院线地区就地设置（只在电影 × TMDB 视角出现）：管理员可切换，选择即保存，随后整页重拉
struct DiscoverRegionFooter: View {
    let onChanged: () async -> Void
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @State private var region: String?
    @State private var canEdit = false
    @State private var saved = false

    var body: some View {
        Group {
            if let region {
                HStack(spacing: 6) {
                    Text("院线地区：")
                    if canEdit {
                        Menu {
                            ForEach(DiscoverRegions.all, id: \.code) { item in
                                Button {
                                    Task { await pick(item.code) }
                                } label: {
                                    if item.code == region { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text(DiscoverRegions.name(region)).underline()
                                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                            }
                            .foregroundStyle(Theme.textMuted)
                        }
                        .accessibilityIdentifier("discover-region")
                    } else {
                        Text(DiscoverRegions.name(region)).foregroundStyle(Theme.textMuted)
                    }
                    if saved { Text("✓ 已保存").foregroundStyle(Theme.success) }
                }
                .font(.footnote)
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
        .task {
            guard region == nil, let view = try? await api.discoverRegionShow() else { return }
            region = view.region
            canEdit = view.canEdit
        }
    }

    private func pick(_ code: String) async {
        guard code != region else { return }
        let previous = region
        region = code // 乐观更新：菜单一收起就看到新地区名
        do {
            let view = try await api.discoverRegionSet(body: .init(region: code))
            region = view.region
            saved = true
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                saved = false
            }
            await onChanged()
        } catch {
            region = previous
            feedback.error(error)
        }
    }
}
