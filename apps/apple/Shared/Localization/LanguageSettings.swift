import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS) || os(macOS)
struct AppLanguageSettings: View {
    var body: some View {
        Button(action: openSettings) {
            HStack {
                Label(.settingsAppearanceLanguage, systemImage: "globe")
                Spacer()
                Text(verbatim: AppLanguage.name).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("app-language-settings")
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
#endif

#if os(macOS)
/// 设置窗口「通用」里的语言一节（Mac 的语言在系统设置里按 App 选，这里只是入口）
struct MacLanguageSection: View {
    var body: some View {
        Section {
            AppLanguageSettings()
        } header: {
            Text(.settingsAppearanceGeneral)
        } footer: {
            Text(.settingsAppearanceMacHint)
        }
    }
}
#endif
