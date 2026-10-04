import SwiftUI

/// 主窗口：侧边栏 + 内容区（`NavigationSplitView`，docs/design/macos-app.md §3，版式同 Apple Music 的 Mac 版）。
///
/// - 侧边栏（`MacSidebar`）：顶上搜索框；首页、我的收藏；「媒体库」一组逐个列库；「合集」一组列显示在首页的合集；
///   最底下是当前账号，点开切换 / 添加账号、关于、退出登录（`MacAccountButton`）。
/// - 内容区：侧边栏每一项各有一个导航栈（`MacRouter.paths`），切走再切回来还停在原来那一层；
///   搜索框有字时换成搜索结果，清空回到刚才的页面。
/// - 播放器盖在整个窗口上（同 Apple TV App 的 Mac 版：在主窗口里播，⌃⌘F 全屏），侧边栏与工具栏一并收起。
struct MacMainView: View {
    @Environment(AppModel.self) private var model
    @State private var router: MacRouter
    @State private var libraries = MacLibraryDirectory()
    @State private var columns: NavigationSplitViewVisibility = .all
    @FocusState private var searchFocused: Bool
    /// 窗口顶上的一行提示（「已切换到「张三」」这类）：几秒后自己收起
    @State private var notice: String?

    init() {
        #if DEBUG
        let landing = Self.debugLandingUsed ? nil : UserDefaults.standard.string(forKey: "mcTab").flatMap(MainTab.init(rawValue:))
        Self.debugLandingUsed = true
        _router = State(initialValue: MacRouter(selection: landing ?? .home))
        #else
        _router = State(initialValue: MacRouter(selection: .home))
        #endif
    }

    #if DEBUG
    nonisolated(unsafe) private static var debugLandingUsed = false
    #endif

    private var api: APIClient { model.api ?? EnvironmentValues().api }
    private var permissions: Permissions { model.session.map(Permissions.init(session:)) ?? .none }

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $columns) {
            MacSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
        } detail: {
            detail
        }
        .searchable(text: $router.searchText, placement: .sidebar, prompt: "片名、演员、导演")
        .searchFocused($searchFocused)
        .environment(router)
        .environment(libraries)
        .environment(\.api, api)
        .environment(\.permissions, permissions)
        .focusedSceneValue(\.macRouter, router)
        .focusedSceneValue(\.macFocusSearch) { searchFocused = true }
        // 播放器盖在整个窗口上：侧边栏与工具栏收起，画面铺满
        .overlay {
            if let request = router.player {
                MacPlayerScreen(request: request)
                    .environment(router)
                    .environment(\.api, api)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let notice {
                Text(notice)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("mac-notice")
            }
        }
        .task {
            // 切换账号、退出后自动切到别的账号时 AppModel 留了一句话：主界面出来后亮几秒
            guard let text = model.takeNotice() else { return }
            withAnimation(.spring(duration: 0.35)) { notice = text }
            try? await Task.sleep(for: .seconds(3.5))
            withAnimation(.easeOut(duration: 0.3)) { notice = nil }
        }
        // 登录过期被送回登录页：记下停在哪，重新登录后回到这一页（AppModel.captureResume 只在过期时才真的记）
        .onDisappear { model.captureResume(tab: router.selection, path: router.path) }
        .toolbarVisibility(router.player == nil ? .automatic : .hidden, for: .windowToolbar)
        .animation(.easeInOut(duration: 0.25), value: router.player?.id)
        .task { await libraries.load(api: api) }
        // 侧边栏里点的库被删了（换账号、管理员收回权限）：落回首页
        .onChange(of: libraries.libraries) { _, _ in
            if case let .library(id) = router.selection, libraries.loaded, libraries.library(id) == nil {
                router.selection = .home
            }
        }
        .onAppear {
            #if DEBUG
            MacDebugDriver.shared.router = router
            #endif
            if let resume = model.takeResume() {
                router.selection = resume.tab
                router.path = resume.path
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
        .onChange(of: router.player?.id) { _, presented in
            // 提前起播了、播放器却没出来就被撤掉：这里关掉，免得会话与引擎空跑
            if let early = router.activePlayback, !early.viewAttached, early.request.id != presented {
                early.close()
                router.activePlayback = nil
            }
        }
        #if DEBUG
        .task {
            // 开发期：-mcRoute 直接打开一个站内路径（目前支持 /play/{id}[/sXXeYY][?t=秒]）
            guard let path = DebugLaunch.route else { return }
            if let delay = DebugLaunch.routeDelay, delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            if let request = PlayRequest(webPath: path) { router.play(request) }
        }
        #endif
    }

    /// 内容区：有搜索词时是搜索结果（它自己的栈），否则是侧边栏选中项的栈
    @ViewBuilder
    private var detail: some View {
        let tab: MainTab = router.isSearching ? .search : router.selection
        NavigationStack(path: Binding(get: { router.paths[tab] ?? [] }, set: { router.paths[tab] = $0 })) {
            root(tab)
                .navigationDestination(for: AppRoute.self) { route in
                    MacDestination(route: route)
                }
        }
        .id(tab)
    }

    @ViewBuilder
    private func root(_ tab: MainTab) -> some View {
        switch tab {
        case .search: MacSearchView()
        case .home: MacHomeView()
        case let .library(id): MacLibraryView(libraryId: id)
        case let .collection(id): MacCollectionView(collectionId: id, name: libraries.collectionName(id) ?? "合集")
        case .favorites: MacRowWallView(title: "我的收藏", source: .favorites(sort: "favorited_at", reversed: false))
        }
    }
}

/// 压栈页面的路由表
struct MacDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case let .item(libraryId, itemId): MacItemDetailView(libraryId: libraryId, itemId: itemId)
        case let .library(id): MacLibraryView(libraryId: id)
        case let .collection(id, name): MacCollectionView(collectionId: id, name: name)
        case let .person(tmdbId, name, avatar, fromItem):
            MacPersonView(tmdbId: tmdbId, name: name, avatar: avatar, fromItem: fromItem)
        case let .rowWall(title, source): MacRowWallView(title: title, source: source)
        }
    }
}

extension FocusedValues {
    /// 当前窗口的导航状态（菜单栏的「前往」「账号」菜单用）
    @Entry var macRouter: MacRouter?
    /// 把焦点交给侧边栏的搜索框（⌘F）
    @Entry var macFocusSearch: (() -> Void)?
}

/// 当前账号能看到的媒体库清单与显示在首页的合集，按服务端顺序（侧边栏列库、海报墙取库名用）。
///
/// 照片类媒体库本轮不做（同 Apple TV 版），不在 Mac 上出现。
@Observable
final class MacLibraryDirectory {
    private(set) var libraries: [API.LibraryView] = []
    private(set) var loaded = false

    /// 能浏览的库（排除照片库与没有访问权限的）
    var browsable: [API.LibraryView] {
        libraries.filter { $0.viewerAccess && $0.kind != "photo" }
    }

    func load(api: APIClient) async {
        do {
            let fresh = try await api.libraryList(scope: "all")
            if fresh != libraries { libraries = fresh }
        } catch {
            // 拿不到就保持原样（首页会挂自己的错误提示）
        }
        loaded = true
    }

    func library(_ id: Int) -> API.LibraryView? {
        libraries.first { $0.id == id }
    }

    /// 侧边栏「合集」里的合集名（来自首页的合集清单）
    func collectionName(_ id: Int) -> String? {
        LibraryHomeStore.shared.collections.first { $0.id == id }?.name
    }

    /// 侧边栏图标：电影 / 剧集 / 其他视频
    static func symbol(for kind: String) -> String {
        switch kind {
        case "movie": "film"
        case "tv": "tv"
        default: "play.rectangle"
        }
    }
}
