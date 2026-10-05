import Foundation

/// 账号就绪的那一刻（冷启动秒开、登录、切换账号）为它预热 Apple TV 的页面。
/// 名字与 iPhone 版相同（共享的 `AppModel` 只认这个名字），预热的内容按电视上的页面来。
enum SessionPrewarm {
    static func start(server: ServerAddress, session: API.SessionView, landing: MainTab? = nil) {
        // 播放器按网络环境记画质：服务器配的是域名时先在后台查好地址，第一次播放就判得出在家还是在外面
        PlaybackNetwork.prewarm(server: server)
        // 暂停时要不要连下载也停按网络是否计费定：先开始监听，第一次播放时已经有结果
        _ = NetworkCost.shared
        // 首页的快照：冷启动落在首页时当场读完，第一帧就是上次的完整首页，随后静默刷新
        let owner = PageSnapshots.owner(server: server, username: session.username)
        LibraryHomeStore.shared.adopt(owner: owner, synchronously: landing == .home)
        // 发现、订阅的快照在后台读（与 iPhone 版 SessionPrewarm 同一口径）
        DiscoverSnapshots.adopt(owner: owner, synchronously: false)
        if Permissions(session: session).canSubscribe {
            SubscriptionIndex.shared.adopt(api: APIClient(server: server), owner: session.username)
            SubscriptionsHomeFeed.shared.adopt(owner: owner)
        }
    }

    /// 冷启动的落点：首页；调试参数可指定
    static func landingTab(for session: API.SessionView) -> MainTab {
        #if DEBUG
        if let tab = DebugLaunch.tab { return tab }
        #endif
        return .home
    }

    /// 账号退出 / 被移除：连同它的页面快照与会话快照一起删掉
    static func forget(server: ServerAddress, username: String) {
        PageSnapshots.remove(owner: PageSnapshots.owner(server: server, username: username))
        SessionCache.remove(server: server, username: username)
    }
}
