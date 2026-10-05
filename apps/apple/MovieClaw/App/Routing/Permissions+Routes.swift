import Foundation

/// 路由级的权限判断（`Router.guarded` 用）。依赖 iPhone 的路由表，所以放在 iPhone 界面层；
/// `Permissions` 本身在 Shared/，Apple TV 版按自己的入口另行裁剪（docs/design/tvos-app.md §3）。
extension Permissions {
    /// 同 Web `accessiblePathFor`：成员进不了的页面落回媒体库。
    /// 搜索页不在此拦：入口口径是「任一分区可用」（见 SearchAccess.canOpenSearch），媒体库分区要异步
    /// 查可见库才知道；没有任何可用分区时搜索页自己显示「无权限」
    func allows(_ route: AppRoute) -> Bool {
        switch route {
        case .newSession, .session, .activity, .activityPage: isAdmin
        case .subscriptions, .subscription, .subscriptionWall: canSubscribe
        case let .settingsSection(section, _): isAdmin || section.memberVisible
        case .libraryManage: isAdmin
        default: true
        }
    }
}
