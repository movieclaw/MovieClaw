import SwiftUI

/// 设置分区 → 分区页面的派发（每个分区一个 View，由设置模块实现）。
/// 成员打开管理员分区时改为显示「个人信息」（Web settings-view 把越权分区 replace 到 /settings/profile；
/// 路由层 Router.guarded 已先改道，这里兜住直接构造本页的情况）。
struct SettingsSectionView: View {
    let section: SettingsSection
    @Environment(\.permissions) private var permissions

    var body: some View {
        let effective = permissions.isAdmin || section.memberVisible ? section : .profile
        sectionView(effective)
            .navigationTitle(effective.title)
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sectionView(_ section: SettingsSection) -> some View {
        switch section {
        case .profile: ProfileSettingsView()
        case .members: MembersSettingsView()
        case .devices: DevicesSettingsView()
        case .notifications: NotificationSettingsView()
        case .overview, .subscription, .sites, .downloaders, .importWatch, .appPush: WebManagedSectionView(section: section)
        case .scrape: ScrapeSettingsView()
        case .playback: PlaybackSettingsView()
        case .imPush: PushSettingsView()
        case .webhook: WebhookSettingsView()
        case .llm: LLMSettingsView()
        case .mcp: MCPSettingsView()
        case .ai: AIDefaultsSettingsView()
        case .cloud: CloudSettingsView()
        case .app: AppMaintenanceSettingsView()
        case .network: NetworkSettingsView()
        case .logs: LogsSettingsView()
        }
    }
}

/// App 不提供的分区（见 SettingsSection.availableInApp）：说明去网页端管理，并给出直达网页对应分区的按钮。
/// 其他页面里「去站点设置」「去下载器设置」之类的跳转都落到这里，不会打开被隐藏的配置页。
private struct WebManagedSectionView: View {
    let section: SettingsSection
    @Environment(\.api) private var api

    var body: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.systemImage)
        } description: {
            Text("这一项请在网页端的「设置 → \(section.title)」里管理。")
        } actions: {
            Link(destination: api.server.origin.appending(path: "settings/\(section.rawValue)")) {
                Label("在浏览器中打开", systemImage: "safari")
            }
            .buttonStyle(.bordered)
        }
        .appBackground()
    }
}
