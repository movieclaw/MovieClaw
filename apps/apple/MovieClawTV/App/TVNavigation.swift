import Foundation

/// Apple TV 顶栏的一项（docs/design/tvos-app.md §3.3）。
///
/// 名字与 iPhone 版的页签类型相同（都叫 `MainTab`）：共享的 `AppModel`、`DebugLaunch` 只认这个名字，
/// 两个平台各自定义自己的页签。`rawValue` 给调试参数 `-mcTab` 与快照用：`home`、`discover`……
///
/// 顶栏只放固定的几项：各个媒体库不再各占一格（数量不定、会把顶栏挤满），从首页的「我的媒体库」进；
/// 「片段」是低频入口，收进发现页；搜索是顶栏右上角的按钮，压栈成整页（`AppRoute.search`）；
/// 账号是左上角的头像，打开「谁在看」（`TVWhoIsWatchingView`）——它们都不是页签。
enum MainTab: Hashable {
    /// 「媒体库」：即首页（顶部大图 + 接下来继续 + 自定义行），启动后的默认落点
    case home
    case subscriptions
    case discover
}

extension MainTab: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "subscriptions": self = .subscriptions
        case "discover": self = .discover
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .home: "home"
        case .subscriptions: "subscriptions"
        case .discover: "discover"
        }
    }
}

/// Apple TV 上可压栈的页面。与 iPhone 版的 `AppRoute` 同名不同义（共享的 `AppModel` 只用到这个名字，
/// 记「登录过期前停在哪」）。电视上的页面少得多：没有任何管理与设置页。
enum AppRoute: Hashable {
    /// 条目详情（电影 / 剧集 / 其他）：详情接口按「库 + 条目」取
    case item(libraryId: Int, itemId: Int)
    /// 某个媒体库的完整海报墙（从首页的「我的媒体库」进入）
    case library(Int)
    /// 合集：海报墙
    case collection(id: Int, name: String)
    /// 发现里的一部作品（`tmdb:movie:550` / `douban:1292052`）：在库就能播，不在库可以一键订阅
    case discoverTitle(String)
    /// 片段（竖屏短视频流）：从发现页进入
    case reels
    /// 搜索：顶栏右上角的按钮打开，压在当前页签上
    case search
    /// 关于（版本与开源许可）
    case about
}

#if DEBUG
extension TVRouter {
    /// 调试参数 `-mcTab` 的落点：顶栏页签名直接落过去；旧的侧边栏页签名（`library-3`、`libraries`、`reels`、`search`、`account`）
    /// 换算成「所在页签 + 压栈页面」，UI 测试与截图脚本照旧可用
    static func debugLanding(_ raw: String) -> (tab: MainTab, path: [AppRoute])? {
        if let tab = MainTab(rawValue: raw) { return (tab, []) }
        switch raw {
        case "libraries", "account": return (.home, [])  // account：另由 TVMainView 打开「谁在看」
        case "reels": return (.discover, [.reels])
        case "search": return (.home, [.search])
        default:
            guard raw.hasPrefix("library-"), let id = Int(raw.dropFirst("library-".count)) else { return nil }
            return (.home, [.library(id)])
        }
    }
}
#endif
