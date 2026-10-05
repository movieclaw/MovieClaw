import SwiftUI

/// 让页面接入订阅索引：出现时确保已加载；订阅弹层关闭后自动刷新（订阅/取消订阅后卡片状态即时同步）。
struct SubscriptionIndexTracker: ViewModifier {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        content
            // 以「权限 + 账号」为任务标识：冷启动直达（深链、通知）时页面可能先于登录态/权限就绪出现，
            // 只跑一次会被权限守卫挡掉、整页都当成「未订阅」
            .task(id: "\(permissions.canSubscribe)|\(model.session?.username ?? "")") {
                guard permissions.canSubscribe else { return }
                await SubscriptionIndex.shared.ensureLoaded(api: api, owner: model.session?.username)
            }
            .onChange(of: router.sheet == nil) { _, closed in
                guard closed, permissions.canSubscribe else { return }
                Task { await SubscriptionIndex.shared.refresh(api: api, owner: model.session?.username) }
            }
    }
}

extension View {
    /// 页面接入全站订阅状态索引（见 `SubscriptionIndex`）
    func tracksSubscriptionIndex() -> some View { modifier(SubscriptionIndexTracker()) }
}
