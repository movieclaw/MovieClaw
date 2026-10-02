import Foundation

/// Apple TV 侧边栏的一项（docs/design/tvos-app.md §3.3）。
///
/// 名字与 iPhone 版的页签类型相同（都叫 `MainTab`）：共享的 `AppModel`、`DebugLaunch` 只认这个名字，
/// 两个平台各自定义自己的页签。`rawValue` 给调试参数 `-mcTab` 与快照用：`home`、`library-3`、`discover`……
enum MainTab: Hashable {
    case search
    case home
    /// 某个媒体库（id）
    case library(Int)
    /// 媒体库超过侧边栏能放的个数时，多出来的收进这一页
    case allLibraries
    case discover
    case subscriptions
    case reels
}

extension MainTab: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "search": self = .search
        case "home": self = .home
        case "libraries": self = .allLibraries
        case "discover": self = .discover
        case "subscriptions": self = .subscriptions
        case "reels": self = .reels
        default:
            guard rawValue.hasPrefix("library-"), let id = Int(rawValue.dropFirst("library-".count)) else { return nil }
            self = .library(id)
        }
    }

    var rawValue: String {
        switch self {
        case .search: "search"
        case .home: "home"
        case let .library(id): "library-\(id)"
        case .allLibraries: "libraries"
        case .discover: "discover"
        case .subscriptions: "subscriptions"
        case .reels: "reels"
        }
    }
}

/// Apple TV 上可压栈的页面。与 iPhone 版的 `AppRoute` 同名不同义（共享的 `AppModel` 只用到这个名字，
/// 记「登录过期前停在哪」）。电视上的页面少得多：没有任何管理与设置页。
enum AppRoute: Hashable {
    /// 条目详情（电影 / 剧集 / 其他）
    case item(Int)
    /// 某个媒体库的完整海报墙（从首页行标题、「全部媒体库」进入）
    case library(Int)
    /// 合集详情
    case collection(Int)
    /// 关于（版本与开源许可）
    case about
}
