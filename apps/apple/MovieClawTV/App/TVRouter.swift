import SwiftUI

/// Apple TV 的导航状态。页面通过 `@Environment(TVRouter.self)` 拿到它来跳转、起播。
///
/// 每个页签各有一个导航栈（见 `TVMainView`）：二级页压在页签里，进得再深，左滑也能唤出侧边栏（同系统 Apple TV App，
/// 2026-10-04 用户要求）；各页签各自记住浏览位置。
/// 播放器全屏呈现在主界面之上；与 iPhone 版一样，点下播放就建好控制器、发出起播请求，
/// 不等播放器视图出现（见 `startPlaybackEarly`）。
@Observable
final class TVRouter {
    var selectedTab: MainTab
    /// 各页签自己的导航栈
    var paths: [MainTab: [AppRoute]] = [:]
    /// 当前页签的导航栈（页面里 push / pop、深链接都只碰当前页签）
    var path: [AppRoute] {
        get { paths[selectedTab] ?? [] }
        set { paths[selectedTab] = newValue }
    }
    /// 全屏播放器
    var player: PlayRequest?
    /// 侧边栏上按返回键 / 从后台回来时焦点停在侧边栏上：当前二级页把焦点要回去（见 `TVMainView`、`TVDestination`）
    var reclaimPageFocus = 0
    /// 同上，当前页签是首页、没有压着二级页时由首页自己把焦点要回去（见 `TVHomeView`）
    var reclaimHomeFocus = 0
    /// 同上，当前页签是首页以外（搜索、账号）且没有压着二级页时，由页签根页面把焦点要回去（见 `TVTabRoot`）
    var reclaimTabFocus = 0
    /// 正在播放的控制器：播放器视图出现时接过去（同 iPhone 版 `Router.activePlayback`）
    var activePlayback: PlaybackController?

    /// 开机直接落在首页时，首页第一次有内容就把焦点放到「继续播放」上（播放第一：开机按确认就续播）。
    /// 只这一次：焦点落定后清掉，之后用户在侧边栏上移动、经过首页时，首页不能把焦点拽下来（见 TVHomeView）
    @ObservationIgnored var launchFocusPending = false

    init(landing: MainTab, path: [AppRoute] = []) {
        selectedTab = landing
        paths[landing] = path
        launchFocusPending = landing == .home && path.isEmpty
    }

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func pop() {
        _ = path.popLast()
    }

    /// 侧边栏里选中一项：选的就是当前页签（从二级页左滑唤出侧边栏、再点它）→ 退回这个页签的首屏；
    /// 选别的页签 → 切过去，各页签的浏览位置照旧保留
    func select(_ tab: MainTab) {
        if tab == selectedTab {
            paths[tab] = []
        } else {
            selectedTab = tab
        }
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
