import SwiftUI

/// 路由 → 页面的唯一映射表。
///
/// 每个页面类型的名字和入参在这里固定下来，各模块在自己的目录里实现同名 View；
/// 这样并行开发的模块之间不需要改同一个文件。
///
/// 返回类型擦除成 AnyView：写成 `some View` 时，返回类型是把三十来个页面层层套进 `_ConditionalContent`
/// 的一个巨型泛型，每个页签的导航栈第一次建起来（冷启动落地页就在其中）都要为它实例化类型元数据、
/// 逐个做协议一致性检查——等于启动时把全部页面的类型过一遍。擦除后各页面只在真正打开时才实例化
extension AppRoute {
    var destination: AnyView {
        AnyView(page)
    }

    @ViewBuilder
    private var page: some View {
        switch self {
        // 发现
        case let .discover(kind): DiscoverView(kind: kind)
        case let .discoverCollection(kind, provider, collectionId):
            DiscoverCollectionView(kind: kind, provider: provider, collectionId: collectionId)
        case let .mediaDetail(titleRef): MediaDetailView(titleRef: titleRef)
        case let .person(tmdbId): PersonDetailView(tmdbId: tmdbId)
        case let .discoveredPerson(tmdbId): DiscoveredPersonView(tmdbId: tmdbId)
        // 媒体库
        case .libraryHome: LibraryHomeView()
        // Router 把它改成弹出表单（AppSheet.customizeHome），不会真的压栈到这里；页面自带导航栈，所以不能压栈
        case .libraryCustomize: LibraryCustomizeView()
        case .favorites: FavoritesView()
        case .allCollections: AllCollectionsView()
        case let .collection(libraryId, collectionId): CollectionDetailView(libraryId: libraryId, collectionId: collectionId)
        case let .library(id, view, pending):
            LibraryDetailView(libraryId: id, initialView: view.flatMap(LibraryDetailView.WallView.init(rawValue:)) ?? .items, openPending: pending)
        case let .libraryKind(kind, genre): LibraryKindWallView(kind: kind, genre: genre)
        case let .libraryItem(libraryId, itemId, season, episode):
            LibraryItemDetailView(libraryId: libraryId, itemId: itemId, season: season, episode: episode)
        case let .libraryManage(create, tab, item): LibraryManageView(openCreate: create, initialTab: tab, initialItemId: item)
        case .reels: ReelsView()
        // 搜索
        case let .searchHome(mode): SearchHomeView(initialMode: mode)
        case let .search(query): SearchResultsView(query: query)
        // 订阅
        case .subscriptions: SubscriptionsView()
        case let .subscription(id, upgradeRun): SubscriptionDetailView(subscriptionId: id, openUpgradeRun: upgradeRun)
        case let .subscriptionWall(kind): SubscriptionWallView(kind: kind)
        // 活动
        case .activity: ActivityView()
        case let .activityPage(page): ActivityPageView(page: page)
        // AI 会话
        case .newSession: AgentNewSessionView()
        case let .session(id): AgentConversationView(sessionId: id)
        // 我的 / 设置
        case .my: MorePage()
        case .settings: SettingsIndexView()
        case let .settingsSection(section, query): SettingsSectionView(section: section).environment(\.routeQuery, query)
        // Router 把它改成全屏呈现，不会真的压栈；这里只为穷举
        case let .deviceApproval(code, scannedHost): DeviceApprovalFlow(launch: DeviceApprovalLaunch(code: code, host: scannedHost))
        // 分享
        case let .share(slug): SharePageView(slug: slug)
        }
    }
}

extension AppSheet {
    @ViewBuilder
    var content: some View {
        switch self {
        case let .subscribe(request): SubscribeSheet(request: request)
        case .accountSwitcher: AccountSwitcherSheet()
        case .customizeHome: LibraryCustomizeView()
        }
    }
}
