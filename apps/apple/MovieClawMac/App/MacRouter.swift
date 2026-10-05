import SwiftUI

/// Mac 版侧边栏的一项（docs/design/macos-app.md §3）。
///
/// 名字与 iPhone、Apple TV 版的页签类型相同（都叫 `MainTab`）：共享的 `AppModel`、`DebugLaunch` 只认这个名字，
/// 各平台各自定义。Mac 的侧边栏照 Apple Music：顶上搜索框，下面「首页」，再下面一组「媒体库」逐个列库
/// （Mac 窗口放得下，库不必像电视那样收进首页的一行），最后是「我的收藏」与显示在首页的合集。
/// `rawValue` 给调试参数 `-mcTab` 用：`home`、`search`、`library-3`、`collection-5`、`favorites`
enum MainTab: Hashable {
    /// 搜索（侧边栏顶上的搜索框；有输入时内容区换成搜索结果）
    case search
    /// 首页：「接下来继续」大图 + 用户在网页自定义的行，启动后的默认落点
    case home
    /// 一个媒体库的海报墙
    case library(Int)
    /// 一个合集的海报墙（首页「我的媒体库」里那些显示在首页的合集）
    case collection(Int)
    /// 我的收藏
    case favorites
}

extension MainTab: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "search": self = .search
        case "home": self = .home
        case "favorites": self = .favorites
        default:
            if rawValue.hasPrefix("library-"), let id = Int(rawValue.dropFirst("library-".count)) {
                self = .library(id)
            } else if rawValue.hasPrefix("collection-"), let id = Int(rawValue.dropFirst("collection-".count)) {
                self = .collection(id)
            } else {
                return nil
            }
        }
    }

    var rawValue: String {
        switch self {
        case .search: "search"
        case .home: "home"
        case .favorites: "favorites"
        case let .library(id): "library-\(id)"
        case let .collection(id): "collection-\(id)"
        }
    }
}

/// Mac 上可压栈的页面（内容区的导航栈）。与 iPhone 版的 `AppRoute` 同名不同义：共享的 `AppModel` 只用到这个名字，
/// 记「登录过期前停在哪」。只有看片相关的页面，没有任何管理与设置页（docs/design/macos-app.md §2）。
enum AppRoute: Hashable {
    /// 条目详情（电影 / 剧集 / 其他）：详情接口按「库 + 条目」取
    case item(libraryId: Int, itemId: Int)
    /// 某个媒体库的海报墙（从首页「我的媒体库」进；侧边栏点库是直接换页，不压栈）
    case library(Int)
    /// 合集：海报墙
    case collection(id: Int, name: String)
    /// 影人页：这个人在我库里的作品。姓名、头像随路由带过来，页面一打开头部就是全的；`fromItem` 是从哪部片点进来的
    case person(tmdbId: Int, name: String, avatar: String?, fromItem: Int?)
    /// 首页一行的「查看全部」：行标题 + 与这一行同一套取数参数的海报墙
    case rowWall(title: String, source: MacWallSource)
}

/// Mac 版的导航状态。页面通过 `@Environment(MacRouter.self)` 拿到它来跳转、起播。
///
/// - 侧边栏选中项 `selection` 决定内容区的根页面；每一项各有一个导航栈（`paths`），切回来时还停在原来那一层，
///   同 Apple Music（在「资料库 › 专辑」里点进一张专辑，切到「主页」再切回来，还在那张专辑里）；
/// - 搜索框有字时内容区换成搜索结果（`searchText`），清空回到刚才的页面；
/// - 播放器盖在整个窗口上（`player`），与 Apple TV App 的 Mac 版一样在主窗口里播，⌃⌘F 进全屏。
///   与 iPhone 版一样点下播放就建好控制器、发出起播请求，不等播放器视图出现（`startPlaybackEarly`）。
@Observable
final class MacRouter {
    var selection: MainTab
    /// 各侧边栏项自己的导航栈
    var paths: [MainTab: [AppRoute]] = [:]
    /// 侧边栏搜索框里的字。改了词就回到结果列表（点进去的详情是上一个词的）
    var searchText = "" {
        didSet {
            let searching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isSearching != searching { isSearching = searching }
            if searchText != oldValue, paths[.search]?.isEmpty == false { paths[.search] = nil }
        }
    }
    /// 搜索框下拉的联想词（搜索页拿到结果时填，同 Apple TV 版键盘下方那排）
    var searchSuggestions: [String] = []
    /// 全屏播放器
    var player: PlayRequest?
    /// 正在播放的控制器：播放器视图出现时接过去（同 iPhone 版 `Router.activePlayback`）
    var activePlayback: PlaybackController?
    /// 「退出登录」确认框：挂在主窗口上（从账号浮层、菜单栏都能打开；挂在浮层里会跟着浮层一起消失）
    var confirmingLogout = false

    init(selection: MainTab, path: [AppRoute] = []) {
        self.selection = selection
        paths[selection] = path
    }

    /// 眼前这一栈：有搜索词时是「搜索」自己的栈，否则是当前侧边栏项的（页面里 push / pop 都只碰这一栈）
    var path: [AppRoute] {
        get { paths[visibleTab] ?? [] }
        set { paths[visibleTab] = newValue }
    }

    /// 内容区正显示的那一栈对应的项
    var visibleTab: MainTab { isSearching ? .search : selection }

    /// 搜索框有字：内容区显示搜索结果
    private(set) var isSearching = false

    func push(_ route: AppRoute) {
        // 在搜索结果里点了一部：压进「搜索」自己的栈，搜索框里的字保留，返回还是那一屏结果
        path.append(route)
    }

    func pop() {
        _ = path.popLast()
    }

    /// 侧边栏选中一项。再点一次当前项：退回这一项的根页面（同 Apple Music 再点「主页」回到顶层）
    func select(_ tab: MainTab) {
        if tab == selection {
            paths[tab] = []
        } else {
            selection = tab
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
