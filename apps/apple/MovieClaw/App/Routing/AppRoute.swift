import SwiftUI

/// App 内所有可压栈的页面，与 Web 路由一一对应（见 docs/design/ios-app/parity-inventory.md）。
///
/// 设计要点：
/// - 路由是**纯数据**（Hashable），放进 NavigationStack 的 path；页面由 `AppRoute.destination` 统一映射，
///   各模块只实现自己的 View，不改这里的枚举——并行开发时互不冲突；
/// - `init?(webPath:)` 能把后端/网页里的站内链接（通知跳转、AI 卡片、订阅详情里的链接）
///   解析成原生路由，避免到处手拼；
/// - 标签页根页面（发现、媒体库首页、订阅列表、活动、更多）不作为路由压栈，由 MainTabView 直接承载；
///   但它们也有对应 case，便于从别处「切到某个标签并定位」。
enum AppRoute: Hashable {
    // MARK: 发现
    /// /discover/{movie|tv}（标签根）
    case discover(kind: String = "movie")
    /// /discover/{type}/collections/{provider}/{collectionId}
    case discoverCollection(kind: String, provider: String, collectionId: String)
    /// /media/{type}/{id} 或 /media/douban/{id}；titleRef 形如 `tmdb:movie:123` / `douban:tv:456`
    case mediaDetail(titleRef: String)
    /// /people/{id}：库内影人
    case person(tmdbId: Int)
    /// /discover/people/{id}：TMDB 影人
    case discoveredPerson(tmdbId: Int)

    // MARK: 媒体库
    /// /library（标签根）
    case libraryHome
    case libraryCustomize
    case favorites
    case allCollections
    /// /library/{id}/c/{cid} 或 /library/c/{cid}
    case collection(libraryId: Int?, collectionId: Int)
    /// /library/{id}?view=collections&pending=1：view 为合集视图，pending 为进页即开待处理抽屉
    case library(id: Int, view: String? = nil, pending: Bool = false)
    /// /library/kind/{movie|tv|video}?g={TMDB genre id}：按类型的跨库海报墙（首页「全部电影」行的查看全部）；
    /// 带 genre 是首页「按类型找电影 / 剧集」色块的落点，墙按这个 TMDB 类型筛好
    case libraryKind(kind: String, genre: Int? = nil)
    /// /library/{id}/item/{mediaItemId}?season=&episode=
    case libraryItem(libraryId: Int, itemId: Int, season: Int? = nil, episode: Int? = nil)
    /// /library/manage?create=1&tab=duplicates&item={mediaItemId}
    case libraryManage(create: Bool = false, tab: String? = nil, item: Int? = nil)
    /// /library/reels：片段（上下滑动看片段，docs/design/reels.md）。App 独有，网页暂时没有
    case reels

    // MARK: 搜索
    /// 搜索首页（输入框 + 模式 + 最近搜索，对应 Web 的搜索命令面板，没有网页地址）：
    /// 各标签根页右上角的放大镜压栈打开，结果页接着压在同一个栈里。
    /// mode = 进页时预选的模式（媒体库页签进来预选「媒体库」），nil = 沿用上次记住的模式
    case searchHome(mode: SearchVertical? = nil)
    /// /search?q=&tab=&scope=&snapshot=&for_sub=
    case search(SearchQuery)

    // MARK: 订阅
    /// /subscriptions（标签根）
    case subscriptions
    /// /subscriptions/{id}?upgrade-run=1
    case subscription(id: Int, upgradeRun: Bool = false)
    /// 订阅首页「剧集订阅 ›」「电影订阅 ›」压栈的完整海报墙（kind = tv / movie）；
    /// App 独有的二级页，网页的订阅页本身就是海报墙，没有对应地址
    case subscriptionWall(kind: String)

    // MARK: 活动（管理员）
    /// /activity?view=（标签根）：view 点名二级页（plays / stats / history / active）时，总览会接着压栈打开它
    case activity(view: String? = nil)
    /// 活动页的二级页（进行中全部 / 已结束 / 刷流做种 / 最近播放 / 观看统计），从总览分组标题的「查看全部」压栈
    case activityPage(ActivityPage)

    // MARK: AI 会话（管理员）
    case newSession
    case session(id: String)

    // MARK: 我的 / 设置
    case my
    /// /my/downloads：下载（「我的」里的入口与页面都叫「下载」；docs/design/offline-download.md §8）
    case offlineStorage
    case settings
    /// /settings/{section}?…：query 原样透传给分区页（如 /settings/app?tab=storage、
    /// /settings/downloaders?limits=… 的预填与直达），分区页经 `@Environment(\.routeQuery)` 读取
    case settingsSection(SettingsSection, query: [String: String] = [:])
    /// /activate?code=…：批准设备登录（独立页，「我的」页右上角扫码直达）。
    /// scannedHost 是扫到的二维码里的服务器，查不到请求时用来提示「设备连的可能是另一台服务器」
    case deviceApproval(code: String? = nil, scannedHost: String? = nil)

    // MARK: 分享（访客页）
    case share(slug: String)

    /// 搜索页参数（对应 /search 的查询串）
    struct SearchQuery: Hashable {
        var q: String = ""
        /// 同搜词：与 q 一起搜、结果按站点合并（详情页「搜索资源」带上英文名/原名，同 Web 的 also 参数）
        var also: [String] = []
        /// media | torrents | library；nil 表示按权限取第一个可用分区
        var tab: String?
        var scope: String?
        var snapshot: Int?
        /// 手动选种模式：选中的种子直接投给这个订阅
        var forSubscription: Int?
    }
}

/// 设置分区（顺序与分组同 Web `lib/mock-data.ts` 的 settingsSectionGroups）。
/// 网页的「外观」分区（主题、背景图、界面质感、导航顺序）只设置网页本身，App 不提供（用户决定，
/// 已接受的平台差异）；`/settings/appearance` 深链因此落到设置首页。
enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case overview, profile
    case members, devices, notifications
    case subscription, sites, downloaders, importWatch = "import-watch"
    case scrape, playback
    case appPush = "app-push", imPush = "im-push", webhook, llm, mcp, ai
    case cloud, app, network, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: .settingsOverviewTitle)
        case .profile: String(localized: .settingsProfileTitle)
        case .members: String(localized: .settingsMembersTitle)
        case .devices: String(localized: .settingsDevicesTitle)
        case .notifications: String(localized: .settingsNotificationsTitle)
        case .subscription: String(localized: .settingsSubscriptionTitle)
        case .sites: String(localized: .settingsSitesTitle)
        case .downloaders: String(localized: .settingsDownloadersTitle)
        case .importWatch: String(localized: .settingsImportWatchTitle)
        case .scrape: String(localized: .settingsScrapeTitle)
        case .playback: String(localized: .settingsPlaybackTitle)
        case .appPush: String(localized: .settingsAppPushTitle)
        case .imPush: String(localized: .settingsImPushTitle)
        case .webhook: String(localized: .settingsWebhookTitle)
        case .llm: String(localized: .settingsLlmTitle)
        case .mcp: String(localized: .settingsMcpTitle)
        case .ai: String(localized: .settingsAiTitle)
        case .cloud: String(localized: .settingsCloudTitle)
        case .app: String(localized: .settingsAppTitle)
        case .network: String(localized: .settingsNetworkTitle)
        case .logs: String(localized: .settingsLogsTitle)
        }
    }

    var subtitle: String {
        switch self {
        case .overview: String(localized: .settingsOverviewAppDescription)
        case .profile: String(localized: .settingsProfileAppDescription)
        case .members: String(localized: .settingsMembersAppDescription)
        case .devices: String(localized: .settingsDevicesAppDescription)
        case .notifications: String(localized: .settingsNotificationsAppDescription)
        case .subscription: String(localized: .settingsSubscriptionAppDescription)
        case .sites: String(localized: .settingsSitesAppDescription)
        case .downloaders: String(localized: .settingsDownloadersAppDescription)
        case .importWatch: String(localized: .settingsImportWatchAppDescription)
        case .scrape: String(localized: .settingsScrapeAppDescription)
        case .playback: String(localized: .settingsPlaybackAppDescription)
        case .appPush: String(localized: .settingsAppPushAppDescription)
        case .imPush: String(localized: .settingsImPushAppDescription)
        case .webhook: String(localized: .settingsWebhookAppDescription)
        case .llm: String(localized: .settingsLlmAppDescription)
        case .mcp: String(localized: .settingsMcpAppDescription)
        case .ai: String(localized: .settingsAiAppDescription)
        case .cloud: String(localized: .settingsCloudAppDescription)
        case .app: String(localized: .settingsAppAppDescription)
        case .network: String(localized: .settingsNetworkAppDescription)
        case .logs: String(localized: .settingsLogsAppDescription)
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .profile: "person.crop.circle"
        case .members: "person.2.badge.key"
        case .devices: "laptopcomputer.and.iphone"
        case .notifications: "bell.badge"
        case .subscription: "bookmark"
        case .sites: "server.rack"
        case .downloaders: "arrow.down.circle"
        case .importWatch: "folder.badge.gearshape"
        case .scrape: "photo.on.rectangle"
        case .playback: "play.rectangle"
        case .appPush: "app.badge"
        case .imPush: "bubble.left.and.bubble.right"
        case .webhook: "paperplane"
        case .llm: "sparkles"
        case .mcp: "powerplug"
        case .ai: "wand.and.stars"
        case .cloud: "cloud"
        case .app: "gearshape.2"
        case .network: "globe"
        case .logs: "terminal"
        }
    }

    /// 成员能看到「个人信息」「设备」（自己的设备）与「通知」（自己收什么），其余分区仅超级管理员可见
    var memberVisible: Bool { self == .profile || self == .devices || self == .notifications }

    /// App 不提供的分区：资源与下载的配置（订阅规则、资源站点、下载器、自动入库）是部署时一次性的
    /// 服务器配置，表单大、要拖拽排序和多步联调，与 Android 版一样只在网页端管理；资源搜索、订阅、
    /// 下载任务等日常功能 App 里照常提供。「概览」同理：它的主体是订阅链路体检（站点 / 下载器是否配齐），
    /// 一并交给网页端。
    /// 「App 推送」（推送通道与自建中继）表单多、低频，也只在网页端管理（docs/design/cloud-push.md §1）。
    /// 设置首页不列出；其他页面写死的跳转与深链照常解析，分区页显示「请在网页端管理」
    var availableInApp: Bool {
        ![.overview, .subscription, .sites, .downloaders, .importWatch, .appPush].contains(self)
    }

    /// 分组（空标题的组不渲染组头）。「个人信息」不列在设置目录里：「我的」页顶部的头像卡
    /// 就是它的入口（2026-09-27 用户要求去掉重复入口），分区本身与 /settings/profile 深链照旧可用
    static var groups: [(title: String, items: [SettingsSection])] { [
        ("", [.overview]),
        // 「设备」「通知」人人可用（成员看自己的设备、管自己收什么）；「个人信息」走「我的」页头像卡。
        // 「成员」并进这一组（原先各自单成一组、每组只有一行，2026-09-29 用户要求合并）；成员身份只看得到前两项
        (String(localized: .settingsGroupsAccount), [.devices, .notifications, .members]),
        (String(localized: .settingsGroupsDownloads), [.subscription, .sites, .downloaders, .importWatch]),
        (String(localized: .settingsGroupsLibrary), [.scrape, .playback]),
        (String(localized: .settingsGroupsIntegrations), [.appPush, .imPush, .webhook, .llm, .mcp, .ai]),
        // 「MovieClaw Cloud」：整台服务器连到管理员的 MovieClaw 账号（docs/design/cloud-push.md §1）
        (String(localized: .settingsGroupsSystem), [.cloud, .app, .network, .logs]),
    ] }
}

// MARK: - 站内链接解析

extension AppRoute {
    /// 把 Web 站内路径（可带查询串）解析成原生路由。无法识别返回 nil。
    /// 覆盖 Web 端所有页面，外加旧地址的重定向（/tasks、/settings/search 等）。
    init?(webPath raw: String) {
        guard let components = URLComponents(string: raw.hasPrefix("/") ? raw : "/\(raw)") else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        func int(_ s: String?) -> Int? { s.flatMap { Int($0) } }

        switch parts.first {
        case nil:
            self = .discover()
        case "discover":
            if parts.count >= 3, parts[1] == "people", let id = int(parts[2]) {
                self = .discoveredPerson(tmdbId: id)
            } else if parts.count >= 5, parts[2] == "collections" {
                self = .discoverCollection(kind: parts[1], provider: parts[3], collectionId: parts[4])
            } else if parts.count == 3, parts[1] == "movie", parts[2] == "top250" {
                self = .discoverCollection(kind: "movie", provider: "douban", collectionId: "movie_top250")
            } else if parts.count == 3, parts[1] == "movie", parts[2] == "high-score" {
                self = .discoverCollection(kind: "movie", provider: "douban", collectionId: "movie_high_score")
            } else {
                let kind = parts.count > 1 ? parts[1] : "movie"
                // 筛选/数据源参数随类型一起带过去（「地址即状态」，见 DiscoverViewpoint）
                if let q = components.percentEncodedQuery, !q.isEmpty {
                    self = .discover(kind: "\(kind)?\(q)")
                } else {
                    self = .discover(kind: kind)
                }
            }
        case "media":
            guard parts.count >= 3 else { return nil }
            self = parts[1] == "douban" ? .mediaDetail(titleRef: "douban:\(parts[2])") : .mediaDetail(titleRef: "tmdb:\(parts[1]):\(parts[2])")
        case "people":
            guard parts.count >= 2, let id = int(parts[1]) else { return nil }
            self = .person(tmdbId: id)
        case "library":
            if parts.count == 1 { self = .libraryHome; return }
            switch parts[1] {
            case "customize": self = .libraryCustomize
            case "favorites": self = .favorites
            case "reels": self = .reels
            case "collections": self = .allCollections
            case "kind":
                guard parts.count >= 3, HomeRows.mediaKinds.contains(parts[2]) else { return nil }
                self = .libraryKind(kind: parts[2], genre: int(query["g"]))
            case "manage": self = .libraryManage(create: query["create"] == "1", tab: query["tab"], item: int(query["item"]))
            case "c":
                guard parts.count >= 3, let cid = int(parts[2]) else { return nil }
                self = .collection(libraryId: nil, collectionId: cid)
            default:
                guard let lib = int(parts[1]) else { return nil }
                if parts.count >= 4, parts[2] == "item", let item = int(parts[3]) {
                    self = .libraryItem(libraryId: lib, itemId: item, season: int(query["season"]), episode: int(query["episode"]))
                } else if parts.count >= 4, parts[2] == "c", let cid = int(parts[3]) {
                    self = .collection(libraryId: lib, collectionId: cid)
                } else {
                    self = .library(id: lib, view: query["view"], pending: query["pending"] == "1")
                }
            }
        case "search":
            // 网页把搜索范围拆成 label/cats/sites/poster/private/browse 多个参数，折叠成一个 scope 串
            let scopeKeys: Set<String> = ["label", "cats", "sites", "poster", "private", "browse"]
            let scopeParams = query.filter { scopeKeys.contains($0.key) }
            self = .search(.init(
                q: query["q"] ?? "", tab: query["tab"],
                scope: query["scope"] ?? (scopeParams.isEmpty ? nil : SearchScope.encode(fromWebQuery: scopeParams)),
                snapshot: int(query["snapshot"]), forSubscription: int(query["for_sub"])
            ))
        case "subscriptions":
            if parts.count >= 2, let id = int(parts[1]) {
                self = .subscription(id: id, upgradeRun: query["upgrade-run"] == "1")
            } else {
                self = .subscriptions
            }
        case "activity", "tasks":
            self = .activity(view: query["view"])
        case "new":
            self = .newSession
        case "sessions":
            guard parts.count >= 2 else { return nil }
            self = .session(id: parts[1])
        case "my":
            self = parts.count >= 2 && parts[1] == "downloads" ? .offlineStorage : .my
        case "activate":
            self = .deviceApproval(code: query["code"])
        case "settings":
            guard parts.count >= 2 else { self = .settings; return }
            switch parts[1] {
            case "search": self = .settingsSection(.sites)
            case "about": self = .settingsSection(.app)
            case "app" where query["tab"] == "remote": self = .settingsSection(.playback)
            // 旧版服务端发给设备的批准链接：批准已独立成 /activate
            case "devices" where !(query["code"] ?? "").isEmpty: self = .deviceApproval(code: query["code"])
            default:
                guard let section = SettingsSection(rawValue: parts[1]) else { self = .settings; return }
                self = .settingsSection(section, query: query)
            }
        case "s":
            guard parts.count >= 2 else { return nil }
            self = .share(slug: parts[1])
        default:
            return nil
        }
    }

    /// 该路由归属的标签页（切标签定位用）
    /// nil = 不属于任何标签（搜索、设置、AI 会话、分享等），在当前标签打开
    var tab: MainTab? {
        switch self {
        case .discover, .discoverCollection, .mediaDetail, .person, .discoveredPerson: .discover
        case .libraryHome, .libraryCustomize, .favorites, .allCollections, .collection, .library, .libraryKind, .libraryItem, .libraryManage, .reels: .library
        case .subscriptions, .subscription, .subscriptionWall: .subscriptions
        case .activity, .activityPage: .activity
        case .my, .offlineStorage: .more
        case .searchHome, .search, .newSession, .session, .settings, .settingsSection, .deviceApproval, .share: nil
        }
    }
}
