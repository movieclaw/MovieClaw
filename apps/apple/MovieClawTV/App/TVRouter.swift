import SwiftUI

/// Apple TV 的导航状态。页面通过 `@Environment(TVRouter.self)` 拿到它来跳转、起播。
///
/// 每个侧边栏项有独立的导航栈（切换侧边栏不丢各自的浏览位置，同 iPhone 版的标签）。
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

    init(landing: MainTab) {
        selectedTab = landing
    }

    /// 某个侧边栏项的导航栈（绑定给 NavigationStack）
    func path(for tab: MainTab) -> Binding<[AppRoute]> {
        Binding(mcGet: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    /// 在当前侧边栏项内压栈
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
