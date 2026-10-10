import SwiftUI

/// 主界面：系统原生的可收起侧边栏（`sidebarAdaptable`，docs/design/tvos-app.md §3.3，同系统 Apple TV App）。
///
/// 平时只在左上角收成一枚小胶囊（写着当前页），整屏留给内容；按「左」或返回键展开成左侧边栏，焦点移到哪一项就切到哪一页。
/// 从上到下：账号 / 搜索 / 首页。账号在最上面、搜索紧随其后，同系统 Apple TV App 的侧边栏。
/// Apple TV 版只做看片（docs/design/tvos-app.md §3）：订阅、发现与片段不在这个 App 里。
/// 2026-10-03 用户改定（此前是顶部标签栏 + 左上头像 + 右上标志）：顶部一排菜单在电视上压着大图，收进左上角主屏更干净。
/// 各个媒体库从首页的「我的媒体库」进。播放器全屏盖在主界面之上（`fullScreenCover`）。
struct TVMainView: View {
    @Environment(AppModel.self) private var model
    @Environment(TVDeepLinkInbox.self) private var inbox
    @State private var router: TVRouter
    @State private var libraries = TVLibraryDirectory()
    /// 焦点是否在某个页签的页面里（nil = 在侧边栏上）
    @FocusedValue(\.tvPageFocused) private var pageFocused
    @Environment(\.scenePhase) private var scenePhase
    /// 一层黑幕：焦点还没落进页面之前盖住主界面，侧边栏「先展开、再缩回」的过程一帧都不露。
    /// - 启动：主界面第一帧出来时系统已经把焦点给了侧边栏（数据没到，页面里还没有可选的东西），
    ///   录屏逐帧看是整整展开 150 毫秒再缩回（2026-10-04 用户反馈「左上角首页菜单弹一下」）；
    /// - 用返回键退到主屏：退出时焦点在侧边栏上，系统存下的快照就是展开的样子，回来先放快照。
    /// 两种都先盖着，等焦点进了页面、侧边栏收好再淡出（`revealWhenSettled`）
    @State private var focusCover = true
    /// `pageFocused` 的即时副本：后台任务里读 `@FocusedValue` 拿到的是任务开始那一刻的旧值（实测一直是 nil，
    /// 黑幕只能等到超时才揭开），读 `@State` 才是最新的
    @State private var pageFocusedNow = false
    /// 主界面的焦点范围：首页「继续播放」在这个范围里声明「优先默认焦点」，主界面出现时焦点直接落在它上面
    @Namespace private var mainScope

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

    var body: some View {
        tabs
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
        .onChange(of: scenePhase) { old, new in
            // 退到后台拆掉大图预告，回来重新计停留（不在后台留一个引擎）
            if new == .background { TVStagePreview.shared.interrupt(.background) }
            if new == .active { TVStagePreview.shared.endInterruption(.background) }
            if new != .active, old == .active, pageFocused != true {
                // 用返回键退到主屏幕：最后一下返回把焦点交给了侧边栏。系统在后台存下的快照就是「侧边栏展开」，
                // 再打开时先放这张快照、再切实时界面——先看到侧边栏、再缩回去（2026-10-04 用户反馈，逐帧截图确认是快照）。
                // 离开时盖上黑幕（快照就是黑的，回前台那段黑场本来就有），回来把焦点交回页面后再淡出
                focusCover = true
            }
            if old == .background, new == .inactive, pageFocused != true {
                // 从后台回来、还没开始画：系统恢复的是侧边栏，马上交回页面
                reclaimFocus()
            }
            guard new == .active, old != .active else { return }
            Task { await refocusPageAfterResume() }
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
                router.path = [.item(libraryId: libraryId, itemId: itemId)]
            }
        }
        .onChange(of: router.player?.id) { _, presented in
            // 播放器关掉：大图预告重新开始（进播放器时已在 TVRouter.play 里拆掉）
            if presented == nil { TVStagePreview.shared.playerClosed() }
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

    /// 从后台回到前台：焦点停在侧边栏上就交回页面。
    ///
    /// 用返回键退到主屏幕时，最后那一下返回先把焦点交给了侧边栏，App 带着「焦点在侧边栏」退到后台；
    /// 再打开时系统原样恢复，侧边栏整个展开（2026-10-04 用户反馈，系统 Apple TV App 不会这样）。
    /// 先等系统把焦点恢复完再看——用主屏键回去的，焦点本来就在页面里，恢复后不用动
    private func refocusPageAfterResume() async {
        try? await Task.sleep(for: .milliseconds(100))
        if !pageFocusedNow, router.player == nil { reclaimFocus() }
        if focusCover { await revealWhenSettled() }
    }

    /// 等焦点落进页面、侧边栏收起（连同胶囊上的小箭头）都定下来再揭开黑幕。最多等 3 秒：
    /// 万一焦点一直没进页面（极端情况），也不能让主界面一直黑着
    private func revealWhenSettled() async {
        for _ in 0..<30 where !pageFocusedNow {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // 录屏实测：焦点进页面后侧边栏约 150 毫秒收成胶囊，再过约 250 毫秒胶囊上才出现小箭头
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.easeOut(duration: 0.25)) { focusCover = false }
    }

    /// 让当前页面把焦点要回去：压着二级页的给二级页，否则首页自己来
    private func reclaimFocus() {
        if !router.path.isEmpty {
            router.reclaimPageFocus += 1
        } else if router.selectedTab == .home {
            router.reclaimHomeFocus += 1
        } else {
            // 搜索、账号页签的首屏：此前只管首页，在这两页按返回退到主屏再回来，侧边栏一直展开着
            // （2026-10-05 模拟器走查发现）
            router.reclaimTabFocus += 1
        }
    }

    /// 侧边栏与各页签。每个页签各有一个导航栈，二级页压在页签里：进得再深，焦点往左越过页面左沿都能唤出侧边栏，
    /// 侧边栏里点当前页签退回它的首屏（同系统 Apple TV App，2026-10-04 用户要求）。二级页收起左上角的侧边栏小胶囊，
    /// 进了详情只剩这一部（见 `TVDestination`）。
    /// 选中项走 `router.select`：系统对「再点一次当前项」也会调 setter，据此退回首屏
    private var tabs: some View {
        TabView(selection: Binding(get: { router.selectedTab }, set: { router.select($0) })) {
            // 账号：选自己回首页，「关于」在本页签里压栈打开（选别人则整棵主界面按新账号重建）。
            // 头像放进侧边栏顶部（`tabViewSidebarHeader`）要 tvOS 27，先做成第一项
            Tab(session?.nickname ?? "账号", systemImage: "person.crop.circle", value: MainTab.account) {
                stack(.account) {
                    TVWhoIsWatchingView(onClose: { router.selectedTab = .home }, onAbout: { router.push(.about) },
                                        reclaimFocus: router.reclaimTabFocus)
                }
            }
            Tab(value: MainTab.search, role: .search) {
                stack(.search) { TVSearchRoot() }
            }
            Tab("首页", systemImage: "house", value: MainTab.home) {
                stack(.home) { TVHomeView(mainScope: mainScope) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .overlay {
            if focusCover {
                Color.black
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .task { await revealWhenSettled() }
        .onChange(of: pageFocused, initial: true) { _, focused in pageFocusedNow = focused == true }
        // 主界面出现时焦点直接落在首页「继续播放」上，侧边栏不展开。导航栈挪进页签之后，系统评估初始焦点时
        // 改给了侧边栏（选完「谁在看」那一刻侧边栏整个展开，2026-10-04 实测），事后再把焦点拉回来就是「先展开再缩回去」
        .focusScope(mainScope)
        // 从二级页左滑唤出侧边栏后按返回键：系统把侧边栏当最外层，直接退出 App（实测）。当前页签还压着页面时接管：
        // 焦点在侧边栏上 → 收起侧边栏、焦点回到页面（同系统 Apple TV App）：让页面自己把焦点要回去
        // （`reclaimPageFocus`；SwiftUI 的 resetFocus 跨不进系统侧边栏，侧边栏背后也没有 UITabBarController 可用）；
        // 焦点在页面里 → 退一层。
        // 回到页签首屏才交给系统
        .onExitCommand(perform: router.path.isEmpty ? nil : {
            if pageFocused == true {
                router.pop()
            } else {
                router.reclaimPageFocus += 1
            }
        })
    }

    /// 一个页签的导航栈
    private func stack(_ tab: MainTab, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: Binding(get: { router.paths[tab] ?? [] }, set: { router.paths[tab] = $0 })) {
            root()
                .navigationDestination(for: AppRoute.self) { route in
                    TVDestination(route: route)
                }
        }
        .focusedValue(\.tvPageFocused, true)
    }
}

/// 压栈页面的路由表。二级页收起左上角的侧边栏小胶囊：进了详情就只剩这一部（同 Netflix、Apple TV App 的详情页，
/// 2026-10-03 用户嫌详情页顶上还挂着导航菜单、没有沉浸感）；焦点往左越过页面左沿照样唤出侧边栏
struct TVDestination: View {
    let route: AppRoute
    @Environment(TVRouter.self) private var router
    /// 侧边栏上按返回键时由主界面发起：页面把焦点要回来，侧边栏随之收起
    @FocusState private var reclaimed: Bool

    var body: some View {
        // 页签里的导航栈从第二层起，系统把整个页面容器塞进上一层的安全区里：摆到 (160, 120)、宽高少掉 160×120、
        // 自己的安全区成了 0——左边、顶上、右下露出底下的页面，内容贴着屏幕边（2026-10-04 真机与模拟器都复现；
        // 页面里 ignoresSafeArea、去掉收起标签栏都无效）。实测根视图换成一块铺满整屏的透明底、页面挂在它的
        // 覆盖层上就不会了：页面自己的尺寸（铺满全屏的背景图等）不再参与根视图的尺寸，系统也就不再把容器摆歪。
        // 只垫底（ZStack）不行——页面照样撑着根视图的尺寸
        Color.clear
            .ignoresSafeArea()
            .overlay { page }
        .toolbar(.hidden, for: .tabBar)
        .focused($reclaimed)
        .onChange(of: router.reclaimPageFocus) { reclaimed = true }
    }

    @ViewBuilder
    private var page: some View {
        switch route {
        case let .item(libraryId, itemId): TVItemDetailView(libraryId: libraryId, itemId: itemId)
        case let .library(id): TVLibraryView(libraryId: id)
        case let .collection(id, name): TVCollectionView(collectionId: id, name: name)
        case let .person(tmdbId, name, avatar, fromItem):
            TVPersonView(tmdbId: tmdbId, name: name, avatar: avatar, fromItem: fromItem)
        case let .rowWall(title, source): TVRowWallView(title: title, source: source)
        case .about: TVAboutView()
        }
    }
}

/// 搜索页签的首屏：从后台回来、焦点还停在侧边栏上时把焦点要回页面（侧边栏随之收起）。
/// 搜索页的焦点在系统键盘上，拿不到具体元素，只能整页要焦点、由系统落到键盘上。
/// 首页、账号页各有自己的落点（「继续播放」、当前账号），分别由 `TVHomeView`、`TVWhoIsWatchingView` 处理；
/// 二级页由 `TVDestination` 处理
private struct TVSearchRoot: View {
    @Environment(TVRouter.self) private var router
    @FocusState private var reclaimed: Bool

    var body: some View {
        TVSearchView()
            .focused($reclaimed)
            .task(id: router.reclaimTabFocus) {
                guard router.reclaimTabFocus > 0, router.selectedTab == .search else { return }
                // 赋值在焦点系统还没恢复好时可能被忽略：同首页，隔一会儿再补几次
                for delay in [0, 150, 300, 500] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled, router.player == nil, !reclaimed else { return }
                    reclaimed = true
                }
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

extension FocusedValues {
    /// 焦点落在某个页签的页面里（导航栈之内）时为 true；在侧边栏上时没有值
    @Entry var tvPageFocused: Bool?
}
