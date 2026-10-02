import SwiftUI

/// Apple TV 的导航状态。页面通过 `@Environment(TVRouter.self)` 拿到它来跳转、起播。
///
/// 每个顶栏页签有独立的导航栈（切换页签不丢各自的浏览位置，同 iPhone 版的标签）。
/// 播放器全屏呈现在主界面之上；与 iPhone 版一样，点下播放就建好控制器、发出起播请求，
/// 不等播放器视图出现（见 `startPlaybackEarly`）。
@Observable
final class TVRouter {
    var selectedTab: MainTab
    var paths: [MainTab: [AppRoute]] = [:]
    /// 根页面已经往下滚离顶部的页签：顶栏跟着收走（见 `TVTopBar`）。只在越过阈值时变，不随每帧滚动写
    var scrolledAway: Set<MainTab> = []
    /// 请某个页签的根页面滚回顶部（计数变一次滚一次）：根页面上按返回键回顶栏时用
    private(set) var scrollToTopRequests: [MainTab: Int] = [:]

    func scrollToTop(_ tab: MainTab) {
        scrollToTopRequests[tab, default: 0] += 1
    }
    /// 全屏播放器
    var player: PlayRequest?
    /// 「谁在看」盖在主界面上（点顶栏左上角的头像）
    var profilesPresented = false
    /// 正在播放的控制器：播放器视图出现时接过去（同 iPhone 版 `Router.activePlayback`）
    var activePlayback: PlaybackController?

    init(landing: MainTab, path: [AppRoute] = []) {
        selectedTab = landing
        if !path.isEmpty { paths[landing] = path }
    }

    /// 某个页签的导航栈（绑定给 NavigationStack）
    func path(for tab: MainTab) -> Binding<[AppRoute]> {
        Binding(mcGet: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    /// 当前页签停在根页面（没有压栈）：顶栏只在根页面出现，进了详情等二级页就整条收起
    var atRoot: Bool {
        paths[selectedTab]?.isEmpty ?? true
    }

    /// 在当前页签内压栈
    func push(_ route: AppRoute) {
        paths[selectedTab, default: []].append(route)
    }

    func pop() {
        _ = paths[selectedTab]?.popLast()
    }

    func play(_ request: PlayRequest) {
        playRequestedAt = .now
        player = request
        startPlaybackEarly?(request)
    }

    /// 最近一次点播放的时刻：起播分段计时从这里算起
    @ObservationIgnored private(set) var playRequestedAt: ContinuousClock.Instant?

    /// 点下播放就建控制器、发起播请求（由持有 API 客户端的主界面设置）
    @ObservationIgnored var startPlaybackEarly: ((PlayRequest) -> Void)?
}
