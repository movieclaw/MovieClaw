import Foundation

/// Apple TV 顶部标签栏的一项（docs/design/tvos-app.md §3.3，系统原生 `TabView` 标签栏）。
///
/// 名字与 iPhone 版的页签类型相同（都叫 `MainTab`）：共享的 `AppModel`、`DebugLaunch` 只认这个名字，
/// 两个平台各自定义自己的页签。`rawValue` 给调试参数 `-mcTab` 与快照用：`home`、`search`……
///
/// 侧边栏从上到下：账号 / 搜索 / 首页。当前账号不是页签，是标签栏左边单独的头像按钮
/// （`TVAccountButton`）。各个媒体库不再各占一格（数量不定、会把标签栏挤满），从首页的「我的媒体库」进。
enum MainTab: Hashable {
    /// 搜索（系统的搜索页签：屏幕键盘、Siri 听写、附近 iPhone 的键盘都能输入）
    case search
    /// 「首页」（顶部大图 + 接下来继续 + 自定义行），启动后的默认落点
    case home
    /// 当前账号（侧边栏第一项，同系统 Apple TV App）：内容是「谁在看」——切换 / 添加账号、关于、退出登录
    case account
}

extension MainTab: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "search": self = .search
        case "home": self = .home
        case "account": self = .account
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .search: "search"
        case .home: "home"
        case .account: "account"
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
    /// 影人页：这个人在我库里的作品（从条目详情的「演职员」进入）。姓名、头像随路由带过来，页面一打开头部就是全的，
    /// 不等接口；`fromItem` 是从哪部片点进来的，那张海报标「本片」
    case person(tmdbId: Int, name: String, avatar: String?, fromItem: Int?)
    /// 首页一行的「查看全部」：行标题 + 与这一行同一套取数参数的海报墙
    case rowWall(title: String, source: TVWallSource)
    /// 关于（版本与开源许可）：从「账号」页签进入
    case about
}

#if DEBUG
extension TVRouter {
    /// 调试参数 `-mcTab` 的落点：页签名直接落过去；`item-<库>-<条目>` 直接开条目详情；旧的侧边栏页签名（`library-3`、`libraries`）
    /// 换算成「所在页签 + 压栈页面」，UI 测试与截图脚本照旧可用。`account` 落在首页，再由主界面弹出「谁在看」
    static func debugLanding(_ raw: String) -> (tab: MainTab, path: [AppRoute])? {
        if let tab = MainTab(rawValue: raw) { return (tab, []) }
        switch raw {
        case "libraries": return (.home, [])
        default:
            // item-<库 id>-<条目 id>：直接打开条目详情（真机问题在模拟器里复现用）
            if raw.hasPrefix("item-") {
                let parts = raw.dropFirst("item-".count).split(separator: "-").compactMap { Int($0) }
                guard parts.count == 2 else { return nil }
                return (.home, [.item(libraryId: parts[0], itemId: parts[1])])
            }
            guard raw.hasPrefix("library-"), let id = Int(raw.dropFirst("library-".count)) else { return nil }
            return (.home, [.library(id)])
        }
    }
}
#endif
