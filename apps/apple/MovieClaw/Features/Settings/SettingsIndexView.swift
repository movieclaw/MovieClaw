import SwiftUI

/// 设置首页：分区列表（Web 手机端 /settings，components/settings-index.tsx）。
/// App 里叫「服务器设置」：这里改的都是服务器上的配置（对所有设备生效），与 App 本机偏好区分开。
/// 成员只看到「设备」（自己的设备；「个人信息」走「我的」页头像卡，不在这里列）；空标题的组（概览）不渲染组头。
/// 最底部是人人可见的「关于 MovieClaw」。
struct SettingsIndexView: View {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 28
    @State private var cardTitleVisible = true
    @State private var scrollTopInset: CGFloat = 0

    var body: some View {
        sections
        .navigationTitle("服务器设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: cardTitleVisible ? .title : nil)
        .appBackground()
    }

    private var introduction: some View {
        HStack(spacing: 16) {
            Image("MovieClawLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("服务器设置")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settings-title")
                    .onGeometryChange(for: Bool.self) {
                        $0.frame(in: .named("settings-list")).maxY > scrollTopInset
                    } action: { cardTitleVisible = $0 }
                Text("当前服务器：\(api.server.hostLabel)\n修改将保存到这台服务器。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-description")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var sections: some View {
        List {
            SettingsFormSection {
                introduction
                    .listRowInsets(EdgeInsets())
            }
            ForEach(SettingsSection.groups, id: \.title) { group in
                let items = group.items.filter { $0.availableInApp && (permissions.isAdmin || $0.memberVisible) }
                if !items.isEmpty {
                    SettingsFormSection {
                        ForEach(items) { section in
                            NavigationLink(value: AppRoute.settingsSection(section)) {
                                Label {
                                    Text(section.title)
                                } icon: {
                                    Image(systemName: section.systemImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: iconColumn, height: iconSize)
                                        .frame(width: iconColumn, height: iconColumn)
                                        .offset(x: 4)
                                }
                            }
                            .accessibilityIdentifier("settings-\(section.rawValue)")
                        }
                    } header: {
                        if !group.title.isEmpty { Text(group.title) }
                    }
                }
            }
            // 版本、开源许可与数据来源声明（上架必需，人人可见）：低频，放在最底部（原在「我的」页，用户认为太重）
            SettingsFormSection {
                NavigationLink {
                    AboutView()
                } label: {
                    Label {
                        Text("关于 MovieClaw")
                    } icon: {
                        Image(systemName: "info.circle")
                            .resizable()
                            .scaledToFit()
                            .frame(width: iconColumn, height: iconSize)
                            .frame(width: iconColumn, height: iconColumn)
                            .offset(x: 4)
                    }
                }
                .accessibilityIdentifier("settings-about")
            }
        }
        .coordinateSpace(name: "settings-list")
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in
            scrollTopInset = inset
        }
    }
}
