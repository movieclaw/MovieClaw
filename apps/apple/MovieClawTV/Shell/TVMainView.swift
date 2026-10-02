import SwiftUI

/// 主界面：tvOS 的侧边栏导航（docs/design/tvos-app.md §3.3，与系统自带的 Apple TV App 一致）。
///
/// 从上到下：当前账号（账号菜单）/ 搜索 / 首页 / 各媒体库 /「更多」分组（发现、订阅、片段）。
/// 浏览内容时侧边栏收起、内容占满全屏，展开方式由系统决定。每个侧边栏项有自己的导航栈，切换不丢位置。
/// 播放器全屏盖在主界面之上（`fullScreenCover`），返回键退出播放后回到原来的页面。
struct TVMainView: View {
    @Environment(AppModel.self) private var model
    @Environment(TVDeepLinkInbox.self) private var inbox
    @State private var router: TVRouter
    @State private var libraries = TVLibraryDirectory()

    init() {
        let landing: MainTab
        #if DEBUG
        landing = DebugLaunch.tab ?? .home
        #else
        landing = .home
        #endif
        _router = State(initialValue: TVRouter(landing: landing))
    }

    private var api: APIClient { model.api ?? EnvironmentValues().api }
    private var session: API.SessionView? { model.session }
    private var permissions: Permissions { session.map(Permissions.init(session:)) ?? .none }

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab(session?.nickname ?? "账号", systemImage: "person.crop.circle", value: MainTab.account) {
                TVTabRoot(tab: .account) { TVAccountView() }
            }
            Tab(value: MainTab.search, role: .search) {
                TVTabRoot(tab: .search) { TVSearchView() }
            }
            Tab("首页", systemImage: "house", value: MainTab.home) {
                TVTabRoot(tab: .home) { TVHomeView() }
            }
            ForEach(libraries.sidebar, id: \.id) { library in
                Tab(library.name, systemImage: TVLibraryDirectory.symbol(for: library.kind), value: MainTab.library(library.id)) {
                    TVTabRoot(tab: .library(library.id)) { TVLibraryView(libraryId: library.id) }
                }
            }
            if libraries.overflow {
                Tab("全部媒体库", systemImage: "square.grid.2x2", value: MainTab.allLibraries) {
                    TVTabRoot(tab: .allLibraries) { TVAllLibrariesView() }
                }
            }
            TabSection("更多") {
                Tab("发现", systemImage: "sparkles", value: MainTab.discover) {
                    TVTabRoot(tab: .discover) { TVDiscoverView() }
                }
                if permissions.canSubscribe {
                    Tab("订阅", systemImage: "bookmark", value: MainTab.subscriptions) {
                        TVTabRoot(tab: .subscriptions) { TVSubscriptionsView() }
                    }
                }
                Tab("片段", systemImage: "film.stack", value: MainTab.reels) {
                    TVTabRoot(tab: .reels) { TVReelsView() }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
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

/// 一个侧边栏项的根：自己的导航栈 + 电视上能压栈的页面
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

/// 压栈页面的路由表
struct TVDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case let .item(libraryId, itemId): TVItemDetailView(libraryId: libraryId, itemId: itemId)
        case let .library(id): TVLibraryView(libraryId: id)
        case let .collection(id, name): TVCollectionView(collectionId: id, name: name)
        case let .discoverTitle(ref): TVDiscoverDetailView(titleRef: ref)
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
