import SwiftUI

/// Apple TV 的导航状态。页面通过 `@Environment(TVRouter.self)` 拿到它来跳转、起播。
///
/// 整个主界面一个导航栈，套在侧边栏外面：二级页压在侧边栏之上（见 `TVMainView`，2026-10-04 改定；
/// 原先每个页签各有一个导航栈，二级页压在页签里，侧边栏会被拉出来、第二层页面还会被系统摆歪）。
/// 播放器全屏呈现在主界面之上；与 iPhone 版一样，点下播放就建好控制器、发出起播请求，
/// 不等播放器视图出现（见 `startPlaybackEarly`）。
@Observable
final class TVRouter {
    var selectedTab: MainTab
    /// 压在侧边栏之上的页面
    var path: [AppRoute] = []
    /// 全屏播放器
    var player: PlayRequest?
    /// 正在播放的控制器：播放器视图出现时接过去（同 iPhone 版 `Router.activePlayback`）
    var activePlayback: PlaybackController?

    /// 开机直接落在首页时，首页第一次有内容就把焦点放到「继续播放」上（播放第一：开机按确认就续播）。
    /// 只这一次：之后用户在标签栏上左右移动、第一次经过首页时，首页不能把焦点从标签栏上拽下来
    @ObservationIgnored private var launchFocusPending = false

    init(landing: MainTab, path: [AppRoute] = []) {
        selectedTab = landing
        self.path = path
        launchFocusPending = landing == .home && path.isEmpty
    }

    /// 首页问一次「现在该不该把焦点放到继续播放上」（只有开机落在首页的那一次答是）
    func consumeLaunchFocus() -> Bool {
        defer { launchFocusPending = false }
        return launchFocusPending
    }

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func pop() {
        _ = path.popLast()
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
