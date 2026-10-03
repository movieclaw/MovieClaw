import SwiftUI

/// Apple TV 的导航状态。页面通过 `@Environment(TVRouter.self)` 拿到它来跳转、起播。
///
/// 每个页签有独立的导航栈（切换页签不丢各自的浏览位置，同 iPhone 版的标签）。
/// 播放器全屏呈现在主界面之上；与 iPhone 版一样，点下播放就建好控制器、发出起播请求，
/// 不等播放器视图出现（见 `startPlaybackEarly`）。
@Observable
final class TVRouter {
    var selectedTab: MainTab
    var paths: [MainTab: [AppRoute]] = [:]
    /// 全屏播放器
    var player: PlayRequest?
    /// 正在播放的控制器：播放器视图出现时接过去（同 iPhone 版 `Router.activePlayback`）
    var activePlayback: PlaybackController?

    /// 开机直接落在首页时，首页第一次有内容就把焦点放到「继续播放」上（播放第一：开机按确认就续播）。
    /// 只这一次：之后用户在标签栏上左右移动、第一次经过首页时，首页不能把焦点从标签栏上拽下来
    @ObservationIgnored private var launchFocusPending = false

    init(landing: MainTab, path: [AppRoute] = []) {
        selectedTab = landing
        if !path.isEmpty { paths[landing] = path }
        launchFocusPending = landing == .home && path.isEmpty
    }

    /// 首页问一次「现在该不该把焦点放到继续播放上」（只有开机落在首页的那一次答是）
    func consumeLaunchFocus() -> Bool {
        defer { launchFocusPending = false }
        return launchFocusPending
    }

    /// 某个页签的导航栈（绑定给 NavigationStack）
    func path(for tab: MainTab) -> Binding<[AppRoute]> {
        Binding(mcGet: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
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
