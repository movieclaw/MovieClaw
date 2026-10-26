import SwiftUI

/// 设置窗口（菜单「MovieClaw › 设置…」⌘,）：目前只有「通用」（语言、软件更新），以后别的设置往这里放。
/// 开关存在 Sparkle 自己的偏好设置里（MacUpdater 镜像），商店版、开发版只写一句由谁负责更新。
struct MacSettingsView: View {
    var body: some View {
        TabView {
            MacGeneralSettings()
                .tabItem { Label(String(localized: .settingsMacUpdateGeneralTab), systemImage: "gearshape") }
        }
        .frame(width: 520)
    }
}

private struct MacGeneralSettings: View {
    @Bindable private var updater = MacUpdater.shared

    var body: some View {
        Form {
            MacLanguageSection()
            Section(String(localized: .settingsMacUpdateSection)) {
                switch updater.channel {
                case .sparkle:
                    Toggle(isOn: $updater.automaticallyChecks) {
                        Text(String(localized: .settingsMacUpdateAutoCheck))
                        Text(String(localized: .settingsMacUpdateAutoCheckHint))
                    }
                    Toggle(isOn: $updater.automaticallyDownloads) {
                        Text(String(localized: .settingsMacUpdateAutoInstall))
                        Text(String(localized: .settingsMacUpdateAutoInstallHint))
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
                    Text(String(localized: .settingsMacUpdateTestFlight))
                        .foregroundStyle(.secondary)
                case .none:
                    // GitHub 版还没装进「应用程序」时也是这里（正显示安装引导）
                    Text(MacInstallLocation.problem == nil ? String(localized: .settingsMacUpdateDevelopment) : String(localized: .settingsMacUpdateNeedsApplications))
                        .foregroundStyle(.secondary)
                }
                Link(String(localized: .settingsMacUpdateAllReleases),
                     destination: URL(string: "https://github.com/movieclaw/MovieClaw/releases?q=macos-v&expanded=true")!)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
