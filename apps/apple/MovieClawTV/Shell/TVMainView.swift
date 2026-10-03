import SwiftUI

/// 主界面：系统原生的可收起侧边栏（`sidebarAdaptable`，docs/design/tvos-app.md §3.3，同系统 Apple TV App）。
///
/// 平时只在左上角收成一枚小胶囊（写着当前页），整屏留给内容；按「左」或返回键展开成左侧边栏，焦点移到哪一项就切到哪一页。
/// 从上到下：账号 / 搜索 / 首页 / 我的订阅 / 发现电影 / 发现剧集。账号在最上面、搜索紧随其后，同系统 Apple TV App 的侧边栏。
/// 「我的订阅」「发现电影」「发现剧集」暂时收起（`showsDiscoverAndSubscriptions`），见下。
/// 2026-10-03 用户改定（此前是顶部标签栏 + 左上头像 + 右上标志）：顶部一排菜单在电视上压着大图，收进左上角主屏更干净。
/// 各个媒体库从首页的「我的媒体库」进，片段从发现页进。播放器全屏盖在主界面之上（`fullScreenCover`）。
struct TVMainView: View {
    @Environment(AppModel.self) private var model
    @Environment(TVDeepLinkInbox.self) private var inbox
    @State private var router: TVRouter
    @State private var libraries = TVLibraryDirectory()

    init() {
        #if DEBUG
        // 调试落点只用一次：在「谁在看」里换了账号，主界面整棵重建，这时应当落回首页
        let landing = Self.debugLandingUsed ? nil : UserDefaults.standard.string(forKey: "mcTab").flatMap(TVRouter.debugLanding)
        Self.debugLandingUsed = true
        _router = State(initialValue: TVRouter(landing: landing?.tab ?? .home, path: landing?.path ?? []))
        #else
        _router = State(initialValue: TVRouter(landing: .home))
        #endif
    }

    private var api: APIClient { model.api ?? EnvironmentValues().api }
    private var session: API.SessionView? { model.session }
    private var permissions: Permissions { session.map(Permissions.init(session:)) ?? .none }

    #if DEBUG
    nonisolated(unsafe) private static var debugLandingUsed = false
    #endif

    /// 「我的订阅」「发现电影」「发现剧集」三个页签的总开关。2026-10-03 用户决定 Apple TV 先只打磨首页与播放，
    /// 这三项连同从发现页进的「片段」暂时不在侧边栏出现；页面代码原样保留，打磨好后改回 true 即可
    static let showsDiscoverAndSubscriptions = false

    var body: some View {
        @Bindable var router = router
        TabView(selection: Binding(mcGet: { router.selectedTab }, set: { tab in
            // 再点一次当前页签：回到这个页签的最外层（同 iOS / tvOS 的通行做法）。详情这类二级页虽然收起了标签栏，
            // 焦点往左越过页面左沿时系统照样会拉出侧边栏，这时点「首页」原先什么都不发生（2026-10-04 用户在真机上发现）
            if tab == router.selectedTab { router.paths[tab] = [] }
            router.selectedTab = tab
        })) {
            // 账号：选自己回首页，「关于」在本页签里压栈打开（选别人则整棵主界面按新账号重建）。
            // 头像放进侧边栏顶部（`tabViewSidebarHeader`）要 tvOS 27，先做成第一项
            Tab(session?.nickname ?? "账号", systemImage: "person.crop.circle", value: MainTab.account) {
                TVTabRoot(tab: .account) {
                    TVWhoIsWatchingView(onClose: { router.selectedTab = .home }, onAbout: { router.push(.about) })
                }
            }
            Tab(value: MainTab.search, role: .search) {
                TVTabRoot(tab: .search) { TVSearchView() }
            }
            Tab("首页", systemImage: "house", value: MainTab.home) {
                TVTabRoot(tab: .home) { TVHomeView() }
            }
            if Self.showsDiscoverAndSubscriptions {
                if permissions.canSubscribe {
                    Tab("我的订阅", systemImage: "bookmark", value: MainTab.subscriptions) {
                        TVTabRoot(tab: .subscriptions) { TVSubscriptionsView() }
                    }
                }
                Tab("发现电影", systemImage: "film", value: MainTab.discoverMovies) {
                    TVTabRoot(tab: .discoverMovies) { TVDiscoverView(mediaType: "movie") }
                }
                Tab("发现剧集", systemImage: "tv", value: MainTab.discoverShows) {
                    TVTabRoot(tab: .discoverShows) { TVDiscoverView(mediaType: "tv") }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // 侧边栏被拉出来时页签里还压着页面：返回键先退一页。不接的话系统把这一下当成在页签根上按返回，
        // 直接退出 App（2026-10-04 实测）。页签根上不接（nil），交给系统：展开侧边栏 / 退到主屏
        .onExitCommand(perform: (router.paths[router.selectedTab] ?? []).isEmpty ? nil : { router.pop() })
        .environment(router)
        .environment(libraries)
        .environment(\.api, api)
        .environment(\.permissions, permissions)
        .fullScreenCover(item: $router.player) { request in
            TVPlayerScreen(request: request)
                .environment(router)
                .environment(\.api, api)
        }
        .task {
            await libraries.load(api: api)
        }

        .onAppear {
            // 临时：返回键失灵查因，按键时把路由一起记下（见 TVPressDiagnostics）
            TVPressDiagnostics.routerState = { [router] in
                let paths = router.paths.filter { !$0.value.isEmpty }.map { "\($0.key.rawValue)=\($0.value.count)层" }
                return "页签=\(router.selectedTab.rawValue) 栈[\(paths.joined(separator: ","))] 播放器=\(router.player == nil ? "无" : "有")"
            }
            // 点播放就开始起播（同 iPhone 版 Router.startPlaybackEarly）：API 客户端在点击那一刻取，换过账号用的是新的
            router.startPlaybackEarly = { [router, model] request in
                if let current = router.activePlayback, current.isClosed || (!current.viewAttached && current.request.id != request.id) {
                    current.close()
                    router.activePlayback = nil
                }
                guard router.activePlayback?.request.id != request.id else { return }
                let controller = PlaybackController(request: request, api: model.api ?? EnvironmentValues().api, requestedAt: router.playRequestedAt)
                router.activePlayback = controller
                controller.start()
            }
        }
        .onChange(of: inbox.pending, initial: true) { _, link in
            // Top Shelf 的「播放」直接续播、「确认」打开详情（docs/design/tvos-app.md §3.1）；链接由根视图收下
            guard let link else { return }
            inbox.pending = nil
            switch link {
            case let .play(itemId, season, episode):
                router.play(PlayRequest(mediaItemId: itemId, season: season, episode: episode))
            case let .item(libraryId, itemId):
                router.selectedTab = .home
                router.paths[.home] = [.item(libraryId: libraryId, itemId: itemId)]
            }
        }
        .onChange(of: router.player?.id) { _, presented in
            // 提前起播了、播放器却没弹出来就被撤掉：这里关掉，免得会话与引擎空跑
            if let early = router.activePlayback, !early.viewAttached, early.request.id != presented {
                early.close()
                router.activePlayback = nil
            }
        }
        #if DEBUG
        .task {
            // 开发期：-mcRoute 直接打开一个站内路径（目前支持 /play/{id}[/sXXeYY][?t=秒]，模拟器验收用）
            guard let path = DebugLaunch.route else { return }
            if let delay = DebugLaunch.routeDelay, delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            if let request = PlayRequest(webPath: path) { router.play(request) }
        }
        #endif
    }
}

/// 一个页签的根：自己的导航栈 + 电视上能压栈的页面
struct TVTabRoot<Content: View>: View {
    let tab: MainTab
    @ViewBuilder let content: () -> Content
    @Environment(TVRouter.self) private var router

    var body: some View {
        NavigationStack(path: router.path(for: tab)) {
            content()
                .navigationDestination(for: AppRoute.self) { route in
                    TVDestination(route: route)
                }
        }
    }
}

/// 压栈页面的路由表。二级页一律收起系统标签栏：进了详情就只剩这一部（同 Netflix、Apple TV App 的详情页，
/// 2026-10-03 用户嫌详情页顶上还挂着导航菜单、没有沉浸感），返回键退回页签时标签栏再出来
struct TVDestination: View {
    let route: AppRoute

    var body: some View {
        page
            .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private var page: some View {
        switch route {
        case let .item(libraryId, itemId): TVItemDetailView(libraryId: libraryId, itemId: itemId)
        case let .library(id): TVLibraryView(libraryId: id)
        case let .collection(id, name): TVCollectionView(collectionId: id, name: name)
        case let .person(tmdbId, name, avatar, fromItem):
            TVPersonView(tmdbId: tmdbId, name: name, avatar: avatar, fromItem: fromItem)
        case let .discoverTitle(ref): TVDiscoverDetailView(titleRef: ref)
        case .reels: TVReelsView()
        case let .rowWall(title, source): TVRowWallView(title: title, source: source)
        case .about: TVAboutView()
        }
    }
}

/// 还没做的页面（分期实现中）
struct TVPlaceholderPage: View {
    let title: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "hammer")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text(title).font(.title2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
