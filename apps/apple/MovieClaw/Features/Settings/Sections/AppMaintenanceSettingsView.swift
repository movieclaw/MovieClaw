import SwiftUI

/// 更新是首页主任务；缓存和定时任务按层级进入，保留旧链接的 tab 参数。
struct AppMaintenanceSettingsView: View {
    enum Destination: String, Identifiable { case storage, tasks; var id: String { rawValue } }
    @Environment(\.routeQuery) private var routeQuery
    @State private var destination: Destination?
    @State private var routeQueryConsumed = false

    var body: some View {
        AppUpdatePanel {
            SettingsFormSection("维护工具") {
                Button { destination = .storage } label: {
                    maintenanceRow("缓存管理", icon: "internaldrive")
                }.accessibilityIdentifier("app-storage")
                Button { destination = .tasks } label: {
                    maintenanceRow("定时任务", icon: "clock")
                }.accessibilityIdentifier("app-tasks")
            }
        }
        .appBackground()
        .navigationDestination(item: $destination) { value in
            Group {
                switch value {
                case .storage: AppStoragePanel().navigationTitle("缓存管理")
                case .tasks: ScheduledTasksPanel().navigationTitle("定时任务")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .appBackground()
        }
        .onAppear {
            guard !routeQueryConsumed else { return }
            routeQueryConsumed = true
            destination = routeQuery["tab"].flatMap(Destination.init(rawValue:))
        }
    }

    private func maintenanceRow(_ title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }
}
