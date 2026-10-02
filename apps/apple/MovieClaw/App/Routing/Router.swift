import SwiftUI

/// 底部标签页，从左到右：媒体库（首页）、订阅、发现、活动，最右是当前用户的头像（「我的」页，
/// Instagram 式的个人页签）。2026-09-30 用户调整：自己的片库是 App 的首页，排最左、冷启动落在这里；
/// 发现（找新片）退到第三。搜索不占标签，在各标签根页右上角（见 MainTabView 的 AppTopBar）。
/// 标签栏只显示图标，`title` 给读屏与 UI 测试用。
enum MainTab: String, Hashable, CaseIterable {
    case library, subscriptions, discover, activity, more

    var title: String {
        switch self {
        case .discover: "发现"
        case .library: "媒体库"
        case .subscriptions: "订阅"
        case .activity: "活动"
        case .more: "我的"
        }
    }

    /// 页签图标；「我的」平时显示头像，这个图标只在头像位图还没画好时顶一下
    var systemImage: String {
        switch self {
        // 闪光：推荐、新鲜内容（2026-09-30 用户定：指南针像 Safari，爆米花真机上看不清；原来的小房子读成「首页」，
        // 首页现在是媒体库）
        case .discover: "sparkles"
        case .library: "play.square.stack"
        case .subscriptions: "bookmark"
        case .activity: "waveform.path.ecg"
        case .more: "person.crop.circle"
        }
    }
}

/// 播放请求：对应 Web `/play/{mediaItemId}/{sXXeYY}?t=` 与分享页 `/s/{slug}/play/...`。
struct PlayRequest: Identifiable, Hashable {
    var mediaItemId: Int
    var season: Int?
    var episode: Int?
    /// 指定起播秒数（仅对第一个播放单元生效，同 Web `?t=`）
    var startSeconds: Double?
    /// 访客分享播放：走 `/share/{slug}/playback` 接口族，进度只存本地
    var shareSlug: String?
    /// 播放器内切换文件版本时指定
    var fileId: Int?
    /// 片段模式（刷片的「全屏观看」）：只放这一段，见 `PlaybackClip`
    var clip: PlaybackClip?

    var id: String {
        "\(shareSlug ?? "")-\(mediaItemId)-\(season ?? -1)-\(episode ?? -1)" + (clip.map { "-clip\($0.startMs)" } ?? "")
    }
}

/// 播放器的片段模式（docs/design/reels.md §6）：刷片页点「全屏观看」时，这一段交给正片播放器放。
/// 手势、控制条、换音轨字幕、画质、倍速与正片完全一样，区别只在时间轴：
/// - 进度条、时间、锁屏进度都按片段算，**总时长是这一段的长度**，不是整部片的，免得以为在看整部；
/// - 跳转夹在片段之内，放到终点停下（可重播，或点「看全片」原地转成正常播放）；
/// - 不写观看记录：不报进度（不写续播点、不进「继续观看」、不上活动页），也不留播放质量记录。
/// 起止都是文件时间（毫秒），与服务端刷片接口的 `segment` 同一口径
struct PlaybackClip: Hashable {
    var startMs: Int
    var endMs: Int
    /// 片段的画质（`ReelsQuality`，竖屏与全屏共用一份）：片段模式按它开、改了也记回它，不动正片的按片画质记忆
    var maxHeight: Int?
}

/// 片段播放器关掉时的位置：哪个文件、停在文件的第几毫秒
struct ClipReturn {
    let fileId: Int
    let positionMs: Int
}

extension PlayRequest {
    /// 解析站内播放链接（同 Web `lib/player/play-links.ts` 的地址约定）：
    /// - `/play/{mediaItemId}[/sXXeYY][?t=秒]`
    /// - `/s/{slug}/play[/sXXeYY][?t=秒]`（访客播放；条目 id 要等分享页读到影片才知道，这里记 0）
    /// 不是播放链接返回 nil。
    init?(webPath raw: String) {
        guard let components = URLComponents(string: raw.hasPrefix("/") ? raw : "/\(raw)") else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        var unitSegment: String?
        if parts.count >= 2, parts[0] == "play", let id = Int(parts[1]), id > 0 {
            self.init(mediaItemId: id)
            unitSegment = parts.count >= 3 ? parts[2] : nil
        } else if parts.count >= 3, parts[0] == "s", parts[2] == "play" {
            self.init(mediaItemId: 0, shareSlug: parts[1])
            unitSegment = parts.count >= 4 ? parts[3] : nil
        } else {
            return nil
        }
        // sXXeYY 之外的写法（含 s00e00 = 电影）一律当电影 / 由服务端定起点
        if let segment = unitSegment, let match = segment.lowercased().wholeMatch(of: /s(\d+)e(\d+)/),
           let season = Int(match.1), let episode = Int(match.2), season > 0 || episode > 0 {
            self.season = season
            self.episode = episode
        }
        // ?t= 只接受单个非负整数（同 Web queryNumber）
        if let t = components.queryItems?.first(where: { $0.name == "t" })?.value, t.wholeMatch(of: /\d+/) != nil, let seconds = Double(t) {
            startSeconds = seconds
        }
        #if DEBUG
        // 开发期语料测试：`?file=<文件 id>` 指定版本——同一条目有多个版本时，服务端挑的未必是要测的那个
        if let raw = components.queryItems?.first(where: { $0.name == "file" })?.value, let id = Int(raw), id > 0 {
            fileId = id
        }
        #endif
    }
}

/// 全局弹层：多个模块都会唤起的对话框放这里，由根视图统一呈现，避免各页面重复挂载。
enum AppSheet: Identifiable, Hashable {
    /// 订阅对话框（发现海报、详情页、搜索结果、AI 卡片、媒体库「洗版」都会用）
    case subscribe(SubscribeRequest)
    /// 账号切换
    case accountSwitcher
    /// 自定义首页（`/library/customize`）：编辑布局用弹出表单，不压栈，见 `Router.sheetRoute`
    case customizeHome

    var id: String {
        switch self {
        case let .subscribe(request): "subscribe-\(request.hashValue)"
        case .accountSwitcher: "account-switcher"
        case .customizeHome: "customize-home"
        }
    }
}

/// 唤起订阅对话框所需的信息（对应 Web SubscribeDialog 的入参）
struct SubscribeRequest: Hashable {
    /// 作品引用：`tmdb:movie:123` / `tmdb:tv:456` / `douban:tv:789`
    var titleRef: String
    /// 展示用标题（预览接口返回前先显示）
    var title: String?
    /// 洗版模式：只列有洗版目标的规则组，建好后立刻跑一轮洗版
    var upgrade: Bool = false
    /// 洗版模式下的库内作品（用于回跳）
    var libraryItemId: Int?
}

/// 全局导航状态。页面通过 `@Environment(Router.self)` 拿到它来跳转。
///
/// 每个标签页有独立的导航栈（切标签不丢各自的浏览位置）；
/// `push` 压到当前标签，`open(_:)` 按路由归属切到对应标签再压栈。
@Observable
final class Router {
    var selectedTab: MainTab = .library {
        // 打点：切页签的那一刻是页面打开的起点（见 PerfTrace）
        didSet { if selectedTab != oldValue { PerfTrace.pageBegan(selectedTab.rawValue, trigger: "tab") } }
    }
    var paths: [MainTab: [AppRoute]] = [:]
    /// 全屏播放器
    var player: PlayRequest?
    /// 正在播放的控制器：放在这里而不是播放器视图的 @State 里——iOS 26 标签栏在旋转时会重建容器，
    /// 连带全屏呈现的播放器视图被销毁重建；控制器挂在视图上会跟着重开会话、重载引擎，
    /// 横屏后画面错位、又被旧视图的收尾转回竖屏（真机《抓特务》实测）。
    var activePlayback: PlaybackController?
    /// 片段模式的播放器关掉时停在哪：刷片页回来后从这里接着放这一段（见 `ReelsStore.resume`）
    @ObservationIgnored var clipReturn: ClipReturn?
    /// 全局弹层
    var sheet: AppSheet?
    /// 结果页点顶部搜索词胶囊回到搜索首页时要回填的内容；搜索首页出现时取走（见 `SearchHomeView`）
    var searchDraft: SearchDraft?

    /// 当前标签的导航栈（绑定给 NavigationStack）
    func path(for tab: MainTab) -> Binding<[AppRoute]> {
        Binding(
            get: { self.paths[tab] ?? [] },
            set: { self.paths[tab] = $0 }
        )
    }

    /// 当前账号的权限（由 MainTabView 写入），路由守卫据此把越权目标改道。
    /// nil = 还没写入（主界面刚挂载、启动深链抢在权限同步之前）：此时不拦，交给页面与后端兜底
    var permissions: Permissions?

    /// 路由守卫（同 Web `accessiblePathFor` 与设置页的越权回退）：
    /// - 成员打开仅管理员可见的设置分区 → 改去「个人信息」（Web settings-view 的 replace 到 /settings/profile）；
    /// - 其余越权页面（AI 会话、无能力的订阅、活动、媒体库管理）→ 落到媒体库首页。
    /// 界面上本就不给这些入口，守卫兜的是通知、AI 卡片、深链等「从别处跳过来」的情况。
    func guarded(_ route: AppRoute) -> AppRoute {
        guard let permissions, !permissions.allows(route) else { return route }
        if case .settingsSection = route { return .settingsSection(.profile) }
        return .libraryHome
    }

    /// 以弹出表单呈现的路由：压栈 / 打开它们时改成弹出（深链、Agent 页面链接也走这里）
    private func sheetRoute(_ route: AppRoute) -> AppSheet? {
        route == .libraryCustomize ? .customizeHome : nil
    }

    /// 在当前标签内压栈
    func push(_ route: AppRoute) {
        let route = guarded(route)
        if let sheet = sheetRoute(route) { return present(sheet) }
        if let root = Self.tabRoot(of: route) {
            selectedTab = root
            paths[root] = []
            rememberRootParameter(of: route)
            return
        }
        paths[selectedTab, default: []].append(route)
    }

    /// 切到路由归属的标签后压栈（通知、AI 卡片等「从别处跳过来」的场景）
    func open(_ route: AppRoute) {
        let route = guarded(route)
        if let sheet = sheetRoute(route) {
            // 自定义首页盖在媒体库首页上：先切到媒体库标签
            if let target = route.tab, availableTabs.contains(target) { selectedTab = target }
            return present(sheet)
        }
        if let root = Self.tabRoot(of: route) {
            selectedTab = root
            paths[root] = []
            rememberRootParameter(of: route)
            return
        }
        // 切到路由归属的标签（该标签对当前账号不可见时——例如成员没有订阅页——留在当前标签）
        if let target = route.tab, availableTabs.contains(target) { selectedTab = target }
        // 设置分区的返回固定回设置列表（Web app-shell：/settings/[x] 的返回是 /settings）：
        // 从通知「去处理」、更多页「新版本」等处直达分区时，栈顶不是设置列表就先垫一层。
        // 「个人信息」不在设置列表里（入口是「我的」页头像卡），不垫
        if case let .settingsSection(section, _) = route, section != .profile, paths[selectedTab]?.last != .settings {
            paths[selectedTab, default: []].append(.settings)
        }
        paths[selectedTab, default: []].append(route)
    }

    /// 当前账号可见的标签（由 MainTabView 按权限写入）
    var availableTabs: Set<MainTab> = Set(MainTab.allCases)

    /// 打开 Web 站内链接；解析失败返回 false
    @discardableResult
    func open(webPath: String) -> Bool {
        // 站内播放链接：/play/... 直接起播；/s/{slug}/play/... 先开分享页，读到影片后由分享页接着起播
        if let request = PlayRequest(webPath: webPath) {
            if let slug = request.shareSlug {
                pendingSharePlay = request
                open(.share(slug: slug))
            } else {
                play(request)
            }
            return true
        }
        guard var route = AppRoute(webPath: webPath) else { return false }
        // 「/」对成员同样收敛到媒体库（Web accessiblePathFor：成员的 / → /library）
        if let permissions, !permissions.isAdmin, URLComponents(string: webPath)?.path.split(separator: "/").isEmpty ?? false {
            route = .libraryHome
        }
        open(route)
        return true
    }

    func pop() {
        _ = paths[selectedTab]?.popLast()
    }

    /// 从结果页回到搜索首页改词重搜：结果页正压在搜索首页上面就退回去，否则（订阅页手动选种、
    /// 深链等别处直达的结果页）在上面新开一个搜索首页。回填内容经 `searchDraft` 交给搜索首页
    func editSearch(_ draft: SearchDraft) {
        searchDraft = draft
        var path = paths[selectedTab] ?? []
        if path.count >= 2, case .searchHome = path[path.count - 2] {
            path.removeLast()
        } else {
            path.append(.searchHome(mode: draft.mode))
        }
        paths[selectedTab] = path
    }

    func popToRoot() {
        paths[selectedTab] = []
    }

    func play(_ request: PlayRequest) {
        playRequestedAt = .now
        player = request
        startPlaybackEarly?(request)
    }

    /// 最近一次点播放的时刻：起播分段计时从这里算起（含播放器弹出与视图搭建，见 `StartupTrace`）
    @ObservationIgnored private(set) var playRequestedAt: ContinuousClock.Instant?

    /// 点下播放就建好控制器、发出起播请求，不等全屏播放器弹出：冷启动后第一次弹出到视图出现约 100 毫秒（真机），
    /// 起播协商用不着视图。会话回来时主线程常常还在搭播放器界面（第一次约 140 毫秒），所以省下多少取决于界面多重：
    /// 界面热了（同一进程再次打开）请求一回来就能装载引擎。由持有 API 客户端的根视图设置；
    /// 控制器登记在 `activePlayback`，播放器视图出现时接过去（见 `PlayerScreen`）
    @ObservationIgnored var startPlaybackEarly: ((PlayRequest) -> Void)?

    /// 待起播的访客播放链接（`/s/{slug}/play/...`）：分享页读到影片（必要时先过密码）后取走并起播
    var pendingSharePlay: PlayRequest?

    func present(_ sheet: AppSheet) {
        self.sheet = sheet
    }

    /// 切到标签根时附带的参数（活动页的 view、发现页的电影/剧集），由对应根页面读取后清空
    struct RootParameter: Equatable {
        var tab: MainTab
        var value: String
        let id = UUID()
    }

    var rootParameter: RootParameter?

    /// 记下标签根路由携带的参数
    private func rememberRootParameter(of route: AppRoute) {
        switch route {
        // 活动页不带 view 也要下发（空串）：Web 缺省/非法 view 一律回到「观看 · 正在播放」
        case let .activity(view): rootParameter = RootParameter(tab: .activity, value: view ?? "")
        case let .discover(kind): rootParameter = RootParameter(tab: .discover, value: kind)
        default: break
        }
    }

    /// 标签根页面对应的路由不压栈，而是切标签
    private static func tabRoot(of route: AppRoute) -> MainTab? {
        switch route {
        case .discover: .discover
        case .libraryHome: .library
        case .subscriptions: .subscriptions
        case .activity: .activity
        case .my: .more
        default: nil
        }
    }
}
