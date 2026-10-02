import SwiftUI

/// 主界面：顶栏导航（docs/design/tvos-app.md §3.3，排布同 Netflix、Disney+ 的新版电视界面）。
///
/// 左上角是当前账号，正中的胶囊是 🔍 / 媒体库（首页）/ 订阅 / 发现；各个媒体库从首页的「我的媒体库」进，
/// 片段从发现页进。系统 `TabView` 只负责每个页签各自的导航栈（切换不丢位置），它的标签栏藏起来，
/// 换成自己画的 `TVTopBar`（原因见那里）。
/// 播放器全屏盖在主界面之上（`fullScreenCover`），返回键退出播放后回到原来的页面。
struct TVMainView: View {
    @Environment(AppModel.self) private var model
    @Environment(TVDeepLinkInbox.self) private var inbox
    @State private var router: TVRouter
    @State private var libraries = TVLibraryDirectory()
    /// 焦点在顶栏的哪一项（nil = 在页面内容里）
    @FocusState private var barFocus: MainTab?
    /// 冷启动与切页时焦点优先给页面内容，不给顶栏（系统默认挑最左上角，会落到账号头像上）
    @Namespace private var focusNamespace
    /// 按返回键要回顶栏：这一刻首选焦点换成顶栏的当前页签，再请系统重挑一次焦点
    /// （直接给 `barFocus` 赋值在页面滚动时会被系统静默吞掉）
    @State private var barPreferred = false
    @Environment(\.resetFocus) private var resetFocus

    init() {
        #if DEBUG
        let landing = UserDefaults.standard.string(forKey: "mcTab").flatMap(TVRouter.debugLanding) ?? (.home, [])
        _router = State(initialValue: TVRouter(landing: landing.tab, path: landing.path))
        #else
        _router = State(initialValue: TVRouter(landing: .home))
        #endif
    }

    private var api: APIClient { model.api ?? EnvironmentValues().api }
    private var session: API.SessionView? { model.session }
    private var permissions: Permissions { session.map(Permissions.init(session:)) ?? .none }

    /// 顶栏露不露出来：只在根页面；页面滚离顶部就收走，焦点回到顶栏时再出来
    private var barVisible: Bool {
        router.atRoot && (barFocus != nil || !router.scrolledAway.contains(router.selectedTab))
    }

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab(value: MainTab.account) {
                TVTabRoot(tab: .account) { TVAccountView() }
            }
            Tab(value: MainTab.search) {
                TVTabRoot(tab: .search) { TVSearchView() }
            }
            Tab(value: MainTab.home) {
                TVTabRoot(tab: .home) { TVHomeView() }
            }
            if permissions.canSubscribe {
                Tab(value: MainTab.subscriptions) {
                    TVTabRoot(tab: .subscriptions) { TVSubscriptionsView() }
                }
            }
            Tab(value: MainTab.discover) {
                TVTabRoot(tab: .discover) { TVDiscoverView() }
            }
        }
        .prefersDefaultFocus(!barPreferred, in: focusNamespace)
        // 根页面上按返回键：焦点在内容里就把页面滚回顶部、焦点回到顶栏的当前页签（同系统标签栏）；
        // 已经在顶栏（或在二级页）就交给系统（二级页出栈 / 退回主屏幕）
        .onExitCommand(perform: router.atRoot && barFocus == nil ? {
            let tab = router.selectedTab
            let scrolled = router.scrolledAway.contains(tab)
            if scrolled { router.scrollToTop(tab) }
            barPreferred = true
            Task {
                // 滚回顶部的动画（0.3 秒）走完再重挑焦点，否则焦点会追着滚动中的卡片走
                if scrolled { try? await Task.sleep(for: .milliseconds(350)) }
                resetFocus(in: focusNamespace)
            }
        } : nil)
        .overlay(alignment: .top) {
            TVTopBar(focus: $barFocus, focusNamespace: focusNamespace, preferred: barPreferred) {
                barPreferred = false
                resetFocus(in: focusNamespace)
            }
                .opacity(barVisible ? 1 : 0)
                .offset(y: barVisible ? 0 : -40)
                // 收走时仍可获得焦点（焦点一进来它就露出来）；二级页里整条不参与焦点，免得在详情页顶部往上按跳进看不见的顶栏
                .disabled(!router.atRoot)
                .animation(.easeOut(duration: 0.25), value: barVisible)
        }
        .focusScope(focusNamespace)
        .onChange(of: barFocus) { previous, tab in
            if tab != nil { barPreferred = false }
            // 从页面内容往上进顶栏，系统按几何就近会落到左上角的账号头像；同系统标签栏，改落在当前页签上
            if previous == nil, tab == .account, router.selectedTab != .account {
                barFocus = router.selectedTab
                return
            }
            // 焦点移到胶囊里哪一项就切到哪个页签（同系统标签栏）；账号头像要按确认才切
            if let tab, tab != .account { router.selectedTab = tab }
        }
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

/// 一个页签的根：自己的导航栈 + 电视上能压栈的页面。系统标签栏在这里藏掉（换成 `TVTopBar`），
/// 根页面顶部让出顶栏的高度（滚动视图里是内容边距，随内容滚走）
struct TVTabRoot<Content: View>: View {
    let tab: MainTab
    @ViewBuilder let content: () -> Content
    @Environment(TVRouter.self) private var router

    var body: some View {
        NavigationStack(path: router.path(for: tab)) {
            content()
                .safeAreaPadding(.top, TVTopBar.reservedHeight)
                .environment(\.tvRootTab, tab)
                .navigationDestination(for: AppRoute.self) { route in
                    TVDestination(route: route)
                }
        }
        .toolbarVisibility(.hidden, for: .tabBar)
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
        case .reels: TVReelsView()
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
