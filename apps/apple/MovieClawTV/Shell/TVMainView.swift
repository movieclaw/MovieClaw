import SwiftUI

/// 主界面：顶栏导航（docs/design/tvos-app.md §3.3，排布同 Netflix、Disney+ 的新版电视界面）。
///
/// 左上角是当前账号，正中的胶囊是 🔍 / 媒体库（首页）/ 订阅 / 发现；各个媒体库从首页的「我的媒体库」进，
/// 片段从发现页进。顶栏是自己画的 `TVTopBar`（不用系统 `TabView` 的原因见那里），页签容器也自己管。
/// 播放器全屏盖在主界面之上（`fullScreenCover`），返回键退出播放后回到原来的页面。
struct TVMainView: View {
    @Environment(AppModel.self) private var model
    @Environment(TVDeepLinkInbox.self) private var inbox
    @State private var router: TVRouter
    @State private var libraries = TVLibraryDirectory()
    /// 焦点在顶栏的哪一项（nil = 在页面内容里）
    @FocusState private var barFocus: TVBarItem?
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

    /// 当前页签在顶栏上对应的那一项
    private var currentBarItem: TVBarItem {
        router.selectedTab == .account ? .account : .tab(router.selectedTab)
    }

    /// 顶栏露不露出来：只在根页面；页面滚离顶部就收走，焦点回到顶栏时再出来
    private var barVisible: Bool {
        router.atRoot && (barFocus != nil || !router.scrolledAway.contains(router.selectedTab))
    }

    var body: some View {
        @Bindable var router = router
        // 只渲染当前页签：每个页签的导航栈存在 router 里，切走再回来压过的页面都还在；页面数据有快照，秒开。
        // 根页面的滚动位置不保留——切页只会发生在顶栏上，而顶栏只在根页面顶部露出来，切走时本来就在顶部
        TVTabRoot(tab: router.selectedTab) { page(for: router.selectedTab) }
            .id(router.selectedTab)
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
            TVTopBar(focus: $barFocus, focusNamespace: focusNamespace, preferredItem: barPreferred ? currentBarItem : nil) { item in
                barPreferred = false
                switch item {
                case .account:
                    router.selectedTab = .account
                case .search:
                    // 搜索压栈成整页：顶栏随之收起，焦点整个进到搜索页，系统的屏幕键盘才会展开、接住焦点
                    // （搜索页若在焦点还停在顶栏上时建出来，键盘是收着的）
                    router.push(.search)
                case .tab:
                    // 在页签上按确认：焦点下到页面内容（同系统标签栏）
                    resetFocus(in: focusNamespace)
                }
            }
                .opacity(barVisible ? 1 : 0)
                .offset(y: barVisible ? 0 : -40)
                // 收走时仍可获得焦点（焦点一进来它就露出来）；二级页里整条不参与焦点，免得在详情页顶部往上按跳进看不见的顶栏
                .disabled(!router.atRoot)
                .animation(.easeOut(duration: 0.25), value: barVisible)
        }
        .focusScope(focusNamespace)
        .onChange(of: barFocus) { previous, item in
            if item != nil { barPreferred = false }
            // 从页面内容往上进顶栏，系统按几何就近会落到正上方那一项（账号、搜索、别的页签），落上页签就切了页；
            // 同系统标签栏，一律改落在当前页签上
            if previous == nil, let item, item != currentBarItem {
                barFocus = currentBarItem
                return
            }
            // 焦点移到胶囊里哪一项就切到哪个页签（同系统标签栏）；账号与搜索要按确认
            if case let .tab(tab)? = item { router.selectedTab = tab }
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

extension TVMainView {
    @ViewBuilder
    fileprivate func page(for tab: MainTab) -> some View {
        switch tab {
        case .account: TVAccountView()
        case .home: TVHomeView()
        case .subscriptions: TVSubscriptionsView()
        case .discover: TVDiscoverView()
        }
    }
}

/// 一个页签的根：自己的导航栈 + 电视上能压栈的页面。
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
        case .search: TVSearchView()
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
