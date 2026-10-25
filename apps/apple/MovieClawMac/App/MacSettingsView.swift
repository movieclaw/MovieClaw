import SwiftUI

/// 设置窗口（菜单「MovieClaw › 设置…」⌘,）：目前只有「通用 › 软件更新」，以后别的设置往这里放。
/// 开关存在 Sparkle 自己的偏好设置里（MacUpdater 镜像），商店版、开发版只写一句由谁负责更新。
struct MacSettingsView: View {
    var body: some View {
        TabView {
            MacGeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 520)
    }
}

private struct MacGeneralSettings: View {
    @Bindable private var updater = MacUpdater.shared

    var body: some View {
        Form {
            Section("软件更新") {
                switch updater.channel {
                case .sparkle:
                    Toggle(isOn: $updater.automaticallyChecks) {
                        Text("自动检查更新")
                        Text("每天一次，只向官网查询最新版本")
                    }
                    Toggle(isOn: $updater.automaticallyDownloads) {
                        Text("自动下载并在退出时安装")
                        Text("关掉后，有新版本时会先问你")
                    }
                    .disabled(!updater.automaticallyChecks)
                    LabeledContent {
                        Button(updater.primaryTitle) { updater.primaryAction() }
                    } label: {
                        Text("MovieClaw \(MacAboutView.versionText)")
                        Text(updater.statusText)
                    }
                    .accessibilityIdentifier("mac-settings-update")
                case .store:
                    Text("这份 App 通过 TestFlight 安装，更新由 TestFlight 负责。")
                        .foregroundStyle(.secondary)
                case .none:
                    Text("开发版不检查更新。")
                        .foregroundStyle(.secondary)
                }
                Link("在 GitHub 查看所有 Mac 版发布",
                     destination: URL(string: "https://github.com/movieclaw/MovieClaw/releases?q=macos-v&expanded=true")!)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
